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
 incoming:readonly StoredPlaylist[], expectedRestoreJournal?:string
):StoredPlaylist[]{
 // Validate backup playlists before writing. Invalid IDs must not silently
 // merge into the user\'s current playlists.
 parseStoredPlaylists(JSON.stringify(incoming));
 const baseline=storage.getItem(key);
 const existing=parseStoredPlaylists(baseline);
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
 // Restoration must not overwrite playlist cleanup from a track deletion
 // staged by another tab while the merge was in progress. Keep the pending
 // restore journal intact so recovery can retry after deletion reconciliation.
 if(storage.getItem(DELETE_RECOVERY_KEY)!==null)
  throw new Error("Track deletion started during backup restore. Retry recovery after deletion reconciliation.");
 // Detect a concurrent write during merge instead of silently overwriting it.
 // This narrows the race but does not replace a cross-tab atomic lock.
 if(storage.getItem(key)!==baseline)
  throw new Error("Playlists changed during backup restore. Retry recovery without discarding the journal.");
 // Recovery must not commit a stale restore if another tab replaced its intent.
 // Check before the playlist write, not only after it: the latter is too late.
 if(expectedRestoreJournal!==undefined&&storage.getItem(RESTORE_JOURNAL_KEY)!==expectedRestoreJournal)
  throw new Error("Pending backup restore changed before playlist commit. Preserve the newer intent.");
 // Recheck the deletion journal after reading playlists: a storage adapter
 // may synchronously stage another operation during the baseline check.
 if(storage.getItem(DELETE_RECOVERY_KEY)!==null)
  throw new Error("Track deletion started during backup restore. Retry recovery after deletion reconciliation.");
 storage.setItem(key,JSON.stringify(next));
 return next;
}

const RESTORE_JOURNAL_KEY="mp3-shelf-restore-pending";
type RestoreJournal={version:1;key?:string;trackIds:string[];playlists:StoredPlaylist[]};

/** Durable intent is written before any IndexedDB inserts. If the browser
 * terminates between stores, startup can finish the playlist half safely. */
export function stagePlaylistRestore(storage:Pick<Storage,"getItem"|"setItem">,key:string,tracks:readonly {id:string}[],playlists:readonly StoredPlaylist[]):boolean{
 const pending=storage.getItem(RESTORE_JOURNAL_KEY);
 // A deletion can be halfway between playlist cleanup and IndexedDB removal.
 // Do not restore over that state: its recovery journal must be reconciled first.
 if(storage.getItem(DELETE_RECOVERY_KEY)!==null)
  throw new Error("Finish the pending track deletion recovery before restoring a backup.");
 if(!key.trim())throw new Error("Invalid playlist storage key.");
 // Validate the destination before any IndexedDB audio insertion. Otherwise a
 // corrupt local playlist record is only discovered during final commit, after
 // potentially gigabytes of restored audio have already been persisted.
 parseStoredPlaylists(storage.getItem(key));
 parseStoredPlaylists(JSON.stringify(playlists));
 const ids=tracks.map(track=>track.id);
 if(ids.some(id=>typeof id!=="string"||!id.trim())||new Set(ids).size!==ids.length)throw new Error("Invalid backup track IDs.");
 const intent=JSON.stringify({version:1,key,trackIds:ids,playlists} satisfies RestoreJournal);
 if(pending!==null){if(pending!==intent)throw new Error("Finish the pending backup restore using the original backup before importing another.");return false}
 storage.setItem(RESTORE_JOURNAL_KEY,intent);
 return true;
}

/** Never publish playlist references until every backup track is present.
 * Replaying is idempotent and retains edits made to existing playlists. */
