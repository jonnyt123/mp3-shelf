import{readAudioMetadata}from"./id3";
export type Track={id:string;name:string;originalName?:string;artist?:string;album?:string;artwork?:Blob;size:number;type:string;importedAt:number;blob:Blob};
const DATABASE="mp3-shelf", STORE="tracks";
function openDatabase():Promise<IDBDatabase>{return new Promise((resolve,reject)=>{const request=indexedDB.open(DATABASE,1);request.onupgradeneeded=()=>{const db=request.result;if(!db.objectStoreNames.contains(STORE))db.createObjectStore(STORE,{keyPath:"id"})};request.onsuccess=()=>{const db=request.result;db.onversionchange=()=>db.close();resolve(db)};request.onerror=()=>reject(request.error)})}
function finish(transaction:IDBTransaction):Promise<void>{return new Promise((resolve,reject)=>{transaction.oncomplete=()=>resolve();transaction.onerror=()=>reject(transaction.error);transaction.onabort=()=>reject(transaction.error)})}
export async function listTracks():Promise<Track[]>{
 const db=await openDatabase();
 try{
  const transaction=db.transaction(STORE,"readonly");
  const request=transaction.objectStore(STORE).getAll();
  const tracks=await new Promise<Track[]>((resolve,reject)=>{
   request.onsuccess=()=>resolve(request.result as Track[]);
   request.onerror=()=>reject(request.error);
  });
  return tracks.sort((a,b)=>b.importedAt-a.importedAt);
 }finally{db.close()}
}
export async function importTracks(files:File[]):Promise<number>{
 // Files providers sometimes omit the MIME type for M4A recordings.
 // Never persist an empty recording as playable audio; it cannot be decoded,
 // and would otherwise become a permanent broken library entry.
 const selectedIds=new Set<string>();
 const audio=files.filter(file=>{
  if(file.size<=0||!(file.type.startsWith("audio/")||/\.(mp3|m4a)$/i.test(file.name)))return false;
  const id=`${file.name}:${file.size}:${file.lastModified}`;
  // Deduplicate before parsing ID3. Repeated selections can otherwise launch
  // many unnecessary metadata reads (up to 2 MiB each) on mobile Safari.
  if(selectedIds.has(id))return false;
  selectedIds.add(id);
  return true;
 });
 if(!audio.length)return 0;
 // Bound concurrent 2 MiB ID3 reads: a large Files selection must not launch
 // hundreds of arrayBuffer allocations simultaneously on memory-limited iPhones.
 const prepared=new Array<{file:File;metadata:Awaited<ReturnType<typeof readAudioMetadata>>}>(audio.length);
 let cursor=0;
 await Promise.all(Array.from({length:Math.min(4,audio.length)},async()=>{
  while(cursor<audio.length){
   const index=cursor++;
   prepared[index]={file:audio[index],metadata:await readAudioMetadata(audio[index])};
  }
 }));
 const db=await openDatabase();
 try{
  const transaction=db.transaction(STORE,"readwrite");
  const completed=finish(transaction);
  let inserted=0;
  try{
   const store=transaction.objectStore(STORE);
   const seen=new Set<string>();
   for(const {file,metadata} of prepared){
    const id=`${file.name}:${file.size}:${file.lastModified}`;
    // Reimport must not replace locally edited metadata or audio bytes.
    if(seen.has(id))continue;
    seen.add(id);
    const request=store.get(id);
    request.onsuccess=()=>{
     if(request.result!==undefined)return;
     const extension=/\.m4a$/i.test(file.name)?"audio/mp4":"audio/mpeg";
     const add=store.add({id,name:metadata.title?.trim()||file.name.replace(/\.(mp3|m4a)$/i,"").trim()||file.name,originalName:file.name,artist:metadata.artist,album:metadata.album,artwork:metadata.artwork,size:file.size,type:file.type||extension,importedAt:Date.now(),blob:file} satisfies Track);
     add.onsuccess=()=>{inserted++};
    };
   }
  }catch(error){
   try{transaction.abort()}catch{/* Already inactive. */}
   await completed.catch(()=>{});
   throw error;
  }
  await completed;
  return inserted;
 }finally{db.close()}
}
export async function removeTrack(id:string):Promise<void>{
 const db=await openDatabase();
 try{
  const transaction=db.transaction(STORE,"readwrite");
  const completed=finish(transaction);
  try{transaction.objectStore(STORE).delete(id)}
  catch(error){
   try{transaction.abort()}catch{/* Transaction already inactive. */}
   await completed.catch(()=>{});
   throw error;
  }
  await completed;
 }finally{db.close()}
}
export async function renameTrack(id:string,name:string):Promise<void>{
 // Blank titles make the recording impossible to restore from a portable
 // archive, whose validation correctly rejects nameless records.
 if(typeof id!=="string"||!id.trim())throw new Error("Invalid recording ID.");
 if(typeof name!=="string"||!name.trim())throw new Error("Recording name cannot be empty.");
 const normalizedName=name.trim();
 const db=await openDatabase();
 try{
  const transaction=db.transaction(STORE,"readwrite");
  const completed=finish(transaction);
  try{
   const store=transaction.objectStore(STORE);
   const request=store.get(id);
   await new Promise<void>((resolve,reject)=>{
    request.onsuccess=()=>{
     try{
      const track=request.result as Track|undefined;
      if(!track){reject(new Error("Recording no longer exists."));return}
      store.put({...track,name:normalizedName});
      resolve();
     }catch(error){reject(error)}
    };
    request.onerror=()=>reject(request.error);
   });
   await completed;
  }catch(error){
   try{transaction.abort()}catch{/* Transaction already inactive. */}
   await completed.catch(()=>{});
   throw error;
  }
 }finally{db.close()}
}
export async function restoreTracks(tracks:Track[]):Promise<number>{
 if(!tracks.length)return 0;
 // Validate the entire archive before opening a write transaction. This
 // function is also callable independently of the .mp3shelf parser, so do not
 // trust TypeScript annotations or allow corrupt/empty audio into the library.
 // Rejecting up front avoids a partially committed batch of valid recordings.
 const ids=new Set<string>();
 for(const track of tracks){
  if(!track||typeof track!=="object"||
     typeof track.id!=="string"||!track.id.trim()||ids.has(track.id))
   throw new Error("Invalid or duplicate track ID in restore.");
  ids.add(track.id);
  if(typeof track.name!=="string"||!track.name.trim()||
     typeof track.type!=="string"||
     (track.originalName!==undefined&&(typeof track.originalName!=="string"||!track.originalName.trim()))||
     (track.artist!==undefined&&typeof track.artist!=="string")||
     (track.album!==undefined&&typeof track.album!=="string")||
     !Number.isSafeInteger(track.size)||track.size<=0||
     !Number.isFinite(track.importedAt)||track.importedAt<0||
     !(track.blob instanceof Blob)||track.blob.size!==track.size||
     (track.artwork!==undefined&&(!(track.artwork instanceof Blob)||track.artwork.size===0)))
   throw new Error("Invalid recording metadata or audio in restore.");
 }
 const db=await openDatabase();
 try{
  const transaction=db.transaction(STORE,"readwrite");
  // Register completion/error handlers before enqueuing writes. Any synchronous
  // structured-clone failure must abort the entire transaction, not partially
  // restore a library.
  const completed=finish(transaction);
  let inserted=0;
  try{
   const store=transaction.objectStore(STORE);
   // A backup may reuse an existing ID for different audio. Never replace
   // user-owned recordings during restore; only insert genuinely missing IDs.
   // Queue reads and conditional adds within the same transaction so the
   // existing record remains authoritative even when a second restore races.
   for(const track of tracks){
    const request=store.get(track.id);
    request.onsuccess=()=>{
     if(request.result!==undefined)return;
     const add=store.add(track);
     add.onsuccess=()=>{inserted++};
    };
   }
  }catch(error){
   try{transaction.abort()}catch{/* Transaction already inactive. */}
   await completed.catch(()=>{});
   throw error;
  }
  await completed;
  return inserted;
 }finally{db.close()}
}
export function formatBytes(bytes:number):string{if(bytes<=0)return "0 KB";if(bytes<1024*1024)return `${Math.max(1,Math.round(bytes/1024))} KB`;if(bytes<1024*1024*1024)return `${(bytes/1024/1024).toFixed(1)} MB`;return `${(bytes/1024/1024/1024).toFixed(1)} GB`}
