import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, writeFileSync, rmSync, symlinkSync, unlinkSync, truncateSync, mkdirSync, linkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { verifyCheckoutIdentity } from './local-evidence.mjs';
import { buildLocalReceipt, verifyLocalReceipt } from './local-evidence.mjs';
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

test('web and all receipts require exactly one successful dependency install', () => fixture(dir => {
  const omitted = args(dir, webSteps.filter(s => s !== 'npm-ci'));
  assert.equal(buildLocalReceipt(omitted).status, 'incomplete-or-failed');
  const mixed = args(dir, [...webSteps, 'npm-ci-offline']);
  assert.equal(buildLocalReceipt(mixed).status, 'incomplete-or-failed');
  const offline = args(dir, webSteps.map(s => s === 'npm-ci' ? 'npm-ci-offline' : s));
  assert.equal(buildLocalReceipt(offline).status, 'local-checks-passed');
  const all = args(dir, [...webSteps, 'native-local-release', 'post-native-checkout-integrity']);
  all.mode = 'all';
  assert.equal(buildLocalReceipt(all).status, 'local-checks-passed');
  all.steps = all.steps.filter(s => s.name !== 'npm-ci');
  assert.equal(buildLocalReceipt(all).status, 'incomplete-or-failed');
}));
test('successful but empty or reordered step logs cannot pass', () => fixture(dir => {
  const empty = args(dir);
  writeFileSync(join(dir, 'npm-build.log'), '');
  assert.equal(buildLocalReceipt(empty).status, 'incomplete-or-failed');
  const swapped = args(dir);
  [swapped.steps[2], swapped.steps[3]] = [swapped.steps[3], swapped.steps[2]];
  assert.equal(buildLocalReceipt(swapped).status, 'incomplete-or-failed');
}));
test('node-only and native modes reject injected steps', () => fixture(dir => {
  const node = args(dir, ['node-release-safety']); node.mode = 'node-only';
  assert.equal(buildLocalReceipt(node).status, 'local-checks-passed');
  node.steps.push({ name: 'npm-test', success: 1 });
  writeFileSync(join(dir, 'npm-test.log'), 'fake\n');
  assert.equal(buildLocalReceipt(node).status, 'incomplete-or-failed');
  const native = args(dir, ['native-local-release','post-native-checkout-integrity']);
  native.mode = 'native';
  assert.equal(buildLocalReceipt(native).status, 'local-checks-passed');
  native.steps.reverse();
  assert.equal(buildLocalReceipt(native).status, 'incomplete-or-failed');
}));

test('large logs are hashed incrementally without unbounded memory', () => fixture(dir => {
  const a = args(dir);
  const file = join(dir, 'npm-build.log');
  truncateSync(file, 1024 * 1024);
  const receipt = buildLocalReceipt(a);
  assert.equal(receipt.status, 'local-checks-passed');
  assert.equal(receipt.steps.find(s => s.name === 'npm-build').bytes, 1024 * 1024);
}));

test('oversized logs fail closed before exhausting release verifier memory', () => fixture(dir => {
  const a = args(dir);
  truncateSync(join(dir, 'npm-build.log'), 33 * 1024 * 1024);
  assert.throws(() => buildLocalReceipt(a), /32 MiB/);
}));

test('symlink substitution and non-file logs cannot create receipts', () => fixture(dir => {
  const a = args(dir);
  const log = join(dir, 'npm-build.log');
  unlinkSync(log);
  symlinkSync(join(dir, 'npm-test.log'), log);
  assert.throws(() => buildLocalReceipt(a), /regular file/);
  unlinkSync(log);
  mkdirSync(log);
  assert.throws(() => buildLocalReceipt(a), /regular file/);
}));

test('receipt verifier accepts unchanged original logs and rejects byte tampering', () => fixture(dir => {
  const a = args(dir);
  const receipt = buildLocalReceipt(a);
  assert.deepEqual(verifyLocalReceipt(receipt, { expectedSha: sha, logDir: dir }), []);
  writeFileSync(join(dir, 'npm-build.log'), 'changed after receipt\n');
  assert.match(verifyLocalReceipt(receipt, { expectedSha: sha, logDir: dir }).join(' '), /Log changed/);
}));
test('receipt verifier rejects missing, substituted and hard-linked logs', () => fixture(dir => {
  const a = args(dir);
  const receipt = buildLocalReceipt(a);
  unlinkSync(join(dir, 'npm-test.log'));
  assert.match(verifyLocalReceipt(receipt, { expectedSha: sha, logDir: dir }).join(' '), /Cannot verify log/);
  const restored = args(dir);
  const second = buildLocalReceipt(restored);
  const alias = join(dir, 'alias.log');
  linkSync(join(dir, 'npm-build.log'), alias);
  assert.match(verifyLocalReceipt(second, { expectedSha: sha, logDir: dir }).join(' '), /unlinked file/);
}));
test('receipt verifier rejects forged release status and changed SHA', () => fixture(dir => {
  const receipt = buildLocalReceipt(args(dir));
  assert.match(verifyLocalReceipt(receipt, { expectedSha: 'b'.repeat(40), logDir: dir }).join(' '), /SHA mismatch/);
  assert.match(verifyLocalReceipt({ ...receipt, rollback: 'VERIFIED' },
    { expectedSha: sha, logDir: dir }).join(' '), /unauthorized/);
  assert.match(verifyLocalReceipt({ ...receipt, steps: receipt.steps.slice(1) },
    { expectedSha: sha, logDir: dir }).join(' '), /sequence/);
}));

test('receipt CLI rejects mismatched SHA, dirty checkout and tampered original logs', () => fixture(dir => {
  const git = (...args) => execFileSync('git', args, {
    cwd: dir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']
  }).trim();
  git('init', '-q');
  git('config', 'user.name', 'Local Receipt Test');
  git('config', 'user.email', 'local-test@example.invalid');
  writeFileSync(join(dir, 'tracked.txt'), 'original\\n');
  git('add', 'tracked.txt');
  git('commit', '-qm', 'fixture');
  const actual = git('rev-parse', 'HEAD');
  assert.deepEqual(verifyCheckoutIdentity(actual, dir), []);
  assert.match(verifyCheckoutIdentity('b'.repeat(40), dir).join(' '), /HEAD/);
  const script = fileURLToPath(new URL('./local-evidence.mjs', import.meta.url));
  const outside = mkdtempSync(join(tmpdir(), 'mp3-receipt-logs-'));
  try {
    writeFileSync(join(outside, 'node-release-safety.log'), 'Executed node test\\n');
    const receiptPath = join(outside, 'receipt.json');
    const create = spawnSync(process.execPath, [script, receiptPath, actual, 'no',
      'node-only', '0', outside, 'node-release-safety:1'], { cwd: dir, encoding: 'utf8' });
    assert.equal(create.status, 0, create.stderr);
    const verify = () => spawnSync(process.execPath, [script, '--verify', receiptPath,
      actual, outside], { cwd: dir, encoding: 'utf8' });
    assert.equal(verify().status, 0, verify().stderr);
    writeFileSync(join(dir, 'untracked.txt'), 'dirty\\n');
    assert.match(verifyCheckoutIdentity(actual, dir).join(' '), /not clean/);
    const rejected = verify();
    assert.equal(rejected.status, 1);
    assert.match(rejected.stderr, /not clean/);
    rmSync(join(dir, 'untracked.txt'));
    assert.equal(verify().status, 0);
    writeFileSync(join(outside, 'node-release-safety.log'), 'tampered\\n');
    assert.match(verify().stderr, /Log changed/);
  } finally { rmSync(outside, { recursive: true, force: true }); }
}));
