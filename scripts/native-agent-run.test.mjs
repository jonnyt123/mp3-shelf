import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync, symlinkSync, renameSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { nativeAgentRunRecord, executeNativeAgent } from './native-agent-run.mjs';
const sha='a'.repeat(40);
test('real native integration remains distinct from hardware approval',()=>{
 const record=nativeAgentRunRecord({startedAt:'2026-11-16T00:00:00Z',finishedAt:'2026-11-16T01:00:00Z',
   result:{candidateSha:sha,integration:'staged-draft-only',packaging:'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE'}});
 assert.equal(record.status,'BLOCKED');
 assert.equal(record.integration,'staged-draft-only');
 assert.equal(record.packaging,'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE');
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
   assert.equal(success.status,'BLOCKED');
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

test('status directory symlinks fail closed without modifying outside files',async()=>{
 const home=mkdtempSync(join(tmpdir(),'mp3-shelf-agent-parent-'));
 try{
  const outside=join(home,'outside');
  mkdirSync(join(home,'Library'),{recursive:true});
  mkdirSync(outside);
  writeFileSync(join(outside,'sentinel'),'preserve');
  symlinkSync(outside,join(home,'Library','Logs'));
  await assert.rejects(executeNativeAgent({home,root:home,
   run:async()=>({status:'already-staged',sha})}),/directory was redirected/);
  assert.equal(readFileSync(join(outside,'sentinel'),'utf8'),'preserve');
 }finally{rmSync(home,{recursive:true,force:true});}
});

test('overlapping hourly invocations cannot execute the native cycle twice',async()=>{
 const home=mkdtempSync(join(tmpdir(),'mp3-agent-overlap-'));
 let started=0, release;
 try{
  const hold=new Promise(resolve=>{release=resolve});
  const first=executeNativeAgent({home,root:home,run:async()=>{
   started++;await hold;return {status:'already-staged',sha};
  }});
  // The first invocation synchronously creates its exclusive lock before
  // yielding to the injected asynchronous native runner.
  await assert.rejects(executeNativeAgent({home,root:home,run:async()=>{
   started++;return {status:'already-staged',sha};
  }}),/NATIVE_CYCLE_ALREADY_RUNNING/);
  assert.equal(started,1);
  release();
  await first;
  assert.equal(started,1);
  const next=await executeNativeAgent({home,root:home,run:async()=>{
   started++;return {status:'already-staged',sha};
  }});
  assert.equal(next.status,'BLOCKED');
  assert.equal(started,2);
 }finally{release?.();rmSync(home,{recursive:true,force:true});}
});
test('existing lock refuses execution without clobbering the prior receipt',async()=>{
 const home=mkdtempSync(join(tmpdir(),'mp3-agent-lock-'));
 try{
  const dir=join(home,'Library','Logs','MP3Shelf','NativeAgent');
  mkdirSync(dir,{recursive:true});
  writeFileSync(join(dir,'native-cycle.lock'),'prior process');
  writeFileSync(join(dir,'latest-run.json'),'prior receipt');
  let ran=false;
  await assert.rejects(executeNativeAgent({home,root:home,run:async()=>{
   ran=true;return {status:'already-staged',sha};
  }}),/NATIVE_CYCLE_ALREADY_RUNNING/);
  assert.equal(ran,false);
  assert.equal(readFileSync(join(dir,'latest-run.json'),'utf8'),'prior receipt');
 }finally{rmSync(home,{recursive:true,force:true});}
});

test('delivery and packaging claims require a recognized integration and exact candidate SHA',()=>{
 const base={startedAt:'2026-11-17T00:00:00Z',finishedAt:'2026-11-17T00:01:00Z'};
 const forged=nativeAgentRunRecord({...base,result:{
   status:'blocked',candidateSha:sha,delivery:'DELIVERED_VERIFIED_XCODE_ZIP',
   packaging:'READY_FOR_PUBLIC_RELEASE'}});
 assert.equal(forged.delivery,'NOT_VERIFIED');
 assert.equal(forged.packaging,'NOT_VERIFIED');
 const missingSha=nativeAgentRunRecord({...base,result:{
   status:'already-staged',delivery:'ALREADY_DELIVERED'}});
 assert.equal(missingSha.delivery,'NOT_VERIFIED');
 const failed=nativeAgentRunRecord({...base,error:Error('release failed'),result:{
   status:'already-staged',candidateSha:sha,delivery:'ALREADY_DELIVERED'}});
 assert.equal(failed.delivery,'NOT_VERIFIED');
 const eligible=nativeAgentRunRecord({...base,result:{
   status:'already-staged',candidateSha:sha,delivery:'ALREADY_DELIVERED',
   packaging:'EXISTING_VERIFIED_ARCHIVE',sha256:'b'.repeat(64),
   downloadURL:'https://github.com/jonnyt123/mp3-shelf/releases/download/mp3-shelf-ios-'+sha+'/MP3-Shelf-Xcode-'+sha.slice(0,12)+'.zip'}});
 assert.equal(eligible.delivery,'ALREADY_DELIVERED');
 assert.equal(eligible.packaging,'EXISTING_VERIFIED_ARCHIVE');
});

test('agent rejects conflicting exact source identities rather than claiming staging or delivery',()=>{
 const base={startedAt:'2026-11-17T00:00:00Z',finishedAt:'2026-11-17T00:01:00Z'};
 const conflict=nativeAgentRunRecord({...base,result:{
   status:'already-staged',candidateSha:sha,sha:'b'.repeat(40),
   delivery:'ALREADY_DELIVERED'}});
 assert.equal(conflict.status,'BLOCKED');
 assert.equal(conflict.candidateSha,null);
 assert.equal(conflict.integration,'NOT_VERIFIED');
 assert.equal(conflict.delivery,'NOT_VERIFIED');
 const malformed=nativeAgentRunRecord({...base,result:{
   status:'already-staged',candidateSha:'not-a-commit',sha,
   delivery:'ALREADY_DELIVERED'}});
 assert.equal(malformed.status,'BLOCKED');
 assert.equal(malformed.delivery,'NOT_VERIFIED');
 const missing=nativeAgentRunRecord({...base,result:{status:'already-staged'}});
 assert.equal(missing.status,'BLOCKED');
 assert.equal(missing.integration,'NOT_VERIFIED');
 const consistent=nativeAgentRunRecord({...base,result:{
   status:'already-staged',candidateSha:sha,sha,delivery:'ALREADY_DELIVERED',
   packaging:'EXISTING_VERIFIED_ARCHIVE',sha256:'b'.repeat(64),
   downloadURL:'https://github.com/jonnyt123/mp3-shelf/releases/download/mp3-shelf-ios-'+sha+'/MP3-Shelf-Xcode-'+sha.slice(0,12)+'.zip'}});
 assert.equal(consistent.status,'COMPLETED');
 assert.equal(consistent.delivery,'ALREADY_DELIVERED');
});

test('contradictory cycle outcomes never become a completed agent receipt',()=>{
 const base={startedAt:'2026-11-17T00:00:00Z',finishedAt:'2026-11-17T00:01:00Z'};
 for(const status of ['blocked','FAILED','not-staged']){
  const record=nativeAgentRunRecord({...base,result:{
   candidateSha:sha,status,integration:'staged-draft-only',
   delivery:'ALREADY_DELIVERED'}});
  assert.equal(record.status,'BLOCKED');
  assert.equal(record.candidateSha,null);
  assert.equal(record.delivery,'NOT_VERIFIED');
 }
 const legitimate=nativeAgentRunRecord({...base,result:{
  candidateSha:sha,status:'already-staged',integration:'staged-draft-only'}});
 assert.equal(legitimate.status,'BLOCKED');
});
test('malformed or reversed run timestamps cannot claim fresh integration',()=>{
 for(const [startedAt,finishedAt] of [
  ['invalid','2026-11-17T00:01:00Z'],
  ['2026-11-17T00:02:00Z','2026-11-17T00:01:00Z'],
  ['2026-11-17T00:00:00Z','invalid']]){
  const record=nativeAgentRunRecord({startedAt,finishedAt,
   result:{candidateSha:sha,status:'already-staged',delivery:'ALREADY_DELIVERED'}});
  assert.equal(record.status,'BLOCKED');
  assert.equal(record.candidateSha,null);
  assert.equal(record.delivery,'NOT_VERIFIED');
 }
});

test('published ZIP receipts require consistent packaging, hash and canonical download URL',()=>{
 const base={startedAt:'2026-11-17T00:00:00Z',finishedAt:'2026-11-17T00:01:00Z'};
 const valid={status:'already-staged',candidateSha:sha,
  packaging:'EXISTING_VERIFIED_ARCHIVE',delivery:'ALREADY_DELIVERED',
  sha256:'c'.repeat(64),
  downloadURL:'https://github.com/jonnyt123/mp3-shelf/releases/download/mp3-shelf-ios-'+sha+'/MP3-Shelf-Xcode-'+sha.slice(0,12)+'.zip'};
 assert.equal(nativeAgentRunRecord({...base,result:valid}).delivery,'ALREADY_DELIVERED');
 for(const changes of [
  {packaging:'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE'},
  {packaging:'NOT_VERIFIED'},
  {sha256:'invalid'},
  {downloadURL:'https://attacker.example/MP3-Shelf.zip'},
  {downloadURL:'https://github.com/jonnyt123/mp3-shelf/releases/download/mp3-shelf-ios-'+sha+'/MP3-Shelf-Xcode-'+sha.slice(0,12)+'.zip?token=private'},
  {downloadURL:'https://github.com/jonnyt123/mp3-shelf/releases/download/mp3-shelf-ios-'+sha+'/MP3-Shelf-Xcode-'+sha.slice(0,12)+'.zip#fragment'},
  {downloadURL:'https://github.com/jonnyt123/mp3-shelf/releases/download/mp3-shelf-ios-'+('b'.repeat(40))+'/MP3-Shelf-Xcode-'+sha.slice(0,12)+'.zip'},
  {downloadURL:'https://github.com/jonnyt123/mp3-shelf/releases/download/mp3-shelf-ios-'+sha+'/wrong.zip'},
  {downloadURL:'https://github.com/jonnyt123/mp3-shelf/releases/download/mp3-shelf-ios-'+sha+'/MP3-Shelf-Xcode-'+sha.slice(0,12)+'.zip/'},
  {delivery:'PUBLISHED'}]){
  const record=nativeAgentRunRecord({...base,result:{...valid,...changes}});
  assert.equal(record.delivery,'NOT_VERIFIED',JSON.stringify(changes));
  assert.equal(record.xcodeVerification,'NOT_VERIFIED');
 }
});

test('staged draft remains visible but incomplete hardware and unsafe output block the agent cycle',()=>{
 const base={startedAt:'2026-11-18T00:00:00Z',finishedAt:'2026-11-18T00:01:00Z'};
 for(const packaging of ['BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE',
   'INCOMPLETE_OUTPUT_REQUIRES_REVIEW','BLOCKED_UNSAFE_OUTPUT_DESTINATION']){
  const record=nativeAgentRunRecord({...base,result:{candidateSha:sha,
   integration:'already-staged',packaging}});
  assert.equal(record.status,'BLOCKED',packaging);
  assert.equal(record.integration,'already-staged');
  assert.equal(record.packaging,packaging);
  assert.equal(record.delivery,'NOT_VERIFIED');
  assert.equal(record.xcodeVerification,'NOT_VERIFIED');
 }
 const complete=nativeAgentRunRecord({...base,result:{candidateSha:sha,
  integration:'already-staged'}});
 assert.equal(complete.status,'BLOCKED');
});

test('successful staging without verified ZIP remains blocked even if packaging is unknown',()=>{
 const base={startedAt:'2026-11-18T00:00:00Z',finishedAt:'2026-11-18T00:01:00Z'};
 for(const packaging of [undefined,'EXISTING_VERIFIED_ARCHIVE','PACKAGED_VERIFIED_NATIVE_SOURCE','untrusted']){
  const result={candidateSha:sha,integration:'already-staged',packaging};
  const record=nativeAgentRunRecord({...base,result});
  assert.equal(record.status,'BLOCKED');
  assert.equal(record.delivery,'NOT_VERIFIED');
 }
});

test('replacement lock survives first runner cleanup and prevents overlapping execution',async()=>{
 const home=mkdtempSync(join(tmpdir(),'mp3-agent-replaced-lock-'));
 const dir=join(home,'Library','Logs','MP3Shelf','NativeAgent');
 let release;
 try {
  const hold=new Promise(resolve=>{release=resolve;});
  const first=executeNativeAgent({home,root:home,run:async()=>{
   await hold;
   return {status:'already-staged',sha};
  }});
  const lock=join(dir,'native-cycle.lock');
  const old=join(dir,'old-native-cycle.lock');
  renameSync(lock,old);
  writeFileSync(lock,'another runner owns this lock');
  release();
  await assert.rejects(first,/NATIVE_CYCLE_LOCK_OWNERSHIP_LOST/);
  assert.equal(readFileSync(lock,'utf8'),'another runner owns this lock');
  await assert.rejects(executeNativeAgent({home,root:home,run:async()=>{
   throw Error('must not execute');
  }}),/NATIVE_CYCLE_ALREADY_RUNNING/);
  assert.equal(existsSync(old),true);
 }finally {release?.();rmSync(home,{recursive:true,force:true});}
});

test('missing lock is never silently recreated or treated as successful cleanup',async()=>{
 const home=mkdtempSync(join(tmpdir(),'mp3-agent-missing-lock-'));
 let release;
 try {
  const hold=new Promise(resolve=>{release=resolve;});
  const first=executeNativeAgent({home,root:home,run:async()=>{
   await hold;return {status:'already-staged',sha};
  }});
  const lock=join(home,'Library','Logs','MP3Shelf','NativeAgent','native-cycle.lock');
  renameSync(lock,lock+'.moved');
  release();
  await assert.rejects(first,/NATIVE_CYCLE_LOCK_OWNERSHIP_LOST/);
  assert.equal(existsSync(lock),false);
 }finally {release?.();rmSync(home,{recursive:true,force:true});}
});
