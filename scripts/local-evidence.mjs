#!/usr/bin/env node
// SHA-bound local observations, deliberately not a release approval.
import { createHash } from 'node:crypto';
import { closeSync, fstatSync, lstatSync, openSync, readSync, writeFileSync } from 'node:fs';
import { basename, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const SHA = /^[0-9a-f]{40}$/i;
const allowed = new Set(['node-release-safety','npm-ci','npm-ci-offline','npm-test','npm-typecheck','npm-build','post-web-checkout-integrity','native-local-release','post-native-checkout-integrity']);
const required = {
  'node-only': ['node-release-safety'],
  web: ['node-release-safety','npm-test','npm-typecheck','npm-build','post-web-checkout-integrity'],
  native: ['native-local-release','post-native-checkout-integrity'],
  all: ['node-release-safety','npm-test','npm-typecheck','npm-build','post-web-checkout-integrity','native-local-release','post-native-checkout-integrity']
};
export function buildLocalReceipt({ sha, dirty, mode, steps, exitCode, logDir }) {
  if (!SHA.test(sha) || dirty !== 'no') throw Error('Receipt requires a clean checkout at a full Git SHA.');
  if (!Object.hasOwn(required, mode)) throw Error('Unknown verification mode.');
  if (!Number.isSafeInteger(exitCode) || exitCode < 0 || exitCode > 255) throw Error('Invalid exit code.');
  if (!Array.isArray(steps) || steps.some(s => !s || typeof s !== 'object' ||
      !allowed.has(s.name) || ![0, 1].includes(s.success))) throw Error('Malformed step records.');
  const seen = new Set();
  const receipts = steps.map(step => {
    if (seen.has(step.name)) throw Error('Duplicate step receipt.');
    seen.add(step.name);
    const file = step.name + '.log';
    const path = resolve(logDir, file);
    // Logs may contain arbitrarily large provider/build output. Never load
    // unbounded files into memory or follow a substituted symlink.
    const metadata = lstatSync(path);
    if (!metadata.isFile() || metadata.isSymbolicLink()) throw Error('Step log must be a regular file.');
    const fd = openSync(path, 'r');
    try {
      const opened = fstatSync(fd);
      if (!opened.isFile() || opened.dev !== metadata.dev || opened.ino !== metadata.ino)
        throw Error('Step log changed during verification.');
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
      if (final.size !== bytes || final.mtimeMs !== opened.mtimeMs)
        throw Error('Step log changed during verification.');
      return { name: step.name, success: step.success === 1, bytes,
        sha256: hash.digest('hex'), file: basename(file) };
    } finally {
      closeSync(fd);
    }
  });
  // An npm test/build run without an actual dependency reconciliation is not
  // release evidence. Require exactly one install mode, not a skipped install
  // or a mixed online/offline invocation.
  const installSteps = receipts.filter(s => s.name === 'npm-ci' || s.name === 'npm-ci-offline');
  const installValid = !['web', 'all'].includes(mode) ||
    (installSteps.length === 1 && installSteps[0].success);
  // Receipts must describe the execution sequence the runner actually uses.
  // This rejects reordered, injected or duplicate-looking success reports.
  const expected = mode === 'node-only' ? ['node-release-safety'] :
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
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const [out, sha, dirty, mode, code, dir, ...raw] = process.argv.slice(2);
    const steps = raw.map(item => {
      const [name, value] = item.split(':');
      return { name, success: Number(value) };
    });
    const receipt = buildLocalReceipt({ sha, dirty, mode, exitCode: Number(code), logDir: dir, steps });
    writeFileSync(out, JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    console.log('Local execution receipt: ' + out + ' (' + receipt.status + ')');
  } catch (error) {
    console.error('Local receipt unavailable: ' + error.message);
    process.exitCode = 1;
  }
}
