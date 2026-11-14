import "fake-indexeddb/auto";
import {IDBVersionChangeEvent} from "fake-indexeddb";
import{describe,expect,it}from"vitest";
import{formatBytes,importTracks,listTracks,removeTrack,renameTrack,restoreTracks,Track}from"./tracks";
describe("track library",()=>{it("imports MP3s, ignores other files, and removes a track",async()=>{const mp3=new File([new Uint8Array([1,2,3])],"demo.mp3",{type:"audio/mpeg",lastModified:10}),text=new File(["no"],"notes.txt",{type:"text/plain"});expect(await importTracks([mp3,text])).toBe(1);const tracks=await listTracks();expect(tracks).toHaveLength(1);expect(tracks[0].name).toBe("demo");await removeTrack(tracks[0].id);expect(await listTracks()).toHaveLength(0)});it("restores a track atomically into IndexedDB",async()=>{const track:Track={id:"restored",name:"Restored song",size:3,type:"audio/mpeg",importedAt:50,blob:new Blob([new Uint8Array([4,5,6])])};expect(await restoreTracks([track])).toBe(1);expect((await listTracks()).find(item=>item.id==="restored")?.name).toBe("Restored song");await removeTrack("restored")});it("formats file sizes",()=>{expect(formatBytes(0)).toBe("0 KB");expect(formatBytes(1048576)).toBe("1.0 MB");expect(formatBytes(1073741824)).toBe("1.0 GB")})});

describe("Files provider import compatibility",()=>{
 it("imports an M4A recording when Files omits its MIME type",async()=>{
  const file=new File([new Uint8Array([0,0,0,0,102,116,121,112])],"voice-note.M4A",{type:"",lastModified:4321});
  const id="voice-note.M4A:8:4321";
  try{
   expect(await importTracks([file])).toBe(1);
   const saved=(await listTracks()).find(track=>track.id===id);
   expect(saved).toBeDefined();
   expect(saved?.blob.size).toBe(8);
   expect(saved?.type).toBe("audio/mp4");
   expect(saved?.name).toBe("voice-note");
   expect(await importTracks([file])).toBe(0);
  }finally{await removeTrack(id)}
 });
 it("retains explicit audio MIME types and uses the MP3 fallback only for MIME-less MP3 files",async()=>{
  const mp3=new File([new Uint8Array([1,2,3])],"no-mime.mp3",{type:"",lastModified:5432});
  const m4a=new File([new Uint8Array([0,0,0,0,102,116,121,112])],"explicit.m4a",{type:"audio/x-m4a",lastModified:5432});
  const ids=["no-mime.mp3:3:5432","explicit.m4a:8:5432"];
  try{
   expect(await importTracks([mp3,m4a])).toBe(2);
   const saved=await listTracks();
   expect(saved.find(track=>track.id===ids[0])?.type).toBe("audio/mpeg");
   expect(saved.find(track=>track.id===ids[0])?.name).toBe("no-mime");
   expect(saved.find(track=>track.id===ids[1])?.type).toBe("audio/x-m4a");
   expect(saved.find(track=>track.id===ids[1])?.name).toBe("explicit");
  }finally{for(const id of ids)await removeTrack(id)}
 });
 it("rejects zero-byte audio regardless of extension or MIME type",async()=>{
  const emptyMp3=new File([],"empty.mp3",{type:"audio/mpeg",lastModified:1});
  const emptyM4a=new File([],"empty.m4a",{type:"",lastModified:2});
  expect(await importTracks([emptyMp3,emptyM4a])).toBe(0);
  const ids=new Set((await listTracks()).map(track=>track.id));
  expect(ids.has("empty.mp3:0:1")).toBe(false);
  expect(ids.has("empty.m4a:0:2")).toBe(false);
 });
 it("skips invalid files without dropping valid recordings from the same selection",async()=>{
  const valid=new File([new Uint8Array([1,2,3])],"mixed-valid.mp3",{type:"audio/mpeg",lastModified:123});
  const empty=new File([],"mixed-empty.mp3",{type:"audio/mpeg",lastModified:123});
  const other=new File(["text"],"mixed.txt",{type:"text/plain",lastModified:123});
  try{
   expect(await importTracks([empty,other,valid])).toBe(1);
   expect((await listTracks()).some(track=>track.id==="mixed-valid.mp3:3:123")).toBe(true);
  }finally{await removeTrack("mixed-valid.mp3:3:123")}
 });
});

