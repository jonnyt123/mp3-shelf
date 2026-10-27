import{describe,expect,it}from"vitest";
import{createLibraryBackup,parseLibraryBackup}from"./backup";
import type{Track}from"./tracks";

describe("MP3 Shelf backups",()=>{
 it("round-trips track bytes, metadata, artwork, and playlists",async()=>{
  const track:Track={id:"song-1",name:"First song",originalName:"first.mp3",artist:"Artist",album:"Album",size:4,type:"audio/mpeg",importedAt:123,blob:new Blob([new Uint8Array([1,2,3,4])],{type:"audio/mpeg"}),artwork:new Blob([new Uint8Array([8,9])],{type:"image/png"})};
  const file=createLibraryBackup([track],[{id:"mix-1",name:"Favorites",trackIds:["song-1"]}]);
  const restored=await parseLibraryBackup(file);
  expect(restored.tracks[0]).toMatchObject({id:"song-1",name:"First song",artist:"Artist",album:"Album",size:4,type:"audio/mpeg",importedAt:123});
  expect([...new Uint8Array(await restored.tracks[0].blob.arrayBuffer())]).toEqual([1,2,3,4]);
  expect([...new Uint8Array(await restored.tracks[0].artwork!.arrayBuffer())]).toEqual([8,9]);
  expect(restored.playlists).toEqual([{id:"mix-1",name:"Favorites",trackIds:["song-1"]}]);
 });

 it("retains native favorite, lyrics, license credits and Spotify wishes after a browser round trip",async()=>{
  const attribution={sourceURL:"https://example.org/song",licenseURL:"https://example.org/license",creator:"Creator",license:"CC BY",provider:"Independent Catalog"};
  const nativeManifest={
   schema:"mp3-shelf-backup",version:1,createdAt:"2026-10-18T00:00:00Z",
   tracks:[{id:"browser-song-1",name:"Offline original",originalName:"original.mp3",artist:"Creator",album:"EP",importedAt:1792281600000,isFavorite:true,lyrics:"[00:01.00]An original line",attribution,
    audio:{offset:0,length:4,type:"audio/mpeg"},
    artwork:{offset:4,length:3,type:"image/jpeg"}}],
   playlists:[{id:"imported-list-1",name:"My playlist",trackIds:["browser-song-1"],sourceURL:"https://open.spotify.com/playlist/abc",
    wishes:[{title:"Offline original",artist:"Creator",album:"EP",spotifyURL:"https://open.spotify.com/track/abc"}]}]
  };
  const bytes=new TextEncoder().encode(JSON.stringify(nativeManifest));
  const length=new Uint8Array(4);
  new DataView(length.buffer).setUint32(0,bytes.length,true);
  const nativeFile=new Blob(["MP3SHELF1\n",length,bytes,new Uint8Array([73,68,51,4,255,216,217])]);
  const imported=await parseLibraryBackup(nativeFile);
  expect(imported.tracks[0]).toMatchObject({id:"browser-song-1",isFavorite:true,lyrics:"[00:01.00]An original line",attribution});
  expect(imported.playlists[0].wishes?.[0].spotifyURL).toBe("https://open.spotify.com/track/abc");
  const exported=createLibraryBackup(imported.tracks,imported.playlists);
  const roundTripped=await parseLibraryBackup(exported);
  expect(roundTripped.tracks[0]).toMatchObject({id:"browser-song-1",isFavorite:true,lyrics:"[00:01.00]An original line",attribution});
  expect(roundTripped.playlists).toEqual(imported.playlists);
  expect([...new Uint8Array(await roundTripped.tracks[0].blob.arrayBuffer())]).toEqual([73,68,51,4]);
  expect([...new Uint8Array(await roundTripped.tracks[0].artwork!.arrayBuffer())]).toEqual([255,216,217]);
 });

 it("removes deleted song references during export and rejects broken archive references",async()=>{
  const exported=createLibraryBackup([],[{id:"list-1",name:"A list",trackIds:["deleted-song"]}]);
  expect((await parseLibraryBackup(exported)).playlists[0].trackIds).toEqual([]);
  const manifest={schema:"mp3-shelf-backup",version:1,createdAt:"2026-10-18T00:00:00Z",
   tracks:[],playlists:[{id:"list-1",name:"A list",trackIds:["nonexistent"]}]};
  const bytes=new TextEncoder().encode(JSON.stringify(manifest));
  const size=new Uint8Array(4);
  new DataView(size.buffer).setUint32(0,bytes.length,true);
  await expect(parseLibraryBackup(new Blob(["MP3SHELF1\n",size,bytes]))).rejects.toThrow("references");
 });

 it("rejects unrelated and truncated files",async()=>{
  await expect(parseLibraryBackup(new Blob(["not a backup"]))).rejects.toThrow("not an MP3 Shelf backup");
  const valid=createLibraryBackup([],[]);
  await expect(parseLibraryBackup(valid.slice(0,valid.size-1))).rejects.toThrow();
 });
});
