import{describe,expect,it}from"vitest";
import{parseId3Bytes,readAudioMetadata}from"./id3";
function frame(id:string,value:string){const payload=new Uint8Array([3,...new TextEncoder().encode(value)]),out=new Uint8Array(10+payload.length);out.set(new TextEncoder().encode(id));new DataView(out.buffer).setUint32(4,payload.length);out.set(payload,10);return out}
describe("ID3 metadata",()=>{it("reads title, artist and album frames",()=>{const frames=[frame("TIT2","Track Name"),frame("TPE1","Artist Name"),frame("TALB","Album Name")],size=frames.reduce((n,f)=>n+f.length,0),tag=new Uint8Array(10+size);tag.set([73,68,51,3,0,0,0,0,0,size],0);let offset=10;for(const f of frames){tag.set(f,offset);offset+=f.length}expect(parseId3Bytes(tag)).toMatchObject({title:"Track Name",artist:"Artist Name",album:"Album Name"})});it("ignores files without ID3 tags",()=>{expect(parseId3Bytes(new Uint8Array([1,2,3]))).toEqual({})})});

describe("bounded ID3 metadata reads",()=>{
 it("reads only the ten-byte header for files without ID3 metadata",async()=>{
  const file=new Blob([new Uint8Array(3*1024*1024)]);
  const ranges:number[]=[];
  const slice=file.slice.bind(file);
  file.slice=((start?:number,end?:number,type?:string)=>{
   ranges.push((end??file.size)-(start??0));
   return slice(start,end,type);
  }) as typeof file.slice;
  expect(await readAudioMetadata(file)).toEqual({});
  expect(ranges).toEqual([10]);
 });
 it("reads only the declared ID3 tag, not the following audio payload",async()=>{
  const title=frame("TIT2","Bounded");
  const tag=new Uint8Array(10+title.length);
  tag.set([73,68,51,3,0,0,0,0,0,title.length]);
  tag.set(title,10);
  const file=new Blob([tag,new Uint8Array(3*1024*1024)]);
  const ranges:number[]=[];
  const slice=file.slice.bind(file);
  file.slice=((start?:number,end?:number,type?:string)=>{
   ranges.push((end??file.size)-(start??0));
   return slice(start,end,type);
  }) as typeof file.slice;
  expect(await readAudioMetadata(file)).toMatchObject({title:"Bounded"});
  expect(ranges).toEqual([10,tag.length]);
 });
 it("rejects malformed syncsafe lengths without allocating the audio body",async()=>{
  const header=new Uint8Array([73,68,51,3,0,0,255,0,0,0]);
  const file=new Blob([header,new Uint8Array(1024*1024)]);
  let reads=0;
  const slice=file.slice.bind(file);
  file.slice=((start?:number,end?:number,type?:string)=>{
   reads++;
   if(reads>1)throw new Error("Unexpected payload read");
   return slice(start,end,type);
  }) as typeof file.slice;
  expect(await readAudioMetadata(file)).toEqual({});
  expect(reads).toBe(1);
 });
});

describe("ID3 header integrity",()=>{
 it("ignores unsupported ID3v2.2 and unknown versions rather than interpreting frame bytes",async()=>{
  const title=frame("TIT2","False Title");
  for(const version of [2,5,255]){
   const tag=new Uint8Array(10+title.length);
   tag.set([73,68,51,version,0,0,0,0,0,title.length]);
   tag.set(title,10);
   expect(parseId3Bytes(tag)).toEqual({});
   const file=new Blob([tag,new Uint8Array(4096)]);
   let reads=0;
   const slice=file.slice.bind(file);
   file.slice=((start?:number,end?:number,type?:string)=>{
    reads++;
    if(reads>1)throw new Error("Unexpected payload read");
    return slice(start,end,type);
   }) as typeof file.slice;
   expect(await readAudioMetadata(file)).toEqual({});
   expect(reads).toBe(1);
  }
 });
 it("rejects declared tags larger than the file without reading beyond the header",async()=>{
  const header=new Uint8Array([73,68,51,3,0,0,0,0,64,0]);
  const file=new Blob([header,new Uint8Array(10)]);
  let reads=0;
  const slice=file.slice.bind(file);
  file.slice=((start?:number,end?:number,type?:string)=>{
   reads++;
   if(reads>1)throw new Error("Unexpected payload read");
   return slice(start,end,type);
  }) as typeof file.slice;
  expect(await readAudioMetadata(file)).toEqual({});
  expect(reads).toBe(1);
 });
 it("continues to extract valid ID3v2.4 text frames",async()=>{
  const title=frame("TIT2","Version Four");
  const tag=new Uint8Array(10+title.length);
  tag.set([73,68,51,4,0,0,0,0,0,title.length]);
  tag.set(title,10);
  expect(await readAudioMetadata(new Blob([tag]))).toMatchObject({title:"Version Four"});
 });
});

