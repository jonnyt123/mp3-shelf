import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { nativeStageErrors, readNativeQaRecord } from './verify-native-stage.mjs';
import { mkdtempSync, writeFileSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const proposed = 'b'.repeat(40), current = 'a'.repeat(40);
const completed = [
  'playback-order', 'playback-interruptions', 'downloaded-audio-signature',
  'downloaded-audio-format', 'playlist-parser', 'lyrics-parser',
  'authorized-audio-sources', 'catalog-retry-policy', 'catalog-origin-safety',
  'downloader-policy-runtime', 'discovery-resume', 'portable-backup',
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
      '- Simulator smoke requested: false',
      '- Overall execution: PASS',
      '- Exit status: 0',
      '- Failure reason: none',
      '- Apple signing / physical iPhone acceptance: NOT TESTED',
      '- GitHub Actions used: NO',
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

test('duplicate native QA fields cannot override a failed or stale run', () => {
  const x = valid();
  x.qaRecord += '- Overall execution: FAIL\n';
  assert(nativeStageErrors(x).some(e => e.includes('Duplicate native QA field')));
  const y = valid();
  y.qaRecord = '- Checked commit: ' + current + '\n' + y.qaRecord;
  assert(nativeStageErrors(y).some(e => e.includes('Duplicate native QA field')));
});

test('native QA evidence reader rejects symlinks, empty and oversized records', () => {
  const dir = mkdtempSync(join(tmpdir(), 'mp3-native-qa-'));
  try {
    const record = join(dir, 'qa.md'), link = join(dir, 'linked.md');
    writeFileSync(record, valid().qaRecord);
    assert.equal(readNativeQaRecord(record), valid().qaRecord);
    symlinkSync(record, link);
    assert.throws(() => readNativeQaRecord(link), /bounded regular file/);
    writeFileSync(record, '');
    assert.throws(() => readNativeQaRecord(record), /bounded regular file/);
    writeFileSync(record, 'x'.repeat(256 * 1024 + 1));
    assert.throws(() => readNativeQaRecord(record), /bounded regular file/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('missing native QA fields fail closed', () => {
  const x = valid();
  x.qaRecord = x.qaRecord.replace(/^- Exit status: 0\n/m, '');
  assert(nativeStageErrors(x).some(e => e.includes('Missing native QA field: Exit status')));
});

test('native stage refuses ambiguous smoke, failed reason and device/CI approval claims', () => {
  for (const [original, replacement] of [
    ['- Simulator smoke requested: false', '- Simulator smoke requested: true'],
    ['- Failure reason: none', '- Failure reason: Step simulator-debug failed'],
    ['- Apple signing / physical iPhone acceptance: NOT TESTED', '- Apple signing / physical iPhone acceptance: PASS'],
    ['- GitHub Actions used: NO', '- GitHub Actions used: YES']
  ]) {
    const x = valid();
    x.qaRecord = x.qaRecord.replace(original, replacement);
    assert(nativeStageErrors(x).some(error => error.includes('full-suite')));
  }
  const x = valid();
  x.qaRecord = x.qaRecord.replace('- Failure reason: none\\n', '');
  assert(nativeStageErrors(x).some(error => error.includes('Missing native QA field: Failure reason')));
});

test('native stage rejects duplicate, failed and out-of-order receipt steps', () => {
  const duplicate = valid();
  duplicate.receipt.steps.push({ name: 'native-local-release', success: false });
  assert(nativeStageErrors(duplicate).some(e => e.includes('duplicate')));

  const failedExtra = valid();
  failedExtra.receipt.steps.unshift({ name: 'node-release-safety', success: false });
  assert(nativeStageErrors(failedExtra).some(e => e.includes('unsuccessful')));

  const reversed = valid();
  reversed.receipt.steps.reverse();
  assert(nativeStageErrors(reversed).some(e => e.includes('subsequent')));

  const malformed = valid();
  malformed.receipt.steps.push({ success: true });
  assert(nativeStageErrors(malformed).some(e => e.includes('malformed')));

  const extraSuccessful = valid();
  extraSuccessful.receipt.steps.unshift({ name: 'node-release-safety', success: true });
  assert.deepEqual(nativeStageErrors(extraSuccessful), []);
});
