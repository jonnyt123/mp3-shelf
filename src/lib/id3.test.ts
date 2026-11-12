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
