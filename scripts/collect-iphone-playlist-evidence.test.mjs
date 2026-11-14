import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { physicalIPhone, inspectPlaylistCatalog, installedApp, captureDevicePlaylist, verifyPhysicalDeviceTelemetry } from './collect-iphone-playlist-evidence.mjs';
const id = '12345678-1234-1234-1234-123456789012';
const playlistID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const playlist = 'https://open.spotify.com/playlist/' + 'A'.repeat(22);
function device(reality = 'physical', productType = 'iPhone16,2') {
  return { result: { devices: [{ identifier: id, properties: { hardware: { udid: id,
    reality, productType, platform: 'iOS' }, connection: { pairingState: 'paired' },
    software: { osVersionNumber: { stringValue: '26.0' } } } }] } };
}
function catalog() {
  return { tracks: [{ id, fileName: 'Song [123456789abc].mp3' }], playlists: [{
    id: playlistID, sourceURL: playlist, sourceOrder: [{ title: 'Song', artist: 'Artist' }],
    trackIDs: [id], missingTracks: [] }] };
}
test('only a positively recognized paired physical iPhone passes', () => {
  assert.equal(physicalIPhone(device(), id).productType, 'iPhone16,2');
  for (const [reality, model] of [['simulated', 'iPhone16,2'], ['physical', 'iPad14,2'],
    ['unknown', 'iPhone16,2']]) assert.throws(() => physicalIPhone(device(reality, model), id));
  assert.throws(() => physicalIPhone(device(), 'unknown'));
});
test('accepts older devicectl JSON but rejects unpaired phones', () => {
  const legacy = { result: { devices: [{ identifier: id,
    hardwareProperties: { udid: id, reality: 'physical', productType: 'iPhone14,7', platform: 'iOS' },
    connectionProperties: { pairingState: 'paired' }, deviceProperties: { osVersionNumber: '26.0' } }] } };
  assert.equal(physicalIPhone(legacy, id).productType, 'iPhone14,7');
  legacy.result.devices[0].connectionProperties.pairingState = 'unpaired';
  assert.throws(() => physicalIPhone(legacy, id));
});
test('local catalog must identify a Spotify playlist and trustworthy audio paths', () => {
  assert.equal(inspectPlaylistCatalog(catalog(), playlistID).catalogTracks, 1);
  const invalid = catalog(); invalid.playlists[0].sourceURL = 'https://evil.example/playlist/' + 'A'.repeat(22);
  assert.throws(() => inspectPlaylistCatalog(invalid, playlistID));
  const traversed = catalog(); traversed.tracks[0].fileName = '../outside.mp3';
  assert.throws(() => inspectPlaylistCatalog(traversed, playlistID));
  const duplicated = catalog(); duplicated.playlists[0].trackIDs.push(id);
  assert.throws(() => inspectPlaylistCatalog(duplicated, playlistID));
});
test('installed app bundle must match', () => {
  const apps = { result: { apps: [{ bundleIdentifier: 'com.jonnyt.mp3shelf' }] } };
  assert(installedApp(apps, 'com.jonnyt.mp3shelf'));
  assert.throws(() => installedApp(apps, 'com.another.app'));
});
test('Linux cannot produce physical device acceptance evidence', async () => {
  await assert.rejects(captureDevicePlaylist({ platform: 'linux' }), /REAL_DEVICE_NOT_TESTED/);
});

import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, chmodSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

