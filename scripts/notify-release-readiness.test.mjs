import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync,mkdirSync,rmSync,readFileSync,writeFileSync,symlinkSync,openSync,closeSync,unlinkSync,renameSync,existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { normalizedGateState,notificationChanges,notificationMessage,
 deliverChangeOnlyNotification } from './notify-release-readiness.mjs';
const names=['source','agent','native','playlist','playback','review','hardware','smoke','zip'];
const sha='a'.repeat(40),tooling='b'.repeat(40);
const now=Date.parse('2026-11-17T23:00:00Z');
function model(overrides={}){
 return {schema:'mp3shelf-release-readiness-v1',status:'NOT_RELEASE_READY',
  generatedAt:new Date(now).toISOString(),candidateSha:sha,toolingSha:tooling,
  gates:names.map(key=>({key,status:overrides[key]??'UNVERIFIED'})),
  blocking:names.filter(key=>(overrides[key]??'UNVERIFIED')!=='PASS')};
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
test('native source changes reset baseline; new tooling invalidating smoke triggers one real blocker',()=>{
 const older=normalizedGateState(model({native:'PASS',smoke:'PASS'}),{now});
 const newer=normalizedGateState({...model(),candidateSha:'c'.repeat(40)},{now});
 const diff=notificationChanges(older,newer);
 assert.equal(diff.baseline,true);
 assert.equal(notificationMessage(diff),null);
 const other=normalizedGateState({...model({native:'PASS',smoke:'UNVERIFIED'}),
   toolingSha:'d'.repeat(40)},{now});
 const changed=notificationChanges(older,other);
 assert.equal(changed.baseline,false);
 assert.deepEqual(changed.blocked,['smoke']);
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
  assert.throws(()=>deliverChangeOnlyNotification({
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

test('missing source or tooling identity cannot establish a notification baseline',()=>{
 for(const bad of [{candidateSha:null},{toolingSha:null},
   {candidateSha:'not-a-commit'},{toolingSha:'not-a-commit'}]){
  assert.throws(()=>normalizedGateState({...model(),...bad},{now}),/SHA/);
 }
});
test('redirected notification state fails before any new notification is delivered',()=>{
 const x=dir(),sent=[];
 try{
  writeFileSync(x.latest,JSON.stringify(model()));
  deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',send:s=>sent.push(s)});
  writeFileSync(x.latest,JSON.stringify(model({native:'PASS'})));
  rmSync(x.state);
  const outside=join(x.home,'outside.json');
  writeFileSync(outside,'preserve');
  symlinkSync(outside,x.state);
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
   send:s=>sent.push(s)}),/redirected/);
  assert.deepEqual(sent,[]);
  assert.equal(readFileSync(outside,'utf8'),'preserve');
 }finally{rmSync(x.home,{recursive:true,force:true})}
});

test('future or corrupted previous notification state cannot fabricate a gate transition',()=>{
 const current=normalizedGateState(model({native:'BLOCKED'}),{now});
 const prior=normalizedGateState(model({native:'PASS'}),{now});
 for(const bad of [
  {...prior,updatedAt:new Date(now+60000).toISOString()},
  {...prior,updatedAt:'not-a-date'},
  {...prior,toolingSha:'invalid'},
  {...prior,candidateSha:'invalid'},
  {...prior,gates:{...prior.gates,unknown:'PASS',native:undefined}},
  {...prior,gates:{...prior.gates,extra:'PASS'}},
 ]) {
  const diff=notificationChanges(bad,current);
  assert.equal(diff.baseline,true);
  assert.equal(notificationMessage(diff),null);
 }
});
test('same-source, newer-tooling readiness retains real gate transitions',()=>{
 const prior=normalizedGateState(model({smoke:'PASS'}),{now});
 const current=normalizedGateState({...model({smoke:'BLOCKED'}),toolingSha:'c'.repeat(40),
  generatedAt:new Date(now+1000).toISOString()},{now:now+1000});
 const diff=notificationChanges(prior,current);
 assert.equal(diff.baseline,false);
 assert.deepEqual(diff.blocked,['smoke']);
});

test('tampered advisory readiness cannot generate a false gate-cleared notification',()=>{
 const good=model({native:'PASS',hardware:'BLOCKED'});
 for(const bad of [
  {...good,status:'RELEASE_READY'},
  {...good,blocking:[]},
  {...good,blocking:['hardware','hardware']},
  {...good,blocking:[...good.blocking,'native']},
  {...good,blocking:[...good.blocking,'unknown']},
 ]) assert.throws(()=>normalizedGateState(bad,{now}),/malformed|identity/);
 const accepted=normalizedGateState(good,{now});
 assert.equal(accepted.gates.native,'PASS');
});

test('overlapping notification invocations fail closed without duplicate delivery',()=>{
 const x=dir(),sent=[];
 try{
  writeFileSync(x.latest,JSON.stringify(model()));
  deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',send:s=>sent.push(s)});
  writeFileSync(x.latest,JSON.stringify(model({native:'PASS'})));
  const outcome=deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',send:s=>{
   sent.push(s);
   assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
    send:()=>{throw Error('DUPLICATE_NOTIFICATION')}}),/already in progress/);
  }});
  assert.equal(outcome.status,'CHANGE_NOTIFIED');
  assert.equal(sent.length,1);
  assert.equal(deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
   send:s=>sent.push(s)}).status,'NO_CHANGE');
  assert.equal(sent.length,1);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});
