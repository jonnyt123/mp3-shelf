import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { verifyPlaylistAcceptance } from './verify-playlist-acceptance.mjs';
const hash = 'a'.repeat(64);
function fixture() {
  const requested = [{ id: 'song1', title: 'My Song', artist: 'The Artist', edition: '2020 Remaster', durationSeconds: 214 },
    { id: 'song2', title: 'Different Track', artist: 'Guest Artist', edition: '', durationSeconds: 191 }];
  const results = requested.map(track => ({ id: track.id, state: 'imported',
    match: { title: track.title, artist: track.artist, edition: track.edition,
      durationSeconds: track.durationSeconds, confidence: 'high', ambiguous: false,
      directURL: 'https://independent.example.org/' + track.id + '.mp3', spotifyStream: false },
    offlineFile: { exists: true, codec: 'mp3', bytes: 120000, sha256: hash, headerVerified: true,
      decodedDurationSeconds: track.durationSeconds },
    queue: { persisted: true, status: 'imported', activeDuplicateTickets: 0 }, transport: 'wifi',
    playbackProof: { networkDisabled: true, reopenedApp: true, playedLocalFile: true, trackID: track.id, sha256: hash } }));
  return { version: 1, metadataProvider: 'spotify', requested, results,
    backup: { trackCount: 2, preservedPlaylistOrder: true, byteExactRoundTrip: true } };
}
test('full verified playlist returns PASS but never invents device QA', () => {
  const check = verifyPlaylistAcceptance(fixture());
  assert.equal(check.verdict, 'PASS');
  assert.equal(check.metrics.imported, 2);
  assert.equal(check.deviceAcceptance, 'NOT_VERIFIED');
});
test('cover, remix, wrong artist and version cannot be auto-imported', () => {
  for (const mutate of [
    row => { row.match.artist = 'Different Artist'; },
    row => { row.match.edition = 'Live'; },
    row => { row.match.confidence = 'review'; },
    row => { row.match.durationSeconds += 30; }
  ]) { const b = fixture(); mutate(b.results[0]); assert.equal(verifyPlaylistAcceptance(b).verdict, 'FAIL'); }
});
test('invalid audio, unverifiable offline playback, duplicate ticket and cellular bypass fail', () => {
  const mutations = [
    row => { row.offlineFile.headerVerified = false; },
    row => { row.offlineFile.bytes = 20; },
    row => { row.playbackProof.reopenedApp = false; },
    row => { row.queue.activeDuplicateTickets = 1; },
    row => { row.transport = 'cellular'; row.explicitCellularConsent = false; },
    row => { row.match.directURL = 'https://spotify.com/file.mp3'; }
  ];
  for (const mutation of mutations) {
    const b = fixture(); mutation(b.results[0]); assert.equal(verifyPlaylistAcceptance(b).verdict, 'FAIL');
  }
});
test('unavailable and review states are accounted for without phantom downloads', () => {
  const b = fixture(); b.results[1] = { id: 'song2', state: 'unavailable' }; b.backup.trackCount = 1;
  const check = verifyPlaylistAcceptance(b); assert.equal(check.verdict, 'PARTIAL');
  assert.equal(check.metrics.unavailable, 1);
  b.results[1].autoSelected = true;
  assert.equal(verifyPlaylistAcceptance(b).verdict, 'FAIL');
});
test('duplicate or missing IDs and broken backup integrity fail', () => {
  const dup = fixture(); dup.results[1].id = 'song1'; assert.equal(verifyPlaylistAcceptance(dup).verdict, 'FAIL');
  const missing = fixture(); missing.results.pop(); assert.equal(verifyPlaylistAcceptance(missing).verdict, 'FAIL');
  const backup = fixture(); backup.backup.byteExactRoundTrip = false; assert.equal(verifyPlaylistAcceptance(backup).verdict, 'FAIL');
});
