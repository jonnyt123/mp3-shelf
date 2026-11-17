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
 assert.equal(model.gates.find(x=>x.key==='agent').status,'PASS');
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
 assert.equal(model.gates.find(x=>x.key==='playlist').status,'PASS');
 assert.equal(model.gates.find(x=>x.key==='playback').status,'PASS');
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
