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
 const trackIds=new Set<string>(),playlistIds=new Set<string>();
 for(const track of tracks){
  if(typeof track.id!=="string"||!track.id.trim()||
     typeof track.name!=="string"||!track.name.trim())
   throw new Error("Cannot back up a track without an ID and name.");
  if(trackIds.has(track.id))throw new Error("Duplicate track ID in library backup.");
  trackIds.add(track.id);
  if(!Number.isFinite(track.importedAt)||track.importedAt<0)throw new Error("Cannot back up a track with an invalid import date.");
  if(!(track.blob instanceof Blob)||track.blob.size===0)throw new Error("Cannot back up an empty audio recording.");
  if(!Number.isSafeInteger(track.size)||track.size!==track.blob.size)
   throw new Error("Cannot back up a track with mismatched audio size.");
  if(typeof track.type!=="string"||
     (track.originalName!==undefined&&(typeof track.originalName!=="string"||!track.originalName.trim()))||
     (track.artist!==undefined&&typeof track.artist!=="string")||
     (track.album!==undefined&&typeof track.album!=="string"))
   throw new Error("Cannot back up a track with invalid metadata.");
  if(track.artwork!==undefined&&(!(track.artwork instanceof Blob)||track.artwork.size===0))
   throw new Error("Cannot back up empty artwork.");
 }
 for(const playlist of playlists){
  if(typeof playlist.id!=="string"||!playlist.id.trim()||
     typeof playlist.name!=="string"||!playlist.name.trim())
   throw new Error("Cannot back up a playlist without an ID and name.");
  if(playlistIds.has(playlist.id))throw new Error("Duplicate playlist ID in library backup.");
  playlistIds.add(playlist.id);
  if(!Array.isArray(playlist.trackIds)||!playlist.trackIds.every(id=>typeof id==="string"&&Boolean(id.trim())))throw new Error("Cannot back up a playlist with invalid track references.");
  // A portable archive contains only the supplied recordings. Exporting a
  // dangling playlist link produces an archive that cannot be safely restored:
  // recovery refuses to publish references to missing audio. Fail before
  // allocating the payload so users can repair the library first.
  if(playlist.trackIds.some(id=>!trackIds.has(id)))
   throw new Error("Cannot back up a playlist that references missing recordings.");
 }
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
function optionalString(value:unknown,label:string,nonempty=false):string|undefined{
 if(value===undefined)return undefined;
 if(typeof value!=="string"||(nonempty&&!value.trim()))throw new Error(`Invalid ${label} in backup.`);
 return value;
}
function requiredNumber(value:unknown,label:string):number{if(typeof value!=="number"||!Number.isFinite(value))throw new Error(`Invalid ${label} in backup.`);return value}

function readPart(value:unknown,payloadSize:number,label:string):BinaryPart{
 if(!isRecord(value))throw new Error(`Missing ${label} data in backup.`);
 const offset=requiredNumber(value.offset,`${label} offset`),length=requiredNumber(value.length,`${label} length`);
 if(!Number.isSafeInteger(offset)||!Number.isSafeInteger(length)||offset<0||length<0||offset+length>payloadSize)throw new Error(`Invalid ${label} range in backup.`);
 return{offset,length,type:optionalString(value.type,`${label} media type`)||"application/octet-stream"};
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
 const usedRanges:{start:number;end:number;label:string}[]=[];
 const trackIds=new Set<string>();
 const playlistIds=new Set<string>();
 function registerPart(part:BinaryPart,label:string):void{
  if(part.length===0)throw new Error(`Empty ${label} data in backup.`);
  usedRanges.push({start:part.offset,end:part.offset+part.length,label});
 }
 const tracks=parsed.tracks.map((value,index)=>{
  if(!isRecord(value))throw new Error(`Invalid track ${index+1} in backup.`);
  const audio=readPart(value.audio,payloadSize,"audio"),artwork=value.artwork===undefined?undefined:readPart(value.artwork,payloadSize,"artwork");
  const id=requiredString(value.id,"track ID");
  if(trackIds.has(id))throw new Error("Duplicate track ID in backup.");
  trackIds.add(id);
  if(requiredNumber(value.importedAt,"import date")<0)throw new Error("Invalid import date in backup.");
  registerPart(audio,`track ${index+1} audio`);
  if(artwork)registerPart(artwork,`track ${index+1} artwork`);
  const blob=file.slice(payloadStart+audio.offset,payloadStart+audio.offset+audio.length,audio.type);
  return{id,name:requiredString(value.name,"track name"),originalName:optionalString(value.originalName,"original filename",true),artist:optionalString(value.artist,"artist"),album:optionalString(value.album,"album"),size:blob.size,type:audio.type,importedAt:requiredNumber(value.importedAt,"import date"),blob,artwork:artwork?file.slice(payloadStart+artwork.offset,payloadStart+artwork.offset+artwork.length,artwork.type):undefined} satisfies Track;
 });
 const playlists=parsed.playlists.map((value,index)=>{
  if(!isRecord(value)||!Array.isArray(value.trackIds)||!value.trackIds.every(id=>typeof id==="string"&&Boolean(id.trim())))throw new Error(`Invalid playlist ${index+1} in backup.`);
  const id=requiredString(value.id,"playlist ID");
  if(playlistIds.has(id))throw new Error("Duplicate playlist ID in backup.");
  playlistIds.add(id);
  // Reject an incomplete archive at parse time rather than allowing its
  // audio half to be inserted before playlist recovery discovers missing IDs.
  if(value.trackIds.some((trackId:string)=>!trackIds.has(trackId)))
   throw new Error("Backup playlist references missing audio.");
  return{id,name:requiredString(value.name,"playlist name"),trackIds:value.trackIds};
 });
 usedRanges.sort((a,b)=>a.start-b.start);
 for(let i=1;i<usedRanges.length;i++){
  if(usedRanges[i].start<usedRanges[i-1].end)throw new Error("Overlapping audio or artwork data in backup.");
 }
 // The v1 writer packs all media contiguously. Reject incomplete payloads and
 // unreferenced bytes instead of silently restoring a partial/corrupt archive.
 let expectedOffset=0;
 for(const range of usedRanges){
  if(range.start!==expectedOffset)throw new Error("Missing or unreferenced media data in backup.");
  expectedOffset=range.end;
 }
 if(expectedOffset!==payloadSize)throw new Error("Missing or unreferenced media data in backup.");
 return{tracks,playlists};
}
