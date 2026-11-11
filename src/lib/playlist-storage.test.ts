import {describe,it,expect} from "vitest";
import {deleteTrackWithPlaylistCleanup,commitPlaylistEdit,cancelPlaylistRestore,hasPendingPlaylistRestore,parseStoredPlaylists,persistRestoredPlaylists,recoverPlaylistRestore,selectPlaylistTracks,stagePlaylistRestore} from "./playlist-storage";
describe("persistent playlist hydration",()=>{
 it("loads existing playlists without dropping order or track references",()=>{
  const saved=[{id:"mix",name:"Road trip",trackIds:["a","b"]}];
  expect(parseStoredPlaylists(JSON.stringify(saved))).toEqual(saved);
 });
 it("allows first launch with no storage entry",()=>expect(parseStoredPlaylists(null)).toEqual([]));
 it.each(['not json','{}','[null]','[{"id":"x","name":"a","trackIds":[4]}]','[{"id":"x","name":"a","trackIds":[]},{"id":"x","name":"b","trackIds":[]}]'])("rejects corrupt storage instead of silently clearing it: %s",raw=>{
  expect(()=>parseStoredPlaylists(raw)).toThrow();
 });
});

describe("large offline playlist selection",()=>{
 it("preserves library order, ignores missing IDs and duplicate playlist references",()=>{
  const tracks=[{id:"a"},{id:"b"},{id:"c"}];
  expect(selectPlaylistTracks(tracks,["c","c","missing","a"])).toEqual([tracks[0],tracks[2]]);
 });
 it("handles large imports without repeatedly scanning playlist IDs",()=>{
  const tracks=Array.from({length:10000},(_,i)=>({id:`track-${i}`}));
  const ids=Array.from({length:10000},(_,i)=>`track-${i}`);
  const result=selectPlaylistTracks(tracks,ids);
  expect(result).toHaveLength(10000);
  expect(result[9999]).toBe(tracks[9999]);
 });
});

describe("playlist restore commit",()=>{
 it("preserves local playlist edits and adds missing backup links after a successful write",()=>{
  const storage=new Map([["playlists",JSON.stringify([{id:"existing",name:"Old",trackIds:["a"]}])]]);
  const adapter={getItem:(key:string)=>storage.get(key)??null,setItem:(key:string,value:string)=>{storage.set(key,value)}};
  const next=persistRestoredPlaylists(adapter,"playlists",[{id:"existing",name:"Updated",trackIds:["b"]},{id:"new",name:"New",trackIds:[]}]);
  expect(next).toEqual([{id:"existing",name:"Old",trackIds:["a","b"]},{id:"new",name:"New",trackIds:[]}]);
  expect(parseStoredPlaylists(storage.get("playlists")!)).toEqual(next);
 });
 it("deduplicates track references when importing a new playlist without changing existing playlist order",()=>{
  const saved=[{id:"existing",name:"Keep",trackIds:["local","local"]}];
  const data=new Map([["playlists",JSON.stringify(saved)]]);
  const storage={getItem:(key:string)=>data.get(key)??null,setItem:(key:string,value:string)=>{data.set(key,value)}};
  const incoming=[{id:"new",name:"Imported",trackIds:["a","b","a","c","b"]}];
  const result=persistRestoredPlaylists(storage,"playlists",incoming);
  expect(result).toEqual([...saved,{id:"new",name:"Imported",trackIds:["a","b","c"]}]);
  expect(persistRestoredPlaylists(storage,"playlists",incoming)).toEqual(result);
  expect(parseStoredPlaylists(data.get("playlists")!)).toEqual(result);
 });
 it("is idempotent and never reorders or deletes locally edited playlist tracks",()=>{
  const storage=new Map([["playlists",JSON.stringify([{id:"mix",name:"My edited mix",trackIds:["local","shared"]}])]]);
  const adapter={getItem:(key:string)=>storage.get(key)??null,setItem:(key:string,value:string)=>{storage.set(key,value)}};
  const incoming=[{id:"mix",name:"Outdated backup name",trackIds:["shared","archived","archived"]}];
  const first=persistRestoredPlaylists(adapter,"playlists",incoming);
  expect(first).toEqual([{id:"mix",name:"My edited mix",trackIds:["local","shared","archived"]}]);
  expect(persistRestoredPlaylists(adapter,"playlists",incoming)).toEqual(first);
 });
 it("does not claim success or replace the existing playlists when storage is full",()=>{
  const saved=JSON.stringify([{id:"safe",name:"Saved",trackIds:["audio"]}]);
  let writes=0;
  const storage={getItem:()=>saved,setItem:()=>{writes++;throw new DOMException("Storage full","QuotaExceededError")}};
  expect(()=>persistRestoredPlaylists(storage,"playlists",[{id:"restored",name:"Restored",trackIds:[]}])).toThrow();
  expect(writes).toBe(1);
  expect(storage.getItem()).toBe(saved);
 });
 it("rejects duplicate or malformed incoming playlist IDs without touching saved playlists",()=>{
  const saved=JSON.stringify([{id:"safe",name:"My playlist",trackIds:["audio"]}]);
  let writes=0;
  const storage={getItem:()=>saved,setItem:()=>{writes++}};
  expect(()=>persistRestoredPlaylists(storage,"playlists",[
   {id:"collision",name:"First",trackIds:[]},
   {id:"collision",name:"Second",trackIds:[]}
  ])).toThrow("Duplicate saved playlist ID");
  expect(()=>persistRestoredPlaylists(storage,"playlists",[
   {id:"new",name:"Bad",trackIds:[""]}
  ])).toThrow("Invalid saved playlists");
  expect(writes).toBe(0);
  expect(storage.getItem()).toBe(saved);
 });
 it("refuses to overwrite malformed existing playlists",()=>{
  let wrote=false;
  expect(()=>persistRestoredPlaylists({getItem:()=>"{bad",setItem:()=>{wrote=true}},"playlists",[])).toThrow();
  expect(wrote).toBe(false);
 });
});

