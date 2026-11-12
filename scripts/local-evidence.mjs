#!/usr/bin/env node
// SHA-bound local observations, deliberately not a release approval.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { closeSync, fstatSync, lstatSync, openSync, readSync, writeFileSync } from 'node:fs';
import { basename, resolve } from 'node:path';
import { constants as fsConstants } from 'node:fs';
import { pathToFileURL } from 'node:url';

const SHA = /^[0-9a-f]{40}$/i;
const RECEIPT_LIMIT = 256 * 1024;

/**
 * Read a persisted receipt without following symlinks, trusting a mutable
 * pathname after inspection, or allocating memory proportional to file size.
 * The same bound is enforced before JSON parsing, including for CLI input.
 */
export function readPersistedReceipt(path) {
  const metadata = lstatSync(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.nlink !== 1 ||
      metadata.size < 2 || metadata.size > RECEIPT_LIMIT)
    throw Error('Receipt must be a bounded, regular, unlinked JSON file.');
  const fd = openSync(path, fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0));
  try {
    const opened = fstatSync(fd);
    if (!opened.isFile() || opened.dev !== metadata.dev ||
        opened.ino !== metadata.ino || opened.nlink !== 1 ||
        opened.size < 2 || opened.size > RECEIPT_LIMIT)
      throw Error('Receipt changed during opening or exceeds size limit.');
    const chunks = [];
    let bytes = 0;
    const buffer = Buffer.allocUnsafe(16 * 1024);
    let count;
    while ((count = readSync(fd, buffer, 0, buffer.length, null)) !== 0) {
      bytes += count;
      if (bytes > RECEIPT_LIMIT) throw Error('Receipt exceeds 256 KiB size limit.');
      chunks.push(Buffer.from(buffer.subarray(0, count)));
    }
    const final = fstatSync(fd);
    if (final.size !== bytes || final.size !== opened.size ||
        final.dev !== opened.dev || final.ino !== opened.ino ||
        final.mtimeMs !== opened.mtimeMs || final.ctimeMs !== opened.ctimeMs ||
        final.nlink !== 1) throw Error('Receipt changed during reading.');
    // The descriptor can remain valid after the pathname is replaced. Refuse
    // evidence whose original path no longer identifies the inspected inode.
    const current = lstatSync(path);
    if (!current.isFile() || current.isSymbolicLink() || current.nlink !== 1 ||
        current.dev !== opened.dev || current.ino !== opened.ino ||
        current.size !== final.size || current.mtimeMs !== final.mtimeMs ||
        current.ctimeMs !== final.ctimeMs)
      throw Error('Receipt pathname changed during reading.');
    return JSON.parse(Buffer.concat(chunks, bytes).toString('utf8'));
  } finally { closeSync(fd); }
}

const allowed = new Set(['node-release-safety','post-node-checkout-integrity','npm-ci','npm-ci-offline','npm-test','npm-typecheck','npm-build','post-web-checkout-integrity','native-local-release','post-native-checkout-integrity']);
const required = {
  'node-only': ['node-release-safety','post-node-checkout-integrity'],
  web: ['node-release-safety','npm-test','npm-typecheck','npm-build','post-web-checkout-integrity'],
  native: ['native-local-release','post-native-checkout-integrity'],
  all: ['node-release-safety','npm-test','npm-typecheck','npm-build','post-web-checkout-integrity','native-local-release','post-native-checkout-integrity']
};
/** Independently bind CLI receipts to the real, clean Git checkout. */
export function verifyCheckoutIdentity(expectedSha, cwd = process.cwd()) {
  if (!SHA.test(expectedSha ?? '')) return ['Invalid expected checkout SHA.'];
  try {
    const git = (...args) => execFileSync('git', args, {
      cwd, encoding: 'utf8', timeout: 10000, maxBuffer: 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe']
    }).trim();
    const root = git('rev-parse', '--show-toplevel');
    if (resolve(root) !== resolve(cwd))
      return ['Verification must run at the candidate repository root.'];
    if (git('rev-parse', '--verify', 'HEAD') !== expectedSha)
      return ['Current Git HEAD does not match receipt SHA.'];
    if (git('status', '--porcelain', '--untracked-files=all') !== '')
      return ['Current Git checkout is not clean.'];
    return [];
  } catch {
    return ['Unable to independently verify Git checkout identity.'];
  }
}

