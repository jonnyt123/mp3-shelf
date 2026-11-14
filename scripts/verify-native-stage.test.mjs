import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { nativeStageErrors } from './verify-native-stage.mjs';
const proposed = 'b'.repeat(40), current = 'a'.repeat(40);
const completed = [
  'playback-order', 'playback-interruptions', 'downloaded-audio-signature',
  'downloaded-audio-format', 'playlist-parser', 'lyrics-parser',
  'authorized-audio-sources', 'discovery-resume', 'portable-backup',
  'recording-matching-core', 'recording-matcher',
  'simulator-debug', 'simulator-release', 'iphoneos-arm64-release'
];
function valid() {
  return {
    proposed, current,
    receipt: {
      mode: 'native', candidateSha: proposed, status: 'local-checks-passed',
      cleanCheckout: true, exitCode: 0,
      steps: [
        { name: 'native-local-release', success: true },
        { name: 'post-native-checkout-integrity', success: true }
      ]
    },
    qaRecord: [
      '- Checked commit: ' + proposed,
      '- Source provenance: repository HEAD',
      '- Uncommitted changes: no',
      '- Mode: all',
      '- Overall execution: PASS',
      '- Exit status: 0',
      '- Completed checks: ' + completed.join(' ')
    ].join('\n') + '\n'
  };
}
test('valid exact-SHA full native QA record satisfies policy', () => {
  assert.deepEqual(nativeStageErrors(valid()), []);
});
test('wrong SHA, reused parent SHA or stale receipt is rejected', () => {
  for (const mutation of [
    { current: proposed },
    { proposed: 'short' },
    { receipt: { ...valid().receipt, candidateSha: current } }
  ]) assert.notDeepEqual(nativeStageErrors({ ...valid(), ...mutation }), []);
});
test('tests-only, missing native build and missing receipt step are rejected', () => {
  const testsOnly = valid();
  testsOnly.qaRecord = testsOnly.qaRecord.replace('- Mode: all', '- Mode: tests');
  assert(nativeStageErrors(testsOnly).some(s => s.includes('full-suite')));
  const incomplete = valid();
  incomplete.qaRecord = incomplete.qaRecord.replace('simulator-release', 'no-build');
  assert(nativeStageErrors(incomplete).some(s => s.includes('simulator-release')));
  const skipped = valid();
  skipped.receipt.steps = [];
  assert(nativeStageErrors(skipped).some(s => s.includes('Native Xcode')));
});
test('failed, node-only or forged PASS metadata is rejected', () => {
  const failed = valid();
  failed.qaRecord = failed.qaRecord.replace('- Exit status: 0', '- Exit status: 1');
  assert(nativeStageErrors(failed).length > 0);
  const skipped = valid();
  skipped.receipt.mode = 'node-only';
  assert(nativeStageErrors(skipped).length > 0);
  const mismatch = valid();
  mismatch.qaRecord = mismatch.qaRecord.replace('repository HEAD', 'archive metadata');
  assert(nativeStageErrors(mismatch).length > 0);
});

test('matches real local native runner iPhoneOS step and all suite names', () => {
  const qa = valid();
  assert.deepEqual(nativeStageErrors(qa), []);
  qa.qaRecord = qa.qaRecord.replace('iphoneos-arm64-release', 'iphoneos-release');
  assert(nativeStageErrors(qa).some(s => s.includes('iphoneos-arm64-release')));
});
test('partial, duplicated and reordered native suites are blocked', () => {
  for (const step of ['downloaded-audio-format', 'lyrics-parser', 'recording-matching-core']) {
    const x = valid();
    x.qaRecord = x.qaRecord.replace(step, 'skipped');
    assert(nativeStageErrors(x).length > 0);
  }
  const ordered = valid();
  ordered.qaRecord = ordered.qaRecord.replace('playback-order playback-interruptions', 'playback-interruptions playback-order');
  assert(nativeStageErrors(ordered).length > 0);
  const duplicate = valid();
  duplicate.qaRecord = duplicate.qaRecord.replace('portable-backup', 'portable-backup portable-backup');
  assert(nativeStageErrors(duplicate).length > 0);
});
