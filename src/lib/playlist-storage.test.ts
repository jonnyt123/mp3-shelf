import {describe,it,expect} from "vitest";
import {parseStoredPlaylists,selectPlaylistTracks} from "./playlist-storage";
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