describe("crash-safe backup restoration journal",()=>{
 function store(){
  const data=new Map<string,string>([["playlists",JSON.stringify([{id:"local",name:"Edited",trackIds:["a"]}])]]);
  return{getItem:(key:string)=>data.get(key)??null,setItem:(key:string,value:string)=>{data.set(key,value)},removeItem:(key:string)=>{data.delete(key)}};
 }
 const incoming=[{id:"local",name:"Old",trackIds:["b"]},{id:"new",name:"New",trackIds:["b"]}];
 it("rejects corrupt destination playlists before staging any audio restore",()=>{
  const storage=store();
  storage.setItem("playlists","{damaged");
  const original=storage.getItem("playlists");
  expect(()=>stagePlaylistRestore(storage,"playlists",[{id:"b"}],incoming)).toThrow();
  expect(hasPendingPlaylistRestore(storage)).toBe(false);
  expect(storage.getItem("playlists")).toBe(original);
 });
 it("validates the actual destination key, not a hardcoded production key",()=>{
  const storage=store();
  storage.setItem("mp3-shelf-playlists",JSON.stringify([{id:"unrelated",name:"Other",trackIds:[]}]));
  storage.setItem("playlists","{broken");
  expect(()=>stagePlaylistRestore(storage,"playlists",[{id:"b"}],incoming)).toThrow();
  expect(hasPendingPlaylistRestore(storage)).toBe(false);
  storage.setItem("playlists",JSON.stringify([{id:"local",name:"Edited",trackIds:["a"]}]));
  storage.setItem("mp3-shelf-playlists","{broken");
  expect(stagePlaylistRestore(storage,"playlists",[{id:"b"}],incoming)).toBe(true);
 });
 it("recovers after audio commits but before playlists are saved, without reverting local edits",()=>{
  const storage=store();
  stagePlaylistRestore(storage,"playlists",[{id:"b"}],incoming);
  expect(hasPendingPlaylistRestore(storage)).toBe(true);
  const result=recoverPlaylistRestore(storage,new Set(["a","b"]),"playlists");
  expect(result).toEqual([{id:"local",name:"Edited",trackIds:["a","b"]},{id:"new",name:"New",trackIds:["b"]}]);
  expect(hasPendingPlaylistRestore(storage)).toBe(false);
  expect(recoverPlaylistRestore(storage,new Set(["a","b"]),"playlists")).toBeNull();
 });
 it("never publishes playlist links if a crash happened before audio insertion",()=>{
  const storage=store();
  stagePlaylistRestore(storage,"playlists",[{id:"b"}],incoming);
  expect(()=>recoverPlaylistRestore(storage,new Set(["a"]),"playlists")).toThrow("interrupted");
  expect(JSON.parse(storage.getItem("playlists")!)[0].trackIds).toEqual(["a"]);
  expect(hasPendingPlaylistRestore(storage)).toBe(true);
  expect(()=>stagePlaylistRestore(storage,"playlists",[{id:"different"}],incoming)).toThrow("original backup");
  expect(stagePlaylistRestore(storage,"playlists",[{id:"b"}],incoming)).toBe(false);
 });
 it("retains an existing interrupted restore journal when the same backup is retried and audio storage fails",()=>{
  const storage=store();
  expect(stagePlaylistRestore(storage,"playlists",[{id:"b"}],incoming)).toBe(true);
  const original=storage.getItem("mp3-shelf-restore-pending");
  const newlyStaged=stagePlaylistRestore(storage,"playlists",[{id:"b"}],incoming);
  expect(newlyStaged).toBe(false);
  // A failed retry must not call cancelPlaylistRestore on another run's journal.
  if(newlyStaged)cancelPlaylistRestore(storage);
  expect(storage.getItem("mp3-shelf-restore-pending")).toBe(original);
  expect(hasPendingPlaylistRestore(storage)).toBe(true);
 });
 it("retains pending recovery after playlist quota failure",()=>{
  const storage=store();
  stagePlaylistRestore(storage,"playlists",[{id:"b"}],incoming);
  const failed={...storage,setItem:(key:string,value:string)=>{if(key==="playlists")throw new Error("QuotaExceeded");storage.setItem(key,value)}};
  expect(()=>recoverPlaylistRestore(failed,new Set(["a","b"]),"playlists")).toThrow("QuotaExceeded");
  expect(hasPendingPlaylistRestore(storage)).toBe(true);
  expect(JSON.parse(storage.getItem("playlists")!)[0].trackIds).toEqual(["a"]);
  cancelPlaylistRestore(storage);
  expect(hasPendingPlaylistRestore(storage)).toBe(false);
 });
});

 describe("durable ordinary playlist edits",()=>{
  it("writes a valid edit before returning it to the UI",()=>{
   const data=new Map<string,string>();
   const next=[{id:"mix",name:"Favorites",trackIds:["a","b"]}];
   const saved=commitPlaylistEdit({setItem:(key,value)=>{data.set(key,value)}},"playlists",next);
   expect(saved).toEqual(next);
   expect(parseStoredPlaylists(data.get("playlists")!)).toEqual(next);
  });
  it("does not publish an edit when the device refuses the storage write",()=>{
   const old=JSON.stringify([{id:"mix",name:"Keep",trackIds:["a"]}]);
   const data=new Map([["playlists",old]]);
   expect(()=>commitPlaylistEdit({setItem:()=>{throw new DOMException("Full","QuotaExceededError")}},"playlists",[{id:"mix",name:"New",trackIds:["b"]}])).toThrow();
   expect(data.get("playlists")).toBe(old);
  });
  it("rejects duplicate IDs before attempting a write",()=>{
   let writes=0;
   expect(()=>commitPlaylistEdit({setItem:()=>{writes++}},"playlists",[{id:"a",name:"A",trackIds:[]},{id:"a",name:"B",trackIds:[]}])).toThrow("Duplicate saved playlist ID");
   expect(writes).toBe(0);
  });
 });

