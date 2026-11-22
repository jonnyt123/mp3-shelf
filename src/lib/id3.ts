export type AudioMetadata={title?:string;artist?:string;album?:string;artwork?:Blob};
const textFrames:Record<string,keyof AudioMetadata>={TIT2:"title",TPE1:"artist",TALB:"album"};
function syncSafe(bytes:Uint8Array,offset:number){return(bytes[offset]<<21)|(bytes[offset+1]<<14)|(bytes[offset+2]<<7)|bytes[offset+3]}
function uint32(bytes:Uint8Array,offset:number){return(bytes[offset]*0x1000000)+(bytes[offset+1]<<16)+(bytes[offset+2]<<8)+bytes[offset+3]}
function terminator(bytes:Uint8Array,start:number,wide:boolean){for(let i=start;i<bytes.length-(wide?1:0);i+=wide?2:1)if(bytes[i]===0&&(!wide||bytes[i+1]===0))return i;return bytes.length}
function decode(bytes:Uint8Array,encoding:number){if(!bytes.length)return"";if(encoding===3)return new TextDecoder().decode(bytes).replace(/\0+$/,"").trim();if(encoding===1||encoding===2){let view=bytes,little=encoding===1;if(bytes[0]===0xff&&bytes[1]===0xfe){little=true;view=bytes.slice(2)}else if(bytes[0]===0xfe&&bytes[1]===0xff){little=false;view=bytes.slice(2)}const chars=[];for(let i=0;i+1<view.length;i+=2){const code=little?view[i]|(view[i+1]<<8):(view[i]<<8)|view[i+1];if(code)chars.push(String.fromCharCode(code))}return chars.join("").trim()}return new TextDecoder("windows-1252").decode(bytes).replace(/\0+$/,"").trim()}
export function parseId3Bytes(bytes:Uint8Array):AudioMetadata{
 const result:AudioMetadata={};if(bytes.length<10||String.fromCharCode(...bytes.slice(0,3))!=="ID3")return result;
 const version=bytes[3],end=Math.min(bytes.length,10+syncSafe(bytes,6));let offset=10;
 while(offset+10<=end){const id=String.fromCharCode(...bytes.slice(offset,offset+4));if(!/^[A-Z0-9]{4}$/.test(id))break;const size=version===4?syncSafe(bytes,offset+4):uint32(bytes,offset+4);if(size<=0||offset+10+size>end)break;const data=bytes.slice(offset+10,offset+10+size);
  if(textFrames[id]&&data.length>1){const value=decode(data.slice(1),data[0]);if(value)(result as Record<string,unknown>)[textFrames[id]]=value}
  if(id==="APIC"&&data.length>4){const encoding=data[0],mimeEnd=terminator(data,1,false),mime=new TextDecoder().decode(data.slice(1,mimeEnd))||"image/jpeg",pictureType=mimeEnd+1,descStart=pictureType+1,descEnd=terminator(data,descStart,encoding===1||encoding===2),imageStart=Math.min(data.length,descEnd+(encoding===1||encoding===2?2:1));if(imageStart<data.length)result.artwork=new Blob([data.slice(imageStart)],{type:mime})}
  offset+=10+size;
 }
 return result;
}
export async function readAudioMetadata(file:Blob):Promise<AudioMetadata>{try{return parseId3Bytes(new Uint8Array(await file.slice(0,2*1024*1024).arrayBuffer()))}catch{return{}}}
