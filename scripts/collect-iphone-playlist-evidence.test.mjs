import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { physicalIPhone, inspectPlaylistCatalog, installedApp, captureDevicePlaylist } from './collect-iphone-playlist-evidence.mjs';
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