describe("track deletion consistency",()=>{
 const original=[{id:"mix",name:"Mix",trackIds:["keep","remove"]}];
 function storage(){
  const values=new Map<string,string>([["playlists",JSON.stringify(original)]]);
  return {values,setItem:(key:string,value:string)=>{values.set(key,value)},getItem:(key:string)=>values.get(key)??null};
 }
 it("persists reference cleanup before deleting the audio record",async()=>{
  const store=storage();
  const next=await deleteTrackWithPlaylistCleanup(store,"playlists",original,"remove",async()=>{
   expect(parseStoredPlaylists(store.getItem("playlists"))[0].trackIds).toEqual(["keep"]);
  });
  expect(next[0].trackIds).toEqual(["keep"]);
 });
 it("never deletes audio when playlist persistence fails",async()=>{
  const store=storage();let deleted=false;
  const failing={setItem:()=>{throw new Error("QuotaExceededError")}};
  await expect(deleteTrackWithPlaylistCleanup(failing,"playlists",original,"remove",async()=>{deleted=true})).rejects.toThrow("QuotaExceededError");
  expect(deleted).toBe(false);
  expect(parseStoredPlaylists(store.getItem("playlists"))).toEqual(original);
 });
 it("rolls back references if IndexedDB deletion rejects",async()=>{
  const store=storage();
  await expect(deleteTrackWithPlaylistCleanup(store,"playlists",original,"remove",async()=>{throw new Error("IDB abort")})).rejects.toThrow("IDB abort");
  expect(parseStoredPlaylists(store.getItem("playlists"))).toEqual(original);
 });
 it("reports rollback failure without pretending deletion succeeded",async()=>{
  const store=storage();let writes=0;
  const failing={setItem:(key:string,value:string)=>{if(++writes===2)throw new Error("QuotaExceededError");store.setItem(key,value)}};
  await expect(deleteTrackWithPlaylistCleanup(failing,"playlists",original,"remove",async()=>{throw new Error("IDB abort")})).rejects.toThrow("rollback could not be saved");
  expect(parseStoredPlaylists(store.getItem("playlists"))[0].trackIds).toEqual(["keep"]);
 });
});
