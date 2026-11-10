import {describe,it,expect} from "vitest";
import {cancelPlaylistRestore,hasPendingPlaylistRestore,parseStoredPlaylists,persistRestoredPlaylists,recoverPlaylistRestore,selectPlaylistTracks,stagePlaylistRestore} from "./playlist-storage";
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
 it("recovers after audio commits but before playlists are saved, without reverting local edits",()=>{
  const storage=store();
  stagePlaylistRestore(storage,[{id:"b"}],incoming);
  expect(hasPendingPlaylistRestore(storage)).toBe(true);
  const result=recoverPlaylistRestore(storage,new Set(["a","b"]),"playlists");
  expect(result).toEqual([{id:"local",name:"Edited",trackIds:["a","b"]},{id:"new",name:"New",trackIds:["b"]}]);
  expect(hasPendingPlaylistRestore(storage)).toBe(false);
  expect(recoverPlaylistRestore(storage,new Set(["a","b"]),"playlists")).toBeNull();
 });
 it("never publishes playlist links if a crash happened before audio insertion",()=>{
  const storage=store();
  stagePlaylistRestore(storage,[{id:"b"}],incoming);
  expect(()=>recoverPlaylistRestore(storage,new Set(["a"]),"playlists")).toThrow("interrupted");
  expect(JSON.parse(storage.getItem("playlists")!)[0].trackIds).toEqual(["a"]);
  expect(hasPendingPlaylistRestore(storage)).toBe(true);
  expect(()=>stagePlaylistRestore(storage,[{id:"different"}],incoming)).toThrow("original backup");
  expect(()=>stagePlaylistRestore(storage,[{id:"b"}],incoming)).not.toThrow();
 });
 it("retains pending recovery after playlist quota failure",()=>{
  const storage=store();
  stagePlaylistRestore(storage,[{id:"b"}],incoming);
  const failed={...storage,setItem:(key:string,value:string)=>{if(key==="playlists")throw new Error("QuotaExceeded");storage.setItem(key,value)}};
  expect(()=>recoverPlaylistRestore(failed,new Set(["a","b"]),"playlists")).toThrow("QuotaExceeded");
  expect(hasPendingPlaylistRestore(storage)).toBe(true);
  expect(JSON.parse(storage.getItem("playlists")!)[0].trackIds).toEqual(["a"]);
  cancelPlaylistRestore(storage);
  expect(hasPendingPlaylistRestore(storage)).toBe(false);
 });
});
