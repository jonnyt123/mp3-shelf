import type {Track} from "./tracks";

export type BackupPlaylist={id:string;name:string;trackIds:string[]};
export type LibraryBackup={tracks:Track[];playlists:BackupPlaylist[]};

const MAGIC="MP3SHELF1\n";
const MAX_MANIFEST_BYTES=4*1024*1024;
const encoder=new TextEncoder();

type BinaryPart={offset:number;length:number;type:string};
type BackupTrack={id:string;name:string;originalName?:string;artist?:string;album?:string;importedAt:number;audio:BinaryPart;artwork?:BinaryPart};
type Manifest={schema:"mp3-shelf-backup";version:1;createdAt:string;tracks:BackupTrack[];playlists:BackupPlaylist[]};

export function createLibraryBackup(tracks:Track[],playlists:BackupPlaylist[]):Blob{
 const payload:Blob[]=[];let offset=0;
 const archivedTracks=tracks.map(track=>{
  const audio={offset,length:track.blob.size,type:track.type||track.blob.type||"audio/mpeg"};payload.push(track.blob);offset+=track.blob.size;
  let artwork:BinaryPart|undefined;if(track.artwork){artwork={offset,length:track.artwork.size,type:track.artwork.type||"image/jpeg"};payload.push(track.artwork);offset+=track.artwork.size}
  return{id:track.id,name:track.name,originalName:track.originalName,artist:track.artist,album:track.album,importedAt:track.importedAt,audio,artwork};
 });
 const manifest:Manifest={schema:"mp3-shelf-backup",version:1,createdAt:new Date().toISOString(),tracks:archivedTracks,playlists};
 const manifestBytes=encoder.encode(JSON.stringify(manifest));
 if(manifestBytes.byteLength>MAX_MANIFEST_BYTES)throw new Error("This library has too much metadata to back up.");
 const lengthBytes=new Uint8Array(4);new DataView(lengthBytes.buffer).setUint32(0,manifestBytes.byteLength,true);
 return new Blob([MAGIC,lengthBytes,manifestBytes,...payload],{type:"application/vnd.mp3-shelf.backup"});
}

function isRecord(value:unknown):value is Record<string,unknown>{return typeof value==="object"&&value!==null}
function requiredString(value:unknown,label:string):string{if(typeof value!=="string"||!value.trim())throw new Error(`Invalid ${label} in backup.`);return value}
function optionalString(value:unknown):string|undefined{return typeof value==="string"?value:undefined}
function requiredNumber(value:unknown,label:string):number{if(typeof value!=="number"||!Number.isFinite(value))throw new Error(`Invalid ${label} in backup.`);return value}

function readPart(value:unknown,payloadSize:number,label:string):BinaryPart{
 if(!isRecord(value))throw new Error(`Missing ${label} data in backup.`);
 const offset=requiredNumber(value.offset,`${label} offset`),length=requiredNumber(value.length,`${label} length`);
 if(!Number.isSafeInteger(offset)||!Number.isSafeInteger(length)||offset<0||length<0||offset+length>payloadSize)throw new Error(`Invalid ${label} range in backup.`);
 return{offset,length,type:optionalString(value.type)||"application/octet-stream"};
}

export async function parseLibraryBackup(file:Blob):Promise<LibraryBackup>{
 const magicBytes=encoder.encode(MAGIC),headerLength=magicBytes.byteLength+4;
 if(file.size<headerLength)throw new Error("This is not an MP3 Shelf backup.");
 const header=new Uint8Array(await file.slice(0,headerLength).arrayBuffer());
 if(magicBytes.some((byte,index)=>header[index]!==byte))throw new Error("This is not an MP3 Shelf backup.");
 const manifestLength=new DataView(header.buffer,header.byteOffset+magicBytes.byteLength,4).getUint32(0,true);
 if(!manifestLength||manifestLength>MAX_MANIFEST_BYTES||headerLength+manifestLength>file.size)throw new Error("The backup header is damaged.");
 let parsed:unknown;try{parsed=JSON.parse(await file.slice(headerLength,headerLength+manifestLength).text())}catch{throw new Error("The backup manifest is damaged.")}
 if(!isRecord(parsed)||parsed.schema!=="mp3-shelf-backup"||parsed.version!==1||!Array.isArray(parsed.tracks)||!Array.isArray(parsed.playlists))throw new Error("This backup version is not supported.");
 const payloadStart=headerLength+manifestLength,payloadSize=file.size-payloadStart;
 const tracks=parsed.tracks.map((value,index)=>{
  if(!isRecord(value))throw new Error(`Invalid track ${index+1} in backup.`);
  const audio=readPart(value.audio,payloadSize,"audio"),artwork=value.artwork===undefined?undefined:readPart(value.artwork,payloadSize,"artwork");
  const blob=file.slice(payloadStart+audio.offset,payloadStart+audio.offset+audio.length,audio.type);
  return{id:requiredString(value.id,"track ID"),name:requiredString(value.name,"track name"),originalName:optionalString(value.originalName),artist:optionalString(value.artist),album:optionalString(value.album),size:blob.size,type:audio.type,importedAt:requiredNumber(value.importedAt,"import date"),blob,artwork:artwork?file.slice(payloadStart+artwork.offset,payloadStart+artwork.offset+artwork.length,artwork.type):undefined} satisfies Track;
 });
 const playlists=parsed.playlists.map((value,index)=>{
  if(!isRecord(value)||!Array.isArray(value.trackIds)||!value.trackIds.every(id=>typeof id==="string"))throw new Error(`Invalid playlist ${index+1} in backup.`);
  return{id:requiredString(value.id,"playlist ID"),name:requiredString(value.name,"playlist name"),trackIds:value.trackIds};
 });
 return{tracks,playlists};
}
