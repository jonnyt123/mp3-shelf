import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync, linkSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { runNativeReleaseCycle, selectNativeEvidence } from './native-release-cycle.mjs';
const sha = 'a'.repeat(40);
function fixture() {
  const home = mkdtempSync(join(tmpdir(), 'mp3-native-cycle-'));
  const native = join(home, 'Library', 'Logs', 'MP3Shelf', 'NativePreflight', sha, '2026-11-15T120000Z');
  const device = join(home, 'Library', 'Logs', 'MP3Shelf', 'DeviceAcceptance', sha);
  mkdirSync(native, { recursive: true });
  mkdirSync(device, { recursive: true });
  for (const file of ['native-baseline.json','native-QA_RECORD.md','local-evidence.json',
    'native-local-release.log','post-native-checkout-integrity.log'])
    writeFileSync(join(native, file), 'fixture\n');
  return { home, native, device };
}
test('only a complete SHA-bound native receipt directory may be selected', () => {
  const f = fixture();
  try {
    assert.equal(selectNativeEvidence(join(f.home, 'Library/Logs/MP3Shelf/NativePreflight'), sha), f.native);
    assert.equal(selectNativeEvidence(join(f.home, 'Library/Logs/MP3Shelf/NativePreflight'), 'bad'), null);
    rmSync(join(f.native, 'local-evidence.json'));
    assert.equal(selectNativeEvidence(join(f.home, 'Library/Logs/MP3Shelf/NativePreflight'), sha), null);
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});
test('automatic cycle never packages while hardware inventory/approval are absent', async () => {
  const f = fixture();
  try {
    let called = false;
    const result = await runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'already-staged', sha }),
      packageProject: async () => { called = true; throw Error('must not package'); } });
    assert.equal(called, false);
    assert.equal(result.packaging, 'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE');
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});
test('packaging is requested only with both evidence files and correct candidate', async () => {
  const f = fixture();
  try {
    writeFileSync(join(f.device, 'physical-inventory.json'), '{}');
    writeFileSync(join(f.device, 'hardware-acceptance.json'), '{}');
    let called = 0;
    const result = await runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'already-staged', sha }),
      packageProject: async options => {
        called++;
        assert.equal(options.candidateSha, sha);
        assert.equal(options.nativeEvidence, f.native);
        assert.equal(options.deviceEvidence, f.device);
        return { status: 'PACKAGED_VERIFIED_NATIVE_SOURCE', archive: 'fixture.zip', archiveSHA256: 'c'.repeat(64) };
      } });
    assert.equal(called, 1);
    assert.equal(result.packaging, 'PACKAGED_VERIFIED_NATIVE_SOURCE');
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});
test('wrong SHA or an existing artifact cannot be treated as freshly packaged', async () => {
  const f = fixture();
  try {
    await assert.rejects(runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'already-staged', sha: 'wrong' }) }), /exact commit/);
    writeFileSync(join(f.device, 'physical-inventory.json'), '{}');
    writeFileSync(join(f.device, 'hardware-acceptance.json'), '{}');
    const output = join(f.home, 'Documents', 'MP3Shelf', 'VerifiedReleases');
    mkdirSync(output, { recursive: true });
    writeFileSync(join(output, 'MP3-Shelf-Xcode-'+sha.slice(0,12)+'.zip'), 'existing');
    const result = await runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'already-staged', sha }),
      packageProject: async () => { throw Error('must not overwrite'); } });
    assert.equal(result.packaging, 'EXISTING_OUTPUT_REQUIRES_HASH_REVIEW');
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});

test('unpromoted native verification cannot authorize packaging', async () => {
  const f = fixture();
  try {
    writeFileSync(join(f.device, 'physical-inventory.json'), '{}');
    writeFileSync(join(f.device, 'hardware-acceptance.json'), '{}');
    await assert.rejects(runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'verified-not-staged', sha, evidence: f.native }),
      packageProject: async () => { throw Error('packager must not run'); }
    }), /did not confirm staging/);
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});

test('outside-SHA evidence path cannot authorize packaging', async () => {
  const f = fixture();
  try {
    const other = join(f.home, 'other-native-receipt');
    mkdirSync(other);
    await assert.rejects(runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'staged-draft-only', sha, evidence: other }),
      packageProject: async () => { throw Error('packager must not run'); }
    }), /exact candidate SHA directory/);
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});

test('symlinked device evidence is blocked before package invocation', async () => {
  const f = fixture();
  try {
    const actual = join(f.home, 'actual-device');
    mkdirSync(actual);
    writeFileSync(join(actual, 'physical-inventory.json'), '{}');
    writeFileSync(join(actual, 'hardware-acceptance.json'), '{}');
    rmSync(f.device, { recursive: true });
    symlinkSync(actual, f.device, 'dir');
    const result = await runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'already-staged', sha }),
      packageProject: async () => { throw Error('packager must not run'); }
    });
    assert.equal(result.packaging, 'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE');
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});

