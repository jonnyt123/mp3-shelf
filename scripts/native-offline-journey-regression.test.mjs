import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { verifyPlaylistAcceptance } from './verify-playlist-acceptance.mjs';
import { verifyPhysicalDeviceTelemetry } from './collect-iphone-playlist-evidence.mjs';

// Synthetic regression fixtures, NOT evidence that an iPhone was exercised.
// The real device collector, signed install, native receipt and issue #6
// remain mandatory release prerequisites.
const IDS = [
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222'
];
const ARM = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const OFFLINE = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const TICKET = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const PLAYLIST = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const NOW = Date.parse('2026-11-22T20:00:00Z');
const HASH = 'a'.repeat(64);

function playlist() {
  const requested = IDS.map((id, index) => ({
    id, title: 'Recording ' + index, artist: 'Artist ' + index,
    edition: index ? '' : '2020 Remaster', durationSeconds: 180 + index * 20
  }));
  const results = requested.map(track => ({
    id: track.id, state: 'imported',
    match: {
      title: track.title, artist: track.artist, edition: track.edition,
      durationSeconds: track.durationSeconds, confidence: 'high',
      ambiguous: false, directURL: 'https://audio.example.org/' + track.id + '.mp3',
      spotifyStream: false
    },
    offlineFile: {
      exists: true, codec: 'mp3', bytes: 100000, sha256: HASH,
      headerVerified: true, decodedDurationSeconds: track.durationSeconds
    },
    queue: { persisted: true, status: 'imported', activeDuplicateTickets: 0 },
    transport: 'wifi',
    playbackProof: {
      networkDisabled: true, reopenedApp: true, playedLocalFile: true,
      trackID: track.id, sha256: HASH
    }
  }));
  return { version: 1, metadataProvider: 'spotify', requested, results,
    backup: {
      trackCount: requested.length, preservedPlaylistOrder: true,
      byteExactRoundTrip: true
    }
  };
}
function deviceJourney() {
  const events = [
    ['qa-armed', ARM, null],
    ['background-session-wake', ARM, null],
    ['download-completion-callback', ARM, TICKET],
    ['download-audio-staged', ARM, TICKET],
    ['offline-verification-started', OFFLINE, null],
    ['offline-local-playback-advanced', OFFLINE, IDS[0]],
    ['offline-local-playback-advanced', OFFLINE, IDS[1]],
    ['offline-verification-finished', OFFLINE, null]
  ].map(([event, processToken, ticketID], i) => ({
    event, processToken, ...(ticketID ? { ticketID } : {}),
    timeUTC: new Date(NOW - 20000 + i * 1000).toISOString()
  }));
  return {
    proof: {
      schema: 'mp3shelf-physical-offline-v1', status: 'OFFLINE_PLAYBACK_PASS',
      deviceKind: 'physical-iPhone-debug', networkProof: 'NWPATH_UNSATISFIED',
      playlistID: PLAYLIST, armedProcessToken: ARM, processToken: OFFLINE,
      playbackVerified: IDS.length,
      observations: IDS.map(trackID => ({
        trackID, localFile: true, positionSeconds: 1.3
      }))
    },
    events
  };
}

test('full Spotify metadata-to-offline journey contract passes both independent validators', () => {
  const playlistResult = verifyPlaylistAcceptance(playlist());
  assert.equal(playlistResult.verdict, 'PASS');
  assert.equal(playlistResult.metrics.offlineVerified, 2);
  assert.equal(playlistResult.deviceAcceptance, 'NOT_VERIFIED',
    'Synthetic report must never approve a physical iPhone');
  const { proof, events } = deviceJourney();
  assert.deepEqual(
    verifyPhysicalDeviceTelemetry(proof, events, PLAYLIST,
      IDS.map(id => ({ id })), { now: NOW }),
    {
      offlinePlaybackAfterRestart: 'APP_INSTRUMENTED_PHYSICAL_PASS',
      backgroundTransfer: 'APP_RECORDED_STAGING_AND_BACKGROUND_WAKE'
    }
  );
});

test('playlist identity, queue, file, consent and offline backup regressions fail closed', () => {
  const cases = [
    result => { result.results[0].match.artist = 'Wrong Artist'; },
    result => { result.results[0].match.edition = 'Live'; },
    result => { result.results[0].offlineFile.headerVerified = false; },
    result => { result.results[0].queue.activeDuplicateTickets = 1; },
    result => { result.results[0].transport = 'cellular'; },
    result => { result.results[0].playbackProof.networkDisabled = false; },
    result => { result.backup.byteExactRoundTrip = false; },
    result => { result.results[1].state = 'review'; result.results[1].autoSelected = true; }
  ];
  for (const mutate of cases) {
    const record = playlist(); mutate(record);
    assert.equal(verifyPlaylistAcceptance(record).verdict, 'FAIL');
  }
});

test('different offline process and network disconnect are mandatory', () => {
  const a = deviceJourney();
  a.proof.processToken = ARM;
  assert.throws(() => verifyPhysicalDeviceTelemetry(
    a.proof, a.events, PLAYLIST, IDS.map(id => ({ id })), { now: NOW }
  ), /receipt/);
  const b = deviceJourney();
  b.proof.networkProof = 'WIFI_CONNECTED';
  assert.throws(() => verifyPhysicalDeviceTelemetry(
    b.proof, b.events, PLAYLIST, IDS.map(id => ({ id })), { now: NOW }
  ), /receipt/);
});

test('background session wake, completion and audio staging are correlated', () => {
  const withoutWake = deviceJourney();
  withoutWake.events[1].event = 'unrelated';
  assert.equal(verifyPhysicalDeviceTelemetry(
    withoutWake.proof, withoutWake.events, PLAYLIST,
    IDS.map(id => ({ id })), { now: NOW }
  ).backgroundTransfer, 'NOT_VERIFIED');
  const mismatchedTicket = deviceJourney();
  mismatchedTicket.events[2].ticketID = IDS[0];
  assert.equal(verifyPhysicalDeviceTelemetry(
    mismatchedTicket.proof, mismatchedTicket.events, PLAYLIST,
    IDS.map(id => ({ id })), { now: NOW }
  ).backgroundTransfer, 'NOT_VERIFIED');
  const startedTooEarly = deviceJourney();
  startedTooEarly.events[4].event = 'unrelated';
  assert.throws(() => verifyPhysicalDeviceTelemetry(
    startedTooEarly.proof, startedTooEarly.events, PLAYLIST,
    IDS.map(id => ({ id })), { now: NOW }
  ), /session/);
});

test('every local file must have a matching advancing player-clock event', () => {
  const mismatch = deviceJourney();
  mismatch.events[5].ticketID = IDS[1];
  assert.throws(() => verifyPhysicalDeviceTelemetry(
    mismatch.proof, mismatch.events, PLAYLIST,
    IDS.map(id => ({ id })), { now: NOW }
  ), /playback/);
  const duplicate = deviceJourney();
  duplicate.proof.observations[1].trackID = IDS[0];
  assert.throws(() => verifyPhysicalDeviceTelemetry(
    duplicate.proof, duplicate.events, PLAYLIST,
    IDS.map(id => ({ id })), { now: NOW }
  ), /playback/);
});
