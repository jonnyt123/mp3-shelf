import{readAudioMetadata}from"./id3";
export type Track={id:string;name:string;originalName?:string;artist?:string;album?:string;artwork?:Blob;size:number;type:string;importedAt:number;blob:Blob};
const DATABASE="mp3-shelf", STORE="tracks";
function openDatabase():Promise<IDBDatabase>{return new Promise((resolve,reject)=>{const request=indexedDB.open(DATABASE,1);request.onupgradeneeded=()=>{const db=request.result;if(!db.objectStoreNames.contains(STORE))db.createObjectStore(STORE,{keyPath:"id"})};request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error)})}
function finish(transaction:IDBTransaction):Promise<void>{return new Promise((resolve,reject)=>{transaction.oncomplete=()=>resolve();transaction.onerror=()=>reject(transaction.error);transaction.onabort=()=>reject(transaction.error)})}
export async function listTracks():Promise<Track[]>{const db=await openDatabase();const transaction=db.transaction(STORE,"readonly");const request=transaction.objectStore(STORE).getAll();const tracks=await new Promise<Track[]>((resolve,reject)=>{request.onsuccess=()=>resolve(request.result as Track[]);request.onerror=()=>reject(request.error)});db.close();return tracks.sort((a,b)=>b.importedAt-a.importedAt)}
export async function importTracks(files:File[]):Promise<number>{
 const audio=files.filter(file=>file.type.startsWith("audio/")||/\.mp3$/i.test(file.name));
 if(!audio.length)return 0;
 const prepared=await Promise.all(audio.map(async file=>({file,metadata:await readAudioMetadata(file)})));
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
     const add=store.add({id,name:metadata.title||file.name.replace(/\.mp3$/i,""),originalName:file.name,artist:metadata.artist,album:metadata.album,artwork:metadata.artwork,size:file.size,type:file.type||"audio/mpeg",importedAt:Date.now(),blob:file} satisfies Track);
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
export async function removeTrack(id:string):Promise<void>{const db=await openDatabase();const transaction=db.transaction(STORE,"readwrite");transaction.objectStore(STORE).delete(id);await finish(transaction);db.close()}
export async function renameTrack(id:string,name:string):Promise<void>{const db=await openDatabase();const transaction=db.transaction(STORE,"readwrite");const store=transaction.objectStore(STORE);const request=store.get(id);const track=await new Promise<Track|undefined>((resolve,reject)=>{request.onsuccess=()=>resolve(request.result as Track|undefined);request.onerror=()=>reject(request.error)});if(track)store.put({...track,name});await finish(transaction);db.close()}
export async function restoreTracks(tracks:Track[]):Promise<number>{
 if(!tracks.length)return 0;
 // Reject duplicate backup records before opening a write transaction: IDB put()
 // otherwise silently overwrites earlier entries with the same key.
 const ids=new Set<string>();
 for(const track of tracks){
  if(typeof track.id!=="string"||!track.id.trim()||ids.has(track.id))throw new Error("Invalid or duplicate track ID in restore.");
  ids.add(track.id);
 }
 const db=await openDatabase();
 try{
  const transaction=db.transaction(STORE,"readwrite");
  // Register completion/error handlers before enqueuing writes. Any synchronous
  // structured-clone failure must abort the entire transaction, not partially
  // restore a library.
  const completed=finish(transaction);
  try{
   const store=transaction.objectStore(STORE);
   // A backup may reuse an existing ID for different audio. Never replace
   // user-owned recordings during restore; only insert genuinely missing IDs.
   // Queue reads and conditional adds within the same transaction so the
   // existing record remains authoritative even when a second restore races.
   for(const track of tracks){
    const request=store.get(track.id);
    request.onsuccess=()=>{
     if(request.result===undefined)store.add(track);
    };
   }
  }catch(error){
   try{transaction.abort()}catch{/* Transaction already inactive. */}
   await completed.catch(()=>{});
   throw error;
  }
  await completed;
  return tracks.length;
 }finally{db.close()}
}
export function formatBytes(bytes:number):string{if(bytes<=0)return "0 KB";if(bytes<1024*1024)return `${Math.max(1,Math.round(bytes/1024))} KB`;if(bytes<1024*1024*1024)return `${(bytes/1024/1024).toFixed(1)} MB`;return `${(bytes/1024/1024/1024).toFixed(1)} GB`}
