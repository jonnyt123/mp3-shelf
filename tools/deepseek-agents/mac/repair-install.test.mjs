import test from "node:test";
import assert from "node:assert/strict";
import {safeRepairPlan,expectedPlist} from "./repair-install.mjs";
import {diagnoseSnapshot} from "./diagnose-install.mjs";

function healthy(overrides={}) {
  const services = {
    "com.mp3shelf.cloud-coordinator":{plist:true,loaded:true},
    "com.mp3shelf.cloudqa":{plist:true,loaded:true},
    "com.mp3shelf.publisher":{plist:true,loaded:true},
    "com.mp3shelf.cloudqa.reporter":{plist:true,loaded:true}
  };
  return {platform:"darwin",repoOk:true,branchOk:true,gitOk:true,nodeOk:true,
    openCodeOk:true,xcodeOk:true,tokenFile:true,tokenPermissions:true,tokenFormat:true,
    credentialFile:true,credentialPermissions:true,credentialFormat:true,tokenMatches:true,
    cloudStatus:200,cloudPaused:true,deepSeekStatus:200,deepSeekAvailable:true,macOnline:true,
    services,logCodes:[],...overrides};
}
function actions(s){return safeRepairPlan(diagnoseSnapshot(s),s);}
test("healthy setup never mutates anything",()=>{
  assert.deepEqual(actions(healthy()),[]);
});
test("unsafe token and credentials can be restricted without reading them",()=>{
  const s=healthy({tokenPermissions:false,tokenFormat:undefined,credentialPermissions:false});
  const ids=actions(s).map(x=>x.id);
  assert.ok(ids.includes("restrict-token"));
  assert.ok(ids.includes("restrict-credentials"));
  assert.ok(!ids.some(x=>x.includes("install")));
});
test("stale or missing secrets are never regenerated or rotated without user approval",()=>{
  const s=healthy({tokenFile:false,credentialFile:false,cloudStatus:401,tokenMatches:false});
  assert.deepEqual(actions(s),[]);
});
test("only verified paused Cloudflare permits restoring an existing Mac coordinator service",()=>{
  const s=healthy();
  s.services["com.mp3shelf.cloud-coordinator"]={plist:true,loaded:false};
  assert.deepEqual(actions(s).map(x=>x.id),["restore-com.mp3shelf.cloud-coordinator"]);
  for(const part of [{cloudPaused:false},{cloudPaused:null},{cloudStatus:401},
    {tokenMatches:false},{nodeOk:false},{openCodeOk:false},{xcodeOk:false}]){
    assert.deepEqual(actions({...s,...part}),[]);
  }
});
test("missing launchdaemons never trigger root or sudo repair",()=>{
  const s=healthy();
  s.services["com.mp3shelf.publisher"]={plist:false,loaded:false};
  s.services["com.mp3shelf.cloudqa.reporter"]={plist:true,loaded:false};
  assert.deepEqual(actions(s),[]);
});
test("must exactly match expected launchd program arguments",()=>{
  const root="/Users/test/MP3ShelfAgents";
  // Pure matching: only test rejected cases, avoiding test-machine-specific paths.
  assert.equal(expectedPlist("com.mp3shelf.cloud-coordinator",{Label:"com.mp3shelf.cloud-coordinator",
    RunAtLoad:true,ProgramArguments:["/bin/sh","-c","curl bad.example"]}),false);
  assert.equal(expectedPlist("com.mp3shelf.cloudqa",{Label:"com.mp3shelf.cloudqa",
    RunAtLoad:true,ProgramArguments:["/bin/bash",root+"/bad.sh"]}),false);
  assert.equal(expectedPlist("com.mp3shelf.publisher",{Label:"com.mp3shelf.publisher",
    RunAtLoad:true,ProgramArguments:["/bin/bash","/tmp/any"]}),false);
});
test("non-Mac environment refuses all automated repairs",()=>{
  const s=healthy({platform:"linux",tokenPermissions:false});
  assert.deepEqual(actions(s),[]);
});
