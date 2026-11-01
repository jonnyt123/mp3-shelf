import test from "node:test";
import assert from "node:assert/strict";
import { diagnoseSnapshot, logSignals } from "./diagnose-install.mjs";

function healthy(overrides={}) {
  return {
    platform:"darwin",repoOk:true,branchOk:true,gitOk:true,nodeOk:true,
    openCodeOk:true,xcodeOk:true,
    tokenFile:true,tokenFormat:true,tokenPermissions:true,
    credentialFile:true,credentialPermissions:true,credentialFormat:true,
    tokenMatches:true,cloudStatus:200,cloudPaused:true,
    deepSeekStatus:200,deepSeekAvailable:true,macOnline:true,
    services:{
      "com.mp3shelf.cloud-coordinator":{plist:true,loaded:true},
      "com.mp3shelf.cloudqa":{plist:true,loaded:true},
      "com.mp3shelf.publisher":{plist:true,loaded:true},
      "com.mp3shelf.cloudqa.reporter":{plist:true,loaded:true}
    }, logCodes:[],...overrides
  };
}
test("healthy setup returns safe status but does not pretend a model ran",()=>{
  const out=diagnoseSnapshot(healthy());
  assert.equal(out.ok,true);assert.equal(out.issueCount,0);
  assert.equal(out.observations.cloudPaused,true);
  assert.match(out.safety,/no model request/i);
});
test("missing Mac runner and dependencies are diagnosed separately",()=>{
  const s=healthy({nodeOk:false,openCodeOk:false,xcodeOk:false,macOnline:false});
  s.services["com.mp3shelf.cloud-coordinator"]={plist:false,loaded:false};
  const out=diagnoseSnapshot(s);
  const codes=out.issues.map(x=>x.code);
  for(const v of ["NODE_VERSION","OPENCODE_MISSING","XCODE_NOT_READY","AGENT_NOT_INSTALLED"])assert.ok(codes.includes(v));
  assert.equal(out.ok,false);
});
test("Cloudflare 401 and unsynced secrets get targeted remedies",()=>{
  const out=diagnoseSnapshot(healthy({cloudStatus:401,tokenMatches:false}));
  assert.ok(out.issues.some(x=>x.code==="TOKEN_OUT_OF_SYNC"));
  assert.ok(out.issues.some(x=>x.code==="CLOUD_AUTH"));
  assert.ok(out.issues.every(x=>!JSON.stringify(x).includes("test-secret")));
});
test("DeepSeek authentication and balance have different fixes",()=>{
  assert.ok(diagnoseSnapshot(healthy({deepSeekStatus:401})).issues.some(x=>x.code==="DEEPSEEK_AUTH"));
  assert.ok(diagnoseSnapshot(healthy({deepSeekAvailable:false})).issues.some(x=>x.code==="DEEPSEEK_NO_CREDIT"));
});
test("root-only publisher daemon can fail independently",()=>{
  const s=healthy();
  s.services["com.mp3shelf.publisher"]={plist:true,loaded:false};
  assert.ok(diagnoseSnapshot(s).issues.some(x=>x.code==="DAEMON_NOT_LOADED"));
});
test("log classifier extracts signals without echoing token or raw logs",()=>{
  const token="e".repeat(64);
  const msgs="Bearer "+token+" Error 401 unauthorized\nspawn opencode ENOENT\ninvalid model";
  const signals=logSignals(msgs);
  assert.deepEqual(signals,["AUTH_ERROR","COMMAND_NOT_FOUND","MODEL_ERROR"]);
  assert.doesNotMatch(JSON.stringify(signals),new RegExp(token));
});
test("invalid failed stages are discarded and unknown heartbeat is not treated as online",()=>{
  const out=diagnoseSnapshot(healthy({failedStage:"password=topsecret",macOnline:null}));
  assert.equal(out.failedStage,null);
  assert.equal(out.ok,true);
});
