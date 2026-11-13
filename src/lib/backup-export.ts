import {createLibraryBackup} from "./backup";
import {parseStoredPlaylists} from "./playlist-storage";
import {listTracks, type Track} from "./tracks";

const RECOVERY_KEYS=["mp3-shelf-restore-pending","mp3-shelf-delete-recovery"];

/** Export durable data, never a potentially stale tab's rendered library.
 * This detects playlist/recovery changes across the asynchronous IDB read;
 * it is not an atomic transaction spanning IndexedDB and localStorage. */
export async function createStoredLibraryBackup(
 storage:Pick<Storage,"getItem">,
 key:string,
 loadTracks:()=>Promise<Track[]>=listTracks
):Promise<Blob>{
 const assertNoRecovery=()=>{
  if(RECOVERY_KEYS.some(name=>storage.getItem(name)!==null))
   throw new Error("Finish pending library recovery before exporting a backup.");
 };
 assertNoRecovery();
 const baseline=storage.getItem(key);
 const playlists=parseStoredPlaylists(baseline);
 const tracks=await loadTracks();
 const assertSnapshot=()=>{
  assertNoRecovery();
  if(storage.getItem(key)!==baseline)
   throw new Error("Playlists changed while preparing the backup. Retry export.");
 };
 assertSnapshot();
 // Validate metadata/references before scanning any payload. Blob construction
 // alone does not read file-backed data: an inaccessible original can otherwise
 // produce a "ready" archive whose download fails later in the browser.
 const sample=async(blob:Blob):Promise<string>=>{
  // Bound additional I/O for large libraries while detecting common
  // same-size media replacements that metadata-only comparisons miss.
  const window=64*1024;
  // Small and medium recordings can be checked completely with bounded
  // per-read memory. Three probes alone miss edits between sampled regions.
  // Large recordings retain bounded I/O to avoid doubling multi-GB exports.
  const offsets:number[]=[];
  if(blob.size<=1024*1024){
   for(let offset=0;offset<blob.size;offset+=window)offsets.push(offset);
  }else{
   offsets.push(0,Math.floor((blob.size-window)/2),blob.size-window);
  }
  let hash=2166136261;
  for(const offset of offsets){
   const bytes=new Uint8Array(await blob.slice(offset,offset+window).arrayBuffer());
   for(const byte of bytes)hash=Math.imul(hash^byte,16777619)>>>0;
  }
  return `${blob.size}:${hash}`;
 };
 const sampleTracks=async(items:Track[])=>{
  const samples=new Map<string,string>();
  for(const item of items){
   assertSnapshot();
   samples.set(item.id,`${await sample(item.blob)}:${item.artwork?await sample(item.artwork):"none"}`);
  }
  assertSnapshot();
  return samples;
 };
 const originalSamples=await sampleTracks(tracks);
 assertSnapshot();
 const backup=createLibraryBackup(tracks,playlists);
 for(const track of tracks){
  assertSnapshot();
  for(const blob of [track.blob,...(track.artwork?[track.artwork]:[])]){
   let reader:ReadableStreamDefaultReader<Uint8Array>|undefined;
   try{
    reader=blob.stream().getReader();
    let bytes=0;
    let emptyChunks=0;
    while(true){
     // Check before each pull as well as after it. A paused stream must not
     // read another chunk after a concurrent playlist or recovery change.
     assertSnapshot();
     const part=await reader.read();
     if(part.done)break;
     // File-provider streams are untrusted at runtime. Repeated empty chunks
     // can otherwise keep an export spinning indefinitely without progress.
     if(!(part.value instanceof Uint8Array))throw new Error("Invalid saved media chunk.");
     if(part.value.byteLength===0){
      if(++emptyChunks>16)throw new Error("Saved media stream made no progress.");
      continue;
     }
     emptyChunks=0;
     bytes+=part.value.byteLength;
     // Abort a superseded export before reading the rest of a large file.
     // Check outside the media-error handler to preserve conflict details.
     if(bytes>blob.size)throw new Error("Saved media stream exceeded its declared size.");
     if(storage.getItem(key)!==baseline||RECOVERY_KEYS.some(name=>storage.getItem(name)!==null)){
      await reader.cancel();
      reader.releaseLock();
      reader=undefined;
      assertSnapshot();
     }
    }
    if(bytes!==blob.size)throw new Error("Incomplete saved media.");
   }catch(error){
    assertSnapshot();
    throw new Error("A saved recording or artwork could not be read. No backup was created.",{cause:error});
   }finally{
    // A failed read or invalid payload must release the underlying stream,
    // not leave a file-backed reader holding resources on mobile Safari.
    if(reader){
     try{await reader.cancel()}catch{/* Preserve the original media failure. */}
     reader.releaseLock();
    }
   }
  }
 }
 // A second IndexedDB read catches recordings imported, removed, or edited
 // by another tab while large media streams were being validated. This is
 // optimistic conflict detection, not a cross-store atomic snapshot.
 assertSnapshot();
 const latest=await loadTracks();
 assertSnapshot();
 const signature=(items:Track[])=>JSON.stringify(items.map(item=>[
  item.id,item.name,item.originalName,item.artist,item.album,item.size,
  item.type,item.importedAt,item.blob.size,item.blob.type,
  item.artwork?.size??null,item.artwork?.type??null
 ]).sort((a,b)=>String(a[0]).localeCompare(String(b[0]))));
 if(signature(tracks)!==signature(latest))
  throw new Error("Saved recordings changed while preparing the backup. Retry export.");
 const latestSamples=await sampleTracks(latest);
 for(const [id,original] of originalSamples){
  if(latestSamples.get(id)!==original)
   throw new Error("Saved recording bytes changed while preparing the backup. Retry export.");
 }
 return backup;
}