test('mocked devicectl captures a complete local playlist without falsely passing playback', async () => {
  const root = mkdtempSync(join(tmpdir(), 'mp3shelf-device-capture-'));
  const oldCwd = process.cwd(), oldPath = process.env.PATH, oldFixture = process.env.MP3SHELF_FAKE_ROOT;
  try {
    const repo = join(root, 'repo'), bin = join(root, 'bin'), fixtures = join(root, 'fixtures');
    mkdirSync(repo); mkdirSync(bin); mkdirSync(fixtures);
    execFileSync('git', ['init', '-q', repo]);
    writeFileSync(join(repo, 'source.txt'), 'fixture source\n');
    execFileSync('git', ['-C', repo, '-c', 'user.name=Test',
      '-c', 'user.email=qa@example.test', 'add', 'source.txt']);
    execFileSync('git', ['-C', repo, '-c', 'user.name=Test',
      '-c', 'user.email=qa@example.test', 'commit', '-qm', 'fixture']);
    const sha = execFileSync('git', ['-C', repo, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
    writeFileSync(join(fixtures, 'catalog.json'), JSON.stringify(catalog()));
    const audio = Buffer.alloc(1025, 73);
    writeFileSync(join(fixtures, 'audio.bin'), audio);
    const stub = [
      '#!/usr/bin/env node',
      "const fs = require('node:fs'), path = require('node:path');",
      "const args = process.argv.slice(2);",
      "const index = key => args.indexOf(key);",
      "const out = index('--json-output') < 0 ? null : args[index('--json-output')+1];",
      "if (args[0] === 'devicectl' && args[1] === 'list') {",
      " const id = '12345678-1234-1234-1234-123456789012';",
      " fs.writeFileSync(out, JSON.stringify({result:{devices:[{identifier:id,properties:{hardware:{udid:id,reality:'physical',productType:'iPhone16,2',platform:'iOS'},connection:{pairingState:'paired'}}}]}}));",
      "} else if (args[0] === 'devicectl' && args[2] === 'info') {",
      " fs.writeFileSync(out, JSON.stringify({result:{apps:[{bundleIdentifier:'com.jonnyt.mp3shelf'}]}}));",
      "} else if (args[0] === 'devicectl' && args[2] === 'copy') {",
      " const src = args[index('--source')+1];",
      " const name = src.endsWith('library.json') ? 'catalog.json' : 'audio.bin';",
      " fs.copyFileSync(path.join(process.env.MP3SHELF_FAKE_ROOT, name), args[index('--destination')+1]);",
      "} else process.exit(2);"
    ].join('\n') + '\n';
    const cli = join(bin, 'xcrun');
    writeFileSync(cli, stub);
    chmodSync(cli, 0o700);
    process.chdir(repo);
    process.env.PATH = bin + ':' + oldPath;
    process.env.MP3SHELF_FAKE_ROOT = fixtures;
    const output = join(root, 'report.json');
    const report = await captureDevicePlaylist({
      deviceID: id, bundleID: 'com.jonnyt.mp3shelf', playlistID,
      expectedSha: sha, output, platform: 'darwin'
    });
    assert.equal(report.copiedTracks, 1);
    assert.equal(report.files[0].sha256, createHash('sha256').update(audio).digest('hex'));
    assert.equal(report.installedBinaryCommit, 'NOT_VERIFIED');
    assert.equal(report.offlinePlaybackAfterRestart, 'NOT_VERIFIED');
    assert.equal(report.physicalAcceptance, 'INCOMPLETE');
    assert.deepEqual(JSON.parse(readFileSync(output, 'utf8')).files, report.files);
  } finally {
    process.chdir(oldCwd); process.env.PATH = oldPath;
    if (oldFixture === undefined) delete process.env.MP3SHELF_FAKE_ROOT;
    else process.env.MP3SHELF_FAKE_ROOT = oldFixture;
    rmSync(root, { recursive: true, force: true });
  }
});


function observed() {
  const proof = {
    schema: 'mp3shelf-physical-offline-v1',
    status: 'OFFLINE_PLAYBACK_PASS', deviceKind: 'physical-iPhone-debug',
    networkProof: 'NWPATH_UNSATISFIED', playlistID,
    processToken: '11111111-1111-1111-1111-111111111111',
    armedProcessToken: '22222222-2222-2222-2222-222222222222',
    playbackVerified: 1,
    observations: [{ trackID: id, localFile: true, positionSeconds: 0.6 }]
  };
  const events = [
    { event: 'qa-armed', processToken: proof.armedProcessToken },
    { event: 'background-session-wake', processToken: proof.armedProcessToken },
    { event: 'download-audio-staged', processToken: proof.armedProcessToken, ticketID: id },
    { event: 'offline-verification-started', processToken: proof.processToken },
    { event: 'offline-verification-finished', processToken: proof.processToken }
  ];
  return { proof, events, selected: [{ id }] };
}
test('real app playback clock and two-process event receipts can support qualified device evidence', () => {
  const { proof, events, selected } = observed();
  assert.deepEqual(verifyPhysicalDeviceTelemetry(proof, events, playlistID, selected), {
    offlinePlaybackAfterRestart: 'APP_INSTRUMENTED_PHYSICAL_PASS',
    backgroundTransfer: 'APP_RECORDED_STAGING_AND_BACKGROUND_WAKE'
  });
});
test('device proof rejects recycled process, network-connected and phantom playback samples', () => {
  for (const change of [
    x => { x.proof.processToken = x.proof.armedProcessToken; },
    x => { x.proof.networkProof = 'NWPATH_SATISFIED'; },
    x => { x.proof.observations[0].positionSeconds = 0; },
    x => { x.proof.observations[0].trackID = 'wrong'; },
    x => { x.events.pop(); },
    x => { x.proof.playbackVerified = 0; }
  ]) {
    const item = observed(); change(item);
    assert.throws(() => verifyPhysicalDeviceTelemetry(item.proof, item.events, playlistID, item.selected));
  }
});
test('a playback receipt alone cannot fabricate background URLSession completion', () => {
  const { proof, events, selected } = observed();
  const noCallback = events.filter(e => e.event !== 'download-audio-staged');
  const result = verifyPhysicalDeviceTelemetry(proof, noCallback, playlistID, selected);
  assert.equal(result.offlinePlaybackAfterRestart, 'APP_INSTRUMENTED_PHYSICAL_PASS');
  assert.equal(result.backgroundTransfer, 'NOT_VERIFIED');
});