export function buildLocalReceipt({ sha, dirty, mode, steps, exitCode, logDir }) {
  if (!SHA.test(sha) || dirty !== 'no') throw Error('Receipt requires a clean checkout at a full Git SHA.');
  if (!Object.hasOwn(required, mode)) throw Error('Unknown verification mode.');
  if (!Number.isSafeInteger(exitCode) || exitCode < 0 || exitCode > 255) throw Error('Invalid exit code.');
  if (!Array.isArray(steps) || steps.some(s => !s || typeof s !== 'object' ||
      !allowed.has(s.name) || ![0, 1].includes(s.success) ||
      Object.keys(s).some(key => !['name', 'success'].includes(key)))) throw Error('Malformed step records.');
  const seen = new Set();
  const receipts = steps.map(step => {
    if (seen.has(step.name)) throw Error('Duplicate step receipt.');
    seen.add(step.name);
    const file = step.name + '.log';
    const path = resolve(logDir, file);
    // Logs may contain arbitrarily large provider/build output. Never load
    // unbounded files into memory or follow a substituted symlink.
    const fingerprint = readLogFingerprint(path);
    return { name: step.name, success: step.success === 1,
      ...fingerprint, file: basename(file) };
  });
  // An npm test/build run without an actual dependency reconciliation is not
  // release evidence. Require exactly one install mode, not a skipped install
  // or a mixed online/offline invocation.
  const installSteps = receipts.filter(s => s.name === 'npm-ci' || s.name === 'npm-ci-offline');
  const installValid = !['web', 'all'].includes(mode) ||
    (installSteps.length === 1 && installSteps[0].success);
  // Receipts must describe the execution sequence the runner actually uses.
  // This rejects reordered, injected or duplicate-looking success reports.
  const expected = mode === 'node-only' ? ['node-release-safety','post-node-checkout-integrity'] :
    mode === 'native' ? ['native-local-release', 'post-native-checkout-integrity'] :
    ['node-release-safety', installSteps[0]?.name, 'npm-test', 'npm-typecheck',
      'npm-build', 'post-web-checkout-integrity',
      ...(mode === 'all' ? ['native-local-release', 'post-native-checkout-integrity'] : [])];
  const names = receipts.map(s => s.name);
  const exactSequence = names.length === expected.length &&
    names.every((name, index) => name === expected[index]);
  const completed = new Set(receipts.filter(s => s.success && s.bytes > 0).map(s => s.name));
  const passed = exitCode === 0 && installValid && exactSequence &&
    required[mode].every(name => completed.has(name)) &&
    receipts.every(s => s.success && s.bytes > 0);
  return { schemaVersion: 1, candidateSha: sha, mode, cleanCheckout: true, exitCode,
    status: passed ? 'local-checks-passed' : 'incomplete-or-failed', steps: receipts,
    physicalDeviceAcceptance: 'NOT_TESTED', branchProtection: 'NOT_VERIFIED', rollback: 'NOT_VERIFIED' };
}

/**
 * Independently recheck a previously written receipt against its original log
 * directory. A receipt is only an observation, not permission to deploy.
 * The log hash must match the bytes on disk at verification time.
 */
export function verifyLocalReceipt(receipt, { expectedSha, logDir }) {
  const errors = [];
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt)) return ['Invalid receipt object.'];
  // Receipts are a deliberately narrow observation schema. Reject unknown
  // fields rather than silently accepting attacker-added release approvals.
  const receiptFields = new Set([
    'schemaVersion', 'candidateSha', 'mode', 'cleanCheckout', 'exitCode',
    'status', 'steps', 'physicalDeviceAcceptance', 'branchProtection', 'rollback'
  ]);
  if (Object.keys(receipt).some(key => !receiptFields.has(key)))
    errors.push('Unexpected receipt field; local evidence cannot grant release approval.');
  if (receipt.schemaVersion !== 1) errors.push('Unsupported receipt schema version.');
  if (!SHA.test(expectedSha ?? '') || receipt.candidateSha !== expectedSha)
    errors.push('Receipt candidate SHA mismatch.');
  if (!Object.hasOwn(required, receipt.mode)) errors.push('Unknown receipt mode.');
  if (receipt.cleanCheckout !== true || receipt.exitCode !== 0 ||
      receipt.status !== 'local-checks-passed')
    errors.push('Receipt is not a successful clean-checkout observation.');
  if (receipt.physicalDeviceAcceptance !== 'NOT_TESTED' ||
      receipt.branchProtection !== 'NOT_VERIFIED' || receipt.rollback !== 'NOT_VERIFIED')
    errors.push('Local receipt contains unauthorized release approval claims.');
  if (!Array.isArray(receipt.steps) || receipt.steps.length > allowed.size)
    return [...errors, 'Missing or excessive receipt steps.'];
  const steps = receipt.steps;
  const names = steps.map(s => s?.name);
  const installs = names.filter(n => n === 'npm-ci' || n === 'npm-ci-offline');
  const expected = receipt.mode === 'node-only' ? ['node-release-safety','post-node-checkout-integrity'] :
    receipt.mode === 'native' ? ['native-local-release', 'post-native-checkout-integrity'] :
    ['node-release-safety', installs[0], 'npm-test', 'npm-typecheck', 'npm-build',
      'post-web-checkout-integrity',
      ...(receipt.mode === 'all' ? ['native-local-release', 'post-native-checkout-integrity'] : [])];
  if (names.length !== expected.length || names.some((n, i) => n !== expected[i]) ||
      (['web', 'all'].includes(receipt.mode) && installs.length !== 1))
    errors.push('Receipt step sequence is incomplete or unexpected.');
  for (const step of steps) {
    if (!step || typeof step !== 'object' || !allowed.has(step.name) ||
        step.success !== true || !Number.isSafeInteger(step.bytes) ||
        step.bytes < 1 || step.bytes > 32 * 1024 * 1024 ||
        !/^[0-9a-f]{64}$/.test(step.sha256 ?? '') ||
        step.file !== step.name + '.log' ||
        Object.keys(step).some(key => !['name', 'success', 'bytes', 'sha256', 'file'].includes(key))) {
      errors.push('Malformed or unsuccessful receipt step.');
      continue;
    }
    // The filename is generated from an allowlist, never taken from a
    // user-controlled path. The existing bounded, symlink-safe reader also
    // checks the file's identity while hashing.
    try {
      const actual = readLogFingerprint(resolve(logDir, step.file));
      if (actual.bytes !== step.bytes || actual.sha256 !== step.sha256)
        errors.push('Log changed after receipt creation: ' + step.name);
    } catch (error) {
      errors.push('Cannot verify log ' + step.name + ': ' + error.message);
    }
  }
  return errors;
}

