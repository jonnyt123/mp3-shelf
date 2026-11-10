import "fake-indexeddb/auto";
import{describe,expect,it}from"vitest";
import{formatBytes,importTracks,listTracks,removeTrack,renameTrack,restoreTracks,Track}from"./tracks";
describe("track library",()=>{it("imports MP3s, ignores other files, and removes a track",async()=>{const mp3=new File([new Uint8Array([1,2,3])],"demo.mp3",{type:"audio/mpeg",lastModified:10}),text=new File(["no"],"notes.txt",{type:"text/plain"});expect(await importTracks([mp3,text])).toBe(1);const tracks=await listTracks();expect(tracks).toHaveLength(1);expect(tracks[0].name).toBe("demo");await removeTrack(tracks[0].id);expect(await listTracks()).toHaveLength(0)});it("restores a track atomically into IndexedDB",async()=>{const track:Track={id:"restored",name:"Restored song",size:3,type:"audio/mpeg",importedAt:50,blob:new Blob([new Uint8Array([4,5,6])])};expect(await restoreTracks([track])).toBe(1);expect((await listTracks()).find(item=>item.id==="restored")?.name).toBe("Restored song");await removeTrack("restored")});it("formats file sizes",()=>{expect(formatBytes(0)).toBe("0 KB");expect(formatBytes(1048576)).toBe("1.0 MB");expect(formatBytes(1073741824)).toBe("1.0 GB")})});

describe("restore failure safety",()=>{
 const makeTrack=(id:string):Track=>({id,name:id,size:3,type:"audio/mpeg",importedAt:1,blob:new Blob([new Uint8Array([1,2,3])])});
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
