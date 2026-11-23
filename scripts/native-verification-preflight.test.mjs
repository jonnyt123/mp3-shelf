import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const script = new URL('./run-local-verification.sh', import.meta.url).pathname;
const source = readFileSync(script, 'utf8');

test('native-only verification runs source-backed safety tests before Xcode', () => {
  const condition = source.indexOf('if [[ "$MODE" == node-only || "$MODE" == web || "$MODE" == native || "$MODE" == all ]]; then');
  const safety = source.indexOf('run node-release-safety node --test', condition);
  const integrity = source.indexOf('STEP=pre-native-checkout-integrity', safety);
  const nativeBuild = source.indexOf('run native-local-release bash ios/scripts/verify-local-release.sh', integrity);
  assert(condition >= 0 && safety > condition && integrity > safety && nativeBuild > integrity);
  const invocation = source.slice(safety, source.indexOf('\nfi', safety));
  assert.match(invocation, /native-offline-journey-regression\.test\.mjs/);
  assert.match(invocation, /native-branch-reconciliation\.test\.mjs/);
});

test('native safety regression checkout mutation stops before Xcode and cannot mint evidence', () => {
  const start = source.indexOf('if [[ "$MODE" == native ]]; then\n  STEP=pre-native-checkout-integrity');
  const end = source.indexOf('\nfi', start);
  assert(start >= 0 && end > start);
  const block = source.slice(start, end);
  assert.match(block, /if ! checkout_unchanged; then/);
  assert.match(block, /exit 2/);
  assert.match(block, /RECEIPT_STEPS\+=\("\$STEP:1"\)/);
  assert(block.indexOf('exit 2') < block.indexOf('RECEIPT_STEPS+='));
});

test('native preflight script is valid bash', () => {
  const result = spawnSync('bash', ['-n', script], { encoding: 'utf8', timeout: 10000 });
  assert.equal(result.status, 0, result.stderr);
});