function readLogFingerprint(path) {
  const metadata = lstatSync(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.nlink !== 1)
    throw Error('Step log must be a regular, unlinked file.');
  // Avoid following a symlink substituted between lstat and open.
  const fd = openSync(path, fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0));
  try {
    const opened = fstatSync(fd);
    if (!opened.isFile() || opened.dev !== metadata.dev || opened.ino !== metadata.ino ||
        opened.nlink !== 1 || opened.size !== metadata.size ||
        opened.size > 32 * 1024 * 1024) throw Error('Step log changed or exceeds 32 MiB limit.');
    const hash = createHash('sha256');
    const buffer = Buffer.allocUnsafe(64 * 1024);
    let bytes = 0;
    let count;
    while ((count = readSync(fd, buffer, 0, buffer.length, null)) !== 0) {
      bytes += count;
      if (bytes > 32 * 1024 * 1024) throw Error('Step log exceeds 32 MiB receipt limit.');
      hash.update(buffer.subarray(0, count));
    }
    const final = fstatSync(fd);
    if (final.size !== bytes || final.dev !== opened.dev ||
        final.ino !== opened.ino || final.mtimeMs !== opened.mtimeMs ||
        final.ctimeMs !== opened.ctimeMs || final.nlink !== 1)
      throw Error('Step log changed during verification.');
    // A rename or symlink swap leaves the open descriptor readable. Ensure
    // the named log still resolves to the bytes we just fingerprinted.
    const current = lstatSync(path);
    if (!current.isFile() || current.isSymbolicLink() || current.nlink !== 1 ||
        current.dev !== opened.dev || current.ino !== opened.ino ||
        current.size !== final.size || current.mtimeMs !== final.mtimeMs ||
        current.ctimeMs !== final.ctimeMs)
      throw Error('Step log pathname changed during verification.');
    return { bytes, sha256: hash.digest('hex') };
  } finally { closeSync(fd); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    if (process.argv[2] === '--verify') {
      const [, path, sha, dir] = process.argv.slice(2);
      if (!path || !sha || !dir || process.argv.length !== 6)
        throw Error('Usage: --verify receipt.json sha log-directory');
      const errors = [
        ...verifyCheckoutIdentity(sha),
        ...verifyLocalReceipt(readPersistedReceipt(path),
          { expectedSha: sha, logDir: dir })
      ];
      if (errors.length) throw Error(errors.join('; '));
      console.log('Local receipt and original logs verified for ' + sha);
      process.exit(0);
    }
    const [out, sha, dirty, mode, code, dir, ...raw] = process.argv.slice(2);
    if (!out || !sha || !dirty || !mode || code === undefined || !dir)
      throw Error('Usage: receipt.json sha dirty mode exitCode log-directory step:success...');
    const checkoutErrors = verifyCheckoutIdentity(sha);
    if (checkoutErrors.length) throw Error(checkoutErrors.join('; '));
    // Reject ambiguous numeric coercion and ignored colon-delimited fields.
    if (!/^(0|[1-9][0-9]*)$/.test(code))
      throw Error('Exit code must be a decimal integer.');
    const steps = raw.map(item => {
      const match = /^([a-z][a-z0-9-]*):([01])$/.exec(item);
      if (!match) throw Error('Malformed step argument: expected name:0 or name:1.');
      return { name: match[1], success: Number(match[2]) };
    });
    const receipt = buildLocalReceipt({ sha, dirty, mode, exitCode: Number(code), logDir: dir, steps });
    const encoded = JSON.stringify(receipt, null, 2) + '\n';
    if (Buffer.byteLength(encoded) > RECEIPT_LIMIT)
      throw Error('Receipt exceeds 256 KiB size limit.');
    writeFileSync(out, encoded, { flag: 'wx', mode: 0o600 });
    console.log('Local execution receipt: ' + out + ' (' + receipt.status + ')');
  } catch (error) {
    console.error('Local receipt unavailable: ' + error.message);
    process.exitCode = 1;
  }
}
