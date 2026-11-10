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

/** Commit playlist restoration before publishing it to React state. A failed
 * localStorage write must never be reported as a successful playlist restore. */
export function persistRestoredPlaylists(
 storage:Pick<Storage,"getItem"|"setItem">, key:string,
 incoming:readonly StoredPlaylist[]
):StoredPlaylist[]{
 // Validate backup playlists before writing. Invalid IDs must not silently
 // merge into the user\'s current playlists.
 parseStoredPlaylists(JSON.stringify(incoming));
 const existing=parseStoredPlaylists(storage.getItem(key));
 const merged=new Map(existing.map(item=>[item.id,item]));
 for(const item of incoming){
  const saved=merged.get(item.id);
  if(!saved){merged.set(item.id,{...item,trackIds:[...new Set(item.trackIds)]});continue}
  // A backup may be older than the user's local playlist. Restore missing
  // links without reverting a rename, removing songs, or reordering edits.
  const known=new Set(saved.trackIds);
  const missing=item.trackIds.filter(id=>!known.has(id)&&(known.add(id),true));
  if(missing.length)merged.set(item.id,{...saved,trackIds:[...saved.trackIds,...missing]});
 }
 const next=[...merged.values()];
 // Verify the entire merged representation before mutating persistent storage.
 parseStoredPlaylists(JSON.stringify(next));
 storage.setItem(key,JSON.stringify(next));
 return next;
}

const RESTORE_JOURNAL_KEY="mp3-shelf-restore-pending";
type RestoreJournal={version:1;trackIds:string[];playlists:StoredPlaylist[]};

/** Durable intent is written before any IndexedDB inserts. If the browser
 * terminates between stores, startup can finish the playlist half safely. */
export function stagePlaylistRestore(storage:Pick<Storage,"getItem"|"setItem">,key:string,tracks:readonly {id:string}[],playlists:readonly StoredPlaylist[]):boolean{
 const pending=storage.getItem(RESTORE_JOURNAL_KEY);
 // Validate the destination before any IndexedDB audio insertion. Otherwise a
 // corrupt local playlist record is only discovered during final commit, after
 // potentially gigabytes of restored audio have already been persisted.
 parseStoredPlaylists(storage.getItem(key));
 parseStoredPlaylists(JSON.stringify(playlists));
 const ids=tracks.map(track=>track.id);
 if(ids.some(id=>typeof id!=="string"||!id.trim())||new Set(ids).size!==ids.length)throw new Error("Invalid backup track IDs.");
 const intent=JSON.stringify({version:1,trackIds:ids,playlists} satisfies RestoreJournal);
 if(pending!==null){if(pending!==intent)throw new Error("Finish the pending backup restore using the original backup before importing another.");return false}
 storage.setItem(RESTORE_JOURNAL_KEY,intent);
 return true;
}

/** Never publish playlist references until every backup track is present.
 * Replaying is idempotent and retains edits made to existing playlists. */
export function recoverPlaylistRestore(storage:Pick<Storage,"getItem"|"setItem"|"removeItem">,availableTrackIds:ReadonlySet<string>,key:string):StoredPlaylist[]|null{
 const raw=storage.getItem(RESTORE_JOURNAL_KEY);
 if(raw===null)return null;
 const parsed:unknown=JSON.parse(raw);
 if(!parsed||typeof parsed!=="object")throw new Error("Invalid pending restore journal.");
 const journal=parsed as Partial<RestoreJournal>;
 if(journal.version!==1||!Array.isArray(journal.trackIds)||!Array.isArray(journal.playlists)||
    journal.trackIds.some(id=>typeof id!=="string"||!id.trim())||
    new Set(journal.trackIds).size!==journal.trackIds.length)throw new Error("Invalid pending restore journal.");
 parseStoredPlaylists(JSON.stringify(journal.playlists));
 if(!journal.trackIds.every(id=>availableTrackIds.has(id)))throw new Error("A backup restore was interrupted before all recordings were saved. Reimport the backup to finish safely.");
 const result=persistRestoredPlaylists(storage,key,journal.playlists);
 storage.removeItem(RESTORE_JOURNAL_KEY);
 return result;
}

/** A failed IndexedDB transaction has not inserted anything; clear only the
 * intent we own, leaving existing playlists and audio untouched. */
export function cancelPlaylistRestore(storage:Pick<Storage,"removeItem">):void{
 storage.removeItem(RESTORE_JOURNAL_KEY);
}

export function hasPendingPlaylistRestore(storage:Pick<Storage,"getItem">):boolean{return storage.getItem(RESTORE_JOURNAL_KEY)!==null}
