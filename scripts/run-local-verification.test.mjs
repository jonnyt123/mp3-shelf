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
