import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { nativeAgentRunRecord, executeNativeAgent } from './native-agent-run.mjs';
const sha='a'.repeat(40);
test('real native integration remains distinct from hardware approval',()=>{
 const record=nativeAgentRunRecord({startedAt:'2026-11-16T00:00:00Z',finishedAt:'2026-11-16T01:00:00Z',
   result:{candidateSha:sha,integration:'staged-draft-only',packaging:'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE'}});
 assert.equal(record.status,'COMPLETED');
 assert.equal(record.candidateSha,sha);
 assert.equal(record.xcodeVerification,'NOT_VERIFIED');
 assert.equal(record.physicalIPhoneAcceptance,'REQUIRES_SEPARATE_REAL_DEVICE_REVIEW');
});
test('error statuses never claim native Xcode or iPhone passed',()=>{
 const record=nativeAgentRunRecord({startedAt:'2026-11-16T00:00:00Z',finishedAt:'2026-11-16T00:01:00Z',
   error:new Error('/Users/Private/Xcode/secret failure')});
 assert.equal(record.status,'FAILED');
 assert.equal(record.xcodeVerification,'NOT_VERIFIED');
 assert.equal(record.failureReason,'NATIVE_CYCLE_FAILED_REVIEW_LOCAL_LOGS');
 assert(!record.failureReason.includes('/Users/'));
});
test('runner writes atomically updated local success and failure receipts without touching GitHub Actions',async()=>{
 const home=mkdtempSync(join(tmpdir(),'mp3-shelf-agent-test-'));
 let iteration=0;
 try{
   const path=join(home,'Library','Logs','MP3Shelf','NativeAgent','latest-run.json');
   const success=await executeNativeAgent({home,root:home,now:()=>new Date('2026-11-16T00:01:00Z'),
     run:async()=>{iteration++;return{status:'already-staged',sha}}});
   assert.equal(success.status,'COMPLETED');
   assert.equal(JSON.parse(readFileSync(path,'utf8')).candidateSha,sha);
   await assert.rejects(executeNativeAgent({home,root:home,now:()=>new Date('2026-11-16T00:02:00Z'),
     run:async()=>{iteration++;throw Error('real native failure')}}),/real native failure/);
   assert.equal(iteration,2);
   const failure=JSON.parse(readFileSync(path,'utf8'));
   assert.equal(failure.status,'FAILED');
   assert.equal(failure.xcodeVerification,'NOT_VERIFIED');
   assert.equal(failure.githubActions,'NOT_INVOKED');
 }finally{rmSync(home,{recursive:true,force:true});}
});
test('native run status cannot be written through symlinked latest receipt',async()=>{
 const home=mkdtempSync(join(tmpdir(),'mp3-shelf-agent-safe-'));
 try{
   const dir=join(home,'Library','Logs','MP3Shelf','NativeAgent');
   mkdirSync(dir,{recursive:true});
   const outside=join(home,'original.txt');
   writeFileSync(outside,'private data');
   symlinkSync(outside,join(dir,'latest-run.json'));
   await assert.rejects(executeNativeAgent({home,root:home,
     run:async()=>({status:'already-staged',sha})}),/redirected/);
   assert.equal(readFileSync(outside,'utf8'),'private data');
 }finally{rmSync(home,{recursive:true,force:true});}
});

test('untrusted cycle metadata cannot forge native receipt, delivery or leak secrets',()=>{
 const record=nativeAgentRunRecord({startedAt:'2026-11-16T00:00:00Z',finishedAt:'2026-11-16T00:01:00Z',
   result:{status:'verified-not-staged',candidateSha:sha,delivery:'PUBLISHED',
     integration:'unexpected-success',packaging:'unsafe private message'}});
 assert.equal(record.status,'BLOCKED');
 assert.equal(record.xcodeVerification,'NOT_VERIFIED');
 assert.equal(record.integration,'NOT_VERIFIED');
 assert.equal(record.delivery,'NOT_VERIFIED');
 assert.equal(record.packaging,'NOT_VERIFIED');
 const failed=nativeAgentRunRecord({startedAt:'2026-11-16T00:00:00Z',finishedAt:'2026-11-16T00:01:00Z',
   error:Error('token=ghp_SECRET /Users/private/playlist.mp3')});
 assert(!JSON.stringify(failed).includes('ghp_SECRET'));
 assert(!JSON.stringify(failed).includes('playlist.mp3'));
});