test('failed notification releases the exclusive lock so the next run can retry',()=>{
 const x=dir(),sent=[];
 try{
  writeFileSync(x.latest,JSON.stringify(model()));
  deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',send:()=>{}});
  writeFileSync(x.latest,JSON.stringify(model({native:'BLOCKED'})));
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
   send:()=>{throw Error('temporary UI failure')}}),/temporary UI failure/);
  assert.equal(deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
   send:s=>sent.push(s)}).status,'CHANGE_NOTIFIED');
  assert.equal(sent.length,1);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});

test('a replaced notification lock is never removed by the previous owner',()=>{
 const x=dir(),sent=[],lock=join(x.path,'.notification-state.lock');
 try{
  writeFileSync(x.latest,JSON.stringify(model()));
  deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',send:()=>{}});
  writeFileSync(x.latest,JSON.stringify(model({native:'PASS'})));
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
   send:message=>{
    sent.push(message);
    renameSync(lock,join(x.path,'previous-owner.lock'));
    writeFileSync(lock,'another process owns this lock',{flag:'wx'});
   }}),/NOTIFICATION_LOCK_OWNERSHIP_LOST/);
  assert.equal(sent.length,1);
  assert.equal(readFileSync(lock,'utf8'),'another process owns this lock');
  assert(existsSync(join(x.path,'previous-owner.lock')));
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
   send:()=>{throw Error('DUPLICATE')}}),/already in progress/);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});

test('multi-day Mac agent downtime resets notification baseline without replaying stale blockers',()=>{
 const prior=normalizedGateState(model({native:'PASS',hardware:'PASS'}),{now});
 const after=normalizedGateState({...model({native:'BLOCKED',hardware:'BLOCKED'}),
   generatedAt:new Date(now+25*3600000).toISOString()},{now:now+25*3600000});
 const stale=notificationChanges(prior,after);
 assert.equal(stale.baseline,true);
 assert.equal(notificationMessage(stale),null);
 const recent=normalizedGateState({...model({native:'PASS',hardware:'BLOCKED'}),
   generatedAt:new Date(now+25*3600000+60000).toISOString()},
   {now:now+25*3600000+60000});
 assert.deepEqual(notificationChanges(after,recent).cleared,['native']);
});