export function recoverPlaylistRestore(storage:Pick<Storage,"getItem"|"setItem"|"removeItem">,availableTrackIds:ReadonlySet<string>,key:string):StoredPlaylist[]|null{
 const raw=storage.getItem(RESTORE_JOURNAL_KEY);
 if(raw===null)return null;
 // Do not replay a restore while deletion reconciliation still owns the
 // playlist namespace. Resolve deletion first, then retry the restore.
 if(storage.getItem(DELETE_RECOVERY_KEY)!==null)
  throw new Error("Finish pending track deletion recovery before replaying a backup restore.");
 const parsed:unknown=JSON.parse(raw);
 if(!parsed||typeof parsed!=="object")throw new Error("Invalid pending restore journal.");
 const journal=parsed as Partial<RestoreJournal>;
 if(journal.version!==1||(journal.key!==undefined&&(typeof journal.key!=="string"||!journal.key))||
    !Array.isArray(journal.trackIds)||!Array.isArray(journal.playlists)||
    journal.trackIds.some(id=>typeof id!=="string"||!id.trim())||
    new Set(journal.trackIds).size!==journal.trackIds.length)throw new Error("Invalid pending restore journal.");
 parseStoredPlaylists(JSON.stringify(journal.playlists));
 // Never replay a pending restore into a different playlist namespace.
 // Legacy version-1 journals without a key remain readable.
 if(journal.key!==undefined&&journal.key!==key)throw new Error("Pending backup restore belongs to a different playlist storage key.");
 if(!journal.trackIds.every(id=>availableTrackIds.has(id)))throw new Error("A backup restore was interrupted before all recordings were saved. Reimport the backup to finish safely.");
 // A backup may contain playlist links to recordings that were never included
 // in the archive (or were removed locally). Publishing those links would
 // create permanently unplayable entries even when the imported tracks exist.
 // Preserve the recovery intent so a complete archive can be retried safely.
 if(journal.playlists.some(playlist=>playlist.trackIds.some(id=>!availableTrackIds.has(id))))
  throw new Error("A backup playlist references missing audio. Reimport a complete backup before restoring playlists.");
 // A different tab may replace the restore intent while we validate audio.
 // Never consume or clear a journal belonging to a newer operation.
 if(storage.getItem(RESTORE_JOURNAL_KEY)!==raw)
  throw new Error("Pending backup restore changed during recovery. Retry with the current journal.");
 const result=persistRestoredPlaylists(storage,key,journal.playlists,raw);
 if(storage.getItem(RESTORE_JOURNAL_KEY)!==raw)
  throw new Error("Pending backup restore changed before journal cleanup. Preserve the newer intent.");
 storage.removeItem(RESTORE_JOURNAL_KEY);
 return result;
}

/** A failed IndexedDB transaction has not inserted anything; clear only the
 * intent we own, leaving existing playlists and audio untouched. */
export function cancelPlaylistRestore(storage:Pick<Storage,"removeItem">):void{
 storage.removeItem(RESTORE_JOURNAL_KEY);
}

/** Cancel only the exact restore intent this import staged. A second tab may
 * replace the journal while IndexedDB restore is awaiting completion; never
 * erase that newer intent after the first import fails. */
export function cancelOwnedPlaylistRestore(
 storage:Pick<Storage,"getItem"|"removeItem">,
 key:string,tracks:readonly {id:string}[],playlists:readonly StoredPlaylist[]
):boolean{
 const expected=JSON.stringify({version:1,key,trackIds:tracks.map(track=>track.id),playlists} satisfies RestoreJournal);
 const current=storage.getItem(RESTORE_JOURNAL_KEY);
 if(current!==expected)return false;
 storage.removeItem(RESTORE_JOURNAL_KEY);
 return true;
}

export function hasPendingPlaylistRestore(storage:Pick<Storage,"getItem">):boolean{return storage.getItem(RESTORE_JOURNAL_KEY)!==null}

/** Merge an edit against the latest durable playlist state rather than a
 * React snapshot. The updater must be pure: storage failures leave the UI and
 * persisted data unchanged. */
export function updateStoredPlaylists(
 storage:Pick<Storage,"getItem"|"setItem">,key:string,
 updater:(current:readonly StoredPlaylist[])=>readonly StoredPlaylist[]
):StoredPlaylist[]{
 // Never allow ordinary playlist edits to race a pending audio deletion or
 // backup restore. Both workflows have durable journals and may replay edits
 // after a crash; a new edit during that interval could be silently lost.
 // Read the journals before invoking the updater so rejected operations have
 // no side effects (including an updater that allocates a new playlist ID).
 if(storage.getItem(DELETE_RECOVERY_KEY)!==null)
  throw new Error("Finish the pending track deletion before editing playlists.");
 if(storage.getItem(RESTORE_JOURNAL_KEY)!==null)
  throw new Error("Finish the pending backup restore before editing playlists.");
 const baseline=storage.getItem(key);
 const current=parseStoredPlaylists(baseline);
 const next=updater(current);
 // A storage adapter or synchronous cross-context hook can change the value
 // during the updater. Never commit a result derived from a superseded value.
 // This is optimistic conflict detection, not an atomic cross-tab lock.
 if(storage.getItem(key)!==baseline)
  throw new Error("Playlists changed while editing. Reload and retry the edit.");
 // An updater is synchronous, but a test adapter or storage implementation
 // can stage a journal during the read. Fail closed before the final write.
 if(storage.getItem(DELETE_RECOVERY_KEY)!==null||storage.getItem(RESTORE_JOURNAL_KEY)!==null)
  throw new Error("A track deletion or backup restore started while editing playlists.");
 return commitPlaylistEdit(storage,key,next);
}

/** Persist before updating UI state; quota failures must not create phantom edits. */
export function commitPlaylistEdit(storage:Pick<Storage,"setItem">,key:string,next:readonly StoredPlaylist[]):StoredPlaylist[]{
 const serialized=JSON.stringify(next);
 parseStoredPlaylists(serialized);
 storage.setItem(key,serialized);
 return [...next];
}


