import "fake-indexeddb/auto";
import {describe,expect,it,vi} from "vitest";
import {createStoredLibraryBackup} from "./backup-export";
import {parseLibraryBackup} from "./backup";
import {listTracks,removeTrack,restoreTracks,type Track} from "./tracks";

const key="mp3-shelf-playlists";
const playlist=[{id:"mix",name:"Current mix",trackIds:["fresh-export"]}];
const track:Track={id:"fresh-export",name:"Saved recording",size:3,type:"audio/mpeg",importedAt:1,blob:new Blob([new Uint8Array([1,2,3])])};
function store(){
 const values=new Map<string,string>([[key,JSON.stringify(playlist)]]);
 return {values,getItem:(name:string)=>values.get(name)??null};
}

describe("durable backup export",()=>{
 it("reads newly saved audio from IndexedDB instead of an older screen snapshot",async()=>{
  const storage=store();
  expect((await listTracks()).some(item=>item.id===track.id)).toBe(false);
  await restoreTracks([track]);
  try{
   const parsed=await parseLibraryBackup(await createStoredLibraryBackup(storage,key));
   expect(parsed.tracks.map(item=>item.id)).toEqual([track.id]);
   expect([...new Uint8Array(await parsed.tracks[0].blob.arrayBuffer())]).toEqual([1,2,3]);
   expect(parsed.playlists).toEqual(playlist);
  }finally{await removeTrack(track.id)}
 });
 it("exports current saved playlist edits with the fresh audio",async()=>{
  const storage=store();
  storage.values.set(key,JSON.stringify([{...playlist[0],name:"Latest name"}]));
  const parsed=await parseLibraryBackup(await createStoredLibraryBackup(storage,key,async()=>[track]));
  expect(parsed.playlists[0].name).toBe("Latest name");
 });
 it("rejects corrupt saved playlists before reading audio",async()=>{
  const storage=store();storage.values.set(key,"corrupt");
  const load=vi.fn(async()=>[track]);
  await expect(createStoredLibraryBackup(storage,key,load)).rejects.toThrow();
  expect(load).not.toHaveBeenCalled();
  expect(storage.values.get(key)).toBe("corrupt");
 });
 it.each(["mp3-shelf-restore-pending","mp3-shelf-delete-recovery"])("rejects pending %s before reading audio",async journal=>{
  const storage=store();storage.values.set(journal,"pending");
  const load=vi.fn(async()=>[track]);
  await expect(createStoredLibraryBackup(storage,key,load)).rejects.toThrow("Finish pending library recovery");
  expect(load).not.toHaveBeenCalled();
  expect(storage.values.get(journal)).toBe("pending");
 });
 it("rejects a playlist edit made while audio is being read, without overwriting it",async()=>{
  const storage=store();
  const latest=JSON.stringify([{...playlist[0],name:"Other tab edit"}]);
  await expect(createStoredLibraryBackup(storage,key,async()=>{
   await Promise.resolve();storage.values.set(key,latest);return [track];
  })).rejects.toThrow("Playlists changed");
  expect(storage.values.get(key)).toBe(latest);
 });
 it.each(["mp3-shelf-restore-pending","mp3-shelf-delete-recovery"])("rejects %s staged while audio is being read",async journal=>{
  const storage=store();
  await expect(createStoredLibraryBackup(storage,key,async()=>{
   await Promise.resolve();storage.values.set(journal,"new intent");return [track];
  })).rejects.toThrow("Finish pending library recovery");
  expect(storage.values.get(journal)).toBe("new intent");
 });
 it.each(["audio","artwork"])("rejects unreadable %s instead of offering an unusable archive",async part=>{
  const storage=store();const before=new Map(storage.values);
  const unreadable=new Blob([new Uint8Array([1,2,3])]);
  Object.defineProperty(unreadable,"stream",{value:()=>new ReadableStream({
   start(controller){controller.error(new DOMException("Backing file missing","NotFoundError"))}
  })});
  const damaged=part==="audio"?{...track,blob:unreadable}:{...track,artwork:unreadable};
  await expect(createStoredLibraryBackup(storage,key,async()=>[damaged])).rejects.toThrow("could not be read");
  expect(storage.values).toEqual(before);
 });
 it("propagates failed audio reads without producing an archive or modifying saved data",async()=>{
  const storage=store();const before=new Map(storage.values);
  const failure=new Error("Audio storage unavailable");
  await expect(createStoredLibraryBackup(storage,key,async()=>{throw failure})).rejects.toBe(failure);
  expect(storage.values).toEqual(before);
 });
 it("stops a multi-chunk export when another tab changes playlists mid-stream",async()=>{
  const storage=store();
  const newer=JSON.stringify([{...playlist[0],name:"Concurrent edit"}]);
  let pulls=0;
  let cancelled=false;
  const streamed=new Blob([new Uint8Array([1,2,3])]);
  Object.defineProperty(streamed,"stream",{value:()=>new ReadableStream<Uint8Array>({
   pull(controller){
    pulls++;
    if(pulls===1){
     controller.enqueue(new Uint8Array([1]));
     storage.values.set(key,newer);
    }else controller.enqueue(new Uint8Array([2,3]));
   },
   cancel(){cancelled=true}
  },{highWaterMark:0})});
  await expect(createStoredLibraryBackup(storage,key,async()=>[{...track,blob:streamed}]))
   .rejects.toThrow("Playlists changed");
  expect(cancelled).toBe(true);
  expect(pulls).toBe(1);
  expect(storage.values.get(key)).toBe(newer);
 });
 it("stops export when a recovery journal appears during a media stream",async()=>{
  const storage=store();
  const streamed=new Blob([new Uint8Array([1,2,3])]);
  let cancelled=false;
  Object.defineProperty(streamed,"stream",{value:()=>new ReadableStream<Uint8Array>({
   pull(controller){
    controller.enqueue(new Uint8Array([1]));
    storage.values.set("mp3-shelf-delete-recovery","new deletion");
   },
   cancel(){cancelled=true}
  },{highWaterMark:0})});
  await expect(createStoredLibraryBackup(storage,key,async()=>[{...track,blob:streamed}]))
   .rejects.toThrow("Finish pending library recovery");
  expect(cancelled).toBe(true);
  expect(storage.values.get("mp3-shelf-delete-recovery")).toBe("new deletion");
 });
});
