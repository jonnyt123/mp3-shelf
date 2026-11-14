import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { spawnSync } from 'node:child_process';
const script = new URL('./run-local-verification.sh', import.meta.url).pathname;
const invoke = (...args) => spawnSync('bash', [script, ...args], { encoding: 'utf8', timeout: 10000 });
test('help advertises isolated zero-Actions verification modes', () => {
  const r = invoke('--help');
  assert.equal(r.status, 0);
  assert.match(r.stdout, /--node-only/);
  assert.match(r.stdout, /GitHub Actions minutes/);
});
test('conflicting modes rejected before any test or install', () => {
  const r = invoke('--web', '--native');
  assert.equal(r.status, 2);
  assert.match(r.stderr, /Choose one mode/);
});
test('smoke only allowed with native scope', () => {
  const r = invoke('--node-only', '--smoke');
  assert.equal(r.status, 2);
  assert.match(r.stderr, /requires native/);
});
test('unknown mode refused, not treated as web test', () => {
  const r = invoke('--deploy');
  assert.equal(r.status, 2);
  assert.match(r.stderr, /Unknown argument/);
});

test('runner never masks failed release receipt generation', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(script, 'utf8');
  assert.match(source, /receipt_state='FAILED'/);
  assert.match(source, /Verification commands succeeded but receipt generation failed/);
  assert.doesNotMatch(source, /local-evidence\.mjs[^\n]*\|\| true/);
  assert.match(source, /trap - EXIT/);
  assert.match(source, /exit "\$code"/);
});
test('node-only dirty checkout is explicitly excluded from release evidence', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(script, 'utf8');
  assert.match(source, /UNAVAILABLE_UNCLEAN_CHECKOUT/);
  assert.match(source, /DEVELOPMENT CHECKS PASSED; NO RELEASE EVIDENCE/);
});

test('successful release requires independent verification of persisted receipt and original logs', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(script, 'utf8');
  assert.match(source, /local-evidence\.mjs" --verify "\$OUT\/local-evidence\.json" "\$COMMIT" "\$OUT"/);
  assert.match(source, /receipt_state='CREATED_UNVERIFIED'/);
  assert.match(source, /receipt_state='VERIFIED'/);
  assert.match(source, /receipt_state='VERIFICATION_FAILED'/);
  assert.match(source, /receipt_state='INCOMPLETE'/);
  assert.match(source, /code=1[\s\S]*Persisted release receipt failed independent verification/);
  assert.match(source, /"\$receipt_state" == VERIFIED/);
  assert.doesNotMatch(source, /"\$receipt_state" == CREATED/);
});

test('node-only refuses SHA-bound evidence if verification modifies the checkout', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(script, 'utf8');
  assert.match(source, /MODE" == node-only && "\$COMMIT" != unknown && "\$DIRTY" == no/);
  assert.match(source, /STEP=post-node-checkout-integrity/);
  assert.match(source, /checkout_unchanged/);
  assert.match(source, /checkout_unchanged/);
  assert.match(source, /Node verification changed the candidate commit or checkout/);
});

// A successful node-only run must include checkout integrity in the persisted
// receipt, not merely print a success message after testing.
test('node-only integrity check is included in completed and receipt steps', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(script, 'utf8');
  const start = source.indexOf('STEP=post-node-checkout-integrity');
  const end = source.indexOf('if [[ "$MODE" == web || "$MODE" == all ]]', start);
  assert.ok(start > 0 && end > start, 'node-only integrity block must exist');
  const block = source.slice(start, end);
  assert.match(block, /COMPLETED\+=\("\$STEP"\)/);
  assert.match(block, /RECEIPT_STEPS\+=\("\$STEP:1"\)/);
  assert.match(block, /"\$OUT\/\$STEP\.log"/);
  assert.ok(block.indexOf('exit 2') < block.indexOf('RECEIPT_STEPS+='), 'failed integrity must not be recorded as passing');
});

test('receipt-time checkout identity is rechecked even after the final integrity step', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(script, 'utf8');
  const report = source.slice(source.indexOf('report() {'), source.indexOf('trap report EXIT'));
  const recheck = report.indexOf('receipt_state=\'UNAVAILABLE_CHECKOUT_CHANGED\'');
  const receipt = report.indexOf('node "$ROOT/scripts/local-evidence.mjs" "$OUT/local-evidence.json"');
  assert.ok(recheck > 0 && receipt > recheck, 'checkout must be rechecked before receipt creation');
  assert.match(report, /checkout_unchanged/);
  assert.match(report, /checkout_unchanged/);
  assert.ok(report.indexOf('code=1', recheck) > recheck, 'successful execution must become failure');
  assert.match(report, /Checkout changed before receipt generation/);
  assert.match(report, /receipt_state" != UNAVAILABLE_CHECKOUT_CHANGED/);
});

test('initial, web and native integrity checks include untracked source files', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(script, 'utf8');
  const checks = source.match(/if ! checkout_unchanged; then/g) ?? [];
  assert.equal(checks.length, 4, 'receipt, node, web and native checks must use fail-closed helper');
  assert.match(source, /status="\$\(git status --porcelain --untracked-files=all 2>\/dev\/null\)" \|\| return 1/);
  assert.match(source, /current="\$\(valid_candidate\)" \|\| return 1/);
  assert.doesNotMatch(source, /git status --porcelain\)/);
});

test('Git status failure is never interpreted as a clean checkout', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(script, 'utf8');
  const helper = source.slice(source.indexOf('checkout_unchanged() {'), source.indexOf('DIRTY=unknown'));
  assert.match(helper, /valid_candidate/);
  assert.match(helper, /git status --porcelain --untracked-files=all/);
  assert.match(helper, /\|\| return 1/g);
  assert.match(source, /if checkout_unchanged; then DIRTY=no; else DIRTY=yes; fi/);
  assert.match(source, /if ! checkout_unchanged; then/g);
});