/** Keep audio until the playlist cleanup has been durably committed.
 * If deletion fails, restore only the removed track references against the
 * CURRENT saved state, never a stale snapshot that can erase intervening edits.
 * A rollback failure is recoverable by the next startup reconciliation. */
const DELETE_RECOVERY_KEY="mp3-shelf-delete-recovery";
type DeleteRecovery={version:1;key:string;trackId:string;original:StoredPlaylist[]};

export function recoverFailedTrackDeletion(
 storage:Pick<Storage,"getItem"|"setItem"|"removeItem">,
 audioTrackIds:ReadonlySet<string>
):StoredPlaylist[]|null{
 const raw=storage.getItem(DELETE_RECOVERY_KEY);
 if(raw===null)return null;
 // Recovery must not resurrect references while a backup restore is staged.
 // Preserve both journals for explicit reconciliation rather than guessing.
 if(storage.getItem(RESTORE_JOURNAL_KEY)!==null)
  throw new Error("Finish pending backup restore before replaying a track deletion.");
 const value:unknown=JSON.parse(raw);
 if(!value||typeof value!=="object")throw new Error("Invalid track deletion recovery journal.");
 const entry=value as Partial<DeleteRecovery>;
 if(entry.version!==1||typeof entry.key!=="string"||!entry.key.trim()||
    typeof entry.trackId!=="string"||!entry.trackId.trim()||
    !Array.isArray(entry.original))throw new Error("Invalid track deletion recovery journal.");
 parseStoredPlaylists(JSON.stringify(entry.original));
 // Audio was already deleted successfully: cleanup is final.
 if(!audioTrackIds.has(entry.trackId)){
  // The deletion may have succeeded before another tab reattached the ID.
  // Reconcile missing-audio references before clearing the durable journal.
  const baseline=storage.getItem(entry.key);
  const current=parseStoredPlaylists(baseline);
  if(current.some(playlist=>playlist.trackIds.includes(entry.trackId))){
   // Another recovery may have replaced this journal while we read playlists.
   // Do not mutate the namespace using a superseded deletion intent.
   if(storage.getItem(DELETE_RECOVERY_KEY)!==raw)
    throw new Error("Track deletion recovery changed before playlist reconciliation. Preserve the newer intent.");
   // A second tab may edit after recovery reads the playlists. Preserve its
   // newer state and keep the journal so startup can retry reconciliation.
   if(storage.getItem(entry.key)!==baseline)
    throw new Error("Playlists changed during deletion recovery. Retry reconciliation.");
   commitPlaylistEdit(storage,entry.key,current.map(playlist=>({
    ...playlist,trackIds:playlist.trackIds.filter(id=>id!==entry.trackId)
   })));
  }
  if(storage.getItem(DELETE_RECOVERY_KEY)!==raw)
   throw new Error("Track deletion recovery changed before journal cleanup. Preserve the newer intent.");
  storage.removeItem(DELETE_RECOVERY_KEY);
  return parseStoredPlaylists(storage.getItem(entry.key));
 }
 const baseline=storage.getItem(entry.key);
 const current=parseStoredPlaylists(baseline);
 const oldById=new Map(entry.original.map(p=>[p.id,p]));
 const next=current.map(p=>{
  const old=oldById.get(p.id);
  if(!old||!old.trackIds.includes(entry.trackId)||p.trackIds.includes(entry.trackId))return p;
  const index=old.trackIds.indexOf(entry.trackId);
  const previous=old.trackIds.slice(0,index).reverse().find(id=>p.trackIds.includes(id));
  const following=old.trackIds.slice(index+1).find(id=>p.trackIds.includes(id));
  const insertAt=previous?p.trackIds.lastIndexOf(previous)+1:following?p.trackIds.indexOf(following):p.trackIds.length;
  const ids=[...p.trackIds];ids.splice(insertAt,0,entry.trackId);
  return {...p,trackIds:ids};
 });
 if(storage.getItem(entry.key)!==baseline)
  throw new Error("Playlists changed during deletion recovery. Retry reconciliation.");
 if(storage.getItem(DELETE_RECOVERY_KEY)!==raw)
  throw new Error("Track deletion recovery changed before playlist rollback. Preserve the newer intent.");
 commitPlaylistEdit(storage,entry.key,next);
 if(storage.getItem(DELETE_RECOVERY_KEY)!==raw)
  throw new Error("Track deletion recovery changed before journal cleanup. Preserve the newer intent.");
 storage.removeItem(DELETE_RECOVERY_KEY);
 // Read the latest durable playlists: edits may occur while IDB deletion awaits.
 // Returning the pre-await snapshot would erase concurrent edits in React.
 return parseStoredPlaylists(storage.getItem(entry.key));
}

