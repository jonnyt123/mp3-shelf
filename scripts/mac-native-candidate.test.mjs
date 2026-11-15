import { test } from 'node:test';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { strict as assert } from 'node:assert';
import { BASE_REF, PREVIEW_REF, promotionPolicy, verifyDraftPreflightPR, verifyConsolidatedDraftPR, executeNativePreflight, runLogged }
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

test('consolidated candidate must remain an open draft at the exact baseline', () => {
  const pr = { number: 29, state: 'open', draft: true,
    head: { sha: base, ref: 'feat/ios-consolidated-candidate',
      repo: { full_name: 'jonnyt123/mp3-shelf' } },
    base: { sha: 'c'.repeat(40), ref: 'fix/ios-download-finalization-and-conversion',
      repo: { full_name: 'jonnyt123/mp3-shelf' } } };
  assert.deepEqual(verifyConsolidatedDraftPR(pr, { base }), []);
  for (const mutation of [
    p => { p.number = 4; },
    p => { p.state = 'closed'; },
    p => { p.draft = false; },
    p => { p.head.sha = proposed; },
    p => { p.head.ref = 'main'; },
    p => { p.head.repo.full_name = 'other/repo'; },
    p => { p.base.ref = 'feat/ios-consolidated-candidate'; },
    p => { p.base.repo.full_name = 'other/repo'; }
  ]) {
    const modified = structuredClone(pr);
    mutation(modified);
    assert(verifyConsolidatedDraftPR(modified, { base }).length > 0);
  }
  assert(verifyConsolidatedDraftPR(null, { base }).length > 0);
});

test('native log captures both streams before declaring success', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'mp3-native-log-'));
  try {
    const log = join(dir, 'combined.log');
    await runLogged(process.execPath, ['-e',
      "process.stdout.write('stdout-proof\\n'); process.stderr.write('stderr-proof\\n')"],
      dir, log);
    const output = readFileSync(log, 'utf8');
    assert.match(output, /stdout-proof/);
    assert.match(output, /stderr-proof/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('native runner rejects nonzero exit and preserves diagnostic log', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'mp3-native-fail-'));
  try {
    const log = join(dir, 'failure.log');
    await assert.rejects(runLogged(process.execPath, ['-e',
      "process.stderr.write('failed-check\\n'); process.exitCode = 7"],
      dir, log), /exit 7/);
    assert.match(readFileSync(log, 'utf8'), /failed-check/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('native runner rejects unwritable log target instead of reporting PASS', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'mp3-native-log-error-'));
  try {
    await assert.rejects(runLogged(process.execPath, ['-e', "process.stdout.write('ok')"],
      dir, dir), /log could not be written|EISDIR|Native verification/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('log write failure terminates the native subprocess before cleanup', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'mp3-native-child-cleanup-'));
  try {
    const marker = join(dir, 'should-not-exist');
    const script = `const fs = require('node:fs');
      process.stdout.write('start\\n');
      setTimeout(() => fs.writeFileSync(process.argv[1], 'orphan'), 500);
      setInterval(() => process.stdout.write('still running\\n'), 20);`;
    await assert.rejects(
      runLogged(process.execPath, ['-e', script, marker], dir, dir),
      /log could not be written|Native verification/
    );
    await new Promise(resolve => setTimeout(resolve, 650));
    assert.equal(existsSync(marker), false,
      'A failed verifier must not leave a subprocess writing after worktree cleanup');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('native timeout escalates when a subprocess ignores SIGTERM', async () => {
  if (process.platform === 'win32') return;
  const dir = mkdtempSync(join(tmpdir(), 'mp3-native-timeout-'));
  try {
    const log = join(dir, 'timeout.log');
    const started = Date.now();
    await assert.rejects(runLogged(process.execPath, ['-e',
      "process.on('SIGTERM', () => {}); setInterval(() => process.stdout.write('alive\\n'), 10)"],
      dir, log, { timeoutMs: 400, killGraceMs: 300 }), /exceeded timeout/);
    assert(Date.now() - started < 5000, 'Timed-out native verification must terminate promptly');
    assert.match(readFileSync(log, 'utf8'), /alive/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('native timeout options reject invalid durations before spawning', () => {
  assert.throws(() => runLogged(process.execPath, [], '.', '/tmp/unused', {
    timeoutMs: 0
  }), /positive safe integers/);
  assert.throws(() => runLogged(process.execPath, [], '.', '/tmp/unused', {
    killGraceMs: Number.POSITIVE_INFINITY
  }), /positive safe integers/);
});

test('native timeout terminates descendants rather than only the shell', async () => {
  if (process.platform === 'win32') return;
  const dir = mkdtempSync(join(tmpdir(), 'mp3-native-descendants-'));
  try {
    const log = join(dir, 'descendants.log');
    const marker = join(dir, 'orphan-marker');
    // A shell that starts a background child can exit on SIGTERM while that
    // child remains alive. The process-group signal must reach both.
    const script = `node -e "process.on('SIGTERM', () => {}); setTimeout(() => require('node:fs').writeFileSync(process.argv[1], 'orphan'), 1200); setInterval(() => {}, 50)" "${marker}" & wait`;
    await assert.rejects(
      runLogged('sh', ['-c', script], dir, log, { timeoutMs: 300, killGraceMs: 200 }),
      /exceeded timeout/
    );
    await new Promise(resolve => setTimeout(resolve, 1400));
    assert.equal(existsSync(marker), false,
      'Timed-out Xcode descendants must not survive detached worktree cleanup');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});


test('native verification refuses unbounded output without accepting truncated evidence', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'mp3-native-log-limit-'));
  try {
    const log = join(dir, 'bounded.log');
    await assert.rejects(runLogged(process.execPath, ['-e',
      "process.stdout.write('X'.repeat(16384)); setInterval(() => {}, 100)"],
      dir, log, { maxLogBytes: 1024, timeoutMs: 5000, killGraceMs: 200 }),
      /log limit|exceeded 1024 bytes/);
    assert(readFileSync(log).length <= 1024,
      'Rejected output must never grow beyond the configured evidence limit');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('native log size budget is validated before starting a subprocess', () => {
  assert.throws(() => runLogged(process.execPath, [], '.', '/tmp/unused', {
    maxLogBytes: 0
  }), /positive safe integers/);
});

test('stacked draft target is correct while retargeting to main is rejected', () => {
  const draft = { number: 29, state: 'open', draft: true,
    head: { sha: base, ref: 'feat/ios-consolidated-candidate',
      repo: { full_name: 'jonnyt123/mp3-shelf' } },
    base: { ref: 'fix/ios-download-finalization-and-conversion',
      repo: { full_name: 'jonnyt123/mp3-shelf' } } };
  assert.deepEqual(verifyConsolidatedDraftPR(draft, { base }), []);
  assert(verifyConsolidatedDraftPR({ ...draft, base: { ...draft.base, ref: 'main' } },
    { base }).length > 0);
});
