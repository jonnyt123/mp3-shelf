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
 // Validate metadata/references before scanning any payload. Blob construction
 // alone does not read file-backed data: an inaccessible original can otherwise
 // produce a "ready" archive whose download fails later in the browser.
 const backup=createLibraryBackup(tracks,playlists);
 for(const track of tracks){
  for(const blob of [track.blob,...(track.artwork?[track.artwork]:[])]){
   let reader:ReadableStreamDefaultReader<Uint8Array>|undefined;
   try{
    reader=blob.stream().getReader();
    let bytes=0;
    while(true){const part=await reader.read();if(part.done)break;bytes+=part.value.byteLength}
    if(bytes!==blob.size)throw new Error("Incomplete saved media.");
   }catch(error){
    throw new Error("A saved recording or artwork could not be read. No backup was created.",{cause:error});
   }finally{reader?.releaseLock()}
  }
 }
 assertNoRecovery();
 if(storage.getItem(key)!==baseline)
  throw new Error("Playlists changed while preparing the backup. Retry export.");
 return backup;
}
