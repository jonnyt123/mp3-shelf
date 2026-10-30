#!/usr/bin/env node
// Separate GitHub publishing broker. Run ONLY as mp3publisher; never inside OpenCode.
import { spawn } from 'node:child_process';
import { mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';

const repo='jonnyt123/mp3-shelf';
const remote='https://github.com/'+repo+'.git';
const base='feat/ios-premium-visual-refresh';
export const agentIds=['mp3-playback','mp3-sources','mp3-ui','mp3-qa','mp3-integration'];
const evidenceDir=process.env.MP3_APPROVAL_DIR || '/srv/.mp3-shelf-agent-state/approved';
const store=process.env.MP3_PUBLISHER_CLONE || '/var/lib/mp3publisher/repository';

export function validApproval(approval, role, sha) {
  return approval && approval.role===role && approval.sha===sha
    && approval.diffCheck==='pass' && approval.nodeGuardTests==='pass'
    && Array.isArray(approval.files) && approval.files.length>0
    && approval.files.every(f=>typeof f==='string' && !f.includes('..') && !f.startsWith('/'));
}
export function safeBranch(role) {
  if(!agentIds.includes(role))throw Error('Unrecognized worker role');
  return 'agent/'+role;
}
function execute(bin,args,{cwd=store,env=process.env,ms=120000}={}) {
  return new Promise((resolve,reject)=>{
    const child=spawn(bin,args,{cwd,env,stdio:['ignore','pipe','pipe']});
    let out='',err='';
    const timer=setTimeout(()=>child.kill('SIGKILL'),ms);
    child.stdout.on('data',d=>{out+=d.toString();if(out.length>250000)out=out.slice(-250000);});
    child.stderr.on('data',d=>{err+=d.toString();if(err.length>20000)err=err.slice(-20000);});
    child.once('error',e=>{clearTimeout(timer);reject(e);});
    child.once('close',code=>{
      clearTimeout(timer);
      if(code===0)resolve(out.trim());
      else reject(Error(bin+' '+args[0]+' exited '+code+': '+err.slice(-600)));
    });
  });
}
async function git(args){return execute('git',['-c','core.hooksPath=/dev/null','-c','safe.directory=/srv/mp3-shelf','-c','credential.helper=!gh auth git-credential',...args]);}
async function init(){
  await mkdir(path.dirname(store),{recursive:true});
  try{await git(['rev-parse','--is-inside-work-tree']);}
  catch{
    await execute('git',['-c','core.hooksPath=/dev/null','clone','--no-checkout','--filter=blob:none','--single-branch','--branch',base,remote,store],{cwd:path.dirname(store)});
  }
  const origin=await git(['remote','get-url','origin']);
  if(origin!==remote)throw Error('Publisher remote changed; refusing upload');
}
async function publish(role){
  const branch=safeBranch(role);
  const evidence=JSON.parse(await readFile(path.join(evidenceDir,role+'.json'),'utf8'));
  // This reads only Git objects, not a shell command or executable code from the agent.
  await git(['fetch','--no-tags','/srv/mp3-shelf','refs/heads/'+branch]);
  const sha=await git(['rev-parse','FETCH_HEAD']);
  if(!/^[a-f0-9]{40}$/.test(sha)||!validApproval(evidence,role,sha))throw Error(role+' does not have matching verified local evidence');
  const commitMessage=await git(['log','-1','--format=%B',sha]);
  if(!commitMessage.includes('[skip ci]'))throw Error('Missing CI-skip marker; prevents exhausting GitHub Actions');
  const ancestors=await git(['merge-base',sha,'origin/'+base]);
  if(ancestors!==(await git(['rev-parse','origin/'+base])))throw Error('Worker no longer descends from integration base');
  const parent=(await git(['rev-parse',sha+'^'])).trim();
  const files=(await git(['diff','--name-only',parent,sha])).split('\n').filter(Boolean);
  if(files.length!==evidence.files.length || files.some(f=>!evidence.files.includes(f)))throw Error('Commit files do not match trusted local evidence');
  const remoteHead=await git(['ls-remote','--heads','origin','refs/heads/'+branch]);
  if(remoteHead){
    const old=remoteHead.split(/\s+/)[0];
    if(old===sha){console.log(role+' already published');return;}
    await git(['fetch','--no-tags','origin','refs/heads/'+branch]);
    const existing=await git(['rev-parse','FETCH_HEAD']);
    try{await git(['merge-base','--is-ancestor',existing,sha]);}
    catch{throw Error('Remote branch diverged; no force push allowed');}
  }
  // Publishing is non-force and only uses dedicated agent refs. No main/production access.
  await git(['push','origin',sha+':refs/heads/'+branch]);
  const ghEnv={...process.env};
  // gh reads only the broker-scoped GH_TOKEN. This process never executes agent-supplied code.
  const existing=await execute('gh',['pr','list','--repo',repo,'--head',branch,'--state','open','--json','number,url'],{env:ghEnv});
  const prs=JSON.parse(existing);
  if(!prs.length){
    await execute('gh',['pr','create','--repo',repo,'--draft','--base',base,'--head',branch,
      '--title','MP3 Shelf agent: '+role+' (Mac validation pending)',
      '--body','Autonomous coding change staged from the native PR #4 baseline. Local scope/diff/runner guards passed. Native Xcode verification is PENDING via independent Mac; physical-iPhone hardware gate #6 is NOT satisfied. Do not merge until required checks and source review pass. Commits include [skip ci] to conserve exhausted GitHub Actions minutes. Coordination: #22.'],{env:ghEnv});
  }
  console.log('Published draft branch '+branch+' '+sha+'; Mac QA pending');
}
export async function main(args=process.argv.slice(2)){
  if(args[0]==='--dry-run'){console.log(JSON.stringify({repo,base,roles:agentIds,push:'agent/* only',draft:true,autoMerge:false,requiresEvidence:true},null,2));return;}
  if(args[0]!=='--once')throw Error('Usage: publish.mjs --dry-run | --once');
  if(!process.env.GH_TOKEN)throw Error('GH_TOKEN missing from dedicated publisher user; no upload');
  await init();
  await git(['fetch','--no-tags','origin','refs/heads/'+base+':refs/remotes/origin/'+base]);
  for(const role of agentIds){
    try{await publish(role);}
    catch(e){console.error(role+': '+e.message);}
  }
}
if(process.argv[1]&&path.resolve(process.argv[1])===new URL(import.meta.url).pathname){
  main().catch(e=>{console.error(e.message);process.exitCode=1;});
}
