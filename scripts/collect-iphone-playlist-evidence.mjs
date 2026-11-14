#!/usr/bin/env node
// Read-only iPhone app catalog and audio-byte capture. Never claims actual playback or download.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createReadStream, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const sha40 = /^[0-9a-f]{40}$/i;
const safeID = /^[A-Za-z0-9-]{8,120}$/;
const safeBundle = /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;
export function physicalIPhone(inventory, selected) {
  const list = inventory?.result?.devices;
  if (!Array.isArray(list)) throw Error('devicectl device inventory is unavailable');
  const device = list.find(d => d?.identifier === selected ||
    d?.hardwareProperties?.udid === selected || d?.properties?.hardware?.udid === selected);
  if (!device) throw Error('The selected device is not listed by devicectl');
  const hw = device.properties?.hardware ?? device.hardwareProperties ?? {};
  const connection = device.properties?.connection ?? device.connectionProperties ?? {};
  const software = device.properties?.software ?? device.deviceProperties ?? {};
  if (!/^iPhone\d+,\d+$/.test(hw.productType ?? '') ||
      String(hw.reality ?? '').toLowerCase() !== 'physical' ||
      String(hw.platform ?? '').toLowerCase() !== 'ios')
    throw Error('Only a positively identified physical iPhone is permitted');
  if (String(connection.pairingState ?? '').toLowerCase() !== 'paired')
    throw Error('The iPhone is not confirmed paired');
  return { identifier: device.identifier, productType: hw.productType,
    osVersion: software.osVersionNumber?.stringValue ?? software.osVersionNumber ?? 'unknown' };
}
export function inspectPlaylistCatalog(library, playlistID) {
  if (!library || !Array.isArray(library.tracks) || !Array.isArray(library.playlists))
    throw Error('Saved library catalog is missing its track/playlist collections');
  const playlist = library.playlists.find(p => p?.id === playlistID);
  if (!playlist || typeof playlist.sourceURL !== 'string') throw Error('Spotify playlist not found in local catalog');
  let url;
  try { url = new URL(playlist.sourceURL); } catch { throw Error('Invalid Spotify metadata-only playlist URL'); }
  if (url.protocol !== 'https:' || url.hostname !== 'open.spotify.com' ||
      !/^\/playlist\/[A-Za-z0-9]{22}\/?$/.test(url.pathname) || url.username || url.password)
    throw Error('Playlist is not a Spotify metadata import');
  if (!Array.isArray(playlist.sourceOrder) || !Array.isArray(playlist.trackIDs) ||
      !Array.isArray(playlist.missingTracks) || !playlist.sourceOrder.length ||
      playlist.sourceOrder.length > 20000) throw Error('Incomplete playlist order or metadata');
  const trackIDs = new Set(playlist.trackIDs);
  if (trackIDs.size !== playlist.trackIDs.length) throw Error('Duplicate local track references');
  const tracks = new Map(library.tracks.map(t => [t.id, t]));
  if (tracks.size !== library.tracks.length) throw Error('Duplicate persisted track identities');
  const selected = [];
  for (const id of playlist.trackIDs) {
    const track = tracks.get(id);
    if (!track || typeof track.fileName !== 'string' || track.fileName.length > 255 ||
        !track.fileName || track.fileName === '.' || track.fileName === '..' ||
        /[\\/\u0000]/.test(track.fileName)) throw Error('Untrusted or missing track file reference');
    selected.push({ id, fileName: track.fileName });
  }
  if (new Set(selected.map(t => t.fileName.toLowerCase())).size !== selected.length)
    throw Error('Multiple metadata entries alias the same audio path');
  return { playlistID, requested: playlist.sourceOrder.length, unavailable: playlist.missingTracks.length,
    catalogTracks: selected.length, selected };
}
/**
 * Cross-check actual DEBUG on-device measurements against the saved playlist.
 * A host hash proves bytes; this checks a different app process, unsatisfied
 * network path, and the production AVAudioPlayer clock advancing for each file.
 * Device logs are evidence of callback invocation, not completed HTTP identity.
 */
