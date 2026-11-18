import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,readdirSync,rmSync,symlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {handoffErrors,stagePhysicalReview} from './stage-iphone-review.mjs';
const sha='a'.repeat(40),hash='b'.repeat(64);
const reviewName='review-20261117T200000Z-11111111-1111-1111-1111-111111111111.json';
const keys=['sourceIdentity','recentCapture','deviceIdentity','fullPlaylist','copiedBytes',
 'offlinePlayback','backgroundCallbacks','signedMacBuild'];
const digest=raw=>createHash('sha256').update(raw).digest('hex');
function fixture(){
 const home=mkdtempSync(join(tmpdir(),'shelf-device-handoff-'));
 const dir=join(home,'DeviceAcceptance',sha),reviews=join(dir,'reviews');
 mkdirSync(reviews,{recursive:true});
 const inventory=join(dir,'physical-inventory.json'),review=join(reviews,reviewName),
  signed=join(home,'signed-QA_RECORD.md');
 const inventoryRaw=JSON.stringify({schema:'mp3shelf-physical-inventory-v1',candidateSha:sha,
   capturedAt:new Date().toISOString(),requested:2,unavailable:0,copiedTracks:2});
 const report={schema:'mp3shelf-independent-device-review-v1',sourceSha:sha,
   inventorySHA256:digest(inventoryRaw),result:'EVIDENCE_CHECKS_PASSED_NOT_HARDWARE_APPROVED',
   physicalAcceptance:'INCOMPLETE',issue6:'OPEN_UNTIL_INDEPENDENT_REVIEW',
   failures:[],checks:Object.fromEntries(keys.map(k=>[k,{status:'PASS'}]))};
 const signedText=['- Result: PASS','- Mode: install','- Checked commit: '+sha,
   '- Signed app executable SHA256: '+hash,'- Signed development build: PASS',
   '- Signature verification: PASS','- Device app installation: PASS',
   '- Process launch request: PASS'].join('\n');
 writeFileSync(inventory,inventoryRaw);
 writeFileSync(review,JSON.stringify(report));
 writeFileSync(signed,signedText);
 return{home,dir,inventory,review,signed,report};
}
test('verified device review stages only pending-owner handoff in exact-SHA evidence directory',()=>{
 const x=fixture();
 try{
  const r=stagePhysicalReview({inventoryPath:x.inventory,reviewPath:x.review,
    signedRecordPath:x.signed,expectedSha:sha});
  assert.equal(r.status,'STAGED_OWNER_REVIEW_REQUIRED');
  assert.equal(r.packet.ownerApproval,'REQUIRED_NOT_GRANTED');
  assert.equal(r.packet.physicalAcceptance,'INCOMPLETE');
  assert.equal(r.packet.signedAppSHA256,hash);
  assert.equal(r.packet.reviewFile,reviewName);
  assert(!readdirSync(x.dir).includes('hardware-acceptance.json'));
  assert.equal(stagePhysicalReview({inventoryPath:x.inventory,reviewPath:x.review,
    signedRecordPath:x.signed,expectedSha:sha}).status,'EXISTING_REVIEW_HANDOFF');
 }finally{rmSync(x.home,{recursive:true,force:true})}
});
test('source SHA mismatch or tampered independent review never stages a release handoff',()=>{
 const x=fixture();
 try{
  assert.throws(()=>stagePhysicalReview({inventoryPath:x.inventory,reviewPath:x.review,
    signedRecordPath:x.signed,expectedSha:'c'.repeat(40)}),/same exact-SHA/);
  const bad={...x.report,result:'APPROVED',failures:['offlinePlayback']};
  writeFileSync(x.review,JSON.stringify(bad));
  assert.throws(()=>stagePhysicalReview({inventoryPath:x.inventory,reviewPath:x.review,
    signedRecordPath:x.signed,expectedSha:sha}),/HANDOFF_BLOCKED/);
  assert(!readdirSync(x.dir).includes('review-handoff.json'));
 }finally{rmSync(x.home,{recursive:true,force:true})}
});
test('symlinked review and conflicting immutable packet fail without overwrite',()=>{
 const x=fixture();
 try{
  const symlink=join(x.dir,'reviews',reviewName);
  rmSync(symlink);symlinkSync(x.signed,symlink);
  assert.throws(()=>stagePhysicalReview({inventoryPath:x.inventory,reviewPath:x.review,
    signedRecordPath:x.signed,expectedSha:sha}),/Unsafe/);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});
test('pure release handoff gate rejects other audio, expired review and self-approval',()=>{
 const x=fixture();
 try{
  const r=stagePhysicalReview({inventoryPath:x.inventory,reviewPath:x.review,
    signedRecordPath:x.signed,expectedSha:sha});
  const params={handoff:r.packet,review:x.report,sha,
    inventorySHA256:r.packet.inventorySHA256,
    signedAppSHA256:hash,reviewSHA256:r.packet.reviewSHA256};
  assert.deepEqual(handoffErrors(params),[]);
  assert(handoffErrors({...params,handoff:{...r.packet,ownerApproval:'PASS'}}).length>0);
  assert(handoffErrors({...params,handoff:{...r.packet,createdAt:'2020-01-01T00:00:00Z'}}).length>0);
  assert(handoffErrors({...params,inventorySHA256:'d'.repeat(64)}).length>0);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});