describe("ID3 extended headers and truncated metadata",()=>{
 const title=frame("TIT2","Extended Title");
 it("reads ID3v2.3 frames after an extended header",async()=>{
  const extension=new Uint8Array([0,0,0,6,0,0,0,0,0,0]);
  const body=new Uint8Array([...extension,...title]);
  const tag=new Uint8Array(10+body.length);
  tag.set([73,68,51,3,0,0x40,0,0,0,body.length]);
  tag.set(body,10);
  expect(parseId3Bytes(tag)).toMatchObject({title:"Extended Title"});
  expect(await readAudioMetadata(new Blob([tag]))).toMatchObject({title:"Extended Title"});
 });
 it("reads ID3v2.4 frames after a syncsafe extended header",async()=>{
  const extension=new Uint8Array([0,0,0,6,1,0]);
  const body=new Uint8Array([...extension,...title]);
  const tag=new Uint8Array(10+body.length);
  tag.set([73,68,51,4,0,0x40,0,0,0,body.length]);
  tag.set(body,10);
  expect(parseId3Bytes(tag)).toMatchObject({title:"Extended Title"});
  expect(await readAudioMetadata(new Blob([tag]))).toMatchObject({title:"Extended Title"});
 });
 it("rejects malformed extended header sizes and truncated tags",()=>{
  const tag=new Uint8Array(10+title.length);
  tag.set([73,68,51,4,0,0x40,0,0,0,title.length]);
  tag.set(title,10);
  expect(parseId3Bytes(tag)).toEqual({});
  const invalid=tag.slice();
  invalid.set([0,0,0,127],10);
  expect(parseId3Bytes(invalid)).toEqual({});
  const valid=tag.slice();
  valid[5]=0;
  expect(parseId3Bytes(valid.slice(0,-1))).toEqual({});
 });
 it("does not decode invalid ID3v2.4 non-syncsafe frame sizes",()=>{
  const tag=new Uint8Array(10+title.length);
  tag.set([73,68,51,4,0,0,0,0,0,title.length]);
  tag.set(title,10);
  tag[14]=0x80;
  expect(parseId3Bytes(tag)).toEqual({});
 });
});

describe("ID3 frame payload transformation safety",()=>{
 function makeTag(version:3|4,frames:Uint8Array[]){
  const size=frames.reduce((sum,part)=>sum+part.length,0);
  const tag=new Uint8Array(10+size);
  tag.set([73,68,51,version,0,0,0,0,0,size],0);
  let position=10;
  for(const part of frames){tag.set(part,position);position+=part.length}
  return tag;
 }
 it("skips transformed v2.3 text and artwork frames without losing subsequent ordinary metadata",async()=>{
  for(const flag of [0x20,0x40,0x80]){
   const transformed=frame("TIT2","Incorrect Title");
   transformed[9]=flag;
   const ordinary=frame("TPE1","Actual Artist");
   const tag=makeTag(3,[transformed,ordinary]);
   expect(parseId3Bytes(tag)).toEqual({artist:"Actual Artist"});
   expect(await readAudioMetadata(new Blob([tag]))).toEqual({artist:"Actual Artist"});
  }
 });
 it("skips v2.4 grouped, compressed, encrypted, unsynchronised and length-indicated frames",async()=>{
  for(const flag of [0x40,0x08,0x04,0x02,0x01]){
   const transformed=frame("TIT2","Untrusted Title");
   transformed[9]=flag;
   const ordinary=frame("TALB","Safe Album");
   const tag=makeTag(4,[transformed,ordinary]);
   expect(parseId3Bytes(tag)).toEqual({album:"Safe Album"});
   expect(await readAudioMetadata(new Blob([tag]))).toEqual({album:"Safe Album"});
  }
 });
 it("preserves ordinary metadata with non-format status flags",()=>{
  for(const version of [3,4] as const){
   const title=frame("TIT2","Readable");
   title[8]=0x40;
   expect(parseId3Bytes(makeTag(version,[title]))).toEqual({title:"Readable"});
  }
 });
});