export function verifyPhysicalDeviceTelemetry(proof, events, playlistID, selected) {
  if (!proof || proof.schema !== 'mp3shelf-physical-offline-v1' ||
      proof.status !== 'OFFLINE_PLAYBACK_PASS' ||
      proof.deviceKind !== 'physical-iPhone-debug' ||
      proof.networkProof !== 'NWPATH_UNSATISFIED' ||
      proof.playlistID !== playlistID ||
      typeof proof.processToken !== 'string' ||
      typeof proof.armedProcessToken !== 'string' ||
      proof.processToken === proof.armedProcessToken ||
      !Array.isArray(proof.observations) ||
      !Array.isArray(events) || !Array.isArray(selected) ||
      proof.observations.length === 0 ||
      proof.observations.length !== selected.length ||
      proof.playbackVerified !== selected.length)
    throw Error('Native offline playback receipt is absent, incomplete or inconsistent');
  const ids = new Set(selected.map(item => item.id));
  const played = new Set();
  for (const row of proof.observations) {
    if (!row || !ids.has(row.trackID) || played.has(row.trackID) ||
        row.localFile !== true || !Number.isFinite(row.positionSeconds) ||
        row.positionSeconds <= 0.2)
      throw Error('Native playback sample does not prove every local recording advanced');
    played.add(row.trackID);
  }
  const has = (name, process) => events.some(row =>
    row?.event === name && row?.processToken === process);
  if (!has('qa-armed', proof.armedProcessToken) ||
      !has('offline-verification-started', proof.processToken) ||
      !has('offline-verification-finished', proof.processToken))
    throw Error('Device QA log does not corroborate distinct armed and offline processes');
  const staged = events.some(row => row?.event === 'download-audio-staged' &&
    typeof row.ticketID === 'string');
  const woke = events.some(row => row?.event === 'background-session-wake');
  return {
    offlinePlaybackAfterRestart: 'APP_INSTRUMENTED_PHYSICAL_PASS',
    backgroundTransfer: staged && woke
      ? 'APP_RECORDED_STAGING_AND_BACKGROUND_WAKE'
      : 'NOT_VERIFIED'
  };
}

