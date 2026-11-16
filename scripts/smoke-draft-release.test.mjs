import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { smokePreflight, workflowMayRunOnDraftTag, verifiedDraftUpload, runDraftSmoke }
  from './smoke-draft-release.mjs';
const sha='a'.repeat(40),tag='mp3shelf-upload-smoke-'+sha.slice(0,12)+'-1730000000000-abcdef';
const zip='mp3shelf-draft-smoke-aaaaaaaaaaaa.zip';
const json='mp3shelf-draft-smoke-aaaaaaaaaaaa.manifest.json';
const zipSHA='b'.repeat(64),jsonSHA='c'.repeat(64);
function draft(){
 return {draft:true,tag_name:tag,target_commitish:sha,
   assets:[{name:zip,digest:'sha256:'+zipSHA,state:'uploaded',size:128},{name:json,digest:'sha256:'+jsonSHA,state:'uploaded',size:256}]};
}
test('smoke tag is SHA-bound, unique, synthetic and never reuses existing draft/tag',()=>{
 assert.deepEqual(smokePreflight({tag,sha,existing:null,workflows:[]}),[]);
 assert(smokePreflight({tag,sha,existing:draft(),workflows:[]}).length);
 assert(smokePreflight({tag:'mp3-shelf-ios-'+sha,sha,existing:null,workflows:[]}).length);
 assert(smokePreflight({tag,sha:'wrong',existing:null,workflows:[]}).length);
});
test('refuses workflow configurations that could trigger paid Actions on tag or draft creation',()=>{
 for(const workflow of [
   'on:\n  push:\n    tags:\n     - "*"\n',
   'on:\n  release:\n    types: [created]\n',
   'on: [push, pull_request]\n',
   'on: push\n',
   'on: {release: {types: [created]}}\n',
   'on:\n  create:\n',
   'on:\n  issue_comment:\n    types: [created]\n',
   'on: [delete, workflow_dispatch]\n']) {
   assert(smokePreflight({tag,sha,existing:null,workflows:[workflow]}).length);
 }
 assert.deepEqual(smokePreflight({tag,sha,existing:null,
   workflows:['on:\n  pull_request:\n','on:\n  workflow_dispatch:\n']}),[]);
});
test('only a draft with exactly two SHA-matching synthetic upload assets qualifies',()=>{
 assert.equal(verifiedDraftUpload(draft(),{tag,sha,zip,manifest:json,zipSHA,manifestSHA:jsonSHA}),true);
 const bad=draft();bad.draft=false;
 assert(!verifiedDraftUpload(bad,{tag,sha,zip,manifest:json,zipSHA,manifestSHA:jsonSHA}));
 const duplicate=draft();duplicate.assets[1].name=zip;
 assert(!verifiedDraftUpload(duplicate,{tag,sha,zip,manifest:json,zipSHA,manifestSHA:jsonSHA}));
});
test('wrong source identity and missing or altered digests are rejected',()=>{
 const args={tag,sha,zip,manifest:json,zipSHA,manifestSHA:jsonSHA};
 for(const mutate of [
   x=>{x.target_commitish='d'.repeat(40)},
   x=>{x.assets[0].digest='sha256:'+'0'.repeat(64)},
   x=>{delete x.assets[1].digest},
   x=>{x.assets.pop()},
   x=>{x.assets.push({name:'extra.zip',digest:'sha256:'+zipSHA})}
 ]){
  const x=draft();mutate(x);
  assert(!verifiedDraftUpload(x,args));
 }
});
test('remote live smoke never starts by default or from non-Mac host',async()=>{
 await assert.rejects(runDraftSmoke({platform:'linux',allowLive:true}),/MAC_AND_GH_REQUIRED/);
 if(process.platform!=='darwin')
   await assert.rejects(runDraftSmoke({allowLive:false}),/MAC_AND_GH_REQUIRED/);
});

test('quoted, inline, aliased or missing workflow triggers block remote draft smoke',()=>{
 for(const workflow of [
   'on:\n  "push":\n    tags: ["*"]\n',
   "'on':\n  'release':\n    types: [created]\n",
   'on: ["push", "pull_request"]\n',
   'on: { "create": { } }\n',
   'on: issue_comment\n',
   'on: *shared_events\n',
   'on:\n  <<: *events\n',
   'name: missing-trigger\njobs:\n  test:\n    runs-on: ubuntu-latest\n'
 ]) assert.equal(workflowMayRunOnDraftTag(workflow),true,workflow);
 for(const workflow of [
   'on:\n  pull_request:\n    branches: [main]\n',
   '"on": [workflow_dispatch, pull_request]\n',
   'on: workflow_dispatch\n'
 ]) assert.equal(workflowMayRunOnDraftTag(workflow),false,workflow);
});

test('rejects incomplete, empty or already published remote smoke assets',()=>{
 const args={tag,sha,zip,manifest:json,zipSHA,manifestSHA:jsonSHA};
 for(const mutate of [
  x=>{x.published_at='2026-11-16T00:00:00Z'},
  x=>{x.assets[0].state='starter'},
  x=>{x.assets[1].size=0},
  x=>{x.assets[1].size=-1},
  x=>{x.assets[1].size=NaN},
  x=>{delete x.assets[0].state},
  x=>{delete x.assets[0].size}
 ]) {const x=draft();mutate(x);assert.equal(verifiedDraftUpload(x,args),false);}
});
