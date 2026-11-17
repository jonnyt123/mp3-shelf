import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, linkSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ensureReadinessDestination, writeReadiness, readinessModel } from './release-readiness.mjs';

function fixture(fn) {
 const home=mkdtempSync(join(tmpdir(),'mp3-readiness-'));
 try { return fn(home); } finally { rmSync(home,{recursive:true,force:true}); }
}
test('creates private normal dashboard directory',()=>fixture(home=>{
 const dir=ensureReadinessDestination(home);
 assert.equal(dir,join(home,'Library','Logs','MP3Shelf','ReleaseReadiness'));
}));
test('refuses symlinked parent before writing',()=>fixture(home=>{
 const outside=mkdtempSync(join(tmpdir(),'mp3-outside-'));
 try{
  symlinkSync(outside,join(home,'Library'));
  assert.throws(()=>ensureReadinessDestination(home),/Unsafe release readiness directory/);
 }finally{rmSync(outside,{recursive:true,force:true});}
}));
test('refuses redirected output file and preserves external bytes',()=>fixture(home=>{
 const dir=ensureReadinessDestination(home);
 const external=join(home,'external.txt');
 writeFileSync(external,'untouched');
 symlinkSync(external,join(dir,'latest.json'));
 assert.throws(()=>writeReadiness({home,github:()=>({candidateSha:null,toolingSha:null})}),
  /Unsafe release readiness destination/);
 assert.equal(readFileSync(external,'utf8'),'untouched');
}));
test('refuses hard-linked dashboard output',()=>fixture(home=>{
 const dir=ensureReadinessDestination(home);
 const external=join(home,'external.txt');
 writeFileSync(external,'untouched');
 linkSync(external,join(dir,'latest.md'));
 assert.throws(()=>ensureReadinessDestination(home),/Unsafe release readiness destination/);
 assert.equal(readFileSync(external,'utf8'),'untouched');
}));
test('writes complete JSON, Markdown and HTML on a clean directory',()=>fixture(home=>{
 const result=writeReadiness({home,github:()=>({candidateSha:null,toolingSha:null})});
 assert.equal(result.status,'NOT_RELEASE_READY');
 assert.equal(JSON.parse(readFileSync(result.json,'utf8')).status,'NOT_RELEASE_READY');
 assert.match(readFileSync(result.markdown,'utf8'),/Native Release Readiness/);
 assert.match(readFileSync(result.html,'utf8'),/Release readiness/);
}));

test('native wrapper success cannot impersonate independently verified 17-step Xcode evidence',()=>{
 const sha='a'.repeat(40);
 const native={schemaVersion:1,mode:'native',candidateSha:sha,status:'local-checks-passed',
   exitCode:0,cleanCheckout:true,steps:[{success:true},{success:true}]};
 const model=readinessModel({candidateSha:sha,native});
 const gate=model.gates.find(g=>g.key==='native');
 assert.equal(gate.status,'UNVERIFIED');
 assert.match(gate.details,/not been independently verified/);
 assert.equal(model.status,'NOT_RELEASE_READY');
});
test('missing or mismatched native wrapper remains unverified',()=>{
 const sha='b'.repeat(40);
 for(const native of [null,{schemaVersion:1,mode:'native',candidateSha:'c'.repeat(40),
   status:'local-checks-passed',exitCode:0,cleanCheckout:true,steps:[{success:true},{success:true}]}]){
  const gate=readinessModel({candidateSha:sha,native}).gates.find(g=>g.key==='native');
  assert.equal(gate.status,'UNVERIFIED');
  assert.match(gate.details,/No complete native wrapper summary/);
 }
});
