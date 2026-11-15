import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync, rmSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { devicePhaseArguments, runIPhonePhase } from './iphone-qa-session.mjs';
const udid = '12345678-1234-1234-1234-123456789012';
const playlist = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const bundle = 'com.jonnyt.mp3shelf';
test('launch commands always include devicectl -- separator before app flags', () => {
  for (const [phase, expected] of [['arm', '--mp3shelf-qa-arm'], ['offline', '--mp3shelf-qa-offline'], ['stop', '--mp3shelf-qa-stop']]) {
    const args = devicePhaseArguments(phase, { deviceID: udid, bundleID: bundle, playlistID: playlist });
    const i = args.indexOf('--');
    assert.equal(args[i - 1], bundle);
    assert.equal(args[i + 1], expected);
    assert.equal(args[0], 'devicectl');
  }
});
test('strict device and playlist identifiers reject command injection', () => {
  for (const deviceID of [';rm -rf /', '', 'device with spaces']) {
    assert.throws(() => devicePhaseArguments('arm', { deviceID, bundleID: bundle }));
  }
  assert.throws(() => devicePhaseArguments('offline', { deviceID: udid, bundleID: bundle, playlistID: '..' }));
  assert.throws(() => devicePhaseArguments('arm', { deviceID: udid, bundleID: 'com.evil.app' }));
  assert.throws(() => devicePhaseArguments('unknown', { deviceID: udid, bundleID: bundle }));
});
test('Linux cannot create a supposed physical iPhone QA session', async () => {
  await assert.rejects(runIPhonePhase({ phase: 'arm', platform: 'linux' }), /REAL_IPHONE_REQUIRED/);
});
test('a fake devicectl integration exercises physical-device check and actual launch args', async () => {
  const root = mkdtempSync(join(tmpdir(), 'mp3-iphone-qa-mock-'));
  const priorPath = process.env.PATH, priorLog = process.env.MP3_DEVICE_QA_LOG;
  const priorReality = process.env.MP3_DEVICE_QA_REALITY;
  try {
    const repo = join(root, 'repo'), bin = join(root, 'bin');
    mkdirSync(repo); mkdirSync(bin);
    execFileSync('git', ['init', '-q', repo]);
    writeFileSync(join(repo, 'README'), 'test\n');
    execFileSync('git', ['-C', repo, '-c', 'user.name=Test', '-c', 'user.email=qa@example.test', 'add', 'README']);
    execFileSync('git', ['-C', repo, '-c', 'user.name=Test', '-c', 'user.email=qa@example.test', 'commit', '-qm', 'fixture']);
    const sha = execFileSync('git', ['-C', repo, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
    const tool = join(bin, 'xcrun'), logged = join(root, 'launch.json');
    writeFileSync(tool, [
      '#!/usr/bin/env node',
      "const fs = require('node:fs'); const args = process.argv.slice(2);",
      "if (args[1] === 'list') { const file = args[args.indexOf('--json-output')+1];",
      "fs.writeFileSync(file, JSON.stringify({result:{devices:[{identifier:'" + udid + "', properties:{",
      "hardware:{udid:'" + udid + "',platform:'iOS',reality:process.env.MP3_DEVICE_QA_REALITY||'physical',productType:'iPhone16,2'},",
      "connection:{pairingState:'paired'}}}]}}));",
      "} else if (args[1] === 'device') {",
      "fs.writeFileSync(process.env.MP3_DEVICE_QA_LOG, JSON.stringify(args));",
      "} else process.exit(3);"
    ].join('\n') + '\n');
    chmodSync(tool, 0o700);
    process.env.PATH = bin + ':' + priorPath;
    process.env.MP3_DEVICE_QA_LOG = logged;
    const arm = await runIPhonePhase({ phase: 'arm', deviceID: udid, bundleID: bundle, sha, cwd: repo, platform: 'darwin' });
    assert.equal(arm.physicalAcceptance, 'INCOMPLETE');
    assert(readFileSync(logged, 'utf8').includes('--mp3shelf-qa-arm'));
    const off = await runIPhonePhase({ phase: 'offline', deviceID: udid, bundleID: bundle, sha, playlistID: playlist, cwd: repo, platform: 'darwin' });
    assert.equal(off.offlinePlayback, 'NOT_VERIFIED');
    assert(JSON.parse(readFileSync(logged, 'utf8')).includes(playlist));
    rmSync(logged);
    process.env.MP3_DEVICE_QA_REALITY = 'simulated';
    await assert.rejects(runIPhonePhase({ phase: 'arm', deviceID: udid, bundleID: bundle, sha, cwd: repo, platform: 'darwin' }), /physical/i);
    assert.equal(existsSync(logged), false);
  } finally {
    process.env.PATH = priorPath;
    if (priorLog === undefined) delete process.env.MP3_DEVICE_QA_LOG;
    else process.env.MP3_DEVICE_QA_LOG = priorLog;
    if (priorReality === undefined) delete process.env.MP3_DEVICE_QA_REALITY;
    else process.env.MP3_DEVICE_QA_REALITY = priorReality;
    rmSync(root, { recursive: true, force: true });
  }
});
