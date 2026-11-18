#!/usr/bin/env node
/** Read-only launchd/Xcode health inspection; --repair may bootstrap ONLY our verified LaunchAgent. */
import { execFileSync } from 'node:child_process';
import { existsSync, lstatSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const LABEL='com.jonnyt.mp3shelf.native-preflight';
const SHA=/^[0-9a-f]{40}$/;
function command(exe,args,timeout=12000){
 try{return {ok:true,stdout:execFileSync(exe,args,{encoding:'utf8',timeout,maxBuffer:512*1024,
   stdio:['ignore','pipe','pipe']}).trim()};}
 catch(e){return {ok:false,reason:e?.code==='ENOENT'?'COMMAND_MISSING':'COMMAND_FAILED'};}
}
function safeJSON(path,max=128*1024){
 try {const s=lstatSync(path);if(!s.isFile()||s.isSymbolicLink()||s.nlink!==1||s.size<2||s.size>max)return null;
  return JSON.parse(readFileSync(path,'utf8'));}catch{return null;}
}
export function evaluateAgentHealth({platform='darwin',node=null,xcode=null,developerDir=null,
 plist=null,loaded=false,latest=null,now=Date.now(),sourceRoot=null}={}){
 const checks={},put=(key,ok,detail)=>{checks[key]={status:ok?'PASS':'BLOCKED',detail};};
 put('macOS',platform==='darwin','Physical Mac is required for native verification.');
 put('node',typeof node==='string'&&node.length>0,'Node executable is available for launchd.');
 put('xcode',typeof xcode==='string'&&/^Xcode \d/.test(xcode)&&
   typeof developerDir==='string'&&/\/Xcode[^/]*\.app\/Contents\/Developer$/.test(developerDir),
   'Full Xcode is selected; Command Line Tools alone are insufficient.');
 const args=plist?.ProgramArguments;
 const expectedEntry=typeof sourceRoot==='string'?resolve(sourceRoot,'scripts','native-agent-run.mjs'):null;
 const owned=plist?.Label===LABEL&&Array.isArray(args)&&args.length===3&&
   args[0]===node&&args[1]===expectedEntry&&args[2]===sourceRoot&&
   plist.RunAtLoad===true&&plist.StartInterval===3600&&plist.WorkingDirectory===sourceRoot;
 put('plist',owned,'The exact MP3 Shelf hourly launchd plist is owned and correctly configured.');
 put('launchd',owned&&loaded,'The MP3 Shelf user LaunchAgent is loaded by launchctl.');
 const finished=Date.parse(latest?.finishedAt??'');
 const fresh=latest?.schema==='mp3shelf-native-agent-run-v1'&&
   ['COMPLETED','FAILED','BLOCKED'].includes(latest.status)&&
   Number.isFinite(finished)&&Number.isFinite(now)&&finished<=now+300000&&
   now-finished<=2*3600000;
 put('recentRun',fresh,'A real native agent invocation wrote a recent exact-run status.');
 const failed=latest?.status==='FAILED'||latest?.status==='BLOCKED';
 const blockers=Object.entries(checks).filter(([,v])=>v.status!=='PASS').map(([k])=>k);
 return {schema:'mp3shelf-mac-agent-health-v1',generatedAt:new Date(now).toISOString(),
   status:blockers.length||failed?'NEEDS_ATTENTION':'AGENT_RUNNING_RECENTLY',
   checks,blockers,agentStatus:fresh?latest.status:'NOT_VERIFIED',
   candidateSHA:SHA.test(latest?.candidateSha??'')?latest.candidateSha:null,
   xcodeBuild:'NOT_ATTESTED_BY_HEALTH_CHECK',
   repair:platform!=='darwin'?'REQUIRES_MAC':!owned?'RUN_TRUSTED_INSTALLER':
      !loaded?'BOOTSTRAP_OWNED_AGENT':!fresh?'INSPECT_LAUNCHD_LOGS_AND_KICKSTART':'NO_REPAIR_NEEDED',
   note:'Agent health is not a passing Xcode build or physical-iPhone acceptance.'};
}
export function inspectMacAgent({home=homedir(),root=resolve(import.meta.dirname??process.cwd(),'..'),
 repair=false,platform=process.platform,runner=command}={}){
 const plistPath=join(home,'Library','LaunchAgents',LABEL+'.plist');
 const nodePath=process.execPath;
 const xcode=runner('xcodebuild',['-version']);
 const selected=runner('xcode-select',['-p']);
 const plistFile=(()=>{
  try{
   const s=lstatSync(plistPath);
   if(!s.isFile()||s.isSymbolicLink()||s.nlink!==1)return null;
   const p=runner('plutil',['-convert','json','-o','-',plistPath]);
   return p.ok?JSON.parse(p.stdout):null;
  }catch{return null;}
 })();
 const target='gui/'+process.getuid()+'/'+LABEL;
 let loaded=runner('launchctl',['print',target]).ok;
 let report=evaluateAgentHealth({platform,node:nodePath,xcode:xcode.ok?xcode.stdout:null,
  developerDir:selected.ok?selected.stdout:null,plist:plistFile,loaded,
  latest:safeJSON(join(home,'Library','Logs','MP3Shelf','NativeAgent','latest-run.json')),
  sourceRoot:root});
 if(repair){
  if(report.repair!=='BOOTSTRAP_OWNED_AGENT')
   throw Error('Repair refused: only an unloaded, verified MP3 Shelf plist can be bootstrapped. Status: '+report.repair);
  const boot=runner('launchctl',['bootstrap','gui/'+process.getuid(),plistPath]);
  if(!boot.ok)throw Error('launchd bootstrap did not succeed; inspect private launchd diagnostics.');
  loaded=runner('launchctl',['print',target]).ok;
  if(!loaded)throw Error('launchd bootstrap did not confirm loaded status.');
  runner('launchctl',['kickstart','-k',target]);
  report=evaluateAgentHealth({platform,node:nodePath,xcode:xcode.ok?xcode.stdout:null,
    developerDir:selected.ok?selected.stdout:null,plist:plistFile,loaded,
    latest:safeJSON(join(home,'Library','Logs','MP3Shelf','NativeAgent','latest-run.json')),
    sourceRoot:root});
 }
 return report;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 const args=process.argv.slice(2),repair=args.includes('--repair');
 if(args.length>1||args.some(x=>x!=='--repair')){console.error('Usage: node scripts/mac-agent-health.mjs [--repair]');process.exitCode=2;}
 else try{const result=inspectMacAgent({root:resolve(process.cwd()),repair});
  console.log(JSON.stringify(result,null,2));
  if(result.status!=='AGENT_RUNNING_RECENTLY')process.exitCode=1;
 }catch(e){console.error('MAC_NATIVE_AGENT_HEALTH_BLOCKED: '+e.message);process.exitCode=1;}
}
