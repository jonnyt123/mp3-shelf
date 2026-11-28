import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {runInNewContext} from 'node:vm';

const deliver = runInNewContext(readFileSync(new URL('./scheduled-delivery.js', import.meta.url), 'utf8'));
const path = 'ios/MP3Shelf/Views/LyricsView.swift';
const branch = 'agent/mp3-native-product';
const digest = s => createHash('sha1').update(s).digest('hex');
const baseline = 'let title = "First 🎵"\n';
const request = {message:'Update displayed song title', tests:'Fixture comparison', edits:[{path, before:'First', after:'Second'}]};

function fixture(options = {}) {
  const blobs = new Map(), trees = new Map(), commits = new Map();
  function blob(text) { const sha = digest(text); blobs.set(sha,text); return sha; }
  function tree(entries) { const sha = digest(JSON.stringify(entries)); trees.set(sha,entries); return sha; }
  function commit(treeSha, parent) {
    const sha = digest(treeSha + (parent || 'root'));
    commits.set(sha, {tree:{sha:treeSha}, parents:parent ? [{sha:parent}] : []});
    return sha;
  }
  const entries = {[path]:blob(baseline)};
  if (options.workflow) entries['.github/workflows/ci.yml'] = blob(options.workflow);
  const parent = commit(tree(entries));
  const refs = new Map([[branch,parent],['main',parent]]);
  let cp = {version:1,lane:'product',branch,state:'BASELINE',parent,remote:parent,prepared:null,lastVerifiedDelivery:null};
  const marker = '<!-- MP3_SHELF_CHECKPOINT_V1:product -->';
  let updates = 0;
  let failPublish = Boolean(options.stopBeforePush);
  let conflict = Boolean(options.conflict);
  function files(sha) { return trees.get(commits.get(sha).tree.sha); }
  const ops = {
    async fetch({url}) {
      const route = new URL(url).pathname.replace('/repos/jonnyt123/mp3-shelf','');
      if (route.startsWith('/git/ref/heads/')) return {content:JSON.stringify({object:{sha:refs.get(route.slice(15))}})};
      if (route.startsWith('/issues/comments/')) return {content:JSON.stringify({body:marker+'\n```json\n'+JSON.stringify(cp)+'\n```'})};
      if (route.startsWith('/git/trees/')) return {content:JSON.stringify({truncated:false,tree:Object.entries(files(route.slice(11))).map(([path,sha])=>({type:'blob',mode:'100644',path,sha,size:Buffer.byteLength(blobs.get(sha))}))})};
      if (route.startsWith('/git/commits/')) return {content:JSON.stringify(commits.get(route.slice(13)))};
      if (route === '/pulls') return {content:JSON.stringify(options.pr ? [{number:4}] : [])};
      if (route.startsWith('/compare/')) return {content:JSON.stringify({status:'diverged'})};
      throw Error(route);
    },
    async fetch_file({ref,path}) {
      const sha = files(ref)[path];
      return {sha,content:options.truncated && path.endsWith('.swift') ? baseline.trimEnd() : blobs.get(sha),encoding:'utf-8'};
    },
    async create_blob({content}) { return {sha:blob(content)}; },
    async create_tree({base_tree_sha,tree_elements}) {
      const next = {...trees.get(base_tree_sha)};
      for (const e of tree_elements) next[e.path] = e.sha;
      return {sha:tree(next)};
    },
    async create_commit({tree_sha,parent_sha}) { return {sha:commit(tree_sha,parent_sha)}; },
    async update_issue_comment({comment}) { cp = JSON.parse(comment.match(/```json\s*([\s\S]*?)```/)[1]); return {id:1}; },
    async update_ref({branch_name,expected_sha,force,sha}) {
      assert.equal(force,false);
      if (failPublish) { failPublish = false; throw Error('Interrupted before ref update'); }
      if (conflict) { conflict = false; refs.set(branch_name,commit(tree({...entries,other:blob('racing work')}),parent)); }
      assert.equal(expected_sha,refs.get(branch_name),'Concurrent update');
      refs.set(branch_name,sha); updates++;
      if (options.lostReply) throw Error('Lost reply');
      return {sha};
    }
  };
  const tools = {};
  for (const [op, fn] of Object.entries(ops)) {
    const name = (options.legacy ? 'mcp__GitHub__' : 'mcp__codex_apps__github_') + op;
    tools[name] = async args => options.legacy ? {result:await fn(args)} : {structuredContent:await fn(args)};
  }
  const catalog = Object.keys(tools).map(name=>({name}));
  return {parent, run:(job = {})=>deliver(tools,catalog,'product',job), head:()=>refs.get(branch), cp:()=>cp, updates:()=>updates};
}