describe("nameless Files provider import safety",()=>{
 it("skips blank filenames without persisting recordings that cannot be backed up",async()=>{
  const unnamed=new File([new Uint8Array([1,2,3])],"",{type:"audio/mpeg",lastModified:700});
  const whitespace=new File([new Uint8Array([4,5,6])],"   ",{type:"audio/mpeg",lastModified:701});
  const valid=new File([new Uint8Array([7,8,9])],"named.mp3",{type:"audio/mpeg",lastModified:702});
  try{
   expect(await importTracks([unnamed,whitespace,valid])).toBe(1);
   const tracks=await listTracks();
   expect(tracks.some(track=>track.id===":3:700"||track.id==="   :3:701")).toBe(false);
   const saved=tracks.find(track=>track.id==="named.mp3:3:702");
   expect(saved?.originalName).toBe("named.mp3");
   expect(saved?.name).toBe("named");
  }finally{await removeTrack("named.mp3:3:702")}
 });
 it("does not parse metadata or open storage for entirely nameless selections",async()=>{
  const originalSlice=File.prototype.slice;
  let reads=0;
  File.prototype.slice=function(...args){reads++;return originalSlice.apply(this,args)};
  try{
   expect(await importTracks([new File([new Uint8Array([1])],"",{type:"audio/mpeg"})])).toBe(0);
   expect(reads).toBe(0);
  }finally{File.prototype.slice=originalSlice}
 });
});

describe("bulk import bounded metadata work",()=>{
 it("imports a large Files selection without dropping tracks or changing selection order",async()=>{
  const files=Array.from({length:128},(_,i)=>new File([new Uint8Array([1,2,3])],`bulk-${i}.mp3`,{type:"audio/mpeg",lastModified:123}));
  try{
   expect(await importTracks(files)).toBe(128);
   const saved=await listTracks();
   for(const file of files)expect(saved.some(track=>track.id===`${file.name}:3:123`)).toBe(true);
   expect(await importTracks(files)).toBe(0);
  }finally{
   for(const file of files)await removeTrack(`${file.name}:3:123`);
  }
 });
});

describe("duplicate selection metadata performance",()=>{
 it("parses each distinct recording only once before IndexedDB import",async()=>{
  const first=new File([new Uint8Array([1,2,3])],"duplicate-selection.mp3",{type:"audio/mpeg",lastModified:1777});
  const duplicate=new File([new Uint8Array([9,9,9])],"duplicate-selection.mp3",{type:"audio/mpeg",lastModified:1777});
  const second=new File([new Uint8Array([4,5,6])],"unique-selection.mp3",{type:"audio/mpeg",lastModified:1777});
  const ids=["duplicate-selection.mp3:3:1777","unique-selection.mp3:3:1777"];
  const originalSlice=File.prototype.slice;
  let metadataReads=0;
  File.prototype.slice=function(...args){
   metadataReads++;
   return originalSlice.apply(this,args);
  };
  try{
   expect(await importTracks([first,...Array.from({length:64},()=>duplicate),second])).toBe(2);
   expect(metadataReads).toBe(2);
   const saved=await listTracks();
   const preserved=saved.find(track=>track.id===ids[0]);
   expect(Array.from(new Uint8Array(await preserved!.blob.arrayBuffer()))).toEqual([1,2,3]);
   expect(saved.some(track=>track.id===ids[1])).toBe(true);
  }finally{
   File.prototype.slice=originalSlice;
   for(const id of ids)await removeTrack(id);
  }
 });
});

