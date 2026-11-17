import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { independentlyReviewDevice, writeIndependentDeviceReview } from './review-iphone-evidence.mjs';
const sha='a'.repeat(40),hash='b'.repeat(64),id='11111111-1111-1111-1111-111111111111';
const data=()=>({schema:'mp3shelf-physical-inventory-v1',
  candidateSha:sha,capturedAt:new Date().toISOString(),
  device:{productType:'iPhone14,7',osVersion:'26.0',identifierSha256:hash},
  bundleID:'com.jonnyt.mp3shelf',requested:2,copiedTracks:2,unavailable:0,
  fileByteIntegrity:'HOST_HASHED_FROM_PHYSICAL_IPHONE',
  offlinePlaybackAfterRestart:'APP_INSTRUMENTED_PHYSICAL_PASS',
  backgroundTransfer:'APP_RECORDED_STAGING_AND_BACKGROUND_WAKE',
  files:[{trackID:id,sha256:hash,bytes:9000},
    {trackID:'22222222-2222-2222-2222-222222222222',sha256:hash,bytes:12000}]});
const receipt=[
 '- Result: PASS','- Mode: install','- Checked commit: '+sha,
 '- Signed app executable SHA256: '+hash,'- Signature verification: PASS',
 '- Device app installation: PASS','- Process launch request: PASS'
].join('\n');
test('complete synthetic physical receipts produce review-only status, never hardware approval',()=>{
 const r=independentlyReviewDevice({inventory:data(),signedRecord:receipt,
   inventorySHA256:hash,expectedSha:sha});
 assert.equal(r.result,'EVIDENCE_CHECKS_PASSED_NOT_HARDWARE_APPROVED');
 assert.equal(r.physicalAcceptance,'INCOMPLETE');
 assert.equal(r.issue6,'OPEN_UNTIL_INDEPENDENT_REVIEW');
 assert.equal(r.unresolved.installedOnDeviceBinary,'NOT_INDEPENDENTLY_HASH_VERIFIED');
 assert.deepEqual(r.failures,[]);
});
test('missing audio, offline playback, background callbacks and signed provenance are separate blockers',()=>{
 const base=data();
 base.files.pop();
 base.copiedTracks=1;
 base.backgroundTransfer='NOT_VERIFIED';
 base.offlinePlaybackAfterRestart='NOT_VERIFIED';
 const review=independentlyReviewDevice({inventory:base,signedRecord:'- Result: FAIL',expectedSha:sha});
 assert.equal(review.result,'COLLECTED_EVIDENCE_INCOMPLETE');
 for(const key of ['fullPlaylist','copiedBytes','offlinePlayback','backgroundCallbacks','signedMacBuild'])
   assert(review.failures.includes(key));
});
test('wrong SHA, stale session, duplicate audio and incorrect iPhone model reject evidence',()=>{
 const base=data();
 base.capturedAt='2020-01-01T01:00:00Z';
 base.files[1].trackID=base.files[0].trackID;
 base.device.productType='Simulator';
 const review=independentlyReviewDevice({inventory:base,signedRecord:receipt,
   expectedSha:'c'.repeat(40)});
 for(const key of ['sourceIdentity','recentCapture','deviceIdentity','fullPlaylist','signedMacBuild'])
   assert(review.failures.includes(key));
 assert.equal(review.sourceSha,null);
});
test('review writes a unique private file and leaves signed record and inventory unchanged',()=>{
 const root=mkdtempSync(join(tmpdir(),'mp3shelf-review-'));
 try{
  const file=join(root,'physical-inventory.json'),sign=join(root,'signed-QA.md');
  const original=JSON.stringify(data());
  writeFileSync(file,original);
  writeFileSync(sign,receipt);
  const first=writeIndependentDeviceReview({inventoryPath:file,signedRecordPath:sign,expectedSha:sha});
  const second=writeIndependentDeviceReview({inventoryPath:file,signedRecordPath:sign,expectedSha:sha});
  assert.notEqual(first.path,second.path);
  assert.equal(readFileSync(file,'utf8'),original);
  const saved=JSON.parse(readFileSync(first.path,'utf8'));
  assert.equal(saved.result,'EVIDENCE_CHECKS_PASSED_NOT_HARDWARE_APPROVED');
  assert.equal(saved.inventorySHA256.length,64);
 }finally{rmSync(root,{recursive:true,force:true});}
});
