#!/usr/bin/env node
/** Select a Spotify metadata playlist already stored on one physical iPhone.
 * This selector cannot initiate source discovery or download audio.
 */
import { execFileSync } from 'node:child_process';
import { lstatSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
export function spotifyPlaylistChoices(catalog) {
  if (!catalog || !Array.isArray(catalog.playlists)) return [];
  const seen = new Set();
  const choices = [];
  for (const item of catalog.playlists) {
    if (!UUID.test(item?.id ?? '') || seen.has(item.id)) continue;
    let spotify = false;
    try {
      const url = new URL(item.sourceURL);
      spotify = url.protocol === 'https:' && url.hostname === 'open.spotify.com' &&
        !url.username && !url.password && !url.hash &&
        /^\/playlist\/[A-Za-z0-9]{22}\/?$/.test(url.pathname);
    } catch { /* Not Spotify metadata. */ }
    if (!spotify || !Array.isArray(item.sourceOrder) || item.sourceOrder.length < 1 ||
        item.sourceOrder.length > 20000) continue;
    seen.add(item.id);
    const name = String(item.name ?? 'Unnamed Spotify playlist')
      .replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu, ' ').trim().slice(0, 64) || 'Unnamed Spotify playlist';
    const available = Array.isArray(item.trackIDs) ? item.trackIDs.length : 0;
    const label = name + ' (' + available + '/' + item.sourceOrder.length +
      ' downloaded) [' + item.id + ']';
    choices.push({ id: item.id, label, total: item.sourceOrder.length,
      downloaded: available });
    if (choices.length > 50) throw Error('Too many Spotify playlists for unattended device QA.');
  }
  return choices.sort((a,b)=>a.label.localeCompare(b.label));
}
function asAppleString(value) {
  return '"' + value.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}
export function selectPlaylist(choices, { chooser } = {}) {
  if (!Array.isArray(choices) || !choices.length)
    throw Error('No Spotify playlists in the iPhone library. Import one in MP3 Shelf first.');
  if (choices.length === 1) return choices[0].id;
  if (typeof chooser !== 'function')
    throw Error('More than one playlist requires a visible user selection.');
  const labels = choices.map(c=>c.label);
  const result = chooser(labels);
  const found = choices.find(x=>x.label === result);
  if (!found) throw Error('No Spotify playlist was selected.');
  return found.id;
}
function chooseByMacDialog(labels) {
  const script = 'set picked to choose from list {' +
    labels.map(asAppleString).join(', ') +
    '} with title "MP3 Shelf" with prompt "Choose a Spotify playlist to verify offline:" ' +
    'without multiple selections allowed\n' +
    'if picked is false then error "Cancelled"\n' +
    'return item 1 of picked';
  return execFileSync('osascript',['-e',script],{encoding:'utf8',
    timeout:180000,maxBuffer:16384,stdio:['ignore','pipe','pipe']}).trim();
}
export function choosePlaylistFromFile(path, { chooser = chooseByMacDialog } = {}) {
  const full = resolve(path);
  const meta = lstatSync(full);
  if (!meta.isFile() || meta.isSymbolicLink() || meta.nlink !== 1 ||
      meta.size < 2 || meta.size > 16*1024*1024)
    throw Error('Unsafe or unreadable iPhone playlist catalog.');
  const choices = spotifyPlaylistChoices(JSON.parse(readFileSync(full,'utf8')));
  return selectPlaylist(choices,{chooser});
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (process.argv.length !== 3) {
    console.error('Usage: node scripts/choose-iphone-playlist.mjs SAVED_IPHONE_LIBRARY_JSON');
    process.exitCode = 2;
  } else {
    try { console.log(choosePlaylistFromFile(process.argv[2])); }
    catch(error){ console.error('SPOTIFY_PLAYLIST_SELECTION_BLOCKED: '+error.message);process.exitCode=1; }
  }
}