describe("existing recording metadata preflight",()=>{
 it("avoids re-reading audio metadata when an entire Files selection already exists",async()=>{
  const files=Array.from({length:48},(_,i)=>new File([new Uint8Array([1,2,3])],`existing-bulk-${i}.mp3`,{type:"audio/mpeg",lastModified:2026}));
  const originalSlice=File.prototype.slice;
  try{
   expect(await importTracks(files)).toBe(48);
   let metadataReads=0;
   File.prototype.slice=function(...args){
    metadataReads++;
    return originalSlice.apply(this,args);
   };
   expect(await importTracks(files)).toBe(0);
   expect(metadataReads).toBe(0);
   expect((await listTracks()).filter(track=>track.id.startsWith("existing-bulk-"))).toHaveLength(48);
  }finally{
   File.prototype.slice=originalSlice;
   for(const file of files)await removeTrack(`${file.name}:${file.size}:${file.lastModified}`);
  }
 });
 it("reads only new metadata in mixed repeat imports and never replaces existing bytes",async()=>{
  const old=new File([new Uint8Array([1,2,3])],"preflight-old.mp3",{type:"audio/mpeg",lastModified:301});
  const conflicting=new File([new Uint8Array([9,9,9])],"preflight-old.mp3",{type:"audio/mpeg",lastModified:301});
  const fresh=new File([new Uint8Array([4,5,6])],"preflight-new.mp3",{type:"audio/mpeg",lastModified:302});
  const ids=["preflight-old.mp3:3:301","preflight-new.mp3:3:302"];
  const originalSlice=File.prototype.slice;
  try{
   expect(await importTracks([old])).toBe(1);
   let metadataReads=0;
   File.prototype.slice=function(...args){
    metadataReads++;
    return originalSlice.apply(this,args);
   };
   expect(await importTracks([conflicting,fresh])).toBe(1);
   expect(metadataReads).toBe(1);
   const tracks=await listTracks();
   const preserved=tracks.find(track=>track.id===ids[0])!;
   expect(Array.from(new Uint8Array(await preserved.blob.arrayBuffer()))).toEqual([1,2,3]);
   expect(tracks.some(track=>track.id===ids[1])).toBe(true);
  }finally{
   File.prototype.slice=originalSlice;
   for(const id of ids)await removeTrack(id);
  }
 });
});

describe("large import IndexedDB preflight batching",()=>{
 it("bounds each duplicate lookup transaction while preserving all new recordings",async()=>{
  const files=Array.from({length:300},(_,i)=>new File([new Uint8Array([1,2,3])],`lookup-batch-${i}.mp3`,{type:"audio/mpeg",lastModified:551}));
  const originalGetKey=IDBObjectStore.prototype.getKey;
  const originalTransaction=IDBDatabase.prototype.transaction;
  let lookups=0,readTransactions=0,maxPerTransaction=0,perTransaction=0;
  IDBDatabase.prototype.transaction=function(...args){
   if(args[1]==="readonly"){
    readTransactions++;
    perTransaction=0;
   }
   return originalTransaction.apply(this,args);
  };
  IDBObjectStore.prototype.getKey=function(...args){
   lookups++;
   perTransaction++;
   maxPerTransaction=Math.max(maxPerTransaction,perTransaction);
   return originalGetKey.apply(this,args);
  };
  try{
   expect(await importTracks(files)).toBe(300);
   expect(lookups).toBe(300);
   expect(readTransactions).toBe(3);
   expect(maxPerTransaction).toBeLessThanOrEqual(128);
   expect((await listTracks()).filter(track=>track.id.startsWith("lookup-batch-"))).toHaveLength(300);
  }finally{
   IDBObjectStore.prototype.getKey=originalGetKey;
   IDBDatabase.prototype.transaction=originalTransaction;
   for(const file of files)await removeTrack(`${file.name}:${file.size}:${file.lastModified}`);
  }
 });
 it("skips metadata reads across multiple preflight batches of existing recordings",async()=>{
  const files=Array.from({length:260},(_,i)=>new File([new Uint8Array([1,2,3])],`lookup-existing-${i}.mp3`,{type:"audio/mpeg",lastModified:552}));
  const originalSlice=File.prototype.slice;
  try{
   expect(await importTracks(files)).toBe(260);
   let metadataReads=0;
   File.prototype.slice=function(...args){
    metadataReads++;
    return originalSlice.apply(this,args);
   };
   expect(await importTracks(files)).toBe(0);
   expect(metadataReads).toBe(0);
  }finally{
   File.prototype.slice=originalSlice;
   for(const file of files)await removeTrack(`${file.name}:${file.size}:${file.lastModified}`);
  }
 });
});

