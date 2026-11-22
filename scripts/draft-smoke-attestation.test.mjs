import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { smokeAttestationLine, verifiedSmokeComment } from './draft-smoke-attestation.mjs';
const toolingSha = 'a'.repeat(40),zipSHA256='b'.repeat(64),manifestSHA256='c'.repeat(64);
const tagAt=Date.now()-15*60*1000;
const tag='mp3shelf-upload-smoke-'+toolingSha.slice(0,12)+'-'+tagAt+'-abcdef';
function comment(now=Date.now()) {
 return { id:123, user:{login:'jonnyt123'},
   created_at:new Date(now-10*60*1000).toISOString(),
   body:smokeAttestationLine({toolingSha,tag,zipSHA256,manifestSHA256}) };
}
test('exact authenticated owner GitHub attestation validates a deleted draft ZIP byte check',()=>{
 const sample=comment();
 assert.equal(verifiedSmokeComment(sample,toolingSha).tag,tag);
 assert.equal(verifiedSmokeComment(sample,toolingSha).zipSHA256,zipSHA256);
});
test('no other author, stale tool commit or altered tag may satisfy release gate',()=>{
 const c=comment();
 assert.equal(verifiedSmokeComment({...c,user:{login:'other'}},toolingSha),null);
 assert.equal(verifiedSmokeComment(c,'d'.repeat(40)),null);
 assert.equal(verifiedSmokeComment({...c,body:c.body.replace(tag,'another-tag')},toolingSha),null);
 assert.throws(()=>smokeAttestationLine({toolingSha:'bad',tag,zipSHA256,manifestSHA256}));
});
test('old or future GitHub comment does not allow a new release',()=>{
 const now=Date.now(),c=comment(now);
 assert.equal(verifiedSmokeComment({...c,created_at:new Date(now-8*86400000).toISOString()},
   toolingSha,now),null);
 assert.equal(verifiedSmokeComment({...c,created_at:new Date(now+10*60000).toISOString()},
   toolingSha,now),null);
});
test('attestation must be exact single line with both real SHA256 asset digests',()=>{
 const c=comment();
 for(const body of [c.body+'\nMP3SHELF_DEVICE_GATE_APPROVED',c.body.replace(zipSHA256,'0'.repeat(64)),
   c.body.replace('RESULT=UPLOAD_DOWNLOAD_VERIFIED_AND_CLEANED','RESULT=UPLOAD_REQUESTED'),
   c.body.replace(manifestSHA256, 'NOT_VERIFIED')]) {
   assert.equal(verifiedSmokeComment({...c,body},toolingSha),null);
 }
});

test('edited old smoke tag cannot be reused with a fresh owner comment',()=>{
 const now=Date.now(),c=comment(now);
 const oldTag='mp3shelf-upload-smoke-'+toolingSha.slice(0,12)+'-'+(now-9*86400000)+'-abcdef';
 assert.equal(verifiedSmokeComment({...c,body:c.body.replace(tag,oldTag)},toolingSha,now),null);
});
test('future and mismatched upload timestamps cannot authorize a release',()=>{
 const now=Date.now(),c=comment(now);
 for(const at of [now+3600000,now-2*86400000,Number.MAX_SAFE_INTEGER]){
  const changed='mp3shelf-upload-smoke-'+toolingSha.slice(0,12)+'-'+at+'-abcdef';
  assert.equal(verifiedSmokeComment({...c,body:c.body.replace(tag,changed)},toolingSha,now),null);
 }
});
test('a genuine recent smoke tag with a delayed owner attestation remains valid',()=>{
 const now=Date.now();
 const validTag='mp3shelf-upload-smoke-'+toolingSha.slice(0,12)+'-'+(now-20*3600000)+'-abcdef';
 const c={...comment(now),created_at:new Date(now-1000).toISOString()};
 assert.equal(verifiedSmokeComment({...c,body:c.body.replace(tag,validTag)},toolingSha,now)?.tag,validTag);
});