test('a blocked gate losing its supporting evidence is an actionable transition',()=>{
 const prior=normalizedGateState(model({native:'BLOCKED',hardware:'BLOCKED'}),{now});
 const current=normalizedGateState({...model({native:'UNVERIFIED',hardware:'UNVERIFIED'}),
  generatedAt:new Date(now+60000).toISOString()},{now:now+60000});
 const change=notificationChanges(prior,current);
 assert.equal(change.baseline,false);
 assert.deepEqual(change.blocked,['native','hardware']);
 assert.match(notificationMessage(change),/Needs review: Xcode build, hardware approval/);
 const repeat=notificationChanges(current,current);
 assert.deepEqual(repeat.blocked,[]);
 assert.equal(notificationMessage(repeat),null);
});
test('a blocked to unverified transition sends once and persists its state',()=>{
 const x=dir(),sent=[];
 try{
  writeFileSync(x.latest,JSON.stringify(model({native:'BLOCKED'})));
  deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',send:s=>sent.push(s)});
  writeFileSync(x.latest,JSON.stringify(model({native:'UNVERIFIED'})));
  const changed=deliverChangeOnlyNotification({home:x.home,now:now+1000,
   platform:'darwin',send:s=>sent.push(s)});
  assert.equal(changed.status,'CHANGE_NOTIFIED');
  assert.deepEqual(changed.blocked,['native']);
  assert.equal(sent.length,1);
  assert.equal(deliverChangeOnlyNotification({home:x.home,now:now+2000,
   platform:'darwin',send:s=>sent.push(s)}).status,'NO_CHANGE');
  assert.equal(sent.length,1);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});

test('regression alerts prioritize all actionable blockers without truncating names',()=>{
 const diff={baseline:false,cleared:['source','agent','native','playlist','playback','review','hardware','smoke','zip'],
  blocked:['source','agent','native','playlist','playback','review','hardware','smoke','zip']};
 const message=notificationMessage(diff);
 assert(message.startsWith('Needs review: native source, Mac agent, Xcode build'));
 assert(message.includes(' +4 more'));
 assert(message.includes('Passed: native source, Mac agent, Xcode build, playlist +5 more'));
 assert(message.length<=235);
 assert(!message.endsWith(','));
});

test('a notification with only many blockers retains its complete summary',()=>{
 const diff={baseline:false,cleared:[],
  blocked:['source','agent','native','playlist','playback','review','hardware','smoke','zip']};
 const message=notificationMessage(diff);
 assert.match(message,/Needs review: native source, Mac agent, Xcode build, playlist, offline playback \+4 more/);
 assert(message.length<=235);
});

test('symlinked readiness evidence never establishes a baseline or delivers an alert',()=>{
 const x=dir(),sent=[];
 try{
  const outside=join(x.home,'external-evidence.json');
  writeFileSync(outside,JSON.stringify(model({native:'PASS'})));
  symlinkSync(outside,x.latest);
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now,
   platform:'darwin',send:s=>sent.push(s)}),/Missing latest/);
  assert.deepEqual(sent,[]);
  assert.equal(existsSync(x.state),false);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});
test('oversized and nonregular readiness evidence fail closed without state changes',()=>{
 const x=dir(),sent=[];
 try{
  writeFileSync(x.latest,' '.repeat(128*1024+1));
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now,
   platform:'darwin',send:s=>sent.push(s)}),/Missing latest/);
  rmSync(x.latest);
  mkdirSync(x.latest);
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now,
   platform:'darwin',send:s=>sent.push(s)}),/Missing latest/);
  assert.deepEqual(sent,[]);
  assert.equal(existsSync(x.state),false);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});

test('a growing readiness snapshot is rejected rather than trusting its prefix',()=>{
 const x=dir(),sent=[];
 try{
  const base=JSON.stringify(model());
  writeFileSync(x.latest,base);
  assert.equal(deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
   send:m=>sent.push(m)}).status,'BASELINE_SAVED');
  // A complete JSON prefix followed by bytes is not a valid evidence record.
  // The bounded reader must not treat only the original prefix as authoritative.
  writeFileSync(x.latest,base+'\\n'+JSON.stringify(model({native:'PASS'})));
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now:now+1000,
   platform:'darwin',send:m=>sent.push(m)}),/Missing latest/);
  assert.deepEqual(sent,[]);
  assert.equal(JSON.parse(readFileSync(x.state,'utf8')).gates.native,'UNVERIFIED');
 }finally{rmSync(x.home,{recursive:true,force:true})}
});

