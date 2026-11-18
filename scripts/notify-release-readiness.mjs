#!/usr/bin/env node
/** Native macOS Notification Center messages only on new blockers or completed gates.
 * Runs after the existing hourly readiness refresh. No network or scheduled task.
 */
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { lstatSync,readFileSync,renameSync,writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join,resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const SHA=/^[0-9a-f]{40}$/;
const KEYS=['source','agent','native','playlist','playback','review','hardware','smoke','zip'];
const STATUS=new Set(['PASS','BLOCKED','UNVERIFIED']);
function safeRead(path,max=128*1024){
 try{const st=lstatSync(path);if(!st.isFile()||st.isSymbolicLink()||st.nlink!==1||
   st.size<2||st.size>max)return null;return JSON.parse(readFileSync(path,'utf8'));}catch{return null;}
}
export function normalizedGateState(model,{now=Date.now()}={}){
 if(model?.schema!=='mp3shelf-release-readiness-v1'||
   !Array.isArray(model.gates)||model.gates.length!==KEYS.length||
   !Number.isFinite(Date.parse(model.generatedAt??''))||
   now-Date.parse(model.generatedAt)>2*3600000||Date.parse(model.generatedAt)>now+300000)
  throw Error('Readiness evidence is missing, expired or malformed.');
 if(!SHA.test(model.candidateSha??'')||!SHA.test(model.toolingSha??''))
  throw Error('Readiness source or tooling SHA is missing or malformed.');
 const keys=new Set(model.gates.map(g=>g?.key));
 if(keys.size!==KEYS.length||KEYS.some(key=>!keys.has(key))||
   model.gates.some(g=>!STATUS.has(g?.status)))
  throw Error('Readiness gate identity or status is untrusted.');
 return {schema:'mp3shelf-readiness-notification-state-v1',
  candidateSha:model.candidateSha,
  toolingSha:model.toolingSha,
  gates:Object.fromEntries(model.gates.map(g=>[g.key,g.status])),
  updatedAt:model.generatedAt};
}
export function notificationChanges(previous,current){
 if(previous?.schema!=='mp3shelf-readiness-notification-state-v1'||
   !current||previous.candidateSha!==current.candidateSha||
   !SHA.test(previous.toolingSha??'')||
   !Number.isFinite(Date.parse(previous.updatedAt??''))||
   Date.parse(previous.updatedAt)>Date.parse(current.updatedAt)||
   !previous.gates||Object.keys(previous.gates).length!==KEYS.length||
   KEYS.some(key=>!STATUS.has(previous.gates[key])))
  return {baseline:true,cleared:[],blocked:[]};
 const cleared=[],blocked=[];
 for(const key of KEYS){
  const before=previous.gates[key],after=current.gates[key];
  if(after===before)continue;
  if(after==='PASS')cleared.push(key);
  else if(before==='PASS'||after==='BLOCKED')blocked.push(key);
 }
 return {baseline:false,cleared,blocked};
}
export function notificationMessage(diff){
 if(diff.baseline||(!diff.cleared.length&&!diff.blocked.length))return null;
 const names={source:'native source',agent:'Mac agent',native:'Xcode build',
  playlist:'playlist',playback:'offline playback',review:'iPhone review',
  hardware:'hardware approval',smoke:'draft upload',zip:'verified ZIP'};
 const groups=[];
 if(diff.cleared.length)groups.push('Passed: '+diff.cleared.map(k=>names[k]).join(', '));
 if(diff.blocked.length)groups.push('Needs review: '+diff.blocked.map(k=>names[k]).join(', '));
 return groups.join(' | ').slice(0,235);
}
function notifySystem(message) {
 execFileSync('osascript',['-e','on run argv',
   '-e','display notification (item 1 of argv) with title "MP3 Shelf — Release Readiness"',
   '-e','end run','--',message],{encoding:'utf8',timeout:15000,
     stdio:['ignore','pipe','pipe'],maxBuffer:20000});
}
export function deliverChangeOnlyNotification({home=homedir(),now=Date.now(),
 send=notifySystem,platform=process.platform}={}){
 const root=resolve(home,'Library','Logs','MP3Shelf','ReleaseReadiness');
 // This runs under launchd; never follow redirected home log directories.
 for(const dir of [join(home,'Library'),join(home,'Library','Logs'),
   join(home,'Library','Logs','MP3Shelf'),root]){
  const info=lstatSync(dir);
  if(!info.isDirectory()||info.isSymbolicLink())
   throw Error('Readiness notification directory was redirected.');
 }
 const latest=join(root,'latest.json'),previous=join(root,'notification-state.json');
 const model=safeRead(latest);
 if(!model)throw Error('Missing latest local release-readiness JSON');
 const current=normalizedGateState(model,{now});
 const prior=safeRead(previous),diff=notificationChanges(prior,current);
 const message=notificationMessage(diff);
 // Validate the write destination before delivering an irreversible UI alert.
 // Otherwise a redirected state file can cause repeated alerts every hour.
 const st=(()=>{try{return lstatSync(previous);}catch(e){
  if(e.code==='ENOENT')return null;throw e;}})();
 if(st&&(!st.isFile()||st.isSymbolicLink()||st.nlink!==1))
  throw Error('Readiness notification state destination is redirected.');
 // If a notification cannot be delivered, do not commit its new state;
 // the next real hourly transition may retry. Initial baseline is silent.
 if(message){
  if(platform!=='darwin')return {status:'MAC_NOTIFICATION_UNAVAILABLE',diff};
  send(message);
 }
 const tmp=join(root,'.notification-'+randomUUID()+'.tmp');
 writeFileSync(tmp,JSON.stringify(current,null,2)+'\n',{flag:'wx',mode:0o600});
 renameSync(tmp,previous);
 return {status:diff.baseline?'BASELINE_SAVED':message?'CHANGE_NOTIFIED':'NO_CHANGE',
  cleared:diff.cleared,blocked:diff.blocked,message};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 try{const r=deliverChangeOnlyNotification();
  console.log(JSON.stringify({status:r.status,cleared:r.cleared,blocked:r.blocked},null,2));
 }catch(e){console.error('RELEASE_NOTIFICATION_UNVERIFIED: '+e.message);process.exitCode=1;}
}
