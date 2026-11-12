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

 it("rejects unreferenced payload bytes and missing media gaps",async()=>{
  const track:Track={id:"song",name:"Song",size:3,type:"audio/mpeg",importedAt:1,blob:new Blob([new Uint8Array([1,2,3])])};
  const valid=createLibraryBackup([track],[]);
  await expect(parseLibraryBackup(new Blob([valid,new Uint8Array([99])]))).rejects.toThrow("unreferenced media");
  const bytes=new Uint8Array(await valid.arrayBuffer());
  const headerSize=new TextEncoder().encode("MP3SHELF1\n").length+4;
  const manifestSize=new DataView(bytes.buffer).getUint32(headerSize-4,true);
  const manifest=JSON.parse(new TextDecoder().decode(bytes.slice(headerSize,headerSize+manifestSize)));
  manifest.tracks[0].audio.offset=1;
  manifest.tracks[0].audio.length=2;
  const json=new TextEncoder().encode(JSON.stringify(manifest));
  const header=bytes.slice(0,headerSize);
  new DataView(header.buffer).setUint32(headerSize-4,json.length,true);
  await expect(parseLibraryBackup(new Blob([header,json,bytes.slice(headerSize+manifestSize)]))).rejects.toThrow("unreferenced media");
 });

 it("rejects dangling playlist links before creating or importing a backup",async()=>{
  const track:Track={id:"present",name:"Present",size:3,type:"audio/mpeg",importedAt:1,blob:new Blob([new Uint8Array([1,2,3])])};
  expect(()=>createLibraryBackup([track],[{id:"mix",name:"Mix",trackIds:["present","missing"]}]))
   .toThrow("references missing recordings");
  expect(()=>createLibraryBackup([],[{id:"mix",name:"Mix",trackIds:["missing"]}]))
   .toThrow("references missing recordings");
  const valid=createLibraryBackup([track],[{id:"mix",name:"Mix",trackIds:["present"]}]);
  const bytes=new Uint8Array(await valid.arrayBuffer());
  const headerSize=new TextEncoder().encode("MP3SHELF1\n").length+4;
  const manifestSize=new DataView(bytes.buffer).getUint32(headerSize-4,true);
  const manifest=JSON.parse(new TextDecoder().decode(bytes.slice(headerSize,headerSize+manifestSize)));
  manifest.playlists[0].trackIds.push("missing");
  const encoded=new TextEncoder().encode(JSON.stringify(manifest));
  const header=bytes.slice(0,headerSize);
  new DataView(header.buffer).setUint32(headerSize-4,encoded.length,true);
  const corrupt=new Blob([header,encoded,bytes.slice(headerSize+manifestSize)]);
  await expect(parseLibraryBackup(corrupt)).rejects.toThrow("references missing audio");
  const parsed=await parseLibraryBackup(valid);
  expect(parsed.playlists[0].trackIds).toEqual(["present"]);
 });
 it("rejects corrupt playlist links without reading or copying audio payloads",async()=>{
  // Large archives must be rejected from their small manifest; a parser that
  // accidentally materializes payload bytes can exhaust mobile Safari memory.
  const track:Track={id:"song",name:"Song",size:3,type:"audio/mpeg",importedAt:1,blob:new Blob([new Uint8Array([1,2,3])])};
  const valid=createLibraryBackup([track],[{id:"mix",name:"Mix",trackIds:["song"]}]);
  const headerSize=new TextEncoder().encode("MP3SHELF1\n").length+4;
  const header=new Uint8Array(await valid.slice(0,headerSize).arrayBuffer());
  const manifestSize=new DataView(header.buffer).getUint32(headerSize-4,true);
  const manifest=JSON.parse(await valid.slice(headerSize,headerSize+manifestSize).text());
  manifest.playlists[0].trackIds=["missing"];
  const json=new TextEncoder().encode(JSON.stringify(manifest));
  new DataView(header.buffer).setUint32(headerSize-4,json.length,true);
  const archive=new Blob([header,json,valid.slice(headerSize+manifestSize)]);
  const guarded=new Proxy(archive,{
   get(target,property){
    if(property==="arrayBuffer")throw new Error("Whole archive read is forbidden");
    const value=Reflect.get(target,property,target);
    return typeof value==="function"?value.bind(target):value;
   }
  });
  await expect(parseLibraryBackup(guarded)).rejects.toThrow("references missing audio");
 });
 it("round-trips a large playlist without duplicating media in memory",async()=>{
  const track:Track={id:"song",name:"Song",size:1,type:"audio/mpeg",importedAt:1,blob:new Blob([new Uint8Array([42])])};
  const playlists=Array.from({length:200},(_,i)=>({id:"mix-"+i,name:"Mix "+i,trackIds:["song"]}));
  const restored=await parseLibraryBackup(createLibraryBackup([track],playlists));
  expect(restored.playlists).toHaveLength(200);
  expect(restored.playlists[199].trackIds).toEqual(["song"]);
  expect(restored.tracks[0].blob.size).toBe(1);
 });
 it("rejects malformed metadata symmetrically before export and before audio restoration",async()=>{
  const song:Track={id:"song",name:"Song",size:3,type:"audio/mpeg",importedAt:1,blob:new Blob([new Uint8Array([1,2,3])])};
  const invalidExport:Track[]=[
   {...song,size:2},
   {...song,size:4},
   {...song,importedAt:-1},
   {...song,originalName:"  "},
   {...song,artist:123 as unknown as string},
   {...song,album:null as unknown as string},
   {...song,type:null as unknown as string},
   {...song,artwork:"not a blob" as unknown as Blob}
  ];
  for(const bad of invalidExport)
   expect(()=>createLibraryBackup([bad],[])).toThrow();
  const valid=createLibraryBackup([song],[]);
  const magicLength=new TextEncoder().encode("MP3SHELF1\\n").length;
  const header=await valid.slice(0,magicLength+4).arrayBuffer();
  const length=new DataView(header).getUint32(magicLength,true);
  const manifest=JSON.parse(await valid.slice(magicLength+4,magicLength+4+length).text());
  const payload=valid.slice(magicLength+4+length);
  const corrupt=(edit:(track:Record<string,unknown>)=>void)=>{
   const altered=structuredClone(manifest);
   edit(altered.tracks[0]);
   const json=new TextEncoder().encode(JSON.stringify(altered));
   const prefix=new Uint8Array(header.slice(0));
   new DataView(prefix.buffer).setUint32(magicLength,json.byteLength,true);
   return new Blob([prefix,json,payload]);
  };
  const invalidImports=[
   (track:Record<string,unknown>)=>{track.importedAt=-1},
   (track:Record<string,unknown>)=>{track.originalName=42},
   (track:Record<string,unknown>)=>{track.originalName="  "},
   (track:Record<string,unknown>)=>{track.artist={name:"wrong"}},
   (track:Record<string,unknown>)=>{track.album=null},
   (track:Record<string,unknown>)=>{(track.audio as Record<string,unknown>).type=42}
  ];
  for(const edit of invalidImports)
   await expect(parseLibraryBackup(corrupt(edit))).rejects.toThrow("Invalid");
  const parsed=await parseLibraryBackup(valid);
  expect(parsed.tracks[0]).toMatchObject({id:"song",size:3,importedAt:1});
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