describe("ID3 whole-tag unsynchronisation safety",()=>{
 it("does not decode unsynchronised v2.3/v2.4 tags as ordinary frames",async()=>{
  for(const version of [3,4] as const){
   const title=frame("TIT2","Misleading title");
   const tag=new Uint8Array(10+title.length);
   tag.set([73,68,51,version,0,0x80,0,0,0,title.length]);
   tag.set(title,10);
   expect(parseId3Bytes(tag)).toEqual({});
   const file=new Blob([tag,new Uint8Array(3*1024*1024)]);
   const reads:number[]=[];
   const originalSlice=file.slice.bind(file);
   file.slice=((start?:number,end?:number,type?:string)=>{
    reads.push((end??file.size)-(start??0));
    return originalSlice(start,end,type);
   }) as typeof file.slice;
   expect(await readAudioMetadata(file)).toEqual({});
   expect(reads).toEqual([10]);
  }
 });
 it("rejects reserved header flag bits but preserves supported ordinary tags",async()=>{
  const title=frame("TIT2","Valid title");
  for(const version of [3,4] as const){
   const tag=new Uint8Array(10+title.length);
   tag.set([73,68,51,version,0,0,0,0,0,title.length]);
   tag.set(title,10);
   expect(parseId3Bytes(tag)).toMatchObject({title:"Valid title"});
   expect(await readAudioMetadata(new Blob([tag]))).toMatchObject({title:"Valid title"});
   tag[5]=0x01;
   expect(parseId3Bytes(tag)).toEqual({});
   expect(await readAudioMetadata(new Blob([tag]))).toEqual({});
  }
 });
});

describe("ID3 extended-header structural validation",()=>{
 function tag(version:3|4,extension:number[]){
  const title=frame("TIT2","Verified");
  const size=extension.length+title.length;
  const bytes=new Uint8Array(10+size);
  bytes.set([73,68,51,version,0,0x40,0,0,0,size]);
  bytes.set(extension,10);
  bytes.set(title,10+extension.length);
  return bytes;
 }
 it("accepts valid v2.4 update, CRC and restriction extensions",()=>{
  for(const extension of [
   [0,0,0,7,1,0x40,0],
   [0,0,0,12,1,0x20,5,0,0,0,0,0],
   [0,0,0,8,1,0x10,1,0],
  ])expect(parseId3Bytes(tag(4,extension))).toMatchObject({title:"Verified"});
 });
 it("rejects malformed v2.4 extension flags, payload sizes and trailing bytes",()=>{
  for(const extension of [
   [0,0,0,6,2,0],
   [0,0,0,6,1,0x01],
   [0,0,0,7,1,0x20,0],
   [0,0,0,7,1,0,0],
   [0,0,0,7,1,0x40,1],
  ])expect(parseId3Bytes(tag(4,extension))).toEqual({});
 });
 it("accepts valid v2.3 CRC extension and rejects inconsistent flags",()=>{
  expect(parseId3Bytes(tag(3,[0,0,0,10,0x80,0,0,0,0,0,0,0,0,0])))
   .toMatchObject({title:"Verified"});
  for(const extension of [
   [0,0,0,6,0x80,0,0,0,0,0],
   [0,0,0,10,0,0,0,0,0,0,0,0,0,0],
   [0,0,0,6,0x40,0,0,0,0,0],
  ])expect(parseId3Bytes(tag(3,extension))).toEqual({});
 });
});


