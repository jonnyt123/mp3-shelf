import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, symlinkSync, linkSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { diagnoseNativeLog, clearIsolatedDerivedData, readNativeLogTail } from './native-build-diagnostics.mjs';
import { runNativeWithBoundedRecovery } from './mac-native-candidate.mjs';

const scratch = () => mkdtempSync(join(tmpdir(), 'mp3-native-diagnosis-'));
test('Swift code errors take precedence; no unattended source rewrite is permitted', () => {
  const message = "module cache corrupted\nerror: cannot find 'PlaybackController' in scope\n";
  assert.deepEqual(diagnoseNativeLog(message), {
    category: 'swift-source', retryable: false, repair: 'none'
  });
  assert.equal(diagnoseNativeLog('unrelated build failure').retryable, false);
  assert.equal(diagnoseNativeLog('').retryable, false);
});
test('only deterministic transient Xcode service and generated-cache faults permit retry', () => {
  assert.deepEqual(diagnoseNativeLog('build service could not create build operation'), {
    category: 'transient-xcode-service', retryable: true, repair: 'retry-isolated-build'
  });
  assert.deepEqual(diagnoseNativeLog('error: malformed PCM file in ModuleCache.noindex'), {
    category: 'generated-cache', retryable: true, repair: 'clear-isolated-derived-data'
  });
});
test('cache cleanup only touches isolated directory; symlink parents are rejected', () => {
  const root = scratch(), outside = scratch();
  try {
    const generated = join(root, 'ios/build/local-release/DerivedData');
    mkdirSync(generated, { recursive: true });
    writeFileSync(join(generated, 'temporary-cache'), 'data');
    writeFileSync(join(outside, 'user-audio.mp3'), 'valuable');
    assert.equal(clearIsolatedDerivedData(root), true);
    assert.equal(existsSync(generated), false);
    rmSync(join(root, 'ios/build/local-release'), { recursive: true, force: true });
    symlinkSync(outside, join(root, 'ios/build/local-release'));
    assert.throws(() => clearIsolatedDerivedData(root), /symlink|non-directory/);
    assert.equal(readFileSync(join(outside, 'user-audio.mp3'), 'utf8'), 'valuable');
  } finally { rmSync(root, { recursive: true, force: true }); rmSync(outside, { recursive: true, force: true }); }
});
test('normal native success has one attempt and never claims a device pass', async () => {
  const root = scratch();
  try {
    let count = 0;
    await runNativeWithBoundedRecovery({
      cwd: root, output: root,
      run: async (_command, _args, _cwd, log) => { count++; writeFileSync(log, 'success'); }
    });
    assert.equal(count, 1);
    const result = JSON.parse(readFileSync(join(root, 'native-diagnosis.json')));
    assert.equal(result.finalStatus, 'NATIVE_RUNNER_EXIT_ZERO');
    assert.equal(result.retryCount, 0);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test('isolated-cache error retries once, preserving unsuccessful first log', async () => {
  const root = scratch();
  try {
    const cache = join(root, 'ios/build/local-release/DerivedData');
    mkdirSync(cache, { recursive: true });
    writeFileSync(join(cache, 'invalid.pcm'), 'bad cache');
    let count = 0;
    await runNativeWithBoundedRecovery({
      cwd: root, output: root,
      run: async (_command, _args, _cwd, log) => {
        count++;
        if (count === 1) {
          writeFileSync(log, 'malformed PCM file');
          throw Error('first attempt failed');
        }
        assert.equal(existsSync(cache), false);
        writeFileSync(log, 'fresh build passed');
      }
    });
    const result = JSON.parse(readFileSync(join(root, 'native-diagnosis.json')));
    assert.equal(count, 2);
    assert.equal(result.category, 'generated-cache');
    assert.equal(result.retryCount, 1);
    assert.equal(result.finalStatus, 'NATIVE_RUNNER_EXIT_ZERO_AFTER_SAFE_RETRY');
    assert.match(readFileSync(join(root, 'native-console.log'), 'utf8'), /malformed PCM/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test('a source compilation failure blocks immediately and produces a bounded diagnosis', async () => {
  const root = scratch();
  try {
    let calls = 0;
    await assert.rejects(runNativeWithBoundedRecovery({
      cwd: root, output: root,
      run: async (_command, _args, _cwd, log) => {
        calls++;
        writeFileSync(log, "Swift Compiler Error: cannot convert value of type 'Int' to 'String'");
        throw Error('compilation failed');
      }
    }), /swift-source/);
    assert.equal(calls, 1);
    const report = JSON.parse(readFileSync(join(root, 'native-diagnosis.json')));
    assert.equal(report.retryCount, 0);
    assert.equal(report.finalStatus, 'BLOCKED');
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test('recoverable environment failure is retried at most once', async () => {
  const root = scratch();
  try {
    let calls = 0;
    await assert.rejects(runNativeWithBoundedRecovery({
      cwd: root, output: root,
      run: async (_command, _args, _cwd, log) => {
        calls++;
        writeFileSync(log, 'unable to initiate PIF transfer session');
        throw Error('build service unavailable');
      }
    }), /Bounded native retry failed/);
    assert.equal(calls, 2);
    assert.equal(JSON.parse(readFileSync(join(root, 'native-diagnosis.json'))).retryCount, 1);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test('diagnostics reject symlinks and use only the bounded log tail', () => {
  const root = scratch();
  try {
    const log = join(root, 'log'), link = join(root, 'link');
    writeFileSync(log, 'A'.repeat(1024 * 1024) + '\nbuild service could not create build operation');
    assert.match(readNativeLogTail(log), /build service could not create build operation/);
    symlinkSync(log, link);
    assert.throws(() => readNativeLogTail(link), /unsafe/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('native log diagnosis rejects hard-linked files and preserves the final bounded megabyte', () => {
  const root = scratch();
  try {
    const log = join(root, 'log');
    writeFileSync(log, 'old transient\\n' + 'X'.repeat(1024 * 1024) + '\\nNo space left on device');
    assert.match(readNativeLogTail(log), /No space left on device/);
    assert.doesNotMatch(readNativeLogTail(log), /old transient/);
    const hardlink = join(root, 'hardlink');
    linkSync(log, hardlink);
    assert.throws(() => readNativeLogTail(log), /unsafe/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test('fatal toolchain, disk, permissions and dyld failures override transient retry hints', () => {
  for (const fatal of [
    'error: No space left on device',
    'xcode-select: error: tool xcodebuild requires Xcode',
    'error: Permission denied',
    'dyld[123]: Library not loaded: @rpath/libswiftCore.dylib',
    'error: code signing is required for product type Application'
  ]) {
    assert.deepEqual(diagnoseNativeLog('unable to initiate PIF transfer session\\n' + fatal), {
      category: 'fatal-environment', retryable: false, repair: 'none'
    }, fatal);
  }
});
test('fatal native environment errors do not start a second build attempt', async () => {
  const root = scratch();
  try {
    let calls = 0;
    await assert.rejects(runNativeWithBoundedRecovery({
      cwd: root, output: root,
      run: async (_command, _args, _cwd, log) => {
        calls++;
        writeFileSync(log, 'build service could not create build operation\\nNo space left on device');
        throw Error('disk exhausted');
      }
    }), /fatal-environment/);
    assert.equal(calls, 1);
    const receipt = JSON.parse(readFileSync(join(root, 'native-diagnosis.json')));
    assert.equal(receipt.retryCount, 0);
    assert.equal(receipt.finalStatus, 'BLOCKED');
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test('generated-cache cleanup refuses a symlinked worktree root', () => {
  const root = scratch(), parent = scratch();
  try {
    const cache = join(root, 'ios/build/local-release/DerivedData');
    mkdirSync(cache, { recursive: true });
    writeFileSync(join(cache, 'valuable'), 'keep');
    const redirected = join(parent, 'worktree');
    symlinkSync(root, redirected);
    assert.throws(() => clearIsolatedDerivedData(redirected), /redirected worktree root/);
    assert.equal(readFileSync(join(cache, 'valuable'), 'utf8'), 'keep');
  } finally { rmSync(root, { recursive: true, force: true }); rmSync(parent, { recursive: true, force: true }); }
});

test('ordinary Swift file diagnostics override cache and service retry hints', async () => {
  const diagnostics = [
    'Sources/Player.swift:42:18: error: value of type Player has no member refresh',
    '/tmp/native/Playlist.swift:7: error: unterminated string literal',
    'error: emit-module command failed with exit code 1'
  ];
  for (const diagnostic of diagnostics) {
    assert.deepEqual(diagnoseNativeLog('unable to initiate PIF transfer session\\nmodule cache corrupted\\n' + diagnostic), {
      category: 'swift-source', retryable: false, repair: 'none'
    }, diagnostic);
  }
  const root = scratch();
  try {
    let calls = 0;
    await assert.rejects(runNativeWithBoundedRecovery({
      cwd: root, output: root,
      run: async (_command, _args, _cwd, log) => {
        calls++;
        writeFileSync(log, 'build service could not create build operation\\nPlayer.swift:42:18: error: unterminated string literal');
        throw Error('compilation failed');
      }
    }), /swift-source/);
    assert.equal(calls, 1);
    const report = JSON.parse(readFileSync(join(root, 'native-diagnosis.json')));
    assert.equal(report.retryCount, 0);
    assert.equal(report.finalStatus, 'BLOCKED');
  } finally { rmSync(root, { recursive: true, force: true }); }
});