export async function deleteTrackWithPlaylistCleanup(
 storage:Pick<Storage,"getItem"|"setItem"|"removeItem">,key:string,
 playlists:readonly StoredPlaylist[],trackId:string,
 deleteAudio:(id:string)=>Promise<void>
):Promise<StoredPlaylist[]>{
 if(storage.getItem(DELETE_RECOVERY_KEY)!==null)
  throw new Error("A previous track deletion needs recovery before another deletion.");
 // A restore can be between staging its intent and writing its audio records.
 // Deleting any track now can invalidate its durable recovery checkpoint.
 if(storage.getItem(RESTORE_JOURNAL_KEY)!==null)
  throw new Error("Finish the pending backup restore before deleting a recording.");
 if(typeof trackId!=="string"||!trackId.trim())throw new Error("Invalid track ID for deletion.");
 // Use the current durable state rather than a possibly stale React snapshot.
 const baseline=storage.getItem(key);
 const original=parseStoredPlaylists(baseline);
 const next=original.map(item=>({...item,trackIds:item.trackIds.filter(id=>id!==trackId)}));
 const intent:DeleteRecovery={version:1,key,trackId,original};
 const ownedJournal=JSON.stringify(intent);
 storage.setItem(DELETE_RECOVERY_KEY,ownedJournal);
 const assertJournalOwnership=()=>{
  if(storage.getItem(DELETE_RECOVERY_KEY)!==ownedJournal)
   throw new Error("Track deletion recovery journal changed during audio deletion. Preserve the newer intent.");
 };
 try{
  // Staging the journal is a separate storage write. Another tab may edit
  // playlists between our snapshot and the cleanup commit; never overwrite
  // that edit with the pre-journal snapshot.
  if(storage.getItem(key)!==baseline)
   throw new Error("Playlists changed while staging deletion. Retry without losing the newer edit.");
  if(storage.getItem(RESTORE_JOURNAL_KEY)!==null)
   throw new Error("A backup restore started while staging deletion.");
  // A competing tab can replace the journal while staging writes are in progress.
  // Never commit playlist cleanup under another operation's recovery intent.
  assertJournalOwnership();
  commitPlaylistEdit(storage,key,next);
 }catch(error){
  // Do not erase a newer tab's recovery intent when staging fails.
  assertJournalOwnership();
  storage.removeItem(DELETE_RECOVERY_KEY);
  throw error;
 }
 try{
  // An edit from another tab may have reattached the recording while the
  // deletion was being staged. Abort before removing its audio bytes.
  const latest=parseStoredPlaylists(storage.getItem(key));
  if(latest.some(playlist=>playlist.trackIds.includes(trackId)))
   throw new Error("The recording was added to a playlist during deletion. Audio was preserved.");
  await deleteAudio(trackId);
 }catch(error){
  // A different tab may have replaced the journal during the async IDB call.
  // Recovery must not interpret its snapshot as ours or clear the new intent.
  assertJournalOwnership();
  try{
   // Reconciliation merges against current edits, and leaves the journal
   // intact if quota/storage errors prevent the repair.
   recoverFailedTrackDeletion(storage,new Set([trackId]));
  }catch{
   throw new Error("Audio deletion failed and playlist rollback could not be saved. Reload the library before editing playlists.",{cause:error});
  }
  throw error;
 }
 // Never reconcile or clear another tab's intent after an asynchronous write.
 assertJournalOwnership();
 // A different tab may have reattached the track while IndexedDB deletion
 // was in flight. Its audio is now absent, so never return a playlist with
 // dangling references. Reconcile against the *latest* persisted state and
 // retain the journal if persistence fails, allowing startup to retry.
 const reconciliationBaseline=storage.getItem(key);
 const afterDeletion=parseStoredPlaylists(reconciliationBaseline);
 if(afterDeletion.some(playlist=>playlist.trackIds.includes(trackId))){
  const reconciled=afterDeletion.map(playlist=>({
   ...playlist,trackIds:playlist.trackIds.filter(id=>id!==trackId)
  }));
  // Reconciliation can run after an arbitrary IndexedDB delay. If another
  // tab edits playlists while we inspect them, retain its bytes and the
  // deletion journal so startup can safely retry against the new state.
  if(storage.getItem(key)!==reconciliationBaseline)
   throw new Error("Playlists changed during post-deletion reconciliation. Retry recovery.");
  assertJournalOwnership();
  commitPlaylistEdit(storage,key,reconciled);
 }
 // Recheck ownership after reconciliation; a replacement journal must survive.
 assertJournalOwnership();
 // A journal cleanup failure is safe: startup sees that the audio is absent
 // and removes the intent without resurrecting any playlist references.
 storage.removeItem(DELETE_RECOVERY_KEY);
 return parseStoredPlaylists(storage.getItem(key));
}
