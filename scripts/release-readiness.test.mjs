import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readinessModel, readinessMarkdown, readinessHTML, writeReadiness }
  from './release-readiness.mjs';
const sha='a'.repeat(40),tooling='b'.repeat(40),hash='c'.repeat(64);
test('empty evidence dashboard stays not release ready with concrete blockers',()=>{
 const model=readinessModel({candidateSha:sha,toolingSha:tooling,now:Date.parse('2026-11-16T20:00:00Z')});
 assert.equal(model.status,'NOT_RELEASE_READY');
 assert(model.blocking.includes('native'));
 assert(model.blocking.includes('hardware'));
 assert(model.blocking.includes('smoke'));
 assert(model.blocking.includes('zip'));
 const text=readinessMarkdown(model);
 assert(text.includes('Next actions'));
 assert(text.includes('Mac'));
});
test('a successful Mac agent process does not clear hardware and ZIP gates',()=>{
 const model=readinessModel({candidateSha:sha,agent:{status:'COMPLETED'},toolingSha:tooling,
   inventory:{schema:'mp3shelf-physical-inventory-v1',candidateSha:sha,
     requested:2,copiedTracks:1,unavailable:1,files:[]}});
 assert.equal(model.gates.find(x=>x.key==='agent').status,'UNVERIFIED');
 assert.equal(model.gates.find(x=>x.key==='playlist').status,'BLOCKED');
 assert.equal(model.gates.find(x=>x.key==='hardware').status,'BLOCKED');
});
test('reports do not interpret self-reported offline playback as signed hardware acceptance',()=>{
 const inventory={schema:'mp3shelf-physical-inventory-v1',candidateSha:sha,
  requested:2,copiedTracks:2,unavailable:0,
  files:[{sha256:hash,bytes:4000},{sha256:hash,bytes:5000}],
  offlinePlaybackAfterRestart:'APP_INSTRUMENTED_PHYSICAL_PASS',
  backgroundTransfer:'APP_RECORDED_STAGING_AND_BACKGROUND_WAKE'};
 const model=readinessModel({candidateSha:sha,toolingSha:tooling,inventory,
   issue:{number:6,state:'open'}});
 assert.equal(model.gates.find(x=>x.key==='playlist').status,'UNVERIFIED');
 assert.equal(model.gates.find(x=>x.key==='playback').status,'UNVERIFIED');
 assert.equal(model.gates.find(x=>x.key==='hardware').status,'BLOCKED');
 assert(model.blocking.includes('hardware'));
});
test('premium offline HTML escapes untrusted source metadata without executable UI injection',()=>{
 const model=readinessModel({candidateSha:sha,toolingSha:tooling,
  agent:{status:'FAILED',failureReason:'<script>alert("hello")</script>'}});
 const html=readinessHTML(model);
 assert(html.includes('viewport'));
 assert(html.includes('&lt;script&gt;'));
 assert(!html.includes('<script>alert'));
 assert(html.includes('release readiness') || html.includes('Release readiness'));
});
test('read-only dashboard writes JSON, Markdown and HTML without a Mac or GitHub account',()=>{
 const root=mkdtempSync(join(tmpdir(),'shelf-release-dash-'));
 try {
  const result=writeReadiness({home:root,now:Date.parse('2026-11-16T20:00:00Z'),
   github:()=>({candidateSha:sha,toolingSha:tooling,issue:null,smoke:null,release:null})});
  assert.equal(result.status,'NOT_RELEASE_READY');
  assert(readFileSync(result.markdown,'utf8').includes('NOT_RELEASE_READY'));
  const data=JSON.parse(readFileSync(result.json,'utf8'));
  assert(data.blocking.includes('hardware'));
  assert(readFileSync(result.html,'utf8').startsWith('<!doctype html>'));
 }finally{rmSync(root,{recursive:true,force:true})}
});


