import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {evaluateAgentHealth} from './mac-agent-health.mjs';
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
  latest:{schema:'mp3shelf-native-agent-run-v1',finishedAt:new Date(now-60000).toISOString(),
    status:'COMPLETED',candidateSha:'a'.repeat(40)},...override};
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
   status:'COMPLETED',finishedAt:'2025-01-01T00:00:00Z'}}));
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
