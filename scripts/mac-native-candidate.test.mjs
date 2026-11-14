import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { BASE_REF, PREVIEW_REF, promotionPolicy, verifyDraftPreflightPR, executeNativePreflight }
  from './mac-native-candidate.mjs';
const base = 'a'.repeat(40), proposed = 'b'.repeat(40);
const paths = [
  'ios/MP3Shelf/Services/AudioSourceFinder.swift',
  'ios/MP3Shelf/Services/BackgroundAudioDownloader.swift',
  'ios/Tests/AudioCatalogRetryPolicyTests.swift',
  'ios/Tests/BackgroundRedirectNetworkPolicyTests.swift'
];
const accepted = () => ({ base, proposed, current: base, latestPreview: proposed,
  changedFiles: paths, gateErrors: [] });

test('targets draft candidate and review preflight only, never main', () => {
  assert.equal(BASE_REF, 'refs/heads/feat/ios-consolidated-candidate');
  assert.equal(PREVIEW_REF, 'refs/heads/agent/mp3-native-integration-preflight');
  assert.deepEqual(promotionPolicy(accepted()), []);
});
test('does not overwrite a candidate advanced since testing', () => {
  const errors = promotionPolicy({ ...accepted(), current: 'c'.repeat(40) });
  assert(errors.some(e => e.includes('advanced')));
});
test('a newer untested preview commit invalidates the SHA-bound gate', () => {
  const errors = promotionPolicy({ ...accepted(), latestPreview: 'c'.repeat(40) });
  assert(errors.some(e => e.includes('advanced')));
});
test('unreviewed or cross-lane file changes cannot enter draft candidate', () => {
  for (const filename of ['ios/MP3Shelf/Services/MusicLibrary.swift',
    'ios/MP3Shelf/Views/LibraryViews.swift', '.github/workflows/deploy.yml']) {
    assert(promotionPolicy({ ...accepted(), changedFiles: [...paths, filename] })
      .some(e => e.includes('unexpected')));
  }
  assert(promotionPolicy({ ...accepted(), changedFiles: [] }).length > 0);
});
test('missing, failed or unavailable native evidence blocks auto staging', () => {
  for (const gateErrors of [['Xcode not available'], ['Regression failed'], null]) {
    assert(promotionPolicy({ ...accepted(), gateErrors }).length > 0);
  }
  assert(promotionPolicy({ ...accepted(), proposed: base }).length > 0);
  assert(promotionPolicy({ ...accepted(), current: 'truncated' }).length > 0);
});
test('non-macOS runtime fails before git, build or promotion', async () => {
  if (process.platform !== 'darwin') {
    await assert.rejects(executeNativePreflight({ promote: true }), /MAC_XCODE_REQUIRED/);
  }
});

test('draft PR review metadata must agree with both Git SHA refs', () => {
  const pr = { number: 37, state: 'open', draft: true,
    head: { sha: proposed, ref: 'agent/mp3-native-integration-preflight',
      repo: { full_name: 'jonnyt123/mp3-shelf' } },
    base: { sha: base, ref: 'feat/ios-consolidated-candidate',
      repo: { full_name: 'jonnyt123/mp3-shelf' } } };
  assert.deepEqual(verifyDraftPreflightPR(pr, { base, proposed }), []);
  for (const mutation of [
    p => { p.head.sha = 'c'.repeat(40); },
    p => { p.base.sha = 'c'.repeat(40); },
    p => { p.draft = false; },
    p => { p.state = 'closed'; },
    p => { p.head.repo.full_name = 'unknown/fork'; },
    p => { p.base.ref = 'main'; }
  ]) {
    const modified = structuredClone(pr); mutation(modified);
    assert(verifyDraftPreflightPR(modified, { base, proposed }).length > 0);
  }
});
