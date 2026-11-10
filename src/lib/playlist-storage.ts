export type StoredPlaylist={id:string;name:string;trackIds:string[]};

/** Fail closed: corrupt saved state must not be replaced with an empty library. */
export function parseStoredPlaylists(raw:string|null):StoredPlaylist[]{
 if(raw===null)return [];
 const value:unknown=JSON.parse(raw);
 if(!Array.isArray(value)||!value.every(item=>
  item!==null&&typeof item==="object"&&
  typeof item.id==="string"&&Boolean(item.id.trim())&&
  typeof item.name==="string"&&Boolean(item.name.trim())&&
  Array.isArray(item.trackIds)&&item.trackIds.every((id:unknown)=>typeof id==="string"&&Boolean(id.trim()))
 ))throw new Error("Invalid saved playlists.");
 const ids=new Set<string>();
 for(const item of value){if(ids.has(item.id))throw new Error("Duplicate saved playlist ID.");ids.add(item.id)}
 return value as StoredPlaylist[];
}

/** Preserve library order while filtering by playlist membership in linear time. */
export function selectPlaylistTracks<T extends {id:string}>(tracks:readonly T[],trackIds:readonly string[]):T[]{
 const selected=new Set(trackIds);
 return tracks.filter(track=>selected.has(track.id));
}
