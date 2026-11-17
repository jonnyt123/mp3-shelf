#!/usr/bin/env node
/**
 * Physical iPhone QA driver. Explicit opt-in on a paired real device only.
 * It does not toggle Airplane Mode, sign/install apps, or close issue #6.
 * The native DEBUG audit runs in the installed app; this script starts phases.
 */
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { homedir, tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { captureDevicePlaylist, physicalIPhone }
  from './collect-iphone-playlist-evidence.mjs';

const SHA = /^[0-9a-f]{40}$/;
const DEVICE = /^[A-Za-z0-9-]{8,120}$/;
const BUNDLE = /^com\.jonnyt\.mp3shelf$/;
const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;

export function devicePhaseArguments(phase, { deviceID, bundleID, playlistID } = {}) {
  if (!DEVICE.test(deviceID ?? '') || !BUNDLE.test(bundleID ?? ''))
    throw Error('An explicit device identifier and the expected MP3 Shelf bundle are required.');
  const base = ['devicectl', 'device', 'process', 'launch', '--device', deviceID,
    '--terminate-existing', bundleID, '--'];
  if (phase === 'arm') return [...base, '--mp3shelf-qa-arm'];
  if (phase === 'offline') {
    if (!UUID.test(playlistID ?? '')) throw Error('Offline playback requires a local playlist UUID.');
    return [...base, '--mp3shelf-qa-offline', playlistID];
  }
  if (phase === 'stop') return [...base, '--mp3shelf-qa-stop'];
  throw Error('Unknown physical-iPhone audit phase.');
}
function run(command, args, timeout = 30000) {
  return execFileSync(command, args, { encoding: 'utf8', timeout,
    stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 1024 * 1024 });
}
export async function runIPhonePhase({ phase, deviceID, bundleID, playlistID,
  sha, output, cwd = process.cwd(), platform = process.platform } = {}) {
  if (platform !== 'darwin') throw Error('REAL_IPHONE_REQUIRED: macOS and paired real iPhone only');
  if (!SHA.test(sha ?? '')) throw Error('A complete candidate Git commit SHA is required.');
  if (run('git', ['-C', cwd, 'rev-parse', 'HEAD']).trim() !== sha ||
      run('git', ['-C', cwd, 'status', '--porcelain', '--untracked-files=all']).trim())
    throw Error('Physical device QA requires a clean checkout of the exact candidate.');
  // Never allow a passed-in install path or arbitrary bundle ID to redirect a
  // physical user device task toward unrelated apps.
  if (phase === 'arm' || phase === 'offline' || phase === 'stop') {
    const command = devicePhaseArguments(phase, { deviceID, bundleID, playlistID });
    const temp = mkdtempSync(join(tmpdir(), 'mp3shelf-device-qa-'));
    try {
      const inventoryPath = join(temp, 'devices.json');
      run('xcrun', ['devicectl', 'list', 'devices', '--json-output', inventoryPath]);
      physicalIPhone(JSON.parse(readFileSync(inventoryPath, 'utf8')), deviceID);
    } finally { rmSync(temp, { recursive: true, force: true }); }
    run('xcrun', command);
    return { phase, device: 'PHYSICAL_DEVICE_LAUNCH_REQUESTED',
      offlinePlayback: 'NOT_VERIFIED', sourceSHA: sha,
      physicalAcceptance: 'INCOMPLETE' };
  }
  if (phase === 'collect') {
    if (!UUID.test(playlistID ?? '') || (output !== undefined &&
      (typeof output !== 'string' || !output)))
      throw Error('Collection requires a playlist UUID and safe report destination.');
    const target = resolve(output ?? join(homedir(), 'Library', 'Logs', 'MP3Shelf',
      'DeviceAcceptance', sha, 'physical-inventory.json'));
    mkdirSync(dirname(target), { recursive: true, mode: 0o700 });
    const report = await captureDevicePlaylist({
      deviceID, bundleID, playlistID, expectedSha: sha, output: target, cwd, platform
    });
    // This is a TEMPLATE, never approval: independent actual iPhone testing,
    // app-install provenance and issue #6 review must fill every field.
    const raw = readFileSync(target);
    const template = {
      schema: 'mp3shelf-hardware-acceptance-v1', candidateSha: sha,
      installedSourceSha: 'NOT_VERIFIED', signedAppSHA256: 'NOT_VERIFIED',
      inventorySHA256: createHash('sha256').update(raw).digest('hex'),
      reviewer: 'NOT_VERIFIED', reviewedAt: null,
      deviceModel: report.device?.productType ?? 'NOT_VERIFIED',
      iOSVersion: report.device?.osVersion ?? 'NOT_VERIFIED',
      checks: Object.fromEntries([
        'signingInstallation','offlinePlayback','backgroundDownloads',
        'failureHandling','spotifyMetadata','backupInterop','accessibility',
        'sourcePolicy','finalAcceptance'
      ].map(key => [key, 'UNVERIFIED']))
    };
    writeFileSync(join(dirname(target), 'hardware-acceptance.template.json'),
      JSON.stringify(template, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    return { phase, output: target,
      copiedTracks: report.copiedTracks,
      offlinePlayback: report.offlinePlaybackAfterRestart,
      backgroundTransfer: report.backgroundTransfer,
      physicalAcceptance: report.physicalAcceptance };
  }
  throw Error('Unsupported physical iPhone phase');
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [phase, deviceID, bundleID, sha, playlistID, output, ...rest] = process.argv.slice(2);
  if (!['arm', 'offline', 'collect', 'stop'].includes(phase) || rest.length ||
      !deviceID || !bundleID || !sha ||
      (['offline', 'collect'].includes(phase) && !playlistID)) {
    console.error('Usage: node scripts/iphone-qa-session.mjs arm|offline|collect|stop DEVICE_ID com.jonnyt.mp3shelf SHA [PLAYLIST_UUID] [OUTPUT_JSON_OPTIONAL]');
    process.exitCode = 2;
  } else {
    runIPhonePhase({ phase, deviceID, bundleID, sha, playlistID, output }).then(r => {
      console.log(JSON.stringify(r, null, 2));
    }).catch(error => {
      console.error('DEVICE_QA_BLOCKED: ' + error.message);
      process.exitCode = 1;
    });
  }
}
