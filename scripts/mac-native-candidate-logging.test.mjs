import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runLogged } from './mac-native-candidate.mjs';

function workspace(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'mp3-native-logs-'));
  return Promise.resolve().then(() => fn(dir))
    .finally(() => rmSync(dir, { recursive: true, force: true }));
}

test('successful native command persists stdout and stderr before resolving', async () =>
  workspace(async dir => {
    const path = join(dir, 'native.log');
    await runLogged(process.execPath,
      ['-e', "process.stdout.write('out\\n'); process.stderr.write('err\\n')"],
      dir, path);
    const log = readFileSync(path, 'utf8');
    assert.match(log, /out/);
    assert.match(log, /err/);
  }));

test('nonzero native command fails even when its log is successfully persisted', async () =>
  workspace(async dir => {
    const path = join(dir, 'native.log');
    await assert.rejects(runLogged(process.execPath,
      ['-e', "process.stderr.write('failed\\n'); process.exit(7)"],
      dir, path), /exit 7/);
    assert.match(readFileSync(path, 'utf8'), /failed/);
  }));

test('missing log parent refuses a successful command rather than issuing PASS', async () =>
  workspace(async dir => {
    await assert.rejects(runLogged(process.execPath, ['-e', 'process.exit(0)'],
      dir, join(dir, 'missing', 'native.log')), /log could not be written/);
  }));

test('spawn failure cannot masquerade as a native build success', async () =>
  workspace(async dir => {
    await assert.rejects(runLogged(join(dir, 'missing-executable'), [],
      dir, join(dir, 'native.log')), /process failed to start/);
  }));
