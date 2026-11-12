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
  assert.doesNotMatch(source, /local-evidence\\.mjs[^\\n]*\\|\\| true/);
  assert.match(source, /trap - EXIT/);
  assert.match(source, /exit "\\$code"/);
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
  assert.match(source, /local-evidence\\.mjs" --verify "\\$OUT\/local-evidence\\.json" "\\$COMMIT" "\\$OUT"/);
  assert.match(source, /receipt_state='CREATED_UNVERIFIED'/);
  assert.match(source, /receipt_state='VERIFIED'/);
  assert.match(source, /receipt_state='VERIFICATION_FAILED'/);
  assert.match(source, /receipt_state='INCOMPLETE'/);
  assert.match(source, /code=1[\\s\\S]*Persisted release receipt failed independent verification/);
  assert.match(source, /"\\$receipt_state" == VERIFIED/);
  assert.doesNotMatch(source, /"\\$receipt_state" == CREATED/);
});

test('node-only refuses SHA-bound evidence if verification modifies the checkout', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(script, 'utf8');
  assert.match(source, /MODE" == node-only && "\$COMMIT" != unknown && "\$DIRTY" == no/);
  assert.match(source, /STEP=post-node-checkout-integrity/);
  assert.match(source, /git rev-parse --verify HEAD/);
  assert.match(source, /git status --porcelain --untracked-files=all/);
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
  assert.match(report, /git rev-parse --verify HEAD/);
  assert.match(report, /git status --porcelain --untracked-files=all/);
  assert.match(report, /code=1[\\s\\S]*Checkout changed before receipt generation/);
  assert.match(report, /receipt_state" != UNAVAILABLE_CHECKOUT_CHANGED/);
});

test('initial, web and native integrity checks include untracked source files', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(script, 'utf8');
  const matches = source.match(/git status --porcelain --untracked-files=all/g) ?? [];
  assert.ok(matches.length >= 5, 'initial, receipt, node, web and native checks must agree');
  assert.doesNotMatch(source, /git status --porcelain\)/);
});