describe("restore failure safety",()=>{
 const makeTrack=(id:string):Track=>({id,name:id,size:3,type:"audio/mpeg",importedAt:1,blob:new Blob([new Uint8Array([1,2,3])])});
 it("rejects corrupt restore records atomically before opening IndexedDB",async()=>{
  const valid=makeTrack("valid-before-invalid");
  const badCases:Track[]=[
   {...makeTrack("empty-audio"),size:0,blob:new Blob([])},
   {...makeTrack("wrong-size"),size:99},
   {...makeTrack("invalid-date"),importedAt:Number.NaN},
   {...makeTrack("blank-name"),name:"   "},
   {...makeTrack("missing-blob"),blob:undefined as unknown as Blob},
   {...makeTrack("empty-artwork"),artwork:new Blob([])},
   {...makeTrack("invalid-size"),size:Number.POSITIVE_INFINITY},
   {...makeTrack("negative-import-date"),importedAt:-1},
   {...makeTrack("blank-original-name"),originalName:"   "},
   {...makeTrack("nonstring-original-name"),originalName:42 as unknown as string},
   {...makeTrack("invalid-artist"),artist:{display:"Artist"} as unknown as string},
   {...makeTrack("invalid-album"),album:["Album"] as unknown as string},
  ];
  for(const invalid of badCases){
   await expect(restoreTracks([valid,invalid])).rejects.toThrow("Invalid recording metadata or audio");
   expect((await listTracks()).some(track=>track.id===valid.id||track.id===invalid.id)).toBe(false);
  }
 });
 it("accepts complete restore records with matching audio and optional artwork",async()=>{
  const track={...makeTrack("validated-audio"),artwork:new Blob([new Uint8Array([1])],{type:"image/png"})};
  try{
   expect(await restoreTracks([track])).toBe(1);
   const saved=(await listTracks()).find(item=>item.id===track.id);
   expect(saved?.size).toBe(saved?.blob.size);
   expect(saved?.artwork?.size).toBe(1);
  }finally{await removeTrack(track.id)}
 });
 it("restores valid optional metadata without dropping or rewriting fields",async()=>{
  const track={
   ...makeTrack("complete-optional-metadata"),
   originalName:"original.mp3",artist:"Artist",album:"Album",importedAt:0
  };
  try{
   expect(await restoreTracks([track])).toBe(1);
   const saved=(await listTracks()).find(item=>item.id===track.id);
   expect(saved?.originalName).toBe("original.mp3");
   expect(saved?.artist).toBe("Artist");
   expect(saved?.album).toBe("Album");
   expect(saved?.importedAt).toBe(0);
  }finally{await removeTrack(track.id)}
 });
 it("rejects duplicate backup IDs without writing",async()=>{
  await expect(restoreTracks([makeTrack("duplicate-restore"),makeTrack("duplicate-restore")])).rejects.toThrow("duplicate track ID");
  expect((await listTracks()).some(t=>t.id==="duplicate-restore")).toBe(false);
 });
 it("reimport preserves locally renamed metadata and original audio",async()=>{
  const original=new File([new Uint8Array([1,2,3])],"repeat.mp3",{type:"audio/mpeg",lastModified:1234});
  const replacement=new File([new Uint8Array([9,8,7])],"repeat.mp3",{type:"audio/mpeg",lastModified:1234});
  expect(await importTracks([original,original])).toBe(1);
  const id="repeat.mp3:3:1234";
  await renameTrack(id,"My edited title");
  expect(await importTracks([replacement])).toBe(0);
  const saved=(await listTracks()).find(track=>track.id===id);
  expect(saved?.name).toBe("My edited title");
  expect(Array.from(new Uint8Array(await saved!.blob.arrayBuffer()))).toEqual([1,2,3]);
  await removeTrack(id);
 });
 it("counts only newly committed recordings across repeated restores",async()=>{
  const first=makeTrack("restore-count-existing");
  const second=makeTrack("restore-count-new");
  try{
   expect(await restoreTracks([first])).toBe(1);
   expect(await restoreTracks([first,second])).toBe(1);
   expect(await restoreTracks([first,second])).toBe(0);
   expect((await listTracks()).filter(t=>t.id.startsWith("restore-count-"))).toHaveLength(2);
  }finally{
   await removeTrack(first.id);
   await removeTrack(second.id);
  }
 });
 it("never overwrites an existing recording with conflicting backup bytes",async()=>{
  const existing=makeTrack("restore-collision");
  const conflicting={...makeTrack("restore-collision"),name:"Wrong recording",blob:new Blob([new Uint8Array([9,9,9])])};
  await restoreTracks([existing]);
  await restoreTracks([conflicting,makeTrack("restore-new")]);
  const saved=(await listTracks()).find(track=>track.id==="restore-collision");
  expect(saved?.name).toBe("restore-collision");
  expect(Array.from(new Uint8Array(await saved!.blob.arrayBuffer()))).toEqual([1,2,3]);
  expect((await listTracks()).some(track=>track.id==="restore-new")).toBe(true);
  await removeTrack("restore-collision");await removeTrack("restore-new");
 });
 it("rejects an import callback write failure without committing earlier recordings",async()=>{
  const files=["callback-first.mp3","callback-failed.mp3"].map(name=>new File([new Uint8Array([1,2,3])],name,{type:"audio/mpeg",lastModified:987}));
  const add=IDBObjectStore.prototype.add;
  const failure=new DOMException("Injected audio quota failure","QuotaExceededError");
  IDBObjectStore.prototype.add=function(value,...args){
   if(value.id==="callback-failed.mp3:3:987")throw failure;
   return add.call(this,value,...args);
  };
  try{await expect(importTracks(files)).rejects.toBe(failure)}
  finally{IDBObjectStore.prototype.add=add}
  const ids=new Set((await listTracks()).map(track=>track.id));
  for(const file of files)expect(ids.has(`${file.name}:3:987`)).toBe(false);
  // A fresh attempt after failure must remain usable.
  try{expect(await importTracks(files)).toBe(2)}
  finally{for(const file of files)await removeTrack(`${file.name}:3:987`)}
 });
 it("reports the asynchronous request failure after its transaction has aborted",async()=>{
  const existing=makeTrack("async-existing");
  await restoreTracks([existing]);
  const add=IDBObjectStore.prototype.add;
  let aborted=false;
  IDBObjectStore.prototype.add=function(value,...args){
   this.transaction.addEventListener("abort",()=>{aborted=true});
   // Force a genuine asynchronous ConstraintError, not a thrown JS error.
   return add.call(this,value.id==="async-new"?{...value,id:existing.id}:value,...args);
  };
  try{
   await expect(restoreTracks([makeTrack("async-first"),makeTrack("async-new")])).rejects.toMatchObject({name:"ConstraintError"});
   expect(aborted).toBe(true);
  }finally{IDBObjectStore.prototype.add=add}
  const saved=await listTracks();
  expect(saved.some(track=>track.id==="async-first"||track.id==="async-new")).toBe(false);
  expect(saved.find(track=>track.id===existing.id)?.name).toBe(existing.name);
  await removeTrack(existing.id);
 });
 it("aborts all writes when a later track is not structured-cloneable",async()=>{
  const bad={...makeTrack("bad-restore"),uncloneable:()=>{}} as Track;
  await expect(restoreTracks([makeTrack("new-restore"),bad])).rejects.toThrow(/could not be cloned/);
  expect((await listTracks()).some(t=>t.id==="new-restore"||t.id==="bad-restore")).toBe(false);
  // Deleting the database exposes leaked open connections after failure.
  await new Promise<void>((resolve,reject)=>{
   const req=indexedDB.deleteDatabase("mp3-shelf");
   req.onsuccess=()=>resolve();
   req.onerror=()=>reject(req.error);
   req.onblocked=()=>reject(new Error("Restore leaked an IndexedDB connection."));
  });
 });
});

