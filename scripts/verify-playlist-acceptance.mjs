#!/usr/bin/env node
// Validate measured native playlist-to-offline-library results. A report is NOT a device test.
import { readFileSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const SHA = /^[a-f0-9]{64}$/;
const VERSION = /\b(?:live|remaster(?:ed)?|remix|acoustic|radio edit|cover|karaoke|slowed|sped up)\b/i;
const codecs = new Set(['mp3', 'm4a', 'aac', 'wav', 'aiff']);
const clean = s => typeof s === 'string' ? s.normalize('NFKC').toLocaleLowerCase('en').replace(/[^\p{L}\p{N}]+/gu, ' ').trim() : '';
function identity(value) { return [clean(value?.title), clean(value?.artist), clean(value?.edition || '')]; }
const same = (a, b) => a.every((value, index) => value === b[index]);
function allowedDirectURL(raw) {
  try {
    const u = new URL(raw);
    if (u.protocol !== 'https:' || u.username || u.password || u.hash || !u.hostname || (u.port && u.port !== '443')) return false;
    const host = u.hostname.toLowerCase().replace(/\.$/, '');
    return !['spotify.com', 'spotifycdn.com', 'scdn.co'].some(root => host === root || host.endsWith('.' + root));
  } catch { return false; }
}
export function verifyPlaylistAcceptance(report) {
  const errors = [], results = report?.results, requested = report?.requested;
  if (!report || typeof report !== 'object' || Array.isArray(report) || report.version !== 1 ||
      report.metadataProvider !== 'spotify' || !Array.isArray(requested) || !requested.length ||
      requested.length > 20000 || !Array.isArray(results) || results.length !== requested.length)
    return { verdict: 'FAIL', errors: ['Incomplete Spotify playlist request/result inventory.'], metrics: null, deviceAcceptance: 'NOT_VERIFIED' };
  const identifiers = new Set(), outcomes = new Map();
  for (const track of requested) {
    if (!track || typeof track.id !== 'string' || !track.id || identifiers.has(track.id) ||
        !identity(track)[0] || !identity(track)[1] || !Number.isFinite(track.durationSeconds) || track.durationSeconds <= 0) {
      errors.push('Invalid or duplicate requested recording identity.'); continue;
    }
    identifiers.add(track.id);
  }
  for (const item of results) {
    if (!item || !identifiers.has(item.id) || outcomes.has(item.id)) {
      errors.push('Missing, duplicated or unknown result identifier.'); continue;
    }
    outcomes.set(item.id, item);
  }
  const metrics = { total: requested.length, imported: 0, unavailable: 0, review: 0,
    incorrectMatches: 0, offlineVerified: 0, cellularWithoutConsent: 0 };
  for (const track of requested) {
    const result = outcomes.get(track.id);
    if (!result) { errors.push('No result for requested recording ' + track.id); continue; }
    if (result.state === 'unavailable' || result.state === 'review') {
      metrics[result.state]++;
      if (result.offlineFile || result.autoSelected === true || result.playbackProof)
        errors.push('Unresolved recording was silently marked imported: ' + track.id);
      continue;
    }
    if (result.state !== 'imported') { errors.push('Invalid result state: ' + track.id); continue; }
    metrics.imported++;
    const match = result.match;
    const correct = !!match && same(identity(track), identity(match)) &&
      Number.isFinite(match.durationSeconds) && Math.abs(match.durationSeconds - track.durationSeconds) <= 4 &&
      match.confidence === 'high' && match.ambiguous === false &&
      allowedDirectURL(match.directURL) && match.spotifyStream !== true &&
      !(VERSION.test(track.edition || '') && !VERSION.test(match.edition || ''));
    if (!correct) { metrics.incorrectMatches++; errors.push('Incorrect/ambiguous automatic recording match: ' + track.id); }
    const file = result.offlineFile;
    if (!file || file.exists !== true || !codecs.has(file.codec) ||
        !Number.isSafeInteger(file.bytes) || file.bytes < 1024 || file.bytes > 250 * 1024 * 1024 ||
        !SHA.test(file.sha256 ?? '') || file.headerVerified !== true ||
        !Number.isFinite(file.decodedDurationSeconds) ||
        Math.abs(file.decodedDurationSeconds - track.durationSeconds) > 4)
      errors.push('No verified, decoded local audio bytes for: ' + track.id);
    const queue = result.queue;
    if (queue?.persisted !== true || queue?.status !== 'imported' || queue?.activeDuplicateTickets !== 0)
      errors.push('Background transfer is not durably reconciled: ' + track.id);
    if (result.transport === 'cellular' && result.explicitCellularConsent !== true) {
      metrics.cellularWithoutConsent++;
      errors.push('Cellular transfer lacked explicit playlist permission: ' + track.id);
    }
    if (!['wifi', 'cellular'].includes(result.transport)) errors.push('Unknown transport: ' + track.id);
    const proof = result.playbackProof;
    if (proof?.networkDisabled === true && proof?.reopenedApp === true &&
        proof?.playedLocalFile === true && proof?.trackID === track.id &&
        proof?.sha256 === file?.sha256) metrics.offlineVerified++;
    else errors.push('Offline reopen/playback proof missing or mismatched: ' + track.id);
  }
  const accounted = metrics.imported + metrics.review + metrics.unavailable;
  if (accounted !== requested.length) errors.push('Batch accounting is incomplete.');
  if (report.backup?.trackCount !== metrics.imported || report.backup?.preservedPlaylistOrder !== true ||
      report.backup?.byteExactRoundTrip !== true) errors.push('Portable backup integrity/reordering proof missing.');
  const verdict = errors.length ? 'FAIL' : metrics.unavailable || metrics.review ? 'PARTIAL' : 'PASS';
  return { verdict, metrics, errors, deviceAcceptance: 'NOT_VERIFIED' };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (process.argv.length !== 3) { console.error('Usage: node scripts/verify-playlist-acceptance.mjs batch-result.json'); process.exitCode = 2; }
  else {
    try {
      const path = process.argv[2];
      if (statSync(path).size > 2 * 1024 * 1024) throw Error('Batch report exceeds 2 MiB');
      const result = verifyPlaylistAcceptance(JSON.parse(readFileSync(path, 'utf8')));
      console.log(JSON.stringify(result, null, 2));
      if (result.verdict !== 'PASS') process.exitCode = 1;
    } catch (error) { console.error('UNVERIFIED: ' + error.message); process.exitCode = 2; }
  }
}
