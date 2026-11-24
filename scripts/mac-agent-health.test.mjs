import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {evaluateAgentHealth,safeJSON} from './mac-agent-health.mjs';
import {mkdtempSync,writeFileSync,symlinkSync,linkSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const root='/Users/example/mp3-shelf';
const node='/opt/homebrew/bin/node';
const plist={Label:'com.jonnyt.mp3shelf.native-preflight',
 ProgramArguments:[node,root+'/scripts/native-agent-run.mjs',root],
 RunAtLoad:true,StartInterval:3600,WorkingDirectory:root};
function sample(override={}){
 const now=Date.parse('2026-11-17T22:00:00Z');
 return {platform:'darwin',node,xcode:'Xcode 26.0\nBuild version ABC',
  developerDir:'/Applications/Xcode.app/Contents/Developer',plist,
  loaded:true,sourceRoot:root,now,
  latest:{schema:'mp3shelf-native-agent-run-v1',startedAt:new Date(now-120000).toISOString(),
    finishedAt:new Date(now-60000).toISOString(),status:'COMPLETED',
    integration:'already-staged',candidateSha:'a'.repeat(40),
    packaging:'EXISTING_VERIFIED_ARCHIVE',delivery:'ALREADY_DELIVERED',
    sha256:'b'.repeat(64),
    downloadURL:'https://github.com/jonnyt123/mp3-shelf/releases/download/mp3-shelf-ios-'+
      'a'.repeat(40)+'/MP3-Shelf-Xcode-'+ 'a'.repeat(12)+'.zip'},...override};
}
test('verified loaded agent and recent Mac receipt distinguish agent health from Xcode success',()=>{
 const h=evaluateAgentHealth(sample());
 assert.equal(h.status,'AGENT_RUNNING_RECENTLY');
 assert.equal(h.repair,'NO_REPAIR_NEEDED');
 assert.equal(h.xcodeBuild,'NOT_ATTESTED_BY_HEALTH_CHECK');
});
test('only precisely-owned missing launchd registration permits safe bootstrap',()=>{
 const h=evaluateAgentHealth(sample({loaded:false}));
 assert.equal(h.repair,'BOOTSTRAP_OWNED_AGENT');
 assert(h.blockers.includes('launchd'));
 for(const p of [{...plist,Label:'unrelated'}, {...plist,StartInterval:60},
  {...plist,ProgramArguments:['/bin/sh','-c','rm']},
  {...plist,WorkingDirectory:'/tmp'}]){
   const u=evaluateAgentHealth(sample({loaded:false,plist:p}));
   assert.equal(u.repair,'RUN_TRUSTED_INSTALLER');
 }
});
test('stale, failed and absent Mac build receipts are not healthy',()=>{
 const old=evaluateAgentHealth(sample({latest:{schema:'mp3shelf-native-agent-run-v1',
   status:'COMPLETED',startedAt:'2025-01-01T00:00:00Z',
   finishedAt:'2025-01-01T00:00:00Z'}}));
 assert(old.blockers.includes('recentRun'));
 const bad=evaluateAgentHealth(sample({latest:{...sample().latest,status:'FAILED'}}));
 assert.equal(bad.status,'NEEDS_ATTENTION');
 assert.equal(bad.agentStatus,'FAILED');
 const noXcode=evaluateAgentHealth(sample({developerDir:'/Library/Developer/CommandLineTools'}));
 assert(noXcode.blockers.includes('xcode'));
});
test('Linux and false scheduling metadata never satisfy physical Mac runner requirements',()=>{
 const x=evaluateAgentHealth(sample({platform:'linux'}));
 assert.equal(x.repair,'REQUIRES_MAC');
 assert.equal(x.status,'NEEDS_ATTENTION');
 const y=evaluateAgentHealth(sample({plist:{...plist,RunAtLoad:false}}));
 assert.equal(y.checks.plist.status,'BLOCKED');
});

test('a fresh but contradictory or unbound receipt cannot claim a healthy Mac agent',()=>{
 const valid=sample().latest;
 const cases=[
  {startedAt:null},
  {startedAt:'2030-01-01T00:00:00Z'},
  {startedAt:new Date(Date.parse(valid.finishedAt)+1000).toISOString()},
  {candidateSha:'not-a-sha'},
  {candidateSha:null},
  {integration:'NOT_VERIFIED'},
  {integration:'already-staged',failureReason:'NATIVE_CYCLE_FAILED_REVIEW_LOCAL_LOGS'},
  {status:'COMPLETED',integration:'NOT_VERIFIED'},
 ];
 for(const change of cases){
  const h=evaluateAgentHealth(sample({latest:{...valid,...change}}));
  assert.equal(h.status,'NEEDS_ATTENTION',JSON.stringify(change));
  assert(h.blockers.includes('recentRun'),JSON.stringify(change));
  assert.equal(h.agentStatus,'NOT_VERIFIED');
 }
});
test('a recent blocked or failed invocation is visible without claiming compilation',()=>{
 for(const status of ['FAILED','BLOCKED']){
  const h=evaluateAgentHealth(sample({latest:{...sample().latest,status,
   integration:'NOT_VERIFIED',candidateSha:null}}));
  assert.equal(h.status,'NEEDS_ATTENTION');
  assert.equal(h.agentStatus,status);
  assert.equal(h.xcodeBuild,'NOT_ATTESTED_BY_HEALTH_CHECK');
 }
});

test('bootstrap-only repair never requires killing a newly launched Xcode job',()=>{
 const h=evaluateAgentHealth(sample({loaded:false}));
 assert.equal(h.repair,'BOOTSTRAP_OWNED_AGENT');
 assert.equal(h.checks.plist.status,'PASS');
 // A newly loaded agent can be running while its first receipt is pending.
 const pending=evaluateAgentHealth(sample({loaded:true,latest:null}));
 assert.equal(pending.repair,'INSPECT_LAUNCHD_LOGS_AND_WAIT_FOR_RECEIPT');
 assert.equal(pending.status,'NEEDS_ATTENTION');
});

test('completed release health requires a canonical SHA-bound archive and published delivery',()=>{
 const valid=sample().latest;
 assert.equal(evaluateAgentHealth(sample()).checks.recentRun.status,'PASS');
 for(const mutation of [
  {delivery:'NOT_VERIFIED'},
  {packaging:'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE'},
  {packaging:'NOT_VERIFIED'},
  {sha256:'not-a-digest'},
  {downloadURL:'https://example.invalid/archive.zip'},
  {downloadURL:valid.downloadURL+'?secret=1'},
  {downloadURL:valid.downloadURL.replace('a'.repeat(40),'c'.repeat(40))},
  {failureReason:'NATIVE_CYCLE_FAILED_REVIEW_LOCAL_LOGS'}
 ]){
  const health=evaluateAgentHealth(sample({latest:{...valid,...mutation}}));
  assert.equal(health.status,'NEEDS_ATTENTION',JSON.stringify(mutation));
  assert(health.blockers.includes('recentRun'),JSON.stringify(mutation));
  assert.equal(health.agentStatus,'NOT_VERIFIED');
 }
});

test('Mac receipt reader rejects redirected, oversized, truncated and hardlinked evidence',()=>{
 const dir=mkdtempSync(join(tmpdir(),'mp3-shelf-health-'));
 try{
  const good=join(dir,'good.json');
  writeFileSync(good,JSON.stringify({schema:'receipt',status:'BLOCKED'}));
  assert.equal(safeJSON(good)?.status,'BLOCKED');
  assert.equal(safeJSON(good,8),null);
  writeFileSync(join(dir,'invalid.json'),'{');
  assert.equal(safeJSON(join(dir,'invalid.json')),null);
  const redirected=join(dir,'redirect.json');
  symlinkSync(good,redirected);
  assert.equal(safeJSON(redirected),null);
  const alias=join(dir,'alias.json');
  linkSync(good,alias);
  assert.equal(safeJSON(good),null);
  assert.equal(safeJSON(alias),null);
  assert.equal(safeJSON(join(dir,'missing.json')),null);
  assert.equal(safeJSON(dir),null);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
