import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { nativePackageGate, hardwareInventoryErrors, packageNativeXcode, fetchAllIssueComments, assertSafeArchiveDestination } from './package-verified-native.mjs';
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
    capturedAt:new Date(Date.now() - 60000).toISOString(),
    device:{ productType:'iPhone14,7', osVersion:'26.0', identifierSha256:hash },
    bundleID:'com.jonnyt.mp3shelf',
    playlistID:'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    source:'Spotify metadata only', requested:2, unavailable:0, copiedTracks:2,
    offlinePlaybackAfterRestart:'APP_INSTRUMENTED_PHYSICAL_PASS',
    backgroundTransfer:'APP_RECORDED_STAGING_AND_BACKGROUND_WAKE',
    files:[
      {trackID:'11111111-1111-1111-1111-111111111111',sha256:hash,bytes:4096},
      {trackID:'22222222-2222-2222-2222-222222222222',sha256:hash,bytes:4096}
    ] };
  const hardware = {
    schema:'mp3shelf-hardware-acceptance-v1',
    candidateSha:sha, installedSourceSha:sha,
    signedAppSHA256:hash, inventorySHA256:hash,
    reviewer:'jonnyt123', reviewedAt:new Date().toISOString(),
    deviceModel:'iPhone14,7', iOSVersion:'26.0',
    checks:Object.fromEntries(keys.map(key=>[key,'PASS']))
  };
  const review={schema:'mp3shelf-independent-device-review-v1',
    sourceSha:sha,inventorySHA256:hash,
    result:'EVIDENCE_CHECKS_PASSED_NOT_HARDWARE_APPROVED',
    physicalAcceptance:'INCOMPLETE',issue6:'OPEN_UNTIL_INDEPENDENT_REVIEW',
    failures:[],checks:Object.fromEntries([
      'sourceIdentity','recentCapture','deviceIdentity','fullPlaylist','copiedBytes',
      'offlinePlayback','backgroundCallbacks','signedMacBuild'
    ].map(key=>[key,{status:'PASS'}]))};
  const reviewSHA256=hash;
  const reviewHandoff={schema:'mp3shelf-physical-review-handoff-v1',
    candidateSha:sha,createdAt:new Date().toISOString(),
    reviewFile:'review-20261117T200000Z-11111111-1111-1111-1111-111111111111.json',
    inventorySHA256:hash,reviewSHA256:hash,signedAppSHA256:hash,
    signedBinaryProvenance:'SIGNED_MAC_BUILD_ONLY',
    physicalAcceptance:'INCOMPLETE',ownerApproval:'REQUIRED_NOT_GRANTED'};
  const issue = {number:6,state:'closed',
    body:labels.map(x=>'- [x] **'+x+':** Passed on exact candidate').join('\n') };
  const comments = [{user:{login:'jonnyt123'},body:'MP3SHELF_DEVICE_GATE_APPROVED SHA='+sha+' INVENTORY_SHA256='+hash+' SIGNED_APP_SHA256='+hash}];
  const pr = {number:29,state:'open',draft:true,
    head:{sha,ref:'feat/ios-consolidated-candidate',repo:{full_name:'jonnyt123/mp3-shelf'}},
    base:{ref:'fix/ios-download-finalization-and-conversion',repo:{full_name:'jonnyt123/mp3-shelf'}}};
  return {sha,base,receipt,qa,inventory,inventoryHash:hash,hardware,
    review,reviewHandoff,reviewSHA256,issue,comments,pr};
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


test('hardware reviewer must approve the same fresh captured device and exact source playlist', () => {
  const changes = [
    x => { x.inventory.capturedAt = new Date(Date.now() - 10 * 86400000).toISOString(); },
    x => { x.inventory.capturedAt = new Date(Date.now() + 10 * 60000).toISOString(); },
    x => { x.hardware.reviewedAt = new Date(Date.now() - 5 * 60000).toISOString(); },
    x => { x.hardware.deviceModel = 'iPhone14,8'; },
    x => { x.hardware.iOSVersion = '25.0'; },
    x => { x.inventory.bundleID = 'com.another.app'; },
    x => { x.inventory.source = 'not Spotify'; },
    x => { x.inventory.playlistID = 'invalid'; },
    x => { x.inventory.device.identifierSha256 = 'unverified'; },
    x => { x.inventory.requested = 1; },
    x => { x.inventory.unavailable = 4; },
    x => { x.inventory.files[1].trackID = x.inventory.files[0].trackID; },
    x => { x.inventory.files[1].trackID = 'invalid'; }
  ];
  for (const change of changes) {
    const evidence = fixture();
    change(evidence);
    assert(hardwareInventoryErrors(evidence.inventory, evidence.hardware).length > 0);
    assert(nativePackageGate(evidence).length > 0);
  }
});
test('synthetic hardware approval requires full source inventory and current matching iPhone', () => {
  const evidence = fixture();
  assert.deepEqual(hardwareInventoryErrors(evidence.inventory, evidence.hardware), []);
  assert.deepEqual(nativePackageGate(evidence), []);
  evidence.inventory.copiedTracks = 3;
  assert(nativePackageGate(evidence).length > 0);
});


test('owner GitHub approval must bind the actual signed iPhone app digest', () => {
  const x = fixture();
  x.hardware.signedAppSHA256 = 'd'.repeat(64);
  assert(nativePackageGate(x).some(error => error.includes('owner-issued')));
  const altered = fixture();
  altered.comments[0].body = altered.comments[0].body.replace(
    ' SIGNED_APP_SHA256=' + hash, '');
  assert(nativePackageGate(altered).some(error => error.includes('owner-issued')));
});
test('unknown iOS version is not valid physical signing provenance', () => {
  const x = fixture();
  x.inventory.device.osVersion = 'unknown';
  x.hardware.iOSVersion = 'unknown';
  assert(hardwareInventoryErrors(x.inventory, x.hardware).length > 0);
});

