export type AudioMetadata={title?:string;artist?:string;album?:string;artwork?:Blob};
const textFrames:Record<string,keyof AudioMetadata>={TIT2:"title",TPE1:"artist",TALB:"album"};
function syncSafe(bytes:Uint8Array,offset:number){return(bytes[offset]<<21)|(bytes[offset+1]<<14)|(bytes[offset+2]<<7)|bytes[offset+3]}
function uint32(bytes:Uint8Array,offset:number){return(bytes[offset]*0x1000000)+(bytes[offset+1]<<16)+(bytes[offset+2]<<8)+bytes[offset+3]}
function terminator(bytes:Uint8Array,start:number,wide:boolean){for(let i=start;i<bytes.length-(wide?1:0);i+=wide?2:1)if(bytes[i]===0&&(!wide||bytes[i+1]===0))return i;return bytes.length}
function decode(bytes:Uint8Array,encoding:number){if(!bytes.length)return"";if(encoding===3)return new TextDecoder().decode(bytes).replace(/\0+$/,"").trim();if(encoding===1||encoding===2){let view=bytes,little=encoding===1;if(bytes[0]===0xff&&bytes[1]===0xfe){little=true;view=bytes.slice(2)}else if(bytes[0]===0xfe&&bytes[1]===0xff){little=false;view=bytes.slice(2)}const chars=[];for(let i=0;i+1<view.length;i+=2){const code=little?view[i]|(view[i+1]<<8):(view[i]<<8)|view[i+1];if(code)chars.push(String.fromCharCode(code))}return chars.join("").trim()}return new TextDecoder("windows-1252").decode(bytes).replace(/\0+$/,"").trim()}
export function parseId3Bytes(bytes:Uint8Array):AudioMetadata{
 const result:AudioMetadata={};if(bytes.length<10||String.fromCharCode(...bytes.slice(0,3))!=="ID3")return result;
 const version=bytes[3];
 // v2.2 uses six-byte frame headers; v2.3/v2.4 use ten-byte headers.
 // Never interpret an unsupported layout as valid artwork or song metadata.
 if(version!==3&&version!==4)return result;
 // Whole-tag unsynchronisation inserts 0x00 after 0xff bytes and changes
 // frame payload offsets. Do not present altered text/artwork as genuine
 // metadata until this transformation is explicitly supported.
 // Reject unknown header flags too: their layouts are not safe to guess.
 const allowedFlags=version===3?0xe0:0xf0;
 if((bytes[5]&~allowedFlags)!==0||(bytes[5]&0x80)!==0)return result;
 if(bytes.slice(6,10).some(byte=>byte>127))return result;
 const declared=10+syncSafe(bytes,6);
 // Never return partially parsed metadata from a truncated tag.
 if(declared>bytes.length)return result;
 const end=declared;let offset=10;
 // The extended header precedes frames. v2.3 sizes exclude the four-byte
 // size field, whereas v2.4 syncsafe sizes include it.
 if(bytes[5]&0x40){
  if(offset+4>end)return result;
  if(version===4&&bytes.slice(offset,offset+4).some(byte=>byte>127))return result;
  const extensionSize=version===4?syncSafe(bytes,offset):uint32(bytes,offset);
  const skip=version===4?extensionSize:extensionSize+4;
  if(skip<6||offset+skip>end)return result;
  if(version===4){
   // A v2.4 extended header contains one flag byte followed by exactly
   // the declared length-prefixed update, CRC and restriction fields.
   if(bytes[offset+4]!==1)return result;
   const flags=bytes[offset+5];
   if((flags&~0x70)!==0)return result;
   let cursor=offset+6;
   for(const bit of [0x40,0x20,0x10]){
    if(!(flags&bit))continue;
    if(cursor>=offset+skip)return result;
    const length=bytes[cursor++];
    if((bit===0x40&&length!==0)||(bit===0x20&&length!==5)||
       (bit===0x10&&length!==1)||cursor+length>offset+skip)return result;
    cursor+=length;
   }
   if(cursor!==offset+skip)return result;
  }else{
   // v2.3 permits only the CRC-present flag; size 6 without CRC or 10
   // with CRC. Padding size occupies the four bytes after the flags.
   if(extensionSize!==6&&extensionSize!==10)return result;
   const crc=(bytes[offset+4]&0x80)!==0;
   if((bytes[offset+4]&0x7f)!==0||bytes[offset+5]!==0||
      extensionSize!==(crc?10:6))return result;
  }
  offset+=skip;
 }
 while(offset+10<=end){const id=String.fromCharCode(...bytes.slice(offset,offset+4));if(!/^[A-Z0-9]{4}$/.test(id))break;
  if(version===4&&bytes.slice(offset+4,offset+8).some(byte=>byte>127))break;
  const size=version===4?syncSafe(bytes,offset+4):uint32(bytes,offset+4);
  if(size<=0||offset+10+size>end)break;
  // ID3 frame format flags change the on-disk payload layout. Encrypted,
  // compressed, grouped, data-length-indicated and unsynchronised frames
  // cannot safely be decoded as ordinary text or artwork. Skip only the
  // affected frame so later unmodified frames still import correctly.
  const formatFlags=bytes[offset+9];
  const unsupported=version===3
   ?Boolean(formatFlags&0xe0)
   :Boolean(formatFlags&0x4f);
  if(unsupported){offset+=10+size;continue}
  const data=bytes.slice(offset+10,offset+10+size);
  if(textFrames[id]&&data.length>1){const value=decode(data.slice(1),data[0]);if(value)(result as Record<string,unknown>)[textFrames[id]]=value}
  if(id==="APIC"&&data.length>4){const encoding=data[0],mimeEnd=terminator(data,1,false),mime=new TextDecoder().decode(data.slice(1,mimeEnd))||"image/jpeg",pictureType=mimeEnd+1,descStart=pictureType+1,descEnd=terminator(data,descStart,encoding===1||encoding===2),imageStart=Math.min(data.length,descEnd+(encoding===1||encoding===2?2:1));if(imageStart<data.length)result.artwork=new Blob([data.slice(imageStart)],{type:mime})}
  offset+=10+size;
 }
 return result;
}
export async function readAudioMetadata(file:Blob):Promise<AudioMetadata>{
 try{
  // Most imported recordings have no ID3v2 header. Reading only ten bytes
  // first avoids allocating a 2 MiB buffer per file during bulk imports.
  const MAX_TAG_READ=2*1024*1024;
  const header=new Uint8Array(await file.slice(0,10).arrayBuffer());
  if(header.length<10||header[0]!==73||header[1]!==68||header[2]!==51)return{};
  // ID3v2 sizes are four 7-bit syncsafe bytes. Refuse malformed headers
  // rather than trusting a corrupt length or reading beyond our memory cap.
  const allowedFlags=header[3]===3?0xe0:0xf0;
  if((header[3]!==3&&header[3]!==4)||
     (header[5]&~allowedFlags)!==0||(header[5]&0x80)!==0||
     header.slice(6,10).some(byte=>byte>127))return{};
  const declared=10+syncSafe(header,6);
  if(declared<=10||declared>file.size)return{};
  const bytes=new Uint8Array(await file.slice(0,Math.min(MAX_TAG_READ,declared)).arrayBuffer());
  return parseId3Bytes(bytes);
 }catch{return{}}
}
