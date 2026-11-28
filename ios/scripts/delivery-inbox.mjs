import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {appendFileSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {runInNewContext} from 'node:vm';
import {fileURLToPath} from 'node:url';

const repository = 'jonnyt123/mp3-shelf';
const api = 'https://api.github.com/repos/' + repository;
const lanes = {playback:'agent/mp3-playback-delivery',downloads:'agent/mp3-downloads-delivery',ux:'agent/mp3-ux-delivery',product:'agent/mp3-native-product',integration:'agent/mp3-native-integration-delivery'};
const sha = /^[0-9a-f]{40}$/;
function check(ok, reason) { if (!ok) throw Error(reason); }
function gitBlob(text) {
  const data = Buffer.from(text);
  return createHash('sha1').update('blob ' + data.length + '\0').update(data).digest('hex');
}
export function validateRequest(data) {
  check(data && Object.hasOwn(lanes,data.lane), 'Unknown lane');
  check(['edit','compose','resume'].includes(data.kind), 'Unknown request kind');
  if (data.kind === 'resume') {
    check(sha.test(data.commit) && sha.test(data.parent), 'Resume requires the exact prepared commit and parent');
    return;
  }
  check(typeof data.message === 'string' && data.message.trim() && data.message.length <= 200 && !/[\r\n\0]/.test(data.message), 'Invalid commit subject');
  if (data.kind === 'compose') {
    check(data.lane === 'integration' && data.sourceLane !== 'integration' && Object.hasOwn(lanes,data.sourceLane) && sha.test(data.source), 'Invalid composition source');
    return;
  }
  check(sha.test(data.parent) && Array.isArray(data.edits) && data.edits.length && data.edits.length <= 80, 'Provide a pinned parent and scoped edits');
  for (const e of data.edits) {
    check(typeof e?.path === 'string' && /^ios\/(?:MP3Shelf\/(?:Models|Services|Views)|Tests)\/[\w-]+\.swift$/.test(e.path), 'Inbox edits are limited to app Swift sources and tests');
    check((e.before === null || typeof e.before === 'string') && typeof e.after === 'string', 'Invalid text edit');
  }
  check(data.lane !== 'integration', 'Integration inbox requests compose reviewed worker changes');
}
async function http(url, {method='GET', body}={}) {
  check(url === 'https://api.github.com/graphql' || url.startsWith(api + '/') || url === api, 'Unexpected API origin');
  const response = await fetch(url, {method, redirect:'error', headers:{
    'User-Agent':'mp3-shelf-delivery', Accept:'application/vnd.github+json', Authorization:'Bearer ' + process.env.GITHUB_TOKEN,
    'Content-Type':'application/json'
  }, ...(body ? {body:JSON.stringify(body)} : {})});
  const json = await response.json();
  check(response.ok && !json.errors, method + ' ' + new URL(url).pathname + ' ' + response.status + ' ' + (json.message || json.errors?.map(e=>e.message).join(', ') || ''));
  return json;
}
const get = path => http(api + path);
async function readFile(path, ref) {
  const file = await get('/contents/' + path + '?ref=' + encodeURIComponent(ref));
  check(file.type === 'file' && file.encoding === 'base64', 'Incomplete GitHub file ' + path);
  const content = Buffer.from(file.content,'base64').toString('utf8');
  check(gitBlob(content) === file.sha, 'File digest mismatch: ' + path);
  return {content, sha:file.sha, encoding:'utf-8'};
}
const helper = runInNewContext(readFileSync(new URL('./scheduled-delivery.js', import.meta.url),'utf8'));
// The planner has only two read operations available. No request content is executed here.
const readers = {
  mcp__codex_apps__github_fetch:async ({url})=>({structuredContent:{content:JSON.stringify(await http(url))}}),
  mcp__codex_apps__github_fetch_file:async ({path,ref})=>({structuredContent:await readFile(path,ref)})
};
const catalog = Object.keys(readers).map(name=>({name}));
async function plan() {
  const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH,'utf8'));
  check(event.repository.full_name === repository && event.repository.private === false && event.ref === 'refs/heads/' + lanes.integration, 'Unexpected repository, visibility or intake branch');
  check(sha.test(event.after) && sha.test(event.before), 'Invalid event revision');
  const intake = await get('/commits/' + event.after);
  check(intake.parents.length === 1 && intake.parents[0].sha === event.before && intake.files.length === 1, 'Submit one request per commit');
  const addition = intake.files[0];
  check(addition.status === 'added' && /^ios\/automation\/requests\/[a-z0-9][a-z0-9-]{1,100}\.json$/.test(addition.filename), 'Submit a new request file');
  const payload = await readFile(addition.filename,event.after);
  check(Buffer.byteLength(payload.content) <= 240000, 'Oversized delivery request');
  const data = JSON.parse(payload.content);
  validateRequest(data);
  const branch = lanes[data.lane], head = (await get('/git/ref/heads/' + branch)).object.sha;
  const trailer = 'MP3-Shelf-Request: ' + event.after;
  const commits = await get('/commits?sha=' + encodeURIComponent(branch) + '&per_page=50');
  if (commits.some(c=>c.commit.message.split('\n').includes(trailer))) return {status:'ALREADY_DELIVERED',branch};
  let work;
  if (data.kind === 'resume') {
    if (head === data.commit || (await get('/compare/' + data.commit + '...' + head)).status === 'ahead') return {status:'ALREADY_DELIVERED',branch};
    const saved = await helper(readers,catalog,data.lane,{dryRun:true});
    check(saved.status === 'PREPARED' && saved.commit === data.commit && saved.parent === data.parent && head === data.parent, 'Prepared receipt or branch moved');
    const files = [];
    for (const path of saved.paths) files.push({path,content:(await readFile(path,data.commit)).content});
    work = {parent:head,files};
  } else {
    const args = data.kind === 'compose' ? {compose:true,sourceLane:data.sourceLane,source:data.source} : {edits:data.edits};
    const parent = data.kind === 'compose' ? head : data.parent;
    work = await helper(readers,catalog,data.lane,{...args,parent,dryRun:true,returnFiles:true,durableInbox:true,message:data.message,tests:'Independent Linux job pending'});
    if (work.status === 'ALREADY_COMPOSED') return {status:work.status,branch};
    check(work.status === 'CHECKED' && work.files?.length, 'An outstanding prepared commit requires its own resume request');
  }
  check(work.files.every(f=>/^ios\/(MP3Shelf\/(Models|Services|Views)|Tests)\/[\w-]+\.swift$/.test(f.path)), 'Only Swift sources/tests may be published by this inlet');
  const files = work.files.sort((a,b)=>a.path.localeCompare(b.path));
  const digest = createHash('sha256').update(JSON.stringify([event.after,work.parent,files.map(f=>[f.path,gitBlob(f.content)])])).digest('hex');
  return {status:'READY',branch,parent:work.parent,files,digest,data,trailer};
}
function out(name,value) {
  check(typeof value === 'string' && !/[\r\n]/.test(value), 'Invalid job output');
  appendFileSync(process.env.GITHUB_OUTPUT,name+'='+value+'\n');
}
async function verifyRef(p,id) {
  const [commit,ref] = await Promise.all([get('/commits/'+id),get('/git/ref/heads/'+p.branch)]);
  check(commit.parents.length === 1 && commit.parents[0].sha === p.parent, 'Readback parent mismatch');
  check(commit.files.length === p.files.length && p.files.every(f=>commit.files.some(x=>x.filename===f.path && x.sha===gitBlob(f.content))), 'Readback file mismatch');
  check(ref.object.sha === id || (await get('/compare/'+id+'...'+ref.object.sha)).status === 'ahead', 'Published commit is not on the lane');
  console.log('Verified https://github.com/'+repository+'/commit/'+id);
}
async function main(mode) {
  const p = await plan();
  console.log(p.status, p.branch);
  if (mode === 'plan') {
    out('status',p.status);
    if (p.status !== 'READY') return;
    out('parent',p.parent); out('digest',p.digest);
    const dest = join(process.env.RUNNER_TEMP,'mp3-candidate');
    execFileSync('git',['init','--quiet',dest]);
    execFileSync('git',['-C',dest,'fetch','--quiet','--no-tags','--depth=1','https://github.com/'+repository+'.git',p.parent]);
    execFileSync('git',['-C',dest,'checkout','--quiet','--detach','FETCH_HEAD']);
    check(execFileSync('git',['-C',dest,'rev-parse','HEAD'],{encoding:'utf8'}).trim()===p.parent,'Wrong test checkout');
    for (const f of p.files) { const path = join(dest,f.path); mkdirSync(dirname(path),{recursive:true}); writeFileSync(path,f.content); }
    writeFileSync(join(process.env.RUNNER_TEMP,'mp3-paths.json'),JSON.stringify(p.files.map(f=>f.path)));
    return;
  }
  check(mode === 'publish', 'Unknown mode');
  if (p.status !== 'READY') return;
  check(p.digest === process.env.EXPECTED_DIGEST && p.parent === process.env.EXPECTED_PARENT, 'Candidate changed after testing');
  const graph = (query,variables)=>http('https://api.github.com/graphql',{method:'POST',body:{query,variables}});
  let id;
  if (p.data.kind === 'resume') {
    const repositoryId = (await http(api)).node_id;
    await graph('mutation($input:UpdateRefsInput!){updateRefs(input:$input){clientMutationId}}',
      {input:{repositoryId,refUpdates:[{name:'refs/heads/'+p.branch,beforeOid:p.parent,afterOid:p.data.commit,force:false}]}});
    id=p.data.commit;
  } else {
    const result=await graph('mutation($input:CreateCommitOnBranchInput!){createCommitOnBranch(input:$input){commit{oid}}}',
      {input:{branch:{repositoryNameWithOwner:repository,branchName:p.branch},expectedHeadOid:p.parent,
        message:{headline:p.data.message,body:p.trailer+(p.data.kind==='compose' ? '\nWorker-Commit: '+p.data.source : '')},
        fileChanges:{additions:p.files.map(f=>({path:f.path,contents:Buffer.from(f.content).toString('base64')}))}}});
    id=result.data.createCommitOnBranch.commit.oid;
  }
  await verifyRef(p,id);
}
if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv[2]).catch(error=>{console.error(error.message);process.exitCode=1;});