test('hardware approval pagination reads owner marker beyond first 100 comments', async () => {
  const calls = [];
  const pages = [
    Array.from({length:100}, (_,i)=>({id:i,user:{login:'other'},body:'not approved'})),
    [{id:101,user:{login:'jonnyt123'},body:'exact owner approval'}]
  ];
  const comments = await fetchAllIssueComments('https://api.github.com/repos/jonnyt123/mp3-shelf/issues/6/comments',
    async url => { calls.push(url); return pages[calls.length-1]; });
  assert.equal(comments.length,101);
  assert.equal(comments[100].body,'exact owner approval');
  assert.match(calls[0],/per_page=100&page=1$/);
  assert.match(calls[1],/per_page=100&page=2$/);
});
test('hardware approval pagination fails closed on malformed and truncated history', async () => {
  await assert.rejects(fetchAllIssueComments('https://example.test/comments',
    async () => ({not:'an array'})), /Malformed/);
  await assert.rejects(fetchAllIssueComments('https://example.test/comments',
    async () => Array.from({length:100},()=>({})), 2), /exceeds bounded/);
  await assert.rejects(fetchAllIssueComments('https://example.test/comments',
    async () => Array.from({length:101},()=>({}))), /Malformed/);
});

test('hardware approval pagination rejects repeated pages and forged record shapes', async () => {
  const first = Array.from({length:100}, (_, i) => ({
    id:i+1, user:{login:'other'}, body:'not approved'
  }));
  await assert.rejects(fetchAllIssueComments('https://example.test/comments',
    async () => first), /repeated GitHub hardware approval comment/);
  for (const bad of [
    {id:1, user:{login:'jonnyt123'}, body:null},
    {id:1, user:null, body:'approval'},
    {id:'1', user:{login:'jonnyt123'}, body:'approval'}
  ]) {
    await assert.rejects(fetchAllIssueComments('https://example.test/comments',
      async () => [bad]), /Malformed or repeated/);
  }
});

test('full-playlist inventory rejects missing, overlapping and fractional accounting', () => {
  for (const change of [
    x => { x.inventory.unavailable = 1; },
    x => { x.inventory.requested = 3; },
    x => { x.inventory.copiedTracks = 1; x.inventory.files.pop(); },
    x => { x.inventory.copiedTracks = 1.5; },
    x => { x.inventory.copiedTracks = -1; }
  ]) {
    const evidence = fixture();
    change(evidence);
    assert(hardwareInventoryErrors(evidence.inventory, evidence.hardware).length > 0);
    assert(nativePackageGate(evidence).length > 0);
  }
  const completeWithUnavailable = fixture();
  completeWithUnavailable.inventory.requested = 3;
  completeWithUnavailable.inventory.unavailable = 1;
  assert.deepEqual(hardwareInventoryErrors(
    completeWithUnavailable.inventory, completeWithUnavailable.hardware), []);
});

test('direct ZIP packager rejects redirected, dangling and file ancestors', () => {
  const root = mkdtempSync(join(homedir(), '.mp3-release-destination-'));
  try {
    const actual = join(root, 'real');
    mkdirSync(actual);
    const link = join(root, 'linked');
    symlinkSync(actual, link, 'dir');
    assert.throws(() => assertSafeArchiveDestination(join(link, 'archive')), /linked or non-directory/);
    const dangling = join(root, 'dangling');
    symlinkSync(join(root, 'missing'), dangling, 'dir');
    assert.throws(() => assertSafeArchiveDestination(join(dangling, 'archive')), /linked or non-directory/);
    const file = join(root, 'ordinary-file');
    writeFileSync(file, 'not a directory');
    assert.throws(() => assertSafeArchiveDestination(join(file, 'archive')), /linked or non-directory/);
    assert.equal(assertSafeArchiveDestination(join(actual, 'new', 'archive')),
      join(actual, 'new', 'archive'));
    assert.throws(() => assertSafeArchiveDestination('/tmp/mp3-shelf-untrusted'), /subdirectory/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});


test('partial Spotify playlist does not satisfy complete offline-archive acceptance', () => {
  const partial = fixture();
  partial.inventory.unavailable = 1;
  partial.inventory.copiedTracks = 1;
  partial.inventory.files = [partial.inventory.files[0]];
  assert(hardwareInventoryErrors(partial.inventory, partial.hardware).length > 0);
  assert(nativePackageGate(partial).length > 0);
  const missing = fixture();
  missing.inventory.unavailable = 0;
  missing.inventory.copiedTracks = 1;
  missing.inventory.files = [missing.inventory.files[0]];
  assert(hardwareInventoryErrors(missing.inventory, missing.hardware).length > 0);
});


test('owner-approved ZIP also requires a separate exact-source independently reviewed iPhone handoff',()=>{
  const missing=fixture(); delete missing.reviewHandoff;
  assert(nativePackageGate(missing).some(e=>e.includes('handoff')||e.includes('hashes')));
  for(const change of [
    x=>{x.reviewHandoff.candidateSha=base;},
    x=>{x.reviewHandoff.inventorySHA256='d'.repeat(64);},
    x=>{x.reviewHandoff.ownerApproval='PASS';},
    x=>{x.reviewHandoff.signedAppSHA256='d'.repeat(64);},
    x=>{x.review.result='NOT_VERIFIED';},
    x=>{x.review.failures.push('offlinePlayback');},
    x=>{x.reviewSHA256='d'.repeat(64);},
    x=>{x.reviewHandoff.createdAt='2020-01-01T00:00:00Z';}
  ]){
    const item=fixture();change(item);
    assert(nativePackageGate(item).length>0);
  }
});
