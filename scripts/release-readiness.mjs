#!/usr/bin/env node
/**
 * Read-only release readiness. Shows observable evidence and blockers; this
 * report NEVER grants authorization to publish an archive.
 */
import { execFileSync } from 'node:child_process';
import { readFileSync, readSync, lstatSync, fstatSync, openSync, closeSync, constants, mkdirSync, readdirSync, renameSync, writeFileSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { selectNativeEvidence } from './native-release-cycle.mjs';
import { verifiedSmokeComment } from './draft-smoke-attestation.mjs';
import { handoffErrors } from './stage-iphone-review.mjs';

const SHA=/^[0-9a-f]{40}$/;
const HASH=/^[0-9a-f]{64}$/;
const REPO='jonnyt123/mp3-shelf';
const CATEGORIES=['Signing / installation','Offline playback','Background licensed downloads',
  'Failure handling','Spotify metadata integration','Portable backup interoperability',
  'Accessible responsive UI','Policy/source audit','Final acceptance'];
export function readSafe(path,max=1024*1024){
 // Open the actual evidence inode without following a last-component symlink.
 // lstat(path) followed by readFile(path) permits a replacement race.
 if(!Number.isSafeInteger(max)||max<1)return null;
 let fd;
 try{
  fd=openSync(path,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);
  const info=fstatSync(fd);
  if(!info.isFile()||info.nlink!==1||info.size<1||info.size>max)return null;
  // Bound the actual read, not just the pre-read stat: another writer may
  // grow this inode after fstat. A single descriptor avoids path swaps.
  const bytes=Buffer.allocUnsafe(info.size);
  let offset=0;
  while(offset<bytes.length){
   const n=readSync(fd,bytes,offset,bytes.length-offset,offset);
   if(n===0)return null;
   offset+=n;
  }
  const after=fstatSync(fd);
  if(!after.isFile()||after.nlink!==1||after.size!==info.size||
     after.mtimeMs!==info.mtimeMs||after.ctimeMs!==info.ctimeMs)return null;
  // Reject appended data even when it arrives after the original size.
  const extra=Buffer.allocUnsafe(1);
  if(readSync(fd,extra,0,1,bytes.length)!==0)return null;
  return bytes.toString('utf8');
 }catch{return null;}
 finally{if(fd!==undefined)closeSync(fd);}
}
function json(path,max){try{const text=readSafe(path,max);return text?JSON.parse(text):null;}catch{return null;}}
function ghJSON(path){
 try{
  return JSON.parse(execFileSync('gh',['api','-H','Accept: application/vnd.github+json',
    'repos/'+REPO+'/'+path],{encoding:'utf8',timeout:15000,
      maxBuffer:2*1024*1024,stdio:['ignore','pipe','ignore']}));
 }catch{return null;}
}
function definite404(path){
 try {
  execFileSync('gh',['api','-H','Accept: application/vnd.github+json',
    'repos/'+REPO+'/'+path],{encoding:'utf8',timeout:15000,
     maxBuffer:512*1024,stdio:['ignore','pipe','pipe']});
  return false;
 } catch(error) {
  // Unlike a transient network, auth or rate-limit error, an explicit GitHub
  // HTTP 404 is evidence that this disposable smoke resource is absent.
  return /(?:HTTP\s*)?404|Not Found/.test(String(error.stderr ?? error.message));
 }
}
export function readinessModel({candidateSha=null,toolingSha=null,agent=null,native=null,
  inventory=null,inventorySHA256=null,review=null,reviewHandoff=null,
  reviewSHA256=null,hardware=null,issue=null,ownerComments=null,smoke=null,
  release=null,now=Date.now()}={}){
 const gates=[],add=(key,label,ok,details,action)=>gates.push({
   key,label,status:ok===true?'PASS':ok===null?'UNVERIFIED':'BLOCKED',
   details,action:ok===true?null:action});
 const sha=SHA.test(candidateSha??'')?candidateSha:null;
 add('source','Exact consolidated native source',!!sha,
   sha?sha:'The authoritative native branch SHA has not been verified.',
   'Refresh the current GitHub consolidated candidate branch.');
 // A successful invocation from an older source revision must not appear
 // current after the candidate moves. Also reject malformed/future/stale
 // timestamps and untrusted receipt schemas instead of granting a PASS.
 const agentTimestamp=Date.parse(agent?.finishedAt??'');
 const agentCurrent=!!sha&&agent?.schema==='mp3shelf-native-agent-run-v1'&&
   agent.candidateSha===sha&&agent.status==='COMPLETED'&&
   Number.isFinite(agentTimestamp)&&now>=agentTimestamp&&
   now-agentTimestamp<=24*60*60*1000&&
   Number.isFinite(Date.parse(agent.startedAt??''))&&
   Date.parse(agent.startedAt)<=agentTimestamp;
 add('agent','Mac hourly agent',agentCurrent?true:
   agent?.status==='FAILED'?false:null,
   agentCurrent?'A recent matching-source Mac invocation completed; this does not prove native compilation.':
   agent?.status==='FAILED'?'Mac invocation failed; inspect the private local diagnostics.':
   'No recent, schema-valid completed Mac invocation matches the current candidate SHA.',
   'Run the Mac agent against the current candidate and inspect its exact-SHA receipt.');
 // Local metadata is not an independently verified 17-step Xcode receipt.
 // The authoritative native stage verifier validates hashed logs and QA records.
 // Never turn a two-step wrapper summary into a dashboard PASS.
 const nativeSummaryMatches=!!sha&&native?.schemaVersion===1&&native?.mode==='native'&&
   native?.candidateSha===sha&&native?.status==='local-checks-passed'&&
   native?.exitCode===0&&native?.cleanCheckout===true&&
   Array.isArray(native?.steps)&&native.steps.length===2&&
   native.steps.every(step=>step?.success===true);
 add('native','Xcode and Swift regression receipt',null,
   nativeSummaryMatches?
     'A matching local wrapper summary exists, but its 17-step logs and QA hashes have not been independently verified here.':
     'No complete native wrapper summary matches the exact candidate SHA.',
   'Verify the 17 native steps, exact source SHA, hashed logs and independent QA record with verify-native-stage.mjs.');
 const full=!!sha&&inventory?.schema==='mp3shelf-physical-inventory-v1'&&
   inventory.candidateSha===sha&&Number.isSafeInteger(inventory.requested)&&
   inventory.requested>=2&&inventory.copiedTracks===inventory.requested&&
   inventory.unavailable===0&&Array.isArray(inventory.files)&&
   inventory.files.length===inventory.requested&&
   inventory.files.every(f=>HASH.test(f?.sha256??'')&&Number.isSafeInteger(f.bytes)&&f.bytes>=1024);
 add('playlist','Full physical Spotify playlist and audio hashes',full?null:false,
   full?inventory.requested+' audio files reported with SHA-256 values; bytes have not been independently rehashed by this dashboard.':
     'Missing exact-SHA full playlist audio inventory, or some recordings are unavailable.',
   'Run the paired-iPhone playlist acceptance and copy every recording for hashing.');
 const playback=full&&inventory.offlinePlaybackAfterRestart==='APP_INSTRUMENTED_PHYSICAL_PASS'&&
   inventory.backgroundTransfer==='APP_RECORDED_STAGING_AND_BACKGROUND_WAKE';
 add('playback','Real offline playback and URLSession callbacks',playback?null:false,
   playback?'App-reported offline playback and background callbacks exist; independent on-device verification is still required.':
     'No corroborated real-iPhone offline restart plus background callback evidence.',
   'Complete the on-device radios-off playback and background-transfer test.');
 const reviewed=!!sha&&HASH.test(inventorySHA256??'')&&
   handoffErrors({handoff:reviewHandoff,review,sha,inventorySHA256,
     signedAppSHA256:reviewHandoff?.signedAppSHA256,reviewSHA256,now}).length===0;
 add('review','Independent collected-device evidence review handoff',reviewed?true:null,
   reviewed?'Exact-SHA iPhone review and original hash-bound handoff are staged; owner approval remains separate.':
     'No fully matched independent iPhone review and source-bound release handoff are recorded.',
   'Run iPhone acceptance, independent review, and exact-SHA review handoff staging.');
 const ownerMarker='MP3SHELF_DEVICE_GATE_APPROVED SHA='+(sha??'')+
   ' INVENTORY_SHA256='+(inventorySHA256??'')+
   ' SIGNED_APP_SHA256='+(hardware?.signedAppSHA256??'');
 const ownerApproved=HASH.test(inventorySHA256??'')&&
   hardware?.inventorySHA256===inventorySHA256&&
   Array.isArray(ownerComments)&&ownerComments.some(comment=>
     comment?.user?.login==='jonnyt123'&&typeof comment.body==='string'&&
     comment.body.split(/\r?\n/).some(line=>line.trim()===ownerMarker));
 const hardwareApproved=ownerApproved&&!!sha&&issue?.number===6&&issue?.state==='closed'&&
   typeof issue.body==='string'&&CATEGORIES.every(label=>
     issue.body.split(/\r?\n/).some(line=>line.startsWith('- [x] **'+label+':**')))&&
   hardware?.schema==='mp3shelf-hardware-acceptance-v1'&&
   hardware.candidateSha===sha&&hardware.installedSourceSha===sha&&
   HASH.test(hardware.signedAppSHA256??'')&&hardware.reviewer==='jonnyt123'&&
   CATEGORIES.length===9&&Array.isArray(hardwareChecks(hardware))&&
   hardwareChecks(hardware).every(value=>value==='PASS');
 add('hardware','Owner-approved physical-iPhone release gate #6',
   hardwareApproved?true:false,
   hardwareApproved?'Checklist closed with matching owner-reviewed hardware JSON; final publish independently verifies owner comments.':
     'Issue #6 is open/unapproved, or signed-device checklist is incomplete.',
   'Independently inspect the real iPhone, approve its signed SHA-256 and close issue #6.');
 const smokeOK=!!toolingSha&&SHA.test(toolingSha)&&smoke?.toolingSha===toolingSha&&
   smoke?.deleted===true&&Number.isFinite(Date.parse(smoke.createdAt??''))&&
   now-Date.parse(smoke.createdAt)>=0&&now-Date.parse(smoke.createdAt)<7*86400000;
 add('smoke','Verified draft GitHub ZIP transport',smokeOK?null:false,
   smokeOK?'A recent local deletion record exists; this dashboard has not independently verified the owner attestation or remote asset digests.':
    'No recent owner-attested, checksum-matched and deleted draft upload for the current tooling SHA.',
   'Run the one-time draft upload smoke on Mac and verify its GitHub owner attestation.');
 // A GitHub release can contain two unrelated or duplicate assets with
 // valid-looking digests. Only the exact source-bound ZIP and manifest names
 // count as an observable delivery, and both must have nonempty uploaded bytes.
 // This remains advisory: the authoritative publisher re-downloads and hashes.
 const zipName=sha?'MP3-Shelf-Xcode-'+sha.slice(0,12)+'.zip':null;
 const manifestName=sha?'MP3-Shelf-Xcode-'+sha.slice(0,12)+'.manifest.json':null;
 const expectedNames=[zipName,manifestName];
 const released=!!sha&&release?.draft===false&&
   release?.tag_name==='mp3-shelf-ios-'+sha&&
   Array.isArray(release?.assets)&&release.assets.length===2&&
   expectedNames.every(name=>release.assets.some(asset=>
     asset?.name===name&&asset.state==='uploaded'&&
     Number.isSafeInteger(asset.size)&&asset.size>0&&
     /^sha256:[a-f0-9]{64}$/.test(asset.digest??'')));
 add('zip','Published verified Xcode project ZIP',released?null:false,
   released?'A matching source release advertises two SHA-256 digests; actual downloaded bytes and release authorization remain unverified here.':
     'No published GitHub Xcode project ZIP for the verified candidate.',
   'Complete all native, hardware and draft-smoke gates before publishing.');
 return {schema:'mp3shelf-release-readiness-v1',
   generatedAt:new Date(now).toISOString(),candidateSha:sha,toolingSha:SHA.test(toolingSha??'')?toolingSha:null,
   status:'NOT_RELEASE_READY',
   gates,blocking:gates.filter(g=>g.status!=='PASS').map(g=>g.key),
   disclaimer:'Read-only dashboard. It does not authorize ZIP publication or replace release verification.'};
}
function hardwareChecks(hardware){
 const keys=['signingInstallation','offlinePlayback','backgroundDownloads','failureHandling',
 'spotifyMetadata','backupInterop','accessibility','sourcePolicy','finalAcceptance'];
 return keys.map(k=>hardware?.checks?.[k]);
}
export function readinessMarkdown(model) {
 const lines=['# MP3 Shelf — Native Release Readiness','',
   'Generated: '+model.generatedAt,
   'Candidate: '+(model.candidateSha??'NOT_VERIFIED'),
   'Release tooling: '+(model.toolingSha??'NOT_VERIFIED'),
   'Overall: **'+model.status+'**','',
   '| Gate | State | Evidence |','|---|---|---|'];
 for(const g of model.gates)
   lines.push('| '+g.label.replace(/\|/g,'/')+' | '+g.status+
     ' | '+g.details.replace(/[|\n\r]/g,' ').slice(0,200)+' |');
 lines.push('','## Next actions');
 const blocked=model.gates.filter(g=>g.status!=='PASS');
 if(!blocked.length)lines.push('All dashboard indicators are present; the authoritative release gate still applies.');
 else blocked.forEach(g=>lines.push('- **'+g.label+':** '+g.action));
 lines.push('','This dashboard never substitutes for a real iPhone or exact-SHA native release verification.');
 return lines.join('\n')+'\n';
}
function htmlEscape(s){return String(s).replace(/[&<>"']/g,c=>({
  '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
export function readinessHTML(model){
 const cards=model.gates.map(g=>'<article class="gate"><div class="head"><strong>'+
   htmlEscape(g.label)+'</strong><span class="status '+g.status.toLowerCase()+'">'+
   htmlEscape(g.status)+'</span></div><p>'+htmlEscape(g.details)+'</p>'+
   (g.action?'<div class="action">'+htmlEscape(g.action)+'</div>':'')+'</article>').join('\n');
 const done=model.gates.filter(g=>g.status==='PASS').length;
 return '<!doctype html><html lang="en"><head><meta charset="utf-8">'+
 '<meta name="viewport" content="width=device-width, initial-scale=1">'+
 '<meta name="color-scheme" content="dark light"><title>MP3 Shelf — Release Readiness</title>'+
 '<style>:root{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;'+
 'color-scheme:dark;background:#10131b;color:#eef1f8}body{max-width:980px;margin:auto;padding:30px 18px 50px}'+
 'h1{font-size:clamp(27px,4vw,40px);letter-spacing:-.04em;margin:10px 0}'+
 'p{color:#aab4c6;line-height:1.5}.sub{font-size:13px}.meta{margin:20px 0 26px;'+
 'padding:16px;border:1px solid #30394a;border-radius:18px;background:#181d29}'+
 '.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(270px,1fr));gap:12px}'+
 '.gate{padding:18px;border-radius:18px;border:1px solid #30394a;background:#191f2d}'+
 '.head{display:flex;gap:12px;align-items:flex-start;justify-content:space-between}'+
 '.head strong{font-size:15px}.status{font-size:10px;letter-spacing:.08em;padding:6px 8px;'+
 'border:1px solid #4d5566;border-radius:99px;white-space:nowrap}.pass{color:#63dba6;border-color:#28684e}'+
 '.blocked{color:#ffb879;border-color:#87572c}.unverified{color:#d1d7e2}'+
 '.action{padding-top:12px;border-top:1px solid #353b4a;color:#c6d1e8;font-size:13px;line-height:1.45}'+
 '.gate p{font-size:13px}.foot{margin-top:30px;color:#8f9aaf;font-size:12px}</style></head><body>'+
 '<div class="sub">MP3 SHELF · NATIVE IOS</div><h1>Release readiness</h1>'+
 '<p>Read-only evidence dashboard. No synthetic results, no automatic hardware approval.</p>'+
 '<div class="meta"><strong>'+done+' / '+model.gates.length+' evidence gates recorded</strong>'+
 '<p class="sub">Overall: '+htmlEscape(model.status)+' · Source '+htmlEscape(model.candidateSha??'UNVERIFIED')+
 ' · Tooling '+htmlEscape(model.toolingSha??'UNVERIFIED')+'</p>'+
 '<p class="sub">Updated '+htmlEscape(model.generatedAt)+'</p></div>'+
 '<div class="grid">'+cards+'</div><p class="foot">'+htmlEscape(model.disclaimer)+'</p></body></html>';
}
function getLatestReview(home,sha){
 if(!SHA.test(sha??''))return null;
 const dir=join(home,'Library','Logs','MP3Shelf','DeviceAcceptance',sha,'reviews');
 try{
  const names=readdirSync(dir).filter(n=>/^review-[0-9TZ-]+-[0-9a-f-]{36}\.json$/.test(n)).sort().reverse();
  return names.length?json(join(dir,names[0])):null;
 }catch{return null;}
}
function gitHubLive(now){
 const branch=n=>ghJSON('git/ref/heads/'+n)?.object?.sha??null;
 const candidateSha=branch('feat/ios-consolidated-candidate');
 const toolingSha=branch('agent/mp3-release-evidence-gate');
 const issue=ghJSON('issues/6');
 let ownerComments=null;
 if(issue?.state==='closed'){
  ownerComments=[];
  for(let page=1;page<=20;page++){
   const items=ghJSON('issues/6/comments?per_page=100&page='+page);
   if(!Array.isArray(items)){ownerComments=null;break;}
   ownerComments.push(...items);
   if(items.length<100)break;
  }
 }
 let smoke=null;
 if(SHA.test(toolingSha??'')){
  for(let page=1;page<=20;page++){
   const comments=ghJSON('issues/22/comments?per_page=100&page='+page);
   if(!Array.isArray(comments))break;
   for(const c of comments){
    const item=verifiedSmokeComment(c,toolingSha,now);
    if(item){
      if(definite404('git/ref/tags/'+item.tag) &&
         definite404('releases/tags/'+item.tag))
        smoke={...item,deleted:true};
    }
   }
   if(comments.length<100)break;
  }
 }
 return{candidateSha,toolingSha,issue,ownerComments,smoke,
   release:SHA.test(candidateSha??'')?ghJSON('releases/tags/mp3-shelf-ios-'+candidateSha):null};
}
// The dashboard is not a release gate, but its output is still written by a
// background agent. Refuse redirected parent directories and hard-linked
// destinations so untrusted local paths cannot overwrite unrelated files.
export function ensureReadinessDestination(home) {
 const parts=[join(home,'Library'),join(home,'Library','Logs'),
   join(home,'Library','Logs','MP3Shelf'),
   join(home,'Library','Logs','MP3Shelf','ReleaseReadiness')];
 for(const dir of parts){
   try{
     const stat=lstatSync(dir);
     if(!stat.isDirectory()||stat.isSymbolicLink())
       throw Error('Unsafe release readiness directory');
   }catch(error){
     if(error.code!=='ENOENT')throw error;
     mkdirSync(dir,{mode:0o700});
   }
 }
 const dir=parts.at(-1);
 for(const ext of ['json','md','html']){
   try{
     const stat=lstatSync(join(dir,'latest.'+ext));
     if(!stat.isFile()||stat.isSymbolicLink()||stat.nlink!==1)
       throw Error('Unsafe release readiness destination');
   }catch(error){if(error.code!=='ENOENT')throw error;}
 }
 return dir;
}
export function writeReadiness({home=homedir(),now=Date.now(),github=gitHubLive}={}){
 const live=github(now);
 const sha=live.candidateSha;
 const logs=join(home,'Library','Logs','MP3Shelf');
 const nativeDir=SHA.test(sha??'')?selectNativeEvidence(join(logs,'NativePreflight'),sha):null;
 const inventoryPath=SHA.test(sha??'')?
   join(logs,'DeviceAcceptance',sha,'physical-inventory.json'):null;
 const rawInventory=inventoryPath?readSafe(inventoryPath,16*1024*1024):null;
 let parsedInventory=null;
 try{if(rawInventory)parsedInventory=JSON.parse(rawInventory);}catch{
   // Corrupt or partial device evidence is a BLOCKER, not a broken dashboard.
 }
 const deviceDir=SHA.test(sha??'')?join(logs,'DeviceAcceptance',sha):null;
 const reviewHandoff=deviceDir?json(join(deviceDir,'review-handoff.json'),65536):null;
 const reviewFile=reviewHandoff?.reviewFile;
 const reviewRaw=deviceDir&&/^review-[0-9TZ-]+-[0-9a-f-]{36}\.json$/.test(reviewFile??'')?
   readSafe(join(deviceDir,'reviews',reviewFile),512*1024):null;
 let reviewedJSON=null;
 try{if(reviewRaw)reviewedJSON=JSON.parse(reviewRaw);}catch{}
 const result=readinessModel({...live,now,
   agent:json(join(logs,'NativeAgent','latest-run.json')),
   native:nativeDir?json(join(nativeDir,'local-evidence.json')):null,
   inventory:parsedInventory,
   inventorySHA256:rawInventory?
     createHash('sha256').update(rawInventory).digest('hex'):null,
   hardware:deviceDir?json(join(deviceDir,'hardware-acceptance.json')):null,
   review:reviewedJSON,
   reviewHandoff,reviewSHA256:reviewRaw?
     createHash('sha256').update(reviewRaw).digest('hex'):null});
 const dir=ensureReadinessDestination(home);
 const body={json:JSON.stringify(result,null,2)+'\n',md:readinessMarkdown(result),html:readinessHTML(result)};
 const pending=[];
 try{
  for(const [ext,text] of Object.entries(body)){
   const target=join(dir,'latest.'+ext),temp=join(dir,'.writing-'+randomUUID()+'.tmp');
   pending.push(temp);
   writeFileSync(temp,text,{flag:'wx',mode:0o600});
  }
  // Recheck the targets immediately before replacing them. Each staged file
  // is private and complete; interrupted runs never leave partial JSON/HTML.
  ensureReadinessDestination(home);
  for(let i=0;i<pending.length;i++)
   renameSync(pending[i],join(dir,'latest.'+Object.keys(body)[i]));
 }finally{
  for(const temp of pending){
   try{unlinkSync(temp);}catch(error){if(error.code!=='ENOENT')throw error;}
  }
 }
 return {status:result.status,blocking:result.blocking,
   html:join(dir,'latest.html'),markdown:join(dir,'latest.md'),json:join(dir,'latest.json')};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 try{console.log(JSON.stringify(writeReadiness(),null,2));}
 catch(e){console.error('READINESS_UNVERIFIED: '+e.message);process.exitCode=1;}
}
