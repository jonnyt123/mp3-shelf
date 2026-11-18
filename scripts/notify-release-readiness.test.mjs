import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync,mkdirSync,rmSync,readFileSync,writeFileSync,symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { normalizedGateState,notificationChanges,notificationMessage,
 deliverChangeOnlyNotification } from './notify-release-readiness.mjs';
const names=['source','agent','native','playlist','playback','review','hardware','smoke','zip'];
const sha='a'.repeat(40),tooling='b'.repeat(40);
const now=Date.parse('2026-11-17T23:00:00Z');
function model(overrides={}){
 return {schema:'mp3shelf-release-readiness-v1',
  generatedAt:new Date(now).toISOString(),candidateSha:sha,toolingSha:tooling,
  gates:names.map(key=>({key,status:overrides[key]??'UNVERIFIED'}))};
}
function dir(){
 const home=mkdtempSync(join(tmpdir(),'shelf-notifications-'));
 const path=join(home,'Library','Logs','MP3Shelf','ReleaseReadiness');
 mkdirSync(path,{recursive:true});
 return {home,path,latest:join(path,'latest.json'),state:join(path,'notification-state.json')};
}
test('first run saves a quiet baseline; identical hourly runs never notify',()=>{
 const x=dir(),sent=[];
 try{
  writeFileSync(x.latest,JSON.stringify(model()));
  const initial=deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
   send:s=>sent.push(s)});
  assert.equal(initial.status,'BASELINE_SAVED');
  assert.equal(sent.length,0);
  const repeat=deliverChangeOnlyNotification({home:x.home,now:now+1000,platform:'darwin',
   send:s=>sent.push(s)});
  assert.equal(repeat.status,'NO_CHANGE');
  assert.equal(sent.length,0);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});
test('only newly cleared gates and new blockers produce one compact macOS notification',()=>{
 const x=dir(),sent=[];
 try{
  writeFileSync(x.latest,JSON.stringify(model({agent:'PASS',native:'PASS'})));
  deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',send:s=>sent.push(s)});
  writeFileSync(x.latest,JSON.stringify(model({agent:'BLOCKED',native:'PASS',
   playlist:'PASS',review:'BLOCKED'})));
  const first=deliverChangeOnlyNotification({home:x.home,now:now+1000,platform:'darwin',
   send:s=>sent.push(s)});
  assert.equal(first.status,'CHANGE_NOTIFIED');
  assert.deepEqual(first.cleared,['playlist']);
  assert.deepEqual(first.blocked,['agent','review']);
  assert.equal(sent.length,1);
  assert(sent[0].includes('Passed: playlist'));
  assert(sent[0].includes('Needs review: Mac agent'));
  deliverChangeOnlyNotification({home:x.home,now:now+2000,platform:'darwin',
   send:s=>sent.push(s)});
  assert.equal(sent.length,1);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});
test('new native source or release tooling commit resets baseline without stale PASS claims',()=>{
 const older=normalizedGateState(model({native:'PASS'}),{now});
 const newer=normalizedGateState({...model(),candidateSha:'c'.repeat(40)},{now});
 const diff=notificationChanges(older,newer);
 assert.equal(diff.baseline,true);
 assert.equal(notificationMessage(diff),null);
 const other=normalizedGateState({...model(),toolingSha:'d'.repeat(40)},{now});
 assert.equal(notificationChanges(older,other).baseline,true);
});
test('invalid or stale readiness snapshots never generate notifications',()=>{
 const x=dir();
 try{
  writeFileSync(x.latest,JSON.stringify({...model(),generatedAt:'2020-01-01T00:00:00Z'}));
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
   send:()=>{throw Error('MUST_NOT_SEND')}}),/expired/);
  writeFileSync(x.latest,JSON.stringify({...model(),gates:[{key:'zip',status:'PASS'}]}));
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
   send:()=>{throw Error('MUST_NOT_SEND')}}),/malformed|identity/);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});
test('if Notification Center fails, do not mark a change delivered; retry once next run',()=>{
 const x=dir(),sent=[];
 try{
  writeFileSync(x.latest,JSON.stringify(model()));
  deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',send:()=>{}});
  writeFileSync(x.latest,JSON.stringify(model({hardware:'BLOCKED'})));
  await assert.rejects(async()=>deliverChangeOnlyNotification({
   home:x.home,now,platform:'darwin',send:()=>{throw Error('macOS UI offline')}}),/macOS UI offline/);
  const after=deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
    send:s=>sent.push(s)});
  assert.equal(after.status,'CHANGE_NOTIFIED');
  assert.equal(sent.length,1);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});
test('notification state cannot replace a symlink or escape the local evidence directory',()=>{
 const x=dir();
 try{
  const external=join(x.home,'untouched.txt');
  writeFileSync(external,'untouched');
  writeFileSync(x.latest,JSON.stringify(model()));
  symlinkSync(external,x.state);
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
    send:()=>{}}),/redirected/);
  assert.equal(readFileSync(external,'utf8'),'untouched');
 }finally{rmSync(x.home,{recursive:true,force:true})}
});
