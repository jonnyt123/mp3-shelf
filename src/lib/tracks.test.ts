import "fake-indexeddb/auto";
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
 it("aborts all writes when a later track is not structured-cloneable",async()=>{
  const bad={...makeTrack("bad-restore"),uncloneable:()=>{}} as Track;
  await expect(restoreTracks([makeTrack("new-restore"),bad])).rejects.toThrow();
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
 it("releases the database if the track listing request cannot be created",async()=>{
  const original=IDBObjectStore.prototype.getAll;
  IDBObjectStore.prototype.getAll=function(){throw new Error("Injected getAll failure")};
  try{await expect(listTracks()).rejects.toThrow("Injected getAll failure")}
  finally{IDBObjectStore.prototype.getAll=original}
  await assertDatabaseCanClose();
 });
});