test('contradictory all-PASS advisory readiness cannot announce a release all-clear',()=>{
 const x=dir(),sent=[];
 try{
  writeFileSync(x.latest,JSON.stringify(model({native:'BLOCKED'})));
  deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',send:s=>sent.push(s)});
  const allPass=Object.fromEntries(names.map(key=>[key,'PASS']));
  writeFileSync(x.latest,JSON.stringify(model(allPass)));
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now:now+1000,
   platform:'darwin',send:s=>sent.push(s)}),/identity or status/);
  assert.deepEqual(sent,[]);
  assert.equal(JSON.parse(readFileSync(x.state,'utf8')).gates.native,'BLOCKED');
  // A subsequent legitimate partial recovery remains observable.
  writeFileSync(x.latest,JSON.stringify(model({native:'PASS',hardware:'BLOCKED'})));
  const result=deliverChangeOnlyNotification({home:x.home,now:now+2000,
   platform:'darwin',send:s=>sent.push(s)});
  assert.equal(result.status,'CHANGE_NOTIFIED');
  assert.deepEqual(result.cleared,['native']);
  assert.equal(sent.length,1);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});

test('out-of-order readiness snapshots cannot roll back the alert watermark',()=>{
 const x=dir(),sent=[];
 try{
  const later=new Date(now+60000).toISOString();
  writeFileSync(x.latest,JSON.stringify({...model({native:'PASS'}),generatedAt:later}));
  assert.equal(deliverChangeOnlyNotification({home:x.home,now:now+60000,
   platform:'darwin',send:m=>sent.push(m)}).status,'BASELINE_SAVED');
  const saved=readFileSync(x.state,'utf8');
  // An older, valid snapshot arrives after the newer one was already seen.
  writeFileSync(x.latest,JSON.stringify(model({native:'BLOCKED'})));
  assert.throws(()=>deliverChangeOnlyNotification({home:x.home,now:now+61000,
   platform:'darwin',send:m=>sent.push(m)}),/STALE_READINESS_SNAPSHOT/);
  assert.equal(readFileSync(x.state,'utf8'),saved);
  assert.deepEqual(sent,[]);
  // Once the producer catches up, a real later transition is still delivered.
  writeFileSync(x.latest,JSON.stringify({...model({native:'BLOCKED'}),
   generatedAt:new Date(now+120000).toISOString()}));
  const changed=deliverChangeOnlyNotification({home:x.home,now:now+120000,
   platform:'darwin',send:m=>sent.push(m)});
  assert.equal(changed.status,'CHANGE_NOTIFIED');
  assert.deepEqual(changed.blocked,['native']);
  assert.equal(sent.length,1);
  assert.equal(deliverChangeOnlyNotification({home:x.home,now:now+120001,
   platform:'darwin',send:m=>sent.push(m)}).status,'NO_CHANGE');
  assert.equal(sent.length,1);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});

test('tooling SHA change resets notification baseline without hiding subsequent regressions',()=>{
 const x=dir(),sent=[];
 try{
  const first=model({native:'BLOCKED'});
  writeFileSync(x.latest,JSON.stringify(first));
  assert.equal(deliverChangeOnlyNotification({home:x.home,now,platform:'darwin',
   send:m=>sent.push(m)}).status,'BASELINE_SAVED');
  const newTooling='f'.repeat(40);
  const next={...model({native:'PASS',hardware:'BLOCKED'}),
   toolingSha:newTooling,generatedAt:new Date(now+60000).toISOString()};
  writeFileSync(x.latest,JSON.stringify(next));
  const reset=deliverChangeOnlyNotification({home:x.home,now:now+60000,
   platform:'darwin',send:m=>sent.push(m)});
  assert.equal(reset.status,'BASELINE_SAVED');
  assert.deepEqual(sent,[]);
  assert.equal(JSON.parse(readFileSync(x.state,'utf8')).toolingSha,newTooling);
  const regression={...model({native:'BLOCKED',hardware:'BLOCKED'}),
   toolingSha:newTooling,generatedAt:new Date(now+120000).toISOString()};
  writeFileSync(x.latest,JSON.stringify(regression));
  const changed=deliverChangeOnlyNotification({home:x.home,now:now+120000,
   platform:'darwin',send:m=>sent.push(m)});
  assert.equal(changed.status,'CHANGE_NOTIFIED');
  assert.deepEqual(changed.blocked,['native']);
  assert.equal(sent.length,1);
 }finally{rmSync(x.home,{recursive:true,force:true})}
});
