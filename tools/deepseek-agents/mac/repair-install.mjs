#!/usr/bin/env node
// Conservative macOS repair executor for MP3 Shelf.
// Only local 0600 permissions and known user LaunchAgents. No credential rotation,
// paid AI calls, job claims, root commands, Git pushes, or cloud resumption.
import { lstat, chmod } from "node:fs/promises";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import os from "node:os";
import {snapshot,diagnoseSnapshot} from "./diagnose-install.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const home = os.homedir();
const privateDir = path.join(home, "Library/Application Support/MP3ShelfCloudCoordinator");
const launchDir = path.join(home, "Library/LaunchAgents");
const safeLabels = Object.freeze({
  "com.mp3shelf.cloud-coordinator": {
    args: ["--loop"],
    script: path.join(root,"tools/deepseek-agents/cloudflare/mac-client.mjs")
  },
  "com.mp3shelf.cloudqa": {
    args: [],
    script: path.join(home,".local/bin/mp3-shelf-mac-qa")
  }
});
const permitted = Object.freeze(["TOKEN_PERMISSIONS","CREDENTIAL_PERMISSIONS","AGENT_NOT_LOADED"]);

export function safeRepairPlan(report,s) {
  if(s?.platform!=="darwin" || !report || !Array.isArray(report.issues))return [];
  const actions=[];
  for(const entry of report.issues) {
    if(!permitted.includes(entry.code))continue;
    if(entry.code==="TOKEN_PERMISSIONS" && s.tokenFile)
      actions.push({id:"restrict-token",kind:"permissions"});
    if(entry.code==="CREDENTIAL_PERMISSIONS" && s.credentialFile)
      actions.push({id:"restrict-credentials",kind:"permissions"});
    if(entry.code==="AGENT_NOT_LOADED" && typeof entry.message==="string") {
      const label=Object.keys(safeLabels).find(k=>entry.message.startsWith(k+" "));
      // Never start a coding process if the remote queue is active or unverified.
      if(!label || s.cloudStatus!==200 || s.cloudPaused!==true ||
         s.tokenMatches!==true || s.credentialPermissions!==true ||
         !s.nodeOk || !s.openCodeOk || !s.xcodeOk)continue;
      actions.push({id:"restore-"+label,kind:"launch-agent",label});
    }
  }
  return actions;
}
async function ownRegularFile(filename) {
  try {
    const info=await lstat(filename);
    return info.isFile() && !info.isSymbolicLink() && info.uid===process.getuid();
  } catch { return false; }
}
async function exec(exe,args,ms=7000) {
  return new Promise(resolve=>{
    const proc=spawn(exe,args,{stdio:["ignore","pipe","pipe"],
      env:{PATH:"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",HOME:home}});
    let output="";
    const timeout=setTimeout(()=>proc.kill("SIGKILL"),ms);
    proc.stdout.on("data",d=>{output=(output+d.toString()).slice(-6000);});
    proc.stderr.on("data",d=>{output=(output+d.toString()).slice(-6000);});
    proc.once("error",()=>{clearTimeout(timeout);resolve({ok:false,output:""});});
    proc.once("close",status=>{clearTimeout(timeout);resolve({ok:status===0,output});});
  });
}
export function expectedPlist(label,plist) {
  const spec=safeLabels[label];
  if(!spec || !plist || plist.Label!==label ||
    plist.RunAtLoad!==true || !Array.isArray(plist.ProgramArguments))return false;
  const argv=plist.ProgramArguments;
  if(label==="com.mp3shelf.cloud-coordinator"){
    return argv.length===3 && /\/node$/.test(argv[0]) &&
      argv[1]===spec.script && argv[2]==="--loop";
  }
  return argv.length===2 && argv[0]==="/bin/bash" && argv[1]===spec.script;
}
async function restoreAgent(label) {
  if(!safeLabels[label])return {ok:false,message:"Unrecognized launch agent"};
  const plist=path.join(launchDir,label+".plist");
  if(!(await ownRegularFile(plist)))return {ok:false,message:"Refusing unexpected or unowned service configuration"};
  const checked=await exec("plutil",["-lint",plist]);
  if(!checked.ok)return {ok:false,message:"Invalid launchd property list"};
  const json=await exec("plutil",["-convert","json","-o","-",plist]);
  if(!json.ok)return {ok:false,message:"Cannot inspect launchd configuration"};
  let parsed;
  try {parsed=JSON.parse(json.output);}catch{return {ok:false,message:"Invalid launchd JSON"};}
  if(!expectedPlist(label,parsed))return {ok:false,message:"LaunchAgent differs from the trusted MP3 Shelf installer"};
  // Do not silently start an arbitrary executable; validate the known app-owned script.
  if(!(await ownRegularFile(safeLabels[label].script)))
    return {ok:false,message:"The trusted LaunchAgent script is missing or not owned by this user"};
  const boot=await exec("launchctl",["bootstrap","gui/"+process.getuid(),plist]);
  return {ok:boot.ok,message:boot.ok?"Restored an installed user LaunchAgent":"LaunchAgent bootstrap failed; use the installer for detailed repair"};
}
export async function applySafeRepairs(actions,s) {
  const results=[];
  if(!Array.isArray(actions) || !s || s.platform!=="darwin")return results;
  for(const a of actions){
    if(a.kind==="permissions" && a.id==="restrict-token"){
      const file=path.join(privateDir,"coordinator-token");
      const ok=await ownRegularFile(file);
      if(ok)await chmod(file,0o600);
      results.push({id:a.id,ok,message:ok?"Restricted local token to 0600":"Skipped unowned, missing, or symlinked token file"});
    }else if(a.kind==="permissions" && a.id==="restrict-credentials"){
      const file=path.join(privateDir,"credentials.json");
      const ok=await ownRegularFile(file);
      if(ok)await chmod(file,0o600);
      results.push({id:a.id,ok,message:ok?"Restricted local credentials to 0600":"Skipped unowned, missing, or symlinked credentials file"});
    }else if(a.kind==="launch-agent" && safeLabels[a.label] && a.id==="restore-"+a.label &&
      s.cloudPaused===true && s.cloudStatus===200 && s.tokenMatches===true &&
      s.credentialPermissions===true && s.nodeOk && s.openCodeOk && s.xcodeOk) {
      const result=await restoreAgent(a.label);
      results.push({id:a.id,...result});
    }
  }
  return results;
}
async function main(){
  const s=await snapshot();
  const d=diagnoseSnapshot(s);
  const plan=safeRepairPlan(d,s);
  if(!process.argv.includes("--fix")){
    console.log("MP3 Shelf safe self-repair preview (read-only)");
    console.log(JSON.stringify({possible:plan.map(a=>a.id),issues:d.issues.map(x=>x.code)},null,2));
    console.log("Use --fix to apply only explicitly allowlisted local repairs.");
    return;
  }
  const results=await applySafeRepairs(plan,s);
  console.log(JSON.stringify({attempted:results.length,results,
    skipped:d.issues.map(x=>x.code).filter(code=>!permitted.includes(code)),
    note:"No cloud queue changes, paid model requests, GitHub calls or privileged service changes."},null,2));
  // Unresolved issues require manual review. Don't claim everything passed.
  if(results.some(x=>!x.ok))process.exitCode=1;
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url))
  main().catch(()=>{console.error("Repair was interrupted. No secrets were printed.");process.exitCode=2;});