test('symlinked hardware approval is blocked before package invocation', async () => {
  const f = fixture();
  try {
    writeFileSync(join(f.device, 'physical-inventory.json'), '{}');
    const outside = join(f.home, 'approval.json');
    writeFileSync(outside, '{}');
    symlinkSync(outside, join(f.device, 'hardware-acceptance.json'));
    const result = await runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'already-staged', sha }),
      packageProject: async () => { throw Error('packager must not run'); }
    });
    assert.equal(result.packaging, 'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE');
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});

test('hard-linked native evidence cannot be selected or packaged', async () => {
  const f = fixture();
  try {
    const source = join(f.native, 'local-evidence.json');
    const outside = join(f.home, 'linked-evidence.json');
    linkSync(source, outside);
    const root = join(f.home, 'Library/Logs/MP3Shelf/NativePreflight');
    assert.equal(selectNativeEvidence(root, sha), null);
    writeFileSync(join(f.device, 'physical-inventory.json'), '{}');
    writeFileSync(join(f.device, 'hardware-acceptance.json'), '{}');
    const result = await runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'already-staged', sha, evidence: f.native }),
      packageProject: async () => { throw Error('packager must not run'); }
    });
    assert.equal(result.packaging, 'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE');
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});

test('explicit incomplete receipt cannot bypass automatic receipt selection', async () => {
  const f = fixture();
  try {
    rmSync(join(f.native, 'native-local-release.log'));
    writeFileSync(join(f.device, 'physical-inventory.json'), '{}');
    writeFileSync(join(f.device, 'hardware-acceptance.json'), '{}');
    const result = await runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'already-staged', sha, evidence: f.native }),
      packageProject: async () => { throw Error('packager must not run'); }
    });
    assert.equal(result.packaging, 'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE');
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});

test('an explicitly supplied older receipt cannot replace the latest selected receipt', async () => {
  const f = fixture();
  try {
    const older = join(f.home, 'Library/Logs/MP3Shelf/NativePreflight', sha, '2026-11-14T120000Z');
    mkdirSync(older);
    for (const file of ['native-baseline.json', 'native-QA_RECORD.md',
      'local-evidence.json', 'native-local-release.log',
      'post-native-checkout-integrity.log']) writeFileSync(join(older, file), 'old fixture');
    writeFileSync(join(f.device, 'physical-inventory.json'), '{}');
    writeFileSync(join(f.device, 'hardware-acceptance.json'), '{}');
    const result = await runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'already-staged', sha, evidence: older }),
      packageProject: async () => { throw Error('stale receipt must not package'); } });
    assert.equal(result.packaging, 'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE');
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});

test('symlinked DeviceAcceptance ancestor cannot authorize packaging', async () => {
  const f = fixture();
  try {
    writeFileSync(join(f.device, 'physical-inventory.json'), '{}');
    writeFileSync(join(f.device, 'hardware-acceptance.json'), '{}');
    const parent = join(f.home, 'Library/Logs/MP3Shelf/DeviceAcceptance');
    const outside = join(f.home, 'relocated-device-acceptance');
    const { renameSync } = await import('node:fs');
    renameSync(parent, outside);
    symlinkSync(outside, parent, 'dir');
    const result = await runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'already-staged', sha }),
      packageProject: async () => { throw Error('redirected ancestor must not package'); } });
    assert.equal(result.packaging, 'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE');
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});

test('newest incomplete native run blocks stale complete receipt fallback', async () => {
  const f = fixture();
  try {
    const newer = join(f.home, 'Library/Logs/MP3Shelf/NativePreflight', sha, '2026-11-16T120000Z');
    mkdirSync(newer);
    writeFileSync(join(newer, 'native-baseline.json'), '{}');
    const root = join(f.home, 'Library/Logs/MP3Shelf/NativePreflight');
    assert.equal(selectNativeEvidence(root, sha), null);
    writeFileSync(join(f.device, 'physical-inventory.json'), '{}');
    writeFileSync(join(f.device, 'hardware-acceptance.json'), '{}');
    const result = await runNativeReleaseCycle({ home: f.home, repo: f.home,
      preflight: async () => ({ status: 'already-staged', sha }),
      packageProject: async () => { throw Error('older complete receipt must not package'); }
    });
    assert.equal(result.packaging, 'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE');
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});

test('newest redirected native run blocks stale complete receipt fallback', () => {
  const f = fixture();
  try {
    const newer = join(f.home, 'Library/Logs/MP3Shelf/NativePreflight', sha, '2026-11-16T120000Z');
    const outside = join(f.home, 'external-receipt');
    mkdirSync(outside);
    symlinkSync(outside, newer, 'dir');
    const root = join(f.home, 'Library/Logs/MP3Shelf/NativePreflight');
    assert.equal(selectNativeEvidence(root, sha), null);
  } finally { rmSync(f.home, { recursive: true, force: true }); }
});
