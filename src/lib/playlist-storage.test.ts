import {describe,it,expect} from "vitest";
import {parseStoredPlaylists} from "./playlist-storage";
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
