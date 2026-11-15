import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { nativePackageGate, packageNativeXcode } from './package-verified-native.mjs';
const base = 'a'.repeat(40), sha = 'b'.repeat(40), hash = 'c'.repeat(64);
const names = ['playback-order','playback-interruptions','downloaded-audio-signature',
  'downloaded-audio-format','playlist-parser','lyrics-parser','authorized-audio-sources',
  'catalog-retry-policy','catalog-origin-safety','downloader-policy-runtime',
  'discovery-resume','portable-backup','recording-matching-core',
  'recording-matcher','simulator-debug','simulator-release','iphoneos-arm64-release'];
const labels = ['Signing / installation','Offline playback',
  'Background licensed downloads','Failure handling','Spotify metadata integration',
  'Portable backup interoperability','Accessible responsive UI','Policy/source audit',
  'Final acceptance'];
const keys = ['signingInstallation','offlinePlayback','backgroundDownloads',
  'failureHandling','spotifyMetadata','backupInterop','accessibility',
  'sourcePolicy','finalAcceptance'];
function fixture() {
  const receipt = { mode: 'native',candidateSha:sha, status:'local-checks-passed',
    cleanCheckout:true, exitCode:0,
    steps:[{name:'native-local-release',success:true},
      {name:'post-native-checkout-integrity',success:true}] };
  const qa = [
    '- Checked commit: ' + sha, '- Source provenance: repository HEAD',
    '- Uncommitted changes: no', '- Mode: all',
    '- Simulator smoke requested: false', '- Overall execution: PASS',
    '- Exit status: 0', '- Failure reason: none',
    '- Completed checks: ' + names.join(' '),
    '- Apple signing / physical iPhone acceptance: NOT TESTED',
    '- GitHub Actions used: NO'
  ].join('\n');
  const inventory = { schema:'mp3shelf-physical-inventory-v1',candidateSha:sha,
    device:{productType:'iPhone14,7'}, copiedTracks:2,
    offlinePlaybackAfterRestart:'APP_INSTRUMENTED_PHYSICAL_PASS',
    backgroundTransfer:'APP_RECORDED_STAGING_AND_BACKGROUND_WAKE',
    files:[{sha256:hash,bytes:4096},{sha256:hash,bytes:4096}] };
  const hardware = {
    schema:'mp3shelf-hardware-acceptance-v1',
    candidateSha:sha, installedSourceSha:sha,
    signedAppSHA256:hash, inventorySHA256:hash,
    reviewer:'jonnyt123', reviewedAt:new Date().toISOString(),
    deviceModel:'iPhone 14', iOSVersion:'26.0',
    checks:Object.fromEntries(keys.map(key=>[key,'PASS']))
  };
  const issue = {number:6,state:'closed',
    body:labels.map(x=>'- [x] **'+x+':** Passed on exact candidate').join('\n') };
  const comments = [{user:{login:'jonnyt123'},body:'MP3SHELF_DEVICE_GATE_APPROVED SHA='+sha+' INVENTORY_SHA256='+hash}];
  const pr = {number:29,state:'open',draft:true,
    head:{sha,ref:'feat/ios-consolidated-candidate',repo:{full_name:'jonnyt123/mp3-shelf'}},
    base:{ref:'fix/ios-download-finalization-and-conversion',repo:{full_name:'jonnyt123/mp3-shelf'}}};
  return {sha,base,receipt,qa,inventory,inventoryHash:hash,hardware,issue,comments,pr};
}
test('complete synthetic policy fixture can satisfy validation but is not release proof',()=>{
  assert.deepEqual(nativePackageGate(fixture()),[]);
});
test('physical-iPhone issue must have all nine checks and be closed',()=>{
  const open=fixture();open.issue.state='open';
  assert(nativePackageGate(open).some(e=>e.includes('issue #6')));
  const partial=fixture();partial.issue.body=partial.issue.body.replace('- [x] **Offline playback','- [ ] **Offline playback');
  assert(nativePackageGate(partial).some(e=>e.includes('issue #6')));
});
test('manual exact-commit owner approval cannot be substituted by untrusted comment',()=>{
  const d=fixture();d.comments[0].user.login='unknown';
  assert(nativePackageGate(d).some(e=>e.includes('owner-issued')));
  const stale=fixture();stale.comments[0].body=stale.comments[0].body.replace(sha,base);
  assert(nativePackageGate(stale).some(e=>e.includes('owner-issued')));
});
test('native builds and hardware must independently match staged SHA',()=>{
  for (const change of [
    x=>{x.receipt.candidateSha=base;},
    x=>{x.qa=x.qa.replace('iphoneos-arm64-release','not-built');},
    x=>{x.hardware.installedSourceSha=base;},
    x=>{x.inventory.candidateSha=base;},
    x=>{x.pr.head.sha=base;}
  ]) {const x=fixture();change(x);assert(nativePackageGate(x).length>0);}
});
test('offline playback, background callback and signed binary are mandatory',()=>{
  for (const change of [
    x=>{x.inventory.offlinePlaybackAfterRestart='NOT_VERIFIED';},
    x=>{x.inventory.backgroundTransfer='NOT_VERIFIED';},
    x=>{x.hardware.signedAppSHA256='unknown';},
    x=>{x.hardware.checks.spotifyMetadata='UNVERIFIED';},
    x=>{x.inventory.copiedTracks=1;}
  ]) {const x=fixture();change(x);assert(nativePackageGate(x).length>0);}
});
test('Linux refuses any actual Xcode ZIP before device and macOS gates',async()=>{
  if (process.platform !== 'darwin')
    await assert.rejects(packageNativeXcode({candidateSha:sha}), /MAC_HARDWARE_GATE_REQUIRED/);
});
