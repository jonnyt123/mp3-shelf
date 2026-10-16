import {describe,it,expect} from "vitest";
import {sortLibraryTracks} from "./sort-tracks";
const tracks=[
 {id:"3",name:"Track 10",artist:"Bravo",importedAt:30},
 {id:"1",name:"Track 2",artist:"Alpha",importedAt:10},
 {id:"2",name:"Acoustic",artist:"Alpha",importedAt:20}
];
describe("non-destructive music sorting",()=>{
 it("preserves source arrays and sorts recent imports by date",()=>{
  const sorted=sortLibraryTracks(tracks,"recent");
  expect(sorted.map(item=>item.id)).toEqual(["3","2","1"]);
  expect(tracks.map(item=>item.id)).toEqual(["3","1","2"]);
 });
 it("sorts track titles naturally, ignoring numeric lexical surprises",()=>{
  expect(sortLibraryTracks(tracks,"title").map(item=>item.id)).toEqual(["2","1","3"]);
 });
 it("groups artists with title as tie-breaker",()=>{
  expect(sortLibraryTracks(tracks,"artist").map(item=>item.id)).toEqual(["2","1","3"]);
 });
});