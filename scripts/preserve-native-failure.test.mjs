import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, symlinkSync, rmSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { failureEvidencePlan, preserveNativeFailure } from './preserve-native-failure.mjs';
const SHA = 'a'.repeat(40);
const digest = value => createHash('sha256').update(value).digest('hex');
function fixture() {
  const home=mkdtempSync(join(tmpdir(),'shelf-native-failure-test-'));
  const worktree=join(home,'worktree'),output=join(home,'output');
  const out=join(worktree,'ios','build','local-release');
  const runs=join(out,'runs');
  const first='20261116T111111Z-123', second='20261116T111112Z-124';
  mkdirSync(join(runs,first),{recursive:true});
  mkdirSync(join(runs,second),{recursive:true});
  mkdirSync(output);
  writeFileSync(join(out,'QA_RECORD.md'),'FAIL second pass\n');
  writeFileSync(join(runs,first,'playlist-parser-compile.log'),'Swift source error\n');
  writeFileSync(join(runs,first,'QA_RECORD.md'),'FAIL first pass\n');
  writeFileSync(join(runs,second,'simulator-debug.log'),'Xcode build error\n');
  writeFileSync(join(runs,second,'QA_RECORD.md'),'FAIL retry\n');
  return {home,worktree,output,runs,first,second};
}
test('source failure plan preserves both attempts and refuses traversal',()=>{
  const chosen=failureEvidencePlan({runs:['20261116T111111Z-123','20261116T111112Z-124'],sourceSHA:SHA});
  assert.deepEqual(chosen.map(x=>x.prefix),['run-1','run-2']);
  for(const name of ['../../foo','not-an-xcode-run','20261116T111111Z-123/path'])
    assert.throws(()=>failureEvidencePlan({runs:[name],sourceSHA:SHA}));
  assert.throws(()=>failureEvidencePlan({runs:['20261116T111111Z-123'],sourceSHA:'bad'}));
  assert.throws(()=>failureEvidencePlan({runs:['20261116T111111Z-123','20261116T111111Z-123'],sourceSHA:SHA}));
});
test('every failing native suite log and QA report is copied with source-bound checksums',()=>{
  const f=fixture();
  try{
    const r=preserveNativeFailure({worktree:f.worktree,output:f.output,sourceSHA:SHA});
    assert.equal(r.result,'FAILED_NATIVE_RUN_NOT_RELEASE_APPROVED');
    assert.equal(r.attempts,2);
    assert.equal(r.preserved.length,5);
    const firstLog=r.preserved.find(x=>x.file==='run-1-playlist-parser-compile.log');
    assert(firstLog);
    assert.equal(firstLog.sha256,digest('Swift source error\n'));
    assert(readFileSync(join(f.output,'failed-native-steps',firstLog.file),'utf8').includes('Swift source error'));
    assert.equal(JSON.parse(readFileSync(join(f.output,'failed-native-steps','failure-evidence.json'),'utf8')).sourceSHA,SHA);
  }finally{rmSync(f.home,{recursive:true,force:true});}
});
test('preservation never copies symlinks, source files, secrets or unexpected logs',()=>{
 const f=fixture();
 try{
   const first=join(f.runs,f.first);
   writeFileSync(join(first,'README.swift'),'private source code');
   writeFileSync(join(first,'private.env'),'SECRET=private');
   symlinkSync(join(first,'playlist-parser-compile.log'),join(first,'linked.log'));
   const r=preserveNativeFailure({worktree:f.worktree,output:f.output,sourceSHA:SHA});
   assert(!r.preserved.some(x=>x.file.includes('linked')||x.file.includes('private')||x.file.endsWith('.swift')));
   assert(!readdirSync(join(f.output,'failed-native-steps')).some(x=>x.endsWith('.env')||x.endsWith('.swift')));
 }finally{rmSync(f.home,{recursive:true,force:true});}
});
test('missing native run directories remain blocked evidence, never a native PASS',()=>{
 const f=fixture();
 try{
   rmSync(f.runs,{recursive:true,force:true});
   const r=preserveNativeFailure({worktree:f.worktree,output:f.output,sourceSHA:SHA});
   assert.equal(r.result,'FAILED_NATIVE_RUN_NOT_RELEASE_APPROVED');
   assert.equal(r.attempts,0);
   assert.equal(r.preserved.length,1);
 }finally{rmSync(f.home,{recursive:true,force:true});}
});

test('oversized native compiler logs preserve their last bounded bytes and truthful truncation',()=>{
 const f=fixture();
 try {
   const full=Buffer.alloc(5*1024*1024, 65);
   full.write('FINAL SWIFT COMPILER FAILURE',full.length-35,'utf8');
   writeFileSync(join(f.runs,f.first,'playlist-parser-compile.log'),full);
   const snapshot=preserveNativeFailure({worktree:f.worktree,output:f.output,sourceSHA:SHA});
   const entry=snapshot.preserved.find(x=>x.file==='run-1-playlist-parser-compile.log');
   assert(entry);
   assert.equal(entry.originalBytes,5*1024*1024);
   assert.equal(entry.bytes,4*1024*1024);
   assert.equal(entry.truncated,true);
   assert.equal(snapshot.truncated,true);
   assert(readFileSync(join(f.output,'failed-native-steps',entry.file)).includes('FINAL SWIFT COMPILER FAILURE'));
 } finally {rmSync(f.home,{recursive:true,force:true});}
});
