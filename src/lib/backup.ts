import type {Track} from "./tracks";

export type BackupWish={title:string;artist:string;album:string;spotifyURL?:string};
export type BackupPlaylist={id:string;name:string;trackIds:string[];sourceURL?:string;wishes?:BackupWish[]};
export type LibraryBackup={tracks:Track[];playlists:BackupPlaylist[]};

const MAGIC="MP3SHELF1\n";
const MAX_MANIFEST_BYTES=4*1024*1024;
const encoder=new TextEncoder();

type BinaryPart={offset:number;length:number;type:string};
type BackupTrack={
 id:string;name:string;originalName?:string;artist?:string;album?:string;
 importedAt:number;audio:BinaryPart;artwork?:BinaryPart;
 isFavorite?:boolean;lyrics?:string;attribution?:NonNullable<Track["attribution"]>;
};
type Manifest={schema:"mp3-shelf-backup";version:1;createdAt:string;tracks:BackupTrack[];playlists:BackupPlaylist[]};

export function createLibraryBackup(tracks:Track[],playlists:BackupPlaylist[]):Blob{
 const payload:Blob[]=[];let offset=0;
 const archivedTracks=tracks.map(track=>{
  const audio={offset,length:track.blob.size,type:track.type||track.blob.type||"audio/mpeg"};payload.push(track.blob);offset+=track.blob.size;
  let artwork:BinaryPart|undefined;if(track.artwork){artwork={offset,length:track.artwork.size,type:track.artwork.type||"image/jpeg"};payload.push(track.artwork);offset+=track.artwork.size}
  return{id:track.id,name:track.name,originalName:track.originalName,artist:track.artist,album:track.album,importedAt:track.importedAt,audio,artwork,isFavorite:track.isFavorite,lyrics:track.lyrics,attribution:track.attribution};
 });
 // Do not write dangling song references when a browser playlist contains an
 // entry that has since been removed from its local IndexedDB collection.
 const ids=new Set(tracks.map(track=>track.id));
 const cleanPlaylists=playlists.map(playlist=>({...playlist,trackIds:playlist.trackIds.filter(id=>ids.has(id))}));
 const manifest:Manifest={schema:"mp3-shelf-backup",version:1,createdAt:new Date().toISOString(),tracks:archivedTracks,playlists:cleanPlaylists};
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
 const seenTrackIDs=new Set<string>();
 const tracks=parsed.tracks.map((value,index)=>{
  if(!isRecord(value))throw new Error(`Invalid track ${index+1} in backup.`);
  const audio=readPart(value.audio,payloadSize,"audio"),artwork=value.artwork===undefined?undefined:readPart(value.artwork,payloadSize,"artwork");
  const blob=file.slice(payloadStart+audio.offset,payloadStart+audio.offset+audio.length,audio.type);
  const id=requiredString(value.id,"track ID");
  if(seenTrackIDs.has(id))throw new Error("Duplicate track ID in backup.");
  seenTrackIDs.add(id);
  if(value.isFavorite!==undefined&&typeof value.isFavorite!=="boolean")throw new Error("Invalid favorite state in backup.");
  if(value.lyrics!==undefined&&(typeof value.lyrics!=="string"||encoder.encode(value.lyrics).byteLength>500*1024))throw new Error("Invalid lyrics in backup.");
  let attribution:Track["attribution"];
  if(value.attribution!==undefined){
   const info=value.attribution;
   if(!isRecord(info))throw new Error("Invalid source attribution in backup.");
   attribution={
    sourceURL:requiredString(info.sourceURL,"source URL"),
    licenseURL:requiredString(info.licenseURL,"license URL"),
    creator:requiredString(info.creator,"source creator"),
    license:requiredString(info.license,"source license"),
    provider:requiredString(info.provider,"source provider")
   };
  }
  return{id,name:requiredString(value.name,"track name"),originalName:optionalString(value.originalName),artist:optionalString(value.artist),album:optionalString(value.album),size:blob.size,type:audio.type,importedAt:requiredNumber(value.importedAt,"import date"),blob,artwork:artwork?file.slice(payloadStart+artwork.offset,payloadStart+artwork.offset+artwork.length,artwork.type):undefined,...(value.isFavorite!==undefined?{isFavorite:value.isFavorite as boolean}:{}),...(value.lyrics!==undefined?{lyrics:value.lyrics as string}:{}),...(attribution?{attribution}:{})} satisfies Track;
 });
 const seenPlaylistIDs=new Set<string>();
 const playlists=parsed.playlists.map((value,index)=>{
  if(!isRecord(value)||!Array.isArray(value.trackIds)||!value.trackIds.every(id=>typeof id==="string"&&seenTrackIDs.has(id)))throw new Error(`Invalid playlist ${index+1} song references in backup.`);
  const id=requiredString(value.id,"playlist ID");
  if(seenPlaylistIDs.has(id))throw new Error("Duplicate playlist ID in backup.");
  seenPlaylistIDs.add(id);
  let wishes:BackupWish[]|undefined;
  if(value.wishes!==undefined){
   if(!Array.isArray(value.wishes))throw new Error("Invalid Spotify wishes in backup.");
   wishes=value.wishes.map((raw):BackupWish=>{
    if(!isRecord(raw))throw new Error("Invalid Spotify wish in backup.");
    const spotifyURL=optionalString(raw.spotifyURL);
    return{
     title:requiredString(raw.title,"song title"),
     artist:typeof raw.artist==="string"?raw.artist:"",
     album:typeof raw.album==="string"?raw.album:"",
     ...(spotifyURL?{spotifyURL}:{})
    };
   });
  }
  const sourceURL=optionalString(value.sourceURL);
  return{id,name:requiredString(value.name,"playlist name"),trackIds:value.trackIds as string[],
   ...(sourceURL?{sourceURL}:{}),...(wishes?{wishes}:{})};
 });
 return{tracks,playlists};
}
