import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildLocalReceipt } from './local-evidence.mjs';
const sha = 'a'.repeat(40);
const webSteps = ['node-release-safety','npm-ci','npm-test','npm-typecheck','npm-build','post-web-checkout-integrity'];
function fixture(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'mp3-local-receipt-'));
  try { return fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
}
function args(dir, names = webSteps) {
  for (const name of names) writeFileSync(join(dir, name + '.log'), 'Executed ' + name + '\n');
  return { sha, dirty: 'no', mode: 'web', steps: names.map(name => ({ name, success: 1 })), exitCode: 0, logDir: dir };
}
test('web receipt binds candidate SHA and hashed logs', () => fixture(dir => {
  const r = buildLocalReceipt(args(dir));
  assert.equal(r.status, 'local-checks-passed');
  assert.equal(r.candidateSha, sha);
  assert.equal(r.steps.length, 6);
  assert.match(r.steps[0].sha256, /^[0-9a-f]{64}$/);
  assert.equal(r.physicalDeviceAcceptance, 'NOT_TESTED');
  assert.equal(r.branchProtection, 'NOT_VERIFIED');
}));
test('missing mandatory check cannot pass', () => fixture(dir => {
  assert.equal(buildLocalReceipt(args(dir, webSteps.filter(s => s !== 'npm-build'))).status, 'incomplete-or-failed');
}));
test('failed step and nonzero runner exit cannot pass', () => fixture(dir => {
  const a = args(dir); a.steps[1].success = 0;
  assert.equal(buildLocalReceipt(a).status, 'incomplete-or-failed');
  a.steps[1].success = 1; a.exitCode = 1;
  assert.equal(buildLocalReceipt(a).status, 'incomplete-or-failed');
}));
test('dirty or unknown SHA cannot produce receipt', () => fixture(dir => {
  const a = args(dir); a.dirty = 'yes';
  assert.throws(() => buildLocalReceipt(a), /clean checkout/);
  a.dirty = 'no'; a.sha = 'unknown';
  assert.throws(() => buildLocalReceipt(a), /clean checkout/);
}));
test('duplicate, unknown and malformed steps rejected', () => fixture(dir => {
  const a = args(dir); a.steps.push(a.steps[0]);
  assert.throws(() => buildLocalReceipt(a), /Duplicate/);
  a.steps.pop(); a.steps.push({ name: 'unexpected', success: 1 });
  assert.throws(() => buildLocalReceipt(a), /Malformed/);
}));
test('missing log cannot be recorded as executed', () => fixture(dir => {
  const a = args(dir); a.steps.push({ name: 'native-local-release', success: 1 });
  assert.throws(() => buildLocalReceipt(a), /ENOENT/);
}));
test('native receipt requires native checks but never claims device pass', () => fixture(dir => {
  const a = args(dir, ['native-local-release','post-native-checkout-integrity']); a.mode = 'native';
  const r = buildLocalReceipt(a);
  assert.equal(r.status, 'local-checks-passed');
  assert.equal(r.physicalDeviceAcceptance, 'NOT_TESTED');
}));