describe("ID3 reserved frame bits and invalid encoding regression",()=>{
 function tagged(version:3|4,first:Uint8Array,second:Uint8Array){
  const length=first.length+second.length;
  const tag=new Uint8Array(10+length);
  tag.set([73,68,51,version,0,0,0,0,0,length]);
  tag.set(first,10);tag.set(second,10+first.length);
  return tag;
 }
 it("skips reserved status and format flags without losing the next valid frame",async()=>{
  for(const version of [3,4] as const){
   for(const [position,flag] of version===3
    ? [[8,0x01],[9,0x01]] : [[8,0x80],[9,0x80]]){
    const invalid=frame("TIT2","Untrusted");
    invalid[position]=flag;
    const tag=tagged(version,invalid,frame("TPE1","Verified artist"));
    expect(parseId3Bytes(tag)).toEqual({artist:"Verified artist"});
    expect(await readAudioMetadata(new Blob([tag]))).toEqual({artist:"Verified artist"});
   }
  }
 });
 it("rejects unknown text encodings while preserving later valid metadata",()=>{
  for(const version of [3,4] as const){
   const invalid=frame("TIT2","Incorrect");
   invalid[10]=0x7f;
   const tag=tagged(version,invalid,frame("TALB","Trusted album"));
   expect(parseId3Bytes(tag)).toEqual({album:"Trusted album"});
   expect(await readAudioMetadata(new Blob([tag]))).toEqual({album:"Trusted album"});
  }
 });
 it("continues to accept valid status flags and UTF-8 text",()=>{
  for(const version of [3,4] as const){
   const valid=frame("TIT2","Still readable");
   valid[8]=0x40;
   expect(parseId3Bytes(tagged(version,valid,frame("TPE1","Artist"))))
    .toEqual({title:"Still readable",artist:"Artist"});
  }
 });
});

describe("ID3 embedded artwork MIME validation",()=>{
 function artworkTag(mime:string){
  const payload=new Uint8Array([0,...new TextEncoder().encode(mime),0,3,0,1,2,3,4]);
  const frame=new Uint8Array(10+payload.length);
  frame.set(new TextEncoder().encode("APIC"));
  new DataView(frame.buffer).setUint32(4,payload.length);
  frame.set(payload,10);
  const tag=new Uint8Array(10+frame.length);
  tag.set([73,68,51,3,0,0,0,0,0,frame.length]);
  tag.set(frame,10);
  return tag;
 }
 it("preserves supported image artwork and its media type",()=>{
  for(const mime of ["image/jpeg","image/png","image/gif","image/webp"]){
   const artwork=parseId3Bytes(artworkTag(mime)).artwork;
   expect(artwork?.type).toBe(mime);
   expect(artwork?.size).toBe(4);
  }
 });
 it("does not promote arbitrary embedded data to browser artwork",async()=>{
  for(const mime of ["text/html","image/svg+xml","application/javascript"]){
   const tag=artworkTag(mime);
   expect(parseId3Bytes(tag).artwork).toBeUndefined();
   expect((await readAudioMetadata(new Blob([tag]))).artwork).toBeUndefined();
  }
 });
});


describe("ID3 artwork field boundaries",()=>{
 function tag(payload:number[]){
  const bytes=new Uint8Array(20+payload.length);
  bytes.set([73,68,51,3,0,0,0,0,0,10+payload.length]);
  bytes.set(new TextEncoder().encode("APIC"),10);
  new DataView(bytes.buffer).setUint32(14,payload.length);
  bytes.set(payload,20);
  return bytes;
 }
 it("rejects a missing MIME terminator even when the payload contains image-like bytes",async()=>{
  const bytes=tag([0,...new TextEncoder().encode("image/jpeg"),1,2,3,4]);
  expect(parseId3Bytes(bytes).artwork).toBeUndefined();
  expect((await readAudioMetadata(new Blob([bytes]))).artwork).toBeUndefined();
 });
 it("rejects missing picture type and description terminator",()=>{
  const mime=[0,...new TextEncoder().encode("image/png"),0];
  expect(parseId3Bytes(tag(mime)).artwork).toBeUndefined();
  expect(parseId3Bytes(tag([...mime,3])).artwork).toBeUndefined();
  expect(parseId3Bytes(tag([...mime,3,65,66,67])).artwork).toBeUndefined();
 });
 it("preserves valid artwork after an explicitly terminated description",async()=>{
  const payload=[0,...new TextEncoder().encode("image/png"),0,3,65,0,137,80,78,71];
  const bytes=tag(payload);
  const artwork=(await readAudioMetadata(new Blob([bytes]))).artwork;
  expect(artwork?.type).toBe("image/png");
  expect(Array.from(new Uint8Array(await artwork!.arrayBuffer()))).toEqual([137,80,78,71]);
 });
});
