import{describe,expect,it}from"vitest";
import{createLibraryBackup,parseLibraryBackup}from"./backup";
import type{Track}from"./tracks";

describe("MP3 Shelf backups",()=>{
 it("round-trips track bytes, metadata, artwork, and playlists",async()=>{
  const track:Track={id:"song-1",name:"First song",originalName:"first.mp3",artist:"Artist",album:"Album",lyrics:"[00:01.00] Hello",size:4,type:"audio/mpeg",importedAt:123,blob:new Blob([new Uint8Array([1,2,3,4])],{type:"audio/mpeg"}),artwork:new Blob([new Uint8Array([8,9])],{type:"image/png"})};
  const file=createLibraryBackup([track],[{id:"mix-1",name:"Favorites",trackIds:["song-1"]}]);
  const restored=await parseLibraryBackup(file);
  expect(restored.tracks[0]).toMatchObject({id:"song-1",name:"First song",artist:"Artist",album:"Album",lyrics:"[00:01.00] Hello",size:4,type:"audio/mpeg",importedAt:123});
  expect([...new Uint8Array(await restored.tracks[0].blob.arrayBuffer())]).toEqual([1,2,3,4]);
  expect([...new Uint8Array(await restored.tracks[0].artwork!.arrayBuffer())]).toEqual([8,9]);
  expect(restored.playlists).toEqual([{id:"mix-1",name:"Favorites",trackIds:["song-1"]}]);
 });

 it("backs up Spotify playlist metadata without saving Spotify audio",async()=>{
  const playlist={id:"spotify-playlist",name:"Road Mix",trackIds:[],
    sourceURL:"https://open.spotify.com/playlist/0123456789ABCDEFGHIJKL",
    wishes:[{title:"Song",artist:"Artist",album:"Record",spotifyURL:"https://open.spotify.com/track/0123456789ABCDEFGHIJKL"}]};
  const result=await parseLibraryBackup(createLibraryBackup([],[playlist]));
  expect(result.tracks).toHaveLength(0);
  expect(result.playlists).toEqual([playlist]);
 });

 it("round-trips independent audio attribution without altering audio bytes",async()=>{
  const attribution={sourceURL:"https://example.org/source",licenseURL:"https://creativecommons.org/licenses/by/4.0/",
    creator:"Original musician",license:"BY",provider:"Openverse"};
  const track:Track={id:"licensed",name:"Licensed track",size:3,type:"audio/mpeg",
    importedAt:10,blob:new Blob([new Uint8Array([73,68,51])]),attribution};
  const restored=await parseLibraryBackup(createLibraryBackup([track],[]));
  expect(restored.tracks[0].attribution).toEqual(attribution);
  expect([...new Uint8Array(await restored.tracks[0].blob.arrayBuffer())]).toEqual([73,68,51]);
 });
 it("rejects unrelated and truncated files",async()=>{
  await expect(parseLibraryBackup(new Blob(["not a backup"]))).rejects.toThrow("not an MP3 Shelf backup");
  const valid=createLibraryBackup([],[]);
  await expect(parseLibraryBackup(valid.slice(0,valid.size-1))).rejects.toThrow();
 });
});
