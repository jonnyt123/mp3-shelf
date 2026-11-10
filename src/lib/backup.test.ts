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

 it("rejects unrelated and truncated files",async()=>{
  await expect(parseLibraryBackup(new Blob(["not a backup"]))).rejects.toThrow("not an MP3 Shelf backup");
  const valid=createLibraryBackup([],[]);
  await expect(parseLibraryBackup(valid.slice(0,valid.size-1))).rejects.toThrow();
 });
 it("rejects overlapping binary ranges and duplicate IDs before restoring",async()=>{
  const track:Track={id:"song-1",name:"First",size:4,type:"audio/mpeg",importedAt:123,blob:new Blob([new Uint8Array([1,2,3,4])]),artwork:new Blob([new Uint8Array([5,6])])};
  const original=createLibraryBackup([track],[{id:"mix-1",name:"Mix",trackIds:["song-1"]}]);
  const bytes=new Uint8Array(await original.arrayBuffer());
  const headerSize=new TextEncoder().encode("MP3SHELF1\n").length+4;
  const manifestSize=new DataView(bytes.buffer).getUint32(headerSize-4,true);
  const manifest=JSON.parse(new TextDecoder().decode(bytes.slice(headerSize,headerSize+manifestSize)));
  const payload=bytes.slice(headerSize+manifestSize);
  const corrupt=(value:unknown)=>{const json=new TextEncoder().encode(JSON.stringify(value));const header=bytes.slice(0,headerSize);new DataView(header.buffer).setUint32(headerSize-4,json.length,true);return new Blob([header,json,payload])};
  manifest.tracks[0].artwork.offset=2;
  await expect(parseLibraryBackup(corrupt(manifest))).rejects.toThrow("Overlapping");
  manifest.tracks[0].artwork.offset=4;
  manifest.tracks.push({...manifest.tracks[0]});
  await expect(parseLibraryBackup(corrupt(manifest))).rejects.toThrow("Duplicate track ID");
  manifest.tracks.pop();
  manifest.playlists.push({...manifest.playlists[0]});
  await expect(parseLibraryBackup(corrupt(manifest))).rejects.toThrow("Duplicate playlist ID");
  manifest.playlists.pop();
  manifest.playlists[0].trackIds=["  "];
  await expect(parseLibraryBackup(corrupt(manifest))).rejects.toThrow("Invalid playlist 1");
  manifest.playlists[0].trackIds=["song-1"];
  manifest.tracks[0].audio.length=0;
  await expect(parseLibraryBackup(corrupt(manifest))).rejects.toThrow("Empty track 1 audio");
 });

 it("refuses to export records that the restore parser would reject",()=>{
  const makeTrack=(id:string,bytes:number[]):Track=>({id,name:"Song",size:bytes.length,type:"audio/mpeg",importedAt:123,blob:new Blob([new Uint8Array(bytes)])});
  const song=makeTrack("song-1",[1,2,3]);
  expect(()=>createLibraryBackup([song,makeTrack("song-1",[4])],[])).toThrow("Duplicate track ID");
  expect(()=>createLibraryBackup([makeTrack("empty",[])],[])).toThrow("empty audio");
  expect(()=>createLibraryBackup([{...song,artwork:new Blob([])}],[])).toThrow("empty artwork");
  expect(()=>createLibraryBackup([song],[{id:"mix",name:"Mix",trackIds:["song-1"]},{id:"mix",name:"Other",trackIds:[]}])).toThrow("Duplicate playlist ID");
  expect(()=>createLibraryBackup([{...song,name:"  "}],[])).toThrow("without an ID and name");
  expect(()=>createLibraryBackup([{...song,importedAt:Number.NaN}],[])).toThrow("invalid import date");
  expect(()=>createLibraryBackup([{...song,importedAt:Number.POSITIVE_INFINITY}],[])).toThrow("invalid import date");
  expect(()=>createLibraryBackup([song],[{id:"mix",name:"Mix",trackIds:[123] as unknown as string[]}])).toThrow("invalid track references");
  expect(()=>createLibraryBackup([song],[{id:"mix",name:"Mix",trackIds:["  "]}])).toThrow("invalid track references");
 });

});
