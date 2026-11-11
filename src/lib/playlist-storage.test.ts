import {describe,it,expect} from "vitest";
import {deleteTrackWithPlaylistCleanup,recoverFailedTrackDeletion,commitPlaylistEdit,cancelPlaylistRestore,hasPendingPlaylistRestore,parseStoredPlaylists,persistRestoredPlaylists,recoverPlaylistRestore,selectPlaylistTracks,stagePlaylistRestore,updateStoredPlaylists} from "./playlist-storage";
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
 it("refuses to replay a pending restore into a different playlist namespace",()=>{
  const storage=store();
  const other="other-playlists";
  storage.setItem(other,JSON.stringify([{id:"other",name:"Untouched",trackIds:["a"]}]));
  stagePlaylistRestore(storage,"playlists",[{id:"b"}],incoming);
  const original=storage.getItem(other);
  expect(()=>recoverPlaylistRestore(storage,new Set(["a","b"]),other)).toThrow("different playlist storage key");
  expect(storage.getItem(other)).toBe(original);
  expect(hasPendingPlaylistRestore(storage)).toBe(true);
  expect(recoverPlaylistRestore(storage,new Set(["a","b"]),"playlists")).not.toBeNull();
 });
 it("rejects malformed pending journals without modifying any playlist namespace",()=>{
  const malformed=[
   {version:1,key:"playlists",trackIds:["a","a"],playlists:[]},
   {version:1,key:"playlists",trackIds:[""],playlists:[]},
   {version:1,key:"playlists",trackIds:["a"],playlists:[{id:"duplicate",name:"First",trackIds:[]},{id:"duplicate",name:"Second",trackIds:[]}]},
   {version:1,key:"",trackIds:["a"],playlists:[]},
   {version:2,key:"playlists",trackIds:["a"],playlists:[]}
  ];
  for(const journal of malformed){
   const storage=store();
   const before=storage.getItem("playlists");
   storage.setItem("mp3-shelf-restore-pending",JSON.stringify(journal));
   expect(()=>recoverPlaylistRestore(storage,new Set(["a","b"]),"playlists")).toThrow();
   expect(storage.getItem("playlists")).toBe(before);
   expect(hasPendingPlaylistRestore(storage)).toBe(true);
  }
 });
 it("rejects duplicate backup track IDs before creating a recovery journal",()=>{
  const storage=store();
  expect(()=>stagePlaylistRestore(storage,"playlists",[{id:"b"},{id:"b"}],incoming)).toThrow("Invalid backup track IDs");
  expect(hasPendingPlaylistRestore(storage)).toBe(false);
 });
 it("can recover legacy version-one restore journals without a storage key",()=>{
  const storage=store();
  storage.setItem("mp3-shelf-restore-pending",JSON.stringify({version:1,trackIds:["b"],playlists:incoming}));
  expect(recoverPlaylistRestore(storage,new Set(["a","b"]),"playlists")?.[0].trackIds).toEqual(["a","b"]);
  expect(hasPendingPlaylistRestore(storage)).toBe(false);
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
 it("rejects dangling playlist links even after all imported recordings are present",()=>{
  const storage=store();
  const bad=[{id:"new",name:"Incomplete archive",trackIds:["b","missing"]}];
  stagePlaylistRestore(storage,"playlists",[{id:"b"}],bad);
  const before=storage.getItem("playlists");
  expect(()=>recoverPlaylistRestore(storage,new Set(["a","b"]),"playlists"))
   .toThrow("references missing audio");
  expect(storage.getItem("playlists")).toBe(before);
  expect(hasPendingPlaylistRestore(storage)).toBe(true);
 });
 it("allows restored playlists to reference recordings already in the local library",()=>{
  const storage=store();
  stagePlaylistRestore(storage,"playlists",[{id:"b"}],[{id:"new",name:"Mixed",trackIds:["a","b"]}]);
  expect(recoverPlaylistRestore(storage,new Set(["a","b"]),"playlists"))
   .toContainEqual({id:"new",name:"Mixed",trackIds:["a","b"]});
  expect(hasPendingPlaylistRestore(storage)).toBe(false);
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
  return {values,setItem:(key:string,value:string)=>{values.set(key,value)},getItem:(key:string)=>values.get(key)??null,removeItem:(key:string)=>{values.delete(key)}};
 }
 it("refuses audio deletion while a backup restore is staged",async()=>{
  const store=storage();
  const staged=stagePlaylistRestore(store,"playlists",[{id:"restored"}],[{id:"restored-list",name:"Imported",trackIds:["restored"]}]);
  expect(staged).toBe(true);
  let called=false;
  await expect(deleteTrackWithPlaylistCleanup(store,"playlists",original,"remove",async()=>{called=true}))
   .rejects.toThrow("pending backup restore");
  expect(called).toBe(false);
  expect(hasPendingPlaylistRestore(store)).toBe(true);
  expect(store.getItem("mp3-shelf-delete-recovery")).toBeNull();
  expect(parseStoredPlaylists(store.getItem("playlists"))).toEqual(original);
 });
 it("refuses backup staging during an in-flight audio deletion without replacing its journal",async()=>{
  const store=storage();
  let complete!:()=>void;
  const pending=new Promise<void>(resolve=>{complete=resolve});
  const deleting=deleteTrackWithPlaylistCleanup(store,"playlists",original,"remove",async()=>{await pending});
  const before=store.getItem("mp3-shelf-delete-recovery");
  expect(before).not.toBeNull();
  expect(()=>stagePlaylistRestore(store,"playlists",[{id:"restored"}],[{id:"new",name:"New",trackIds:["restored"]}]))
   .toThrow("pending track deletion recovery");
  expect(store.getItem("mp3-shelf-delete-recovery")).toBe(before);
  expect(hasPendingPlaylistRestore(store)).toBe(false);
  complete();
  await deleting;
  expect(store.getItem("mp3-shelf-delete-recovery")).toBeNull();
 });
 it("rejects empty backup destination keys before writing recovery intent",()=>{
  const store=storage();
  expect(()=>stagePlaylistRestore(store," ",[{id:"restored"}],[])).toThrow("Invalid playlist storage key");
  expect(hasPendingPlaylistRestore(store)).toBe(false);
 });
 it("persists reference cleanup before deleting the audio record",async()=>{
  const store=storage();
  const next=await deleteTrackWithPlaylistCleanup(store,"playlists",original,"remove",async()=>{
   expect(parseStoredPlaylists(store.getItem("playlists"))[0].trackIds).toEqual(["keep"]);
  });
  expect(next[0].trackIds).toEqual(["keep"]);
 });
 it("returns latest playlist edits after an asynchronous audio deletion",async()=>{
  const store=storage();
  let finishDeletion!:()=>void;
  const pending=new Promise<void>(resolve=>{finishDeletion=resolve});
  const deleting=deleteTrackWithPlaylistCleanup(store,"playlists",original,"remove",async()=>{await pending});
  // The user renames a playlist and adds another track while IDB is pending.
  commitPlaylistEdit(store,"playlists",[{id:"mix",name:"Updated",trackIds:["keep","new"]}]);
  finishDeletion();
  expect(await deleting).toEqual([{id:"mix",name:"Updated",trackIds:["keep","new"]}]);
  expect(parseStoredPlaylists(store.getItem("playlists"))).toEqual([{id:"mix",name:"Updated",trackIds:["keep","new"]}]);
 });
 it("preserves audio when another tab reattaches a track before deletion",async()=>{
  const store=storage();let deleted=false;
  await expect(deleteTrackWithPlaylistCleanup(store,"playlists",original,"remove",async()=>{
   deleted=true;
  })).resolves.toEqual([{id:"mix",name:"Mix",trackIds:["keep"]}]);
  expect(deleted).toBe(true);
  // Inject a synchronous cross-tab write immediately after the playlist
  // cleanup commit, before the asynchronous IndexedDB deletion begins.
  const other=storage();
  const interfering={...other,
   getItem:store.getItem,
   removeItem:store.removeItem,
   setItem:(key:string,value:string)=>{
    store.setItem(key,value);
    if(key==="playlists"){
     store.setItem(key,JSON.stringify([{id:"mix",name:"Concurrent",trackIds:["keep","remove"]}]));
    }
   }
  };
  deleted=false;
  await expect(deleteTrackWithPlaylistCleanup(interfering,"playlists",original,"remove",async()=>{deleted=true}))
   .rejects.toThrow("added to a playlist during deletion");
  expect(deleted).toBe(false);
  expect(parseStoredPlaylists(store.getItem("playlists"))).toEqual([{id:"mix",name:"Concurrent",trackIds:["keep","remove"]}]);
  expect(store.getItem("mp3-shelf-delete-recovery")).toBeNull();
 });
 it("removes references reattached while IndexedDB deletion is pending",async()=>{
  const store=storage();
  let complete!:()=>void;
  const pending=new Promise<void>(resolve=>{complete=resolve});
  const deletion=deleteTrackWithPlaylistCleanup(store,"playlists",original,"remove",async()=>{await pending});
  // A second tab updates the durable playlist after the pre-delete check.
  store.setItem("playlists",JSON.stringify([
   {id:"mix",name:"Concurrent rename",trackIds:["keep","remove","new"]},
   {id:"other",name:"New playlist",trackIds:["remove","new"]}
  ]));
  complete();
  const result=await deletion;
  expect(result).toEqual([
   {id:"mix",name:"Concurrent rename",trackIds:["keep","new"]},
   {id:"other",name:"New playlist",trackIds:["new"]}
  ]);
  expect(parseStoredPlaylists(store.getItem("playlists"))).toEqual(result);
  expect(store.getItem("mp3-shelf-delete-recovery")).toBeNull();
 });
 it("retains recovery journal if post-delete reference cleanup cannot persist",async()=>{
  const store=storage();
  let writes=0;
  const failing={...store,setItem:(key:string,value:string)=>{
   if(key==="playlists"&&++writes===2)throw new Error("QuotaExceededError");
   store.setItem(key,value);
  }};
  await expect(deleteTrackWithPlaylistCleanup(failing,"playlists",original,"remove",async()=>{
   store.setItem("playlists",JSON.stringify([{id:"mix",name:"Other tab",trackIds:["keep","remove"]}]));
  })).rejects.toThrow("QuotaExceededError");
  expect(store.getItem("mp3-shelf-delete-recovery")).not.toBeNull();
  expect(recoverFailedTrackDeletion(store,new Set(["keep"]))).toEqual([{id:"mix",name:"Other tab",trackIds:["keep"]}]);
  // Startup uses the actual surviving IndexedDB IDs to remove dangling links.
  expect(store.getItem("mp3-shelf-delete-recovery")).toBeNull();
 });
 it("rejects blank track IDs before touching storage or audio",async()=>{
  const store=storage();let deleted=false;
  await expect(deleteTrackWithPlaylistCleanup(store,"playlists",original," ",async()=>{deleted=true})).rejects.toThrow("Invalid track ID");
  expect(deleted).toBe(false);
  expect(store.getItem("mp3-shelf-delete-recovery")).toBeNull();
  expect(parseStoredPlaylists(store.getItem("playlists"))).toEqual(original);
 });
 it("updates playlists from current durable state, preserving edits from other tabs",()=>{
  const store=storage();
  const stale=original;
  store.setItem("playlists",JSON.stringify([{id:"mix",name:"Other tab rename",trackIds:["keep","remove","new"]}]));
  const result=updateStoredPlaylists(store,"playlists",current=>current.map(p=>({...p,trackIds:p.trackIds.filter(id=>id!=="remove")})));
  expect(result).toEqual([{id:"mix",name:"Other tab rename",trackIds:["keep","new"]}]);
  expect(stale[0].name).toBe("Mix");
  expect(parseStoredPlaylists(store.getItem("playlists"))).toEqual(result);
 });
 it("never deletes audio when playlist persistence fails",async()=>{
  const store=storage();let deleted=false;
  const failing={...store,setItem:()=>{throw new Error("QuotaExceededError")}};
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
  const failing={...store,setItem:(key:string,value:string)=>{if(++writes===3)throw new Error("QuotaExceededError");store.setItem(key,value)}};
  await expect(deleteTrackWithPlaylistCleanup(failing,"playlists",original,"remove",async()=>{throw new Error("IDB abort")})).rejects.toThrow("rollback could not be saved");
  expect(parseStoredPlaylists(store.getItem("playlists"))[0].trackIds).toEqual(["keep"]);
  expect(store.getItem("mp3-shelf-delete-recovery")).not.toBeNull();
  expect(recoverFailedTrackDeletion(store,new Set(["remove","keep"]))?.[0].trackIds).toEqual(["keep","remove"]);
 });
 it("reconciles after restart without discarding intervening playlist edits",async()=>{
  const store=storage();let writes=0;
  const failing={...store,setItem:(key:string,value:string)=>{if(++writes===3)throw new Error("QuotaExceededError");store.setItem(key,value)}};
  await expect(deleteTrackWithPlaylistCleanup(failing,"playlists",original,"remove",async()=>{throw new Error("IDB abort")})).rejects.toThrow("rollback could not be saved");
  store.setItem("playlists",JSON.stringify([{id:"mix",name:"Renamed",trackIds:["keep","new"]}]));
  expect(recoverFailedTrackDeletion(store,new Set(["remove","keep","new"]))).toEqual([{id:"mix",name:"Renamed",trackIds:["keep","remove","new"]}]);
  expect(store.getItem("mp3-shelf-delete-recovery")).toBeNull();
 });
 it("recovers a failed deletion using its journaled playlist key",async()=>{
  const store=storage();
  const alternate="custom-playlists";
  store.setItem(alternate,JSON.stringify(original));
  let writes=0;
  const failing={...store,setItem:(key:string,value:string)=>{
   if(key===alternate&&++writes===2)throw new Error("QuotaExceededError");
   store.setItem(key,value);
  }};
  await expect(deleteTrackWithPlaylistCleanup(failing,alternate,original,"remove",async()=>{throw new Error("IDB abort")})).rejects.toThrow("rollback could not be saved");
  expect(recoverFailedTrackDeletion(store,new Set(["keep","remove"]))).toEqual(original);
  expect(parseStoredPlaylists(store.getItem(alternate))).toEqual(original);
 });
 it("does not restore references if audio was already removed before restart",async()=>{
  const store=storage();let writes=0;
  const failing={...store,removeItem:()=>{throw new Error("crash")}};
  await expect(deleteTrackWithPlaylistCleanup(failing,"playlists",original,"remove",async()=>{})).rejects.toThrow("crash");
  expect(recoverFailedTrackDeletion(store,new Set(["keep"]))?.[0].trackIds).toEqual(["keep"]);
 });
});


describe("conflicting recovery journals",()=>{
 function store(){
  const data=new Map<string,string>([["playlists",JSON.stringify([{id:"mix",name:"Safe",trackIds:["audio"]}])]]);
  return {
   getItem:(key:string)=>data.get(key)??null,
   setItem:(key:string,value:string)=>{data.set(key,value)},
   removeItem:(key:string)=>{data.delete(key)}
  };
 }
 it("does not replay a restore while deletion recovery is pending",()=>{
  const storage=store();
  stagePlaylistRestore(storage,"playlists",[{id:"new"}],[{id:"new-list",name:"New",trackIds:["new"]}]);
  const restore=storage.getItem("mp3-shelf-restore-pending");
  storage.setItem("mp3-shelf-delete-recovery",JSON.stringify({
   version:1,key:"playlists",trackId:"audio",
   original:[{id:"mix",name:"Safe",trackIds:["audio"]}]
  }));
  const before=storage.getItem("playlists");
  expect(()=>recoverPlaylistRestore(storage,new Set(["audio","new"]),"playlists"))
   .toThrow("pending track deletion recovery");
  expect(storage.getItem("playlists")).toBe(before);
  expect(storage.getItem("mp3-shelf-restore-pending")).toBe(restore);
  storage.removeItem("mp3-shelf-delete-recovery");
  expect(recoverPlaylistRestore(storage,new Set(["audio","new"]),"playlists")).not.toBeNull();
 });
 it("does not replay a deletion while backup restoration is pending",()=>{
  const storage=store();
  storage.setItem("mp3-shelf-delete-recovery",JSON.stringify({
   version:1,key:"playlists",trackId:"audio",
   original:[{id:"mix",name:"Safe",trackIds:["audio"]}]
  }));
  const deletion=storage.getItem("mp3-shelf-delete-recovery");
  storage.setItem("mp3-shelf-restore-pending",JSON.stringify({
   version:1,key:"playlists",trackIds:["new"],playlists:[]
  }));
  const before=storage.getItem("playlists");
  expect(()=>recoverFailedTrackDeletion(storage,new Set(["audio"])))
   .toThrow("pending backup restore");
  expect(storage.getItem("playlists")).toBe(before);
  expect(storage.getItem("mp3-shelf-delete-recovery")).toBe(deletion);
  storage.removeItem("mp3-shelf-restore-pending");
  expect(recoverFailedTrackDeletion(storage,new Set(["audio"]))).not.toBeNull();
 });
 it.each([""," ","\\t"])("rejects a blank deletion ID (%s) without altering playlists",trackId=>{
  const storage=store();
  storage.setItem("mp3-shelf-delete-recovery",JSON.stringify({
   version:1,key:"playlists",trackId,
   original:[{id:"mix",name:"Safe",trackIds:["audio"]}]
  }));
  const before=storage.getItem("playlists");
  expect(()=>recoverFailedTrackDeletion(storage,new Set(["audio"]))).toThrow("Invalid track deletion recovery journal");
  expect(storage.getItem("playlists")).toBe(before);
  expect(storage.getItem("mp3-shelf-delete-recovery")).not.toBeNull();
 });
});


describe("cross-tab playlist UI mutations",()=>{
 function store(initial:{id:string;name:string;trackIds:string[]}[]){
  const data=new Map([["playlists",JSON.stringify(initial)]]);
  return {getItem:(key:string)=>data.get(key)??null,setItem:(key:string,value:string)=>{data.set(key,value)}};
 }
 it("creates a playlist without erasing a playlist added by another tab",()=>{
  const storage=store([{id:"a",name:"A",trackIds:["one"]}]);
  const staleSnapshot=parseStoredPlaylists(storage.getItem("playlists"));
  storage.setItem("playlists",JSON.stringify([...staleSnapshot,{id:"remote",name:"Remote",trackIds:["two"]}]));
  const result=updateStoredPlaylists(storage,"playlists",current=>[...current,{id:"local",name:"Local",trackIds:[]}]);
  expect(result.map(item=>item.id)).toEqual(["a","remote","local"]);
  expect(parseStoredPlaylists(storage.getItem("playlists"))).toEqual(result);
 });
 it("adds a track without reverting concurrent rename or added songs",()=>{
  const storage=store([{id:"a",name:"Old",trackIds:["one"]}]);
  storage.setItem("playlists",JSON.stringify([{id:"a",name:"Renamed",trackIds:["one","remote"]}]));
  const result=updateStoredPlaylists(storage,"playlists",current=>current.map(item=>item.id==="a"?{...item,trackIds:[...item.trackIds,"local"]}:item));
  expect(result).toEqual([{id:"a",name:"Renamed",trackIds:["one","remote","local"]}]);
 });
 it("deletes only the selected playlist, retaining concurrent additions",()=>{
  const storage=store([{id:"a",name:"A",trackIds:[]},{id:"b",name:"B",trackIds:[]}]);
  storage.setItem("playlists",JSON.stringify([...parseStoredPlaylists(storage.getItem("playlists")),{id:"remote",name:"Remote",trackIds:[]}]));
  const result=updateStoredPlaylists(storage,"playlists",current=>current.filter(item=>item.id!=="a"));
  expect(result.map(item=>item.id)).toEqual(["b","remote"]);
 });
 it("reorders against current persisted order instead of stale UI order",()=>{
  const storage=store([{id:"a",name:"A",trackIds:[]},{id:"b",name:"B",trackIds:[]}]);
  storage.setItem("playlists",JSON.stringify([{id:"remote",name:"Remote",trackIds:[]},...parseStoredPlaylists(storage.getItem("playlists"))]));
  const result=updateStoredPlaylists(storage,"playlists",current=>{const next=[...current],i=next.findIndex(item=>item.id==="b");[next[i-1],next[i]]=[next[i],next[i-1]];return next});
  expect(result.map(item=>item.id)).toEqual(["remote","b","a"]);
 });
 it("preserves the saved value when a write fails",()=>{
  const storage=store([{id:"a",name:"A",trackIds:[]}]);
  const before=storage.getItem("playlists");
  const failing={getItem:storage.getItem,setItem:(_key:string,_value:string):void=>{throw new Error("QuotaExceededError")}};
  expect(()=>updateStoredPlaylists(failing,"playlists",current=>[...current,{id:"b",name:"B",trackIds:[]}])).toThrow("QuotaExceededError");
  expect(storage.getItem("playlists")).toBe(before);
 });
 it("rejects corrupt current storage without overwriting it",()=>{
  const storage=store([]);
  storage.setItem("playlists","{invalid");
  expect(()=>updateStoredPlaylists(storage,"playlists",()=>[])).toThrow();
  expect(storage.getItem("playlists")).toBe("{invalid");
 });
});


describe("journal-aware ordinary playlist edits",()=>{
 function store(){
  const data=new Map<string,string>([["playlists",JSON.stringify([{id:"saved",name:"Keep",trackIds:["audio"]}])]]);
  let writes=0;
  return {data,get writes(){return writes},getItem:(key:string)=>data.get(key)??null,
   setItem:(key:string,value:string)=>{writes++;data.set(key,value)},
   removeItem:(key:string)=>{data.delete(key)}};
 }
 const edit=(items:readonly {id:string;name:string;trackIds:string[]}[])=>
  [...items,{id:"new",name:"New",trackIds:[]}];
 it.each(["mp3-shelf-delete-recovery","mp3-shelf-restore-pending"])(
  "rejects edits while %s exists without invoking updater or changing playlists",journalKey=>{
   const storage=store();
   storage.data.set(journalKey,"pending");
   const before=storage.getItem("playlists");
   let invoked=false;
   expect(()=>updateStoredPlaylists(storage,"playlists",current=>{invoked=true;return edit(current)})).toThrow(/pending|Finish/);
   expect(invoked).toBe(false);
   expect(storage.writes).toBe(0);
   expect(storage.getItem("playlists")).toBe(before);
   expect(storage.getItem(journalKey)).toBe("pending");
  });
 it("allows edits after recovery journals have been cleared",()=>{
  const storage=store();
  storage.data.set("mp3-shelf-delete-recovery","pending");
  storage.removeItem("mp3-shelf-delete-recovery");
  expect(updateStoredPlaylists(storage,"playlists",edit)).toEqual([
   {id:"saved",name:"Keep",trackIds:["audio"]},{id:"new",name:"New",trackIds:[]}
  ]);
  expect(storage.writes).toBe(1);
 });
 it("refuses a journal staged during playlist hydration before committing",()=>{
  const storage=store();
  const before=storage.getItem("playlists");
  const adapter={
   getItem:(key:string)=>{
    const value=storage.getItem(key);
    if(key==="playlists")storage.data.set("mp3-shelf-restore-pending","staged");
    return value;
   },
   setItem:storage.setItem
  };
  expect(()=>updateStoredPlaylists(adapter,"playlists",edit)).toThrow("started while editing");
  expect(storage.getItem("playlists")).toBe(before);
  expect(storage.writes).toBe(0);
 });
});

describe("optimistic playlist edit conflict detection",()=>{
 it("rejects an updater whose storage snapshot changes during evaluation",()=>{
  const key="playlists";
  const original=[{id:"a",name:"Original",trackIds:["one"]}];
  const concurrent=[{id:"a",name:"Edited in another tab",trackIds:["one","two"]}];
  const values=new Map([[key,JSON.stringify(original)]]);
  let writes=0;
  const adapter={
   getItem:(name:string)=>values.get(name)??null,
   setItem:(name:string,value:string)=>{writes++;values.set(name,value)}
  };
  expect(()=>updateStoredPlaylists(adapter,key,current=>{
   values.set(key,JSON.stringify(concurrent));
   return current.map(p=>({...p,name:"Stale rename"}));
  })).toThrow("Playlists changed while editing");
  expect(writes).toBe(0);
  expect(parseStoredPlaylists(values.get(key)!)).toEqual(concurrent);
 });
 it("accepts unchanged snapshots and preserves unrelated tracks",()=>{
  const key="playlists";
  const values=new Map([[key,JSON.stringify([{id:"a",name:"Keep",trackIds:["one"]}])]]);
  const adapter={getItem:(name:string)=>values.get(name)??null,setItem:(name:string,value:string)=>{values.set(name,value)}};
  const updated=updateStoredPlaylists(adapter,key,current=>current.map(p=>({...p,trackIds:[...p.trackIds,"two"]})));
  expect(updated[0].trackIds).toEqual(["one","two"]);
  expect(parseStoredPlaylists(values.get(key)!)).toEqual(updated);
 });
});

describe("restore merge concurrent-write protection",()=>{
 const key="playlists";
 const local=[{id:"mix",name:"Local",trackIds:["one"]}];
 const backup=[{id:"mix",name:"Backup",trackIds:["two"]}];
 it("does not overwrite a newer playlist edit while merging backup",()=>{
  const values=new Map<string,string>([[key,JSON.stringify(local)]]);
  const concurrent=[{id:"mix",name:"Other tab",trackIds:["one","three"]}];
  let reads=0,writes=0;
  const adapter={
   getItem:(name:string)=>{
    if(name===key&&++reads===2)values.set(key,JSON.stringify(concurrent));
    return values.get(name)??null;
   },
   setItem:(name:string,value:string)=>{writes++;values.set(name,value)}
  };
  expect(()=>persistRestoredPlaylists(adapter,key,backup)).toThrow("Playlists changed during backup restore");
  expect(writes).toBe(0);
  expect(parseStoredPlaylists(values.get(key)!)).toEqual(concurrent);
 });
 it("retains a pending restore journal on a concurrent playlist edit",()=>{
  const values=new Map<string,string>([[key,JSON.stringify(local)]]);
  const pendingKey="mp3-shelf-restore-pending";
  const adapter={
   getItem:(name:string)=>values.get(name)??null,
   setItem:(name:string,value:string)=>{values.set(name,value)},
   removeItem:(name:string)=>{values.delete(name)}
  };
  stagePlaylistRestore(adapter,key,[{id:"two"}],backup);
  const pending=values.get(pendingKey);
  let reads=0;
  const concurrent=[{id:"mix",name:"Updated elsewhere",trackIds:["one","three"]}];
  const racing={
   ...adapter,
   getItem:(name:string)=>{
    if(name===key&&++reads===2)values.set(key,JSON.stringify(concurrent));
    return adapter.getItem(name);
   }
  };
  expect(()=>recoverPlaylistRestore(racing,new Set(["one","two","three"]),key))
   .toThrow("Playlists changed during backup restore");
  expect(values.get(pendingKey)).toBe(pending);
  expect(parseStoredPlaylists(values.get(key)!)).toEqual(concurrent);
  expect(recoverPlaylistRestore(adapter,new Set(["one","two","three"]),key))
   .toEqual([{id:"mix",name:"Updated elsewhere",trackIds:["one","three","two"]}]);
  expect(values.has(pendingKey)).toBe(false);
 });
 it("commits a nonconflicting merge preserving local playlist metadata",()=>{
  const values=new Map<string,string>([[key,JSON.stringify(local)]]);
  const adapter={getItem:(name:string)=>values.get(name)??null,setItem:(name:string,value:string)=>{values.set(name,value)}};
  expect(persistRestoredPlaylists(adapter,key,backup))
   .toEqual([{id:"mix",name:"Local",trackIds:["one","two"]}]);
 });
});


describe("deletion snapshot byte-equivalence",()=>{
 const initial=[{id:"mix",name:"Keep",trackIds:["song","other"]}];
 function fixture(raw:string){
  const data=new Map<string,string>([["playlists",raw]]);
  return {getItem:(key:string)=>data.get(key)??null,
   setItem:(key:string,value:string)=>{data.set(key,value)},
   removeItem:(key:string)=>{data.delete(key)}};
 }
 it("accepts valid pretty-printed playlist JSON without a false concurrent-write conflict",async()=>{
  const storage=fixture(JSON.stringify(initial,null,2));
  let calls=0;
  const result=await deleteTrackWithPlaylistCleanup(storage,"playlists",initial,"song",async()=>{calls++});
  expect(calls).toBe(1);
  expect(result).toEqual([{id:"mix",name:"Keep",trackIds:["other"]}]);
  expect(storage.getItem("mp3-shelf-delete-recovery")).toBeNull();
 });
 it("still aborts if persisted bytes change while staging deletion",async()=>{
  const storage=fixture(JSON.stringify(initial,null,2));
  let calls=0;
  const racing={...storage,setItem:(key:string,value:string)=>{
   storage.setItem(key,value);
   if(key==="mp3-shelf-delete-recovery")
    storage.setItem("playlists",JSON.stringify([{id:"mix",name:"Remote",trackIds:["song","other","new"]}]));
  }};
  await expect(deleteTrackWithPlaylistCleanup(racing,"playlists",initial,"song",async()=>{calls++}))
   .rejects.toThrow("Playlists changed while staging deletion");
  expect(calls).toBe(0);
  expect(parseStoredPlaylists(storage.getItem("playlists"))[0].name).toBe("Remote");
  expect(storage.getItem("mp3-shelf-delete-recovery")).toBeNull();
 });
});

describe("deletion journal staging conflict regression",()=>{
 const initial=[{id:"mix",name:"Original",trackIds:["song","other"]}];
 function fixture(){
  const data=new Map<string,string>([["playlists",JSON.stringify(initial)]]);
  return {data,getItem:(key:string)=>data.get(key)??null,
   setItem:(key:string,value:string)=>{data.set(key,value)},
   removeItem:(key:string)=>{data.delete(key)}};
 }
 it("preserves a concurrent playlist edit made during journal staging and never deletes audio",async()=>{
  const store=fixture();
  const concurrent=[{id:"mix",name:"Renamed elsewhere",trackIds:["song","other","new"]}];
  let deleted=false;
  const storage={...store,setItem:(key:string,value:string)=>{
   store.setItem(key,value);
   if(key==="mp3-shelf-delete-recovery")store.setItem("playlists",JSON.stringify(concurrent));
  }};
  await expect(deleteTrackWithPlaylistCleanup(storage,"playlists",initial,"song",async()=>{deleted=true}))
   .rejects.toThrow("Playlists changed while staging deletion");
  expect(deleted).toBe(false);
  expect(parseStoredPlaylists(store.getItem("playlists"))).toEqual(concurrent);
  expect(store.getItem("mp3-shelf-delete-recovery")).toBeNull();
 });
 it("rejects a restore journal appearing while deletion intent is staged",async()=>{
  const store=fixture();
  let deleted=false;
  const storage={...store,setItem:(key:string,value:string)=>{
   store.setItem(key,value);
   if(key==="mp3-shelf-delete-recovery")
    store.setItem("mp3-shelf-restore-pending",JSON.stringify({version:1,key:"playlists",trackIds:[],playlists:[]}));
  }};
  await expect(deleteTrackWithPlaylistCleanup(storage,"playlists",initial,"song",async()=>{deleted=true}))
   .rejects.toThrow("backup restore started");
  expect(deleted).toBe(false);
  expect(parseStoredPlaylists(store.getItem("playlists"))).toEqual(initial);
  expect(store.getItem("mp3-shelf-delete-recovery")).toBeNull();
  expect(store.getItem("mp3-shelf-restore-pending")).not.toBeNull();
 });
});