test('real native schemaVersion 1 receipt with two completed steps is recognized but does not approve device',()=>{
 const receipt={schemaVersion:1,mode:'native',candidateSha:sha,
   status:'local-checks-passed',cleanCheckout:true,exitCode:0,
   steps:[{name:'native-local-release',success:true},{name:'post-native-checkout-integrity',success:true}]};
 const model=readinessModel({candidateSha:sha,native:receipt});
 assert.equal(model.gates.find(x=>x.key==='native').status,'UNVERIFIED');
 assert.equal(model.gates.find(x=>x.key==='hardware').status,'BLOCKED');
 receipt.steps[1].success=false;
 assert.equal(readinessModel({candidateSha:sha,native:receipt}).gates.find(x=>x.key==='native').status,'UNVERIFIED');
});
test('closed GitHub hardware issue alone is insufficient without matching owner SHA-256 approval marker',()=>{
 const labels=['Signing / installation','Offline playback','Background licensed downloads',
   'Failure handling','Spotify metadata integration','Portable backup interoperability',
   'Accessible responsive UI','Policy/source audit','Final acceptance'];
 const hardware={schema:'mp3shelf-hardware-acceptance-v1',candidateSha:sha,installedSourceSha:sha,
   signedAppSHA256:hash,inventorySHA256:hash,reviewer:'jonnyt123',
   checks:Object.fromEntries(['signingInstallation','offlinePlayback','backgroundDownloads',
    'failureHandling','spotifyMetadata','backupInterop','accessibility','sourcePolicy','finalAcceptance']
     .map(name=>[name,'PASS']))};
 const issue={number:6,state:'closed',body:labels.map(label=>'- [x] **'+label+':** PASS').join('\n')};
 const args={candidateSha:sha,issue,hardware,inventorySHA256:hash};
 assert.equal(readinessModel(args).gates.find(g=>g.key==='hardware').status,'BLOCKED');
 const marker='MP3SHELF_DEVICE_GATE_APPROVED SHA='+sha+
   ' INVENTORY_SHA256='+hash+' SIGNED_APP_SHA256='+hash;
 assert.equal(readinessModel({...args,ownerComments:[{user:{login:'jonnyt123'},body:marker}]}).
   gates.find(g=>g.key==='hardware').status,'PASS');
 assert.equal(readinessModel({...args,ownerComments:[{user:{login:'unknown'},body:marker}]}).
   gates.find(g=>g.key==='hardware').status,'BLOCKED');
});

test('plausible local metadata cannot authorize ZIP or draft-smoke transport',()=>{
 const now=Date.parse('2026-11-17T12:00:00Z');
 const release={draft:false,tag_name:'mp3-shelf-ios-'+sha,assets:[
  {state:'uploaded',digest:'sha256:'+hash},
  {state:'uploaded',digest:'sha256:'+hash}]};
 const smoke={toolingSha:tooling,deleted:true,createdAt:'2026-11-17T11:00:00Z'};
 const model=readinessModel({candidateSha:sha,toolingSha:tooling,release,smoke,now});
 assert.equal(model.gates.find(g=>g.key==='smoke').status,'UNVERIFIED');
 assert.equal(model.gates.find(g=>g.key==='zip').status,'UNVERIFIED');
 assert.equal(model.status,'NOT_RELEASE_READY');
 assert(model.blocking.includes('zip'));
 assert(model.blocking.includes('smoke'));
});
test('self-reported review and playlist metadata remain advisory without byte and device proof',()=>{
 const inventory={schema:'mp3shelf-physical-inventory-v1',candidateSha:sha,
  requested:2,copiedTracks:2,unavailable:0,
  files:[{sha256:hash,bytes:4000},{sha256:hash,bytes:5000}],
  offlinePlaybackAfterRestart:'APP_INSTRUMENTED_PHYSICAL_PASS',
  backgroundTransfer:'APP_RECORDED_STAGING_AND_BACKGROUND_WAKE'};
 const review={schema:'mp3shelf-independent-device-review-v1',sourceSha:sha,
  result:'EVIDENCE_CHECKS_PASSED_NOT_HARDWARE_APPROVED',physicalAcceptance:'INCOMPLETE',failures:[]};
 const model=readinessModel({candidateSha:sha,inventory,review});
 for(const key of ['playlist','playback','review'])
  assert.equal(model.gates.find(g=>g.key===key).status,'UNVERIFIED');
 assert.equal(model.status,'NOT_RELEASE_READY');
});