describe("IndexedDB connection lifecycle on failed operations",()=>{
 async function assertDatabaseCanClose():Promise<void>{
  await new Promise<void>((resolve,reject)=>{
   const request=indexedDB.deleteDatabase("mp3-shelf");
   request.onsuccess=()=>resolve();
   request.onerror=()=>reject(request.error);
   request.onblocked=()=>reject(new Error("Failed library operation leaked an IndexedDB connection."));
  });
 }
 it("releases the database after an invalid delete key",async()=>{
  await expect(removeTrack(null as unknown as string)).rejects.toThrow();
  await assertDatabaseCanClose();
  expect(await listTracks()).toEqual([]);
 });
 it("aborts an uncloneable rename and releases the database",async()=>{
  const id="rename-connection-regression";
  const original:Track={id,name:"Original",size:1,type:"audio/mpeg",importedAt:1,blob:new Blob([new Uint8Array([1])])};
  expect(await restoreTracks([original])).toBe(1);
  await expect(renameTrack(id,(()=>{}) as unknown as string)).rejects.toThrow();
  expect((await listTracks()).find(track=>track.id===id)?.name).toBe("Original");
  await assertDatabaseCanClose();
 });
 it("closes a stale connection when IndexedDB announces a version change",async()=>{
  // An upgrade requested by another tab must not remain blocked by an
  // in-flight read's database handle. Simulate the browser versionchange
  // notification while getAll is pending, then verify the upgrade succeeds.
  const original=IDBObjectStore.prototype.getAll;
  const close=IDBDatabase.prototype.close;
  let closeCalls=0;
  IDBDatabase.prototype.close=function(){
   closeCalls++;
   return close.call(this);
  };
  IDBObjectStore.prototype.getAll=function(...args){
   const request=original.apply(this,args);
   const db=this.transaction.db;
   queueMicrotask(()=>db.dispatchEvent(new IDBVersionChangeEvent("versionchange",{oldVersion:1,newVersion:2})));
   return request;
  };
  try{
   expect(await listTracks()).toEqual([]);
   expect(closeCalls).toBeGreaterThanOrEqual(1);
  }finally{
   IDBObjectStore.prototype.getAll=original;
   IDBDatabase.prototype.close=close;
  }
  await assertDatabaseCanClose();
 });
 it("releases the database if the track listing request cannot be created",async()=>{
  const original=IDBObjectStore.prototype.getAll;
  IDBObjectStore.prototype.getAll=function(){throw new Error("Injected getAll failure")};
  try{await expect(listTracks()).rejects.toThrow("Injected getAll failure")}
  finally{IDBObjectStore.prototype.getAll=original}
  await assertDatabaseCanClose();
 });
});