export function installedApp(inventory, bundleID) {
  const apps = inventory?.result?.apps;
  if (!Array.isArray(apps) || !apps.some(a => a?.bundleIdentifier === bundleID))
    throw Error('Expected development application is not installed on the selected iPhone');
  return true;
}
async function hashFile(path) {
  const stat = statSync(path);
  if (!stat.isFile() || stat.size < 1024 || stat.size > 100 * 1024 * 1024)
    throw Error('Copied audio is empty, oversized or not a regular file');
  const hash = createHash('sha256');
  for await (const bytes of createReadStream(path, { highWaterMark: 64 * 1024 })) hash.update(bytes);
  return { bytes: stat.size, sha256: hash.digest('hex') };
}
function runGit(...args) {
  return execFileSync('git', args, { encoding: 'utf8', timeout: 10000, maxBuffer: 100000 }).trim();
}
function runDeviceJSON(args, root, filename) {
  const destination = join(root, filename);
  execFileSync('xcrun', ['devicectl', ...args, '--json-output', destination],
    { timeout: 30000, maxBuffer: 200000 });
  if (statSync(destination).size > 2 * 1024 * 1024) throw Error('Device metadata exceeds bounded JSON limit');
  return JSON.parse(readFileSync(destination, 'utf8'));
}
export async function captureDevicePlaylist({ deviceID, bundleID, playlistID, expectedSha, output, platform = process.platform }) {
  if (platform !== 'darwin') throw Error('REAL_DEVICE_NOT_TESTED: macOS and paired iPhone required');
  if (!safeID.test(deviceID) || !safeBundle.test(bundleID) || !safeID.test(playlistID) ||
      !sha40.test(expectedSha)) throw Error('Invalid device, bundle, playlist or commit identifier');
  if (runGit('rev-parse', 'HEAD') !== expectedSha ||
      runGit('status', '--porcelain', '--untracked-files=all') !== '')
    throw Error('Refusing unclean or wrong-SHA local checkout');
  const temp = mkdtempSync(join(tmpdir(), 'mp3shelf-device-proof-'));
  try {
    const device = physicalIPhone(runDeviceJSON(['list', 'devices'], temp, 'devices.json'), deviceID);
    installedApp(runDeviceJSON(['device', 'info', 'apps', '--device', device.identifier,
      '--bundle-id', bundleID], temp, 'apps.json'), bundleID);
    const copy = (source, destination) => execFileSync('xcrun', [
      'devicectl', 'device', 'copy', 'from', '--device', device.identifier,
      '--domain-type', 'appDataContainer', '--domain-identifier', bundleID,
      '--source', source, '--destination', destination
    ], { timeout: 120000, maxBuffer: 200000 });
    const catalogPath = join(temp, 'catalog.json');
    copy('Library/Application Support/MP3Shelf/library.json', catalogPath);
    if (statSync(catalogPath).size > 16 * 1024 * 1024) throw Error('Copied catalog exceeds size limit');
    const catalog = inspectPlaylistCatalog(JSON.parse(readFileSync(catalogPath, 'utf8')), playlistID);
    const proofs = [];
    for (let i = 0; i < catalog.selected.length; ++i) {
      const track = catalog.selected[i];
      const destination = join(temp, 'audio-' + i);
      copy('Documents/Music/' + track.fileName, destination);
      proofs.push({ trackID: track.id, ...await hashFile(destination) });
      rmSync(destination, { force: true });
    }
    // Evidence remains optional: an ordinary install may not have the
    // explicitly armed DEBUG QA report. Invalid/missing logs never grant PASS.
    let physicalTelemetry = null, physicalTelemetryError = null;
    try {
      const offlineFile = join(temp, 'physical-offline.json');
      const eventsFile = join(temp, 'physical-events.jsonl');
      copy('Documents/MP3ShelfPhysicalOfflineQA.json', offlineFile);
      copy('Documents/MP3ShelfPhysicalQAEvents.jsonl', eventsFile);
      if (statSync(offlineFile).size > 256 * 1024 ||
          statSync(eventsFile).size > 128 * 1024)
        throw Error('Physical QA diagnostics exceed bounded file sizes');
      const proof = JSON.parse(readFileSync(offlineFile, 'utf8'));
      const events = readFileSync(eventsFile, 'utf8').trim().split('\n')
        .filter(Boolean).map(line => JSON.parse(line));
      physicalTelemetry = verifyPhysicalDeviceTelemetry(
        proof, events, playlistID, catalog.selected);
    } catch (error) {
      physicalTelemetryError = error.message;
    }
    const report = { schema: 'mp3shelf-physical-inventory-v1', capturedAt: new Date().toISOString(),
      candidateSha: expectedSha, device: { productType: device.productType, osVersion: device.osVersion,
        identifierSha256: createHash('sha256').update(device.identifier).digest('hex') },
      bundleID, playlistID, source: 'Spotify metadata only', requested: catalog.requested,
      unavailable: catalog.unavailable, copiedTracks: proofs.length, files: proofs,
      fileByteIntegrity: 'HOST_HASHED_FROM_PHYSICAL_IPHONE',
      // A clean Mac checkout and installed bundle ID do not cryptographically
      // prove that the installed binary was built from that exact source SHA.
      installedBinaryCommit: 'NOT_VERIFIED',
      liveSourceSearch: 'NOT_VERIFIED', automaticMatching: 'NOT_VERIFIED',
      backgroundTransfer: physicalTelemetry?.backgroundTransfer ?? 'NOT_VERIFIED',
      cellularConsent: 'NOT_VERIFIED',
      offlinePlaybackAfterRestart: physicalTelemetry?.offlinePlaybackAfterRestart ?? 'NOT_VERIFIED',
      deviceTelemetryError: physicalTelemetryError,
      physicalAcceptance: 'INCOMPLETE' };
    writeFileSync(output, JSON.stringify(report, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    return report;
  } finally { rmSync(temp, { recursive: true, force: true }); }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [deviceID, bundleID, playlistID, sha, output, ...rest] = process.argv.slice(2);
  if (!deviceID || !bundleID || !playlistID || !sha || !output || rest.length) {
    console.error('Usage: node scripts/collect-iphone-playlist-evidence.mjs DEVICE_UDID BUNDLE_ID LOCAL_PLAYLIST_UUID CANDIDATE_SHA OUTPUT_JSON');
    process.exitCode = 2;
  } else {
    captureDevicePlaylist({ deviceID, bundleID, playlistID, expectedSha: sha, output }).then(r => {
      console.log(JSON.stringify({ capturedAt: r.capturedAt, copiedTracks: r.copiedTracks,
        physicalAcceptance: r.physicalAcceptance, offlinePlaybackAfterRestart: r.offlinePlaybackAfterRestart }));
    }).catch(error => {
      console.error('NOT_VERIFIED: ' + error.message);
      process.exitCode = 1;
    });
  }
}