for (const legacy of [false,true]) {
  test('publish and verify using ' + (legacy ? 'legacy' : 'current') + ' connector shape',async()=>{
    const f=fixture({legacy,workflow:'on:\n  pull_request:\n    paths:\n      - ios/**\n  workflow_dispatch:\njobs:\n  test: {}'});
    const result=await f.run({...request,parent:f.parent});
    assert.equal(result.commit,f.head()); assert.equal(f.cp().lastVerifiedDelivery,result.commit); assert.equal(f.updates(),1);
    await assert.rejects(f.run({...request,parent:f.parent}),/Parent changed/);
  });
}
test('resume a prepared commit across independent invocations',async()=>{
  const f=fixture({stopBeforePush:true});
  await assert.rejects(f.run({...request,parent:f.parent}),/Interrupted/);
  assert.equal(f.cp().state,'PREPARED'); const prepared=f.cp().prepared;
  const resumed=await f.run();
  assert.equal(resumed.recovered,true); assert.equal(resumed.commit,prepared); assert.equal(f.updates(),1);
});
test('ambiguous write response is verified without another update',async()=>{
  const f=fixture({lostReply:true}); const result=await f.run({...request,parent:f.parent});
  assert.equal(result.commit,f.head()); assert.equal(f.updates(),1);
});
test('concurrent branch advance preserves competing work and prepared SHA',async()=>{
  const f=fixture({conflict:true});
  await assert.rejects(f.run({...request,parent:f.parent}),/Concurrent update/);
  assert.equal(f.cp().state,'PREPARED'); assert.notEqual(f.head(),f.cp().prepared); assert.equal(f.updates(),0);
});
for (const [label,options,pattern] of [
  ['push workflow',{workflow:'on:\n  push:\njobs: {}'},/workflow triggers/],
  ['flow-style unknown trigger',{workflow:'on: [push, workflow_dispatch]\njobs: {}'},/workflow triggers/],
  ['PR participates in branch',{pr:true},/open PR/],
  ['partial UTF-8 source',{truncated:true},/Incomplete pinned source/]
]) test(label,async()=>{
  const f=fixture(options); await assert.rejects(f.run({...request,parent:f.parent}),pattern);
  assert.equal(f.head(),f.parent); assert.equal(f.cp().state,'BASELINE');
});
test('reject stale text and cross-lane paths',async()=>{
  const f=fixture();
  await assert.rejects(f.run({...request,parent:f.parent,edits:[{path,before:'absent',after:'yes'}]}),/anchor/);
  await assert.rejects(f.run({...request,parent:f.parent,edits:[{path:'ios/MP3Shelf/Models/PlaybackOrder.swift',before:'a',after:'b'}]}),/ownership/);
  assert.equal(f.updates(),0);
});
test('dry run returns exact changed source without creating a receipt',async()=>{
  const f=fixture();
  const r=await f.run({...request,parent:f.parent,dryRun:true,returnFiles:true});
  assert.equal(r.files[0].content,baseline.replace('First','Second')); assert.equal(f.cp().state,'BASELINE'); assert.equal(f.updates(),0);
});