describe("track title integrity across edits and backups",()=>{
 const makeTrack=(id:string):Track=>({id,name:"Original title",size:3,type:"audio/mpeg",importedAt:10,blob:new Blob([new Uint8Array([1,2,3])])});
 it("rejects blank renames without corrupting persisted metadata or portable restore eligibility",async()=>{
  const id="rename-blank-integrity";
  await restoreTracks([makeTrack(id)]);
  try{
   await expect(renameTrack(id,"   ")).rejects.toThrow("cannot be empty");
   await expect(renameTrack(id,"")).rejects.toThrow("cannot be empty");
   expect((await listTracks()).find(t=>t.id===id)?.name).toBe("Original title");
   await renameTrack(id,"  Updated title  ");
   const saved=(await listTracks()).find(t=>t.id===id)!;
   expect(saved.name).toBe("Updated title");
   expect(saved.blob.size).toBe(3);
  }finally{await removeTrack(id)}
 });
 it("rejects stale rename IDs without creating phantom tracks",async()=>{
  const id="missing-rename-integrity";
  await expect(renameTrack(id,"New title")).rejects.toThrow("no longer exists");
  expect((await listTracks()).some(t=>t.id===id)).toBe(false);
  await expect(renameTrack(" ","New title")).rejects.toThrow("Invalid recording ID");
 });
 it("uses a nonblank fallback title for a recording named only by its extension",async()=>{
  const file=new File([new Uint8Array([1,2,3])],".mp3",{type:"audio/mpeg",lastModified:889});
  const id=".mp3:3:889";
  try{
   expect(await importTracks([file])).toBe(1);
   expect((await listTracks()).find(t=>t.id===id)?.name).toBe(".mp3");
  }finally{await removeTrack(id)}
 });
});