test('web preflight fails closed when git status fails instead of running npm', async () => {
  const { mkdtempSync, writeFileSync, chmodSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join, delimiter } = await import('node:path');
  const dir = mkdtempSync(join(tmpdir(), 'mp3-git-failure-'));
  try {
    const git = join(dir, 'git');
    writeFileSync(git, '#!/bin/sh\nif [ "$1" = "rev-parse" ]; then printf "%040d\n" 0; exit 0; fi\nif [ "$1" = "status" ]; then exit 128; fi\nexit 128\n');
    chmodSync(git, 0o755);
    const r = spawnSync('bash', [script, '--web', '--offline'], {
      encoding: 'utf8', timeout: 10000,
      env: { ...process.env, PATH: dir + delimiter + process.env.PATH }
    });
    assert.equal(r.status, 2, r.stderr);
    assert.match(r.stderr, /Refusing release verification without a clean Git checkout/);
    assert.doesNotMatch(r.stdout, /==> npm-ci|==> npm-test|==> npm-build/);
    assert.match(r.stdout, /SHA-bound receipt: UNAVAILABLE_UNCLEAN_CHECKOUT/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('web preflight rejects an unstable HEAD before any dependency install', async () => {
  const { mkdtempSync, writeFileSync, chmodSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join, delimiter } = await import('node:path');
  const dir = mkdtempSync(join(tmpdir(), 'mp3-git-head-'));
  try {
    const git = join(dir, 'git');
    writeFileSync(git, '#!/bin/sh\nif [ "$1" = "rev-parse" ]; then printf "%040d\n" 0; exit 0; fi\nif [ "$1" = "status" ]; then printf " M package-lock.json\n"; exit 0; fi\nexit 128\n');
    chmodSync(git, 0o755);
    const r = spawnSync('bash', [script, '--web', '--offline'], {
      encoding: 'utf8', timeout: 10000,
      env: { ...process.env, PATH: dir + delimiter + process.env.PATH }
    });
    assert.equal(r.status, 2, r.stderr);
    assert.match(r.stderr, /Refusing release verification without a clean Git checkout/);
    assert.doesNotMatch(r.stdout, /==> npm-ci|==> npm-test|==> npm-build/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('receipt verification cannot report PASS if the checkout mutates during validation', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(script, 'utf8');
  const begin = source.indexOf('if node "$ROOT/scripts/local-evidence.mjs" --verify');
  const end = source.indexOf("receipt_state='VERIFICATION_FAILED'", begin);
  assert.ok(begin > 0 && end > begin, 'independent receipt verification branch must exist');
  const branch = source.slice(begin, end);
  assert.match(branch, /if checkout_unchanged; then/);
  assert.match(branch, /receipt_state='VERIFIED'/);
  assert.match(branch, /receipt_state='UNAVAILABLE_CHECKOUT_CHANGED'/);
  assert.match(branch, /Checkout changed during receipt verification/);
  assert.ok(branch.indexOf('if checkout_unchanged; then') < branch.indexOf("receipt_state='VERIFIED'"),
    'success must be gated by a fresh checkout check');
  assert.ok(branch.indexOf('code=1') > branch.indexOf("receipt_state='UNAVAILABLE_CHECKOUT_CHANGED'"),
    'checkout mutation must fail the command');
});

test('release candidate identity requires this repository root and a full commit SHA', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(script, 'utf8');
  const validator = source.slice(source.indexOf('valid_candidate() {'), source.indexOf('COMMIT="$(valid_candidate'));
  assert.match(validator, /git rev-parse --show-toplevel/);
  assert.match(validator, /pwd -P/);
  assert.match(validator, /git rev-parse --verify 'HEAD\^\{commit\}'/);
  assert.match(validator, /\[0-9a-f\]\{40\}/);
  assert.match(source, /current="\$\(valid_candidate\)" \|\| return 1/);
});

test('web preflight rejects a parent repository or forged abbreviated SHA before npm', async () => {
  const { mkdtempSync, writeFileSync, chmodSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join, delimiter } = await import('node:path');
  for (const mode of ['wrong-root', 'short-sha']) {
    const dir = mkdtempSync(join(tmpdir(), 'mp3-git-identity-'));
    try {
      const git = join(dir, 'git');
      const root = mode === 'wrong-root' ? dir : new URL('..', import.meta.url).pathname.replace(/\/$/, '');
      const scriptText = '#!/bin/sh\n' +
        'case "$1" in\n' +
        'rev-parse) if [ "$2" = "--show-toplevel" ]; then printf "%s\n" ' + JSON.stringify(root) + '; else printf "%s\n" ' + JSON.stringify(mode === 'short-sha' ? 'abcdef0' : 'a'.repeat(40)) + '; fi ;;\n' +
        'status) exit 0 ;;\n' +
        '*) exit 128 ;;\n' +
        'esac\n';
      writeFileSync(git, scriptText);
      chmodSync(git, 0o755);
      const result = spawnSync('bash', [script, '--web', '--offline'], {
        encoding: 'utf8', timeout: 10000,
        env: { ...process.env, PATH: dir + delimiter + process.env.PATH }
      });
      assert.equal(result.status, 2, mode + ': ' + result.stderr);
      assert.match(result.stderr, /Refusing release verification without a clean Git checkout/);
      assert.doesNotMatch(result.stdout, /==> npm-ci|==> npm-test|==> npm-build/);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }
});
