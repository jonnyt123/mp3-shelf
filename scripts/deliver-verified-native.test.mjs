import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { deliveryManifestErrors, releaseAssetsMatch, deliverVerifiedNative }
  from './deliver-verified-native.mjs';

const sha = 'a'.repeat(40), digest = 'b'.repeat(64), binary = 'c'.repeat(64);
const names = ['Signing / installation', 'Offline playback', 'Background licensed downloads',
  'Failure handling', 'Spotify metadata integration', 'Portable backup interoperability',
  'Accessible responsive UI', 'Policy/source audit', 'Final acceptance'];
const zipName = 'MP3-Shelf-Xcode-' + sha.slice(0,12) + '.zip';
const jsonName = 'MP3-Shelf-Xcode-' + sha.slice(0,12) + '.manifest.json';
function fixture() {
  const size = 120000;
  const manifest = {
    schema: 'mp3shelf-verified-xcode-project-v1',
    candidateSha: sha,
    nativeBaselineSha: 'd'.repeat(40),
    archive: zipName, sha256: digest, bytes: size,
    nativeReceiptSha256: digest, deviceEvidenceSha256: digest,
    hardwareApprovalSha256: digest, signedAppSHA256: binary,
    hardwareIssue: 6, hardwareIssueClosed: true,
    buildType: 'Xcode project sources, NOT signed IPA',
    reviewedAt: new Date().toISOString()
  };
  const issue = { number: 6, state: 'closed',
    body: names.map(x => '- [x] **' + x + ':** verified at exact SHA').join('\n') };
  return { sha, manifest, archiveName: zipName, archiveHash: digest,
    bytes: size, deviceIssue: issue, ownerApproved: true };
}
function release() {
  return {
    tag_name: 'mp3-shelf-ios-' + sha, target_commitish: sha, draft: true,
    assets: [
      { name: zipName, digest: 'sha256:' + digest },
      { name: jsonName, digest: 'sha256:' + binary }
    ]
  };
}
test('complete synthetic source and device approval satisfies pure policy, not real hardware', () => {
  assert.deepEqual(deliveryManifestErrors(fixture()), []);
});
test('missing owner approval, open issue or unchecked hardware category blocks delivery', () => {
  const unapproved = fixture(); unapproved.ownerApproved = false;
  assert(deliveryManifestErrors(unapproved).some(x => x.includes('owner approval')));
  const open = fixture(); open.deviceIssue.state = 'open';
  assert(deliveryManifestErrors(open).some(x => x.includes('issue #6')));
  const partial = fixture(); partial.deviceIssue.body = partial.deviceIssue.body.replace(
    '- [x] **Offline playback', '- [ ] **Offline playback');
  assert(deliveryManifestErrors(partial).length > 0);
});
test('wrong ZIP checksum, source, identity, signed app or size cannot publish', () => {
  const mutations = [
    v => { v.sha = 'wrong'; },
    v => { v.manifest.candidateSha = 'd'.repeat(40); },
    v => { v.archiveHash = 'f'.repeat(64); },
    v => { v.manifest.signedAppSHA256 = 'NOT_VERIFIED'; },
    v => { v.manifest.hardwareApprovalSha256 = null; },
    v => { v.manifest.hardwareIssueClosed = false; },
    v => { v.bytes = 100; },
    v => { v.manifest.archive = 'other.zip'; },
    v => { v.manifest.buildType = 'signed IPA'; }
  ];
  for (const mutate of mutations) {
    const evidence = fixture(); mutate(evidence);
    assert(deliveryManifestErrors(evidence).length > 0);
  }
});
test('remote release assets require exact two SHA-256 digests, no duplicates', () => {
  assert.equal(releaseAssetsMatch(release(), zipName, digest, jsonName, binary), true);
  const wrongDigest = release(); wrongDigest.assets[0].digest = 'sha256:' + 'f'.repeat(64);
  assert.equal(releaseAssetsMatch(wrongDigest, zipName, digest, jsonName, binary), false);
  const missingHash = release(); delete missingHash.assets[1].digest;
  assert.equal(releaseAssetsMatch(missingHash, zipName, digest, jsonName, binary), false);
  const duplicated = release(); duplicated.assets[1].name = zipName;
  assert.equal(releaseAssetsMatch(duplicated, zipName, digest, jsonName, binary), false);
  const extra = release(); extra.assets.push({ name: 'unverified.bin', digest: 'sha256:' + digest });
  assert.equal(releaseAssetsMatch(extra, zipName, digest, jsonName, binary), false);
});
test('non-Mac release delivery fails before even reading archive paths', async () => {
  if (process.platform !== 'darwin')
    await assert.rejects(deliverVerifiedNative({ archive: '/not/a/real/zip' }),
      /VERIFIED_MAC_REQUIRED/);
});
