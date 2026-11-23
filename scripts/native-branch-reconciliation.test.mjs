import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { auditNativeReconciliation } from './native-branch-reconciliation.mjs';

const SHA = 'a'.repeat(40);
const proposal = (number, path) => ({
  number, headSha: String(number).repeat(40).slice(0,40),
  mergeBaseSha: SHA, ahead: number, behind: 0,
  changedFiles: [path], state: 'open', draft: true,
  headRepo: 'jonnyt123/mp3-shelf', baseRepo: 'jonnyt123/mp3-shelf',
  baseRef: number === 36 ? 'agent/mp3-spotify-pagination-fix' :
    'feat/ios-consolidated-candidate'
});
const healthy = () => ({ candidateSha: SHA, proposals: [
  proposal(37, 'ios/MP3Shelf/Services/AudioSourceFinder.swift'),
  proposal(35, 'ios/MP3Shelf/Services/SpotifyService.swift'),
  proposal(36, 'ios/MP3Shelf/Models/DownloadedAudioSignature.swift')
] });

test('disjoint linear draft PRs are eligible for fresh integration, never automatic release', () => {
  const audit = auditNativeReconciliation(healthy());
  assert.equal(audit.status, 'COMPOSITION_ELIGIBLE');
  assert.equal(audit.compositionEligible, true);
  assert.equal(audit.releaseAuthorized, false);
  assert.deepEqual(audit.order.map(row => row.pr), [37, 35, 36]);
});

test('divergent PR cannot silently enter consolidated native candidate', () => {
  const data = healthy();
  data.proposals[1].behind = 31;
  const result = auditNativeReconciliation(data);
  assert.equal(result.status, 'BLOCKED');
  assert.deepEqual(result.drift, [{ pr: 35, ahead: 35, behind: 31 }]);
  assert(result.blockers.some(item => item.includes('diverged')));
});

test('overlapping native downloader or test changes require explicit review', () => {
  const data = healthy();
  data.proposals[2].changedFiles = [
    'ios/MP3Shelf/Services/AudioSourceFinder.swift'
  ];
  const result = auditNativeReconciliation(data);
  assert.equal(result.compositionEligible, false);
  assert.deepEqual(result.overlap, [{
    path: 'ios/MP3Shelf/Services/AudioSourceFinder.swift',
    previousPR: 37, pr: 36
  }]);
});

test('missing SHA, incomplete PR inventory or closed draft blocks', () => {
  for (const mutate of [
    data => { data.candidateSha = 'main'; },
    data => { data.proposals.pop(); },
    data => { data.proposals.reverse(); },
    data => { data.proposals[0].draft = false; },
    data => { data.proposals[0].state = 'closed'; },
    data => { data.proposals[0].headRepo = 'attacker/fork'; },
    data => { data.proposals[0].headSha = 'malformed'; },
    data => { data.proposals[0].baseRef = 'main'; },
    data => { data.proposals[1].headSha = SHA; }
  ]) {
    const data = healthy(); mutate(data);
    assert.equal(auditNativeReconciliation(data).status, 'BLOCKED');
  }
});

test('unknown, invalid, repeated or web-owned files block composition', () => {
  for (const changedFiles of [
    ['web/src/page.tsx'], [], ['ios/MP3Shelf/../escape.swift'],
    ['ios/MP3Shelf/Models/A.swift', 'ios/MP3Shelf/Models/A.swift'],
    Array(501).fill('ios/bad')
  ]) {
    const data = healthy(); data.proposals[2].changedFiles = changedFiles;
    assert.equal(auditNativeReconciliation(data).status, 'BLOCKED');
  }
});

test('missing, repeated or impossible branch counts never become release evidence', () => {
  const a = healthy();
  a.proposals[2].number = 35;
  assert.equal(auditNativeReconciliation(a).status, 'BLOCKED');
  const b = healthy();
  b.proposals[2].behind = -1;
  assert.equal(auditNativeReconciliation(b).status, 'BLOCKED');
  const c = healthy();
  c.proposals[2].ahead = 0;
  assert.equal(auditNativeReconciliation(c).status, 'BLOCKED');
});

test('malformed native paths cannot pass reconciliation despite ios prefix', () => {
  for (const path of [
    'ios//MP3Shelf/Audio.swift',
    'ios/./MP3Shelf/Audio.swift',
    'ios/MP3Shelf/Audio.swift\\nignored',
    'ios/MP3Shelf/Audio.swift\\t',
    'ios/MP3Shelf/Audio.swift\\u007f'
  ]) {
    const data = healthy();
    data.proposals[0].changedFiles = [path];
    const audit = auditNativeReconciliation(data);
    assert.equal(audit.status, 'BLOCKED', JSON.stringify(path));
    assert(audit.blockers.some(reason => reason.includes('unexpected changed paths')));
  }
});
