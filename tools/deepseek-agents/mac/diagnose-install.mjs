#!/usr/bin/env node
// Read-only, offline-first MP3 Shelf Mac setup diagnosis.
// NEVER claims jobs, starts services, invokes the model, or prints credentials/logs.
import { spawn } from "node:child_process";
import { readFile, lstat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import os from "node:os";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const home = os.homedir();
const coordinator = path.join(home,"Library/Application Support/MP3ShelfCloudCoordinator");
const qa = path.join(home,"Library/Application Support/MP3ShelfCloudQA");
const credentialsPath = path.join(coordinator,"credentials.json");
const tokenPath = path.join(coordinator,"coordinator-token");
const workerUrl = "https://mp3-shelf-coordinator.mp3shelf-jonny.workers.dev";
const stages = Object.freeze(["preflight","prerequisites","tests","cloudflare","mac-connection","publisher","xcode-qa","reporter","verification"]);
const agentLabels = ["com.mp3shelf.cloud-coordinator","com.mp3shelf.cloudqa"];
const daemonLabels = ["com.mp3shelf.publisher","com.mp3shelf.cloudqa.reporter"];

export function diagnoseSnapshot(s) {
  const issues = [];
  function issue(code, section, message, fix) { issues.push({code,section,message,fix}); }
  if (s.platform !== "darwin") issue("NOT_MAC","host","This setup must run on macOS.","Run the installer in Terminal on your Apple Silicon Mac.");
  if (!s.repoOk) issue("REPO_MISSING","repository","The MP3 Shelf source checkout is missing.","Clone the dedicated agent setup branch in ~/MP3ShelfAgents.");
  else if (!s.branchOk) issue("WRONG_BRANCH","repository","The local checkout is not on the agent setup branch.","Switch to agent/mp3-deepseek-low-cost-worker, then rerun the installer.");
  if (!s.gitOk) issue("GIT_MISSING","prerequisites","Git is unavailable.","Open Xcode Command Line Tools installer with xcode-select --install.");
  if (!s.nodeOk) issue("NODE_VERSION","prerequisites","Node.js 22+ is missing or not on PATH.","Run the installer again to install Node with Homebrew; reopen Terminal if PATH is stale.");
  if (!s.openCodeOk) issue("OPENCODE_MISSING","prerequisites","OpenCode V2 with --agent support is unavailable.","Install OpenCode V2 using the guided prerequisites step.");
  if (!s.xcodeOk) issue("XCODE_NOT_READY","prerequisites","Full Xcode is missing, unselected or its license is not accepted.","Open Xcode, accept its license and select /Applications/Xcode.app/Contents/Developer with xcode-select.");
  if (!s.tokenFile) issue("TOKEN_NOT_LOCAL","cloudflare","No locally saved coordinator token was found.","Run setup-all.sh; it will securely synchronize a new token to the existing Cloudflare Worker.");
  else if (!s.tokenFormat) issue("TOKEN_INVALID","cloudflare","The local coordinator token has an invalid format.","Rerun the Cloudflare connection step to generate a valid private token.");
  else if (!s.tokenPermissions) issue("TOKEN_PERMISSIONS","cloudflare","Coordinator token permissions are too broad.","Restrict the private coordinator token to mode 0600.");
  if (!s.credentialFile) issue("DEEPSEEK_SETUP_INCOMPLETE","mac-connection","Mac credentials have not been configured.","Rerun setup-all.sh and enter the DeepSeek key privately when prompted.");
  else if (!s.credentialPermissions) issue("CREDENTIAL_PERMISSIONS","mac-connection","Mac credentials are readable by another user.","Restrict credentials.json to mode 0600; do not share it.");
  else if (!s.credentialFormat) issue("CREDENTIAL_INVALID","mac-connection","Mac credentials failed format validation.","Rerun install-mac-coordinator.sh from setup-all.sh.");
  else if (s.tokenMatches === false) issue("TOKEN_OUT_OF_SYNC","cloudflare","Local token and saved Mac credentials disagree.","Rerun install-mac-coordinator.sh to synchronize local credentials. Do not paste keys into chat.");
  if (s.cloudStatus === 401 || s.cloudStatus === 403) issue("CLOUD_AUTH","cloudflare","Cloudflare rejected the Mac coordinator token.","Run cloudflare/connect-existing.sh to rotate the token, then reinstall the Mac coordinator.");
  else if (s.cloudStatus === "network") issue("CLOUD_NETWORK","cloudflare","Cloudflare is unreachable from your Mac.","Check macOS Internet/DNS/VPN and verify the workers.dev URL loads in Safari.");
  else if (typeof s.cloudStatus === "number" && s.cloudStatus !== 200) issue("CLOUD_RESPONSE","cloudflare","Cloudflare responded with HTTP "+s.cloudStatus+".","Review the Worker deployment and D1 binding; do not recreate the database.");
  if (s.deepSeekStatus === 401 || s.deepSeekStatus === 403) issue("DEEPSEEK_AUTH","deepseek","DeepSeek rejected the API key.","Check DeepSeek API credentials and update them in the local Mac installer.");
  else if (s.deepSeekStatus === "network") issue("DEEPSEEK_NETWORK","deepseek","DeepSeek's balance endpoint is unreachable.","Check network access to api.deepseek.com; no model request was sent.");
  else if (typeof s.deepSeekStatus === "number" && s.deepSeekStatus !== 200) issue("DEEPSEEK_RESPONSE","deepseek","DeepSeek balance check returned HTTP "+s.deepSeekStatus+".","Review DeepSeek Console API access.");
  else if (s.deepSeekStatus === 200 && s.deepSeekAvailable === false) issue("DEEPSEEK_NO_CREDIT","deepseek","DeepSeek reports no usable API balance.","Review API credits before resuming the agents.");
  for (const label of agentLabels) {
    const svc = s.services[label];
    if (!svc?.plist) issue("AGENT_NOT_INSTALLED","launchd",label+" LaunchAgent is missing.","Rerun the guided installer (safe to repeat).");
    else if (svc.loaded === false) issue("AGENT_NOT_LOADED","launchd",label+" is not loaded in your login session.","Check the service plist with plutil -lint and rerun its installer. Do not resume paid work yet.");
  }
  for (const label of daemonLabels) {
    const svc = s.services[label];
    if (!svc?.plist) issue("DAEMON_NOT_INSTALLED","launchd",label+" protected LaunchDaemon is missing.","Rerun the GitHub publisher/status-reporting installation with administrator approval.");
    else if (svc.loaded === false) issue("DAEMON_NOT_LOADED","launchd",label+" is not loaded.","Rerun the corresponding sudo installer; GitHub tokens stay root-only.");
  }
  if (s.macOnline === false && s.cloudStatus === 200 && s.services[agentLabels[0]]?.loaded === true) {
    issue("MAC_HEARTBEAT_MISSING","runtime","Cloudflare has not recently heard from the Mac runner.","Review the local worker-errors.log privately and check the user LaunchAgent. The queue cannot run without it.");
  }
  const fixed = s.logCodes || [];
  if (fixed.includes("AUTH_ERROR") && !issues.some(i=>i.code==="CLOUD_AUTH")) issue("LOG_AUTH_FAILURE","runtime","Mac worker logs indicate a credential rejection.","Reconnect the Mac token without sharing it.");
  if (fixed.includes("COMMAND_NOT_FOUND")) issue("LOG_COMMAND_MISSING","runtime","Worker logs indicate a missing executable.","Recheck Node/OpenCode and the PATH configured for launchd.");
  if (fixed.includes("MODEL_ERROR")) issue("LOG_MODEL_FAILURE","runtime","Agent logs indicate a model/provider configuration problem.","Verify OpenCode V2 and the configured DeepSeek model; no automatic paid retry.");
  const codes=[...new Set(issues.map(i=>i.code))];
  return {ok:issues.length===0,failedStage:stages.includes(s.failedStage)?s.failedStage:null,
    issueCount:issues.length,issues,observations:{
      cloudPaused:s.cloudPaused ?? null,macOnline:s.macOnline ?? null,
      cloudHttp:s.cloudStatus ?? null,deepSeekHttp:s.deepSeekStatus ?? null,
      macServices:Object.fromEntries([...agentLabels,...daemonLabels].map(x=>[x,s.services[x]?.loaded===true]))
    },
    safety:"Read-only checks. No credentials or raw logs included; no model request, job claim, git push or paid action."};
}
export function logSignals(text) {
  // Classify patterns ONLY; never return raw log lines, tokens, URLs or paths.
  const t=String(text||"").slice(-30000);
  const codes=[];
  if (/401|403|unauthori[sz]ed|invalid token|invalid.*credential/i.test(t)) codes.push("AUTH_ERROR");
  if (/command not found|ENOENT|no such file or directory|spawn.*ENOENT/i.test(t)) codes.push("COMMAND_NOT_FOUND");
  if (/invalid model|model.*not found|provider.*not found|unsupported model/i.test(t)) codes.push("MODEL_ERROR");
  return codes;
}
async function run(cmd,args=[],timeout=7000) {
  return new Promise(resolve=>{
    const p=spawn(cmd,args,{stdio:["ignore","pipe","pipe"],env:{
      PATH:"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", HOME:home,
      LANG:"en_US.UTF-8"
    }});
    let output="";
    const timer=setTimeout(()=>p.kill("SIGKILL"),timeout);
    p.stdout.on("data",x=>{output=(output+x.toString()).slice(-5000);});
    p.stderr.on("data",x=>{output=(output+x.toString()).slice(-5000);});
    p.once("error",()=>{clearTimeout(timer);resolve({ok:false,output:""});});
    p.once("close",n=>{clearTimeout(timer);resolve({ok:n===0,output});});
  });
}
async function fileState(filename) {
  try {
    const info=await lstat(filename);
    return {exists:info.isFile(),safe:info.isFile() && (info.mode&0o077)===0};
  } catch { return {exists:false,safe:false}; }
}
async function fetchCode(url,token) {
  try { const r=await fetch(url,{headers:token?{authorization:"Bearer "+token}:{},
    signal:AbortSignal.timeout(8500),redirect:"error"});return r; }
  catch { return null; }
}
export async function snapshot() {
  const s={platform:process.platform,services:{},failedStage:process.env.MP3_FAILED_STAGE || null,
    cloudStatus:null,deepSeekStatus:null,deepSeekAvailable:null,macOnline:null,cloudPaused:null};
  const [git,node,code,xcode,branch,codehelp]=await Promise.all([
    run("git",["--version"]),run("node",["--version"]),
    run("opencode",["--version"]),run("xcodebuild",["-version"]),
    run("git",["-C",root,"branch","--show-current"]),
    run("opencode",["run","--help"])
  ]);
  s.repoOk=(await fileState(path.join(root,".git","HEAD"))).exists || (await fileState(path.join(root,".git"))).exists;
  s.branchOk=branch.ok && branch.output.trim()==="agent/mp3-deepseek-low-cost-worker";
  s.gitOk=git.ok;s.nodeOk=node.ok && /^v(2[2-9]|[3-9]\d)\./.test(node.output.trim());
  s.openCodeOk=code.ok && /^2\./.test(code.output.trim()) && codehelp.ok && codehelp.output.includes("--agent");
  s.xcodeOk=xcode.ok && xcode.output.includes("Xcode");
  const tokenStat=await fileState(tokenPath),credStat=await fileState(credentialsPath);
  s.tokenFile=tokenStat.exists;s.tokenPermissions=tokenStat.safe;
  s.credentialFile=credStat.exists;s.credentialPermissions=credStat.safe;
  let token="",cred=null;
  if(tokenStat.safe){token=(await readFile(tokenPath,"utf8")).trim();s.tokenFormat=/^[a-f0-9]{64}$/.test(token);}
  if(credStat.safe){
    try{
      cred=JSON.parse(await readFile(credentialsPath,"utf8"));
      s.credentialFormat=typeof cred?.workerUrl==="string" && /^https:\/\/[a-z0-9.-]+\/?$/i.test(cred.workerUrl) &&
       /^[a-f0-9]{64}$/.test(cred.coordinatorToken||"") &&
       /^[A-Za-z0-9_.-]{12,}$/.test(cred.deepseekApiKey||"");
      if(tokenStat.safe && s.tokenFormat) s.tokenMatches=cred.coordinatorToken===token;
    }catch{s.credentialFormat=false;}
  }
  for(const [i,label] of [...agentLabels,...daemonLabels].entries()){
    const user=i<2;
    const filename=user?path.join(home,"Library/LaunchAgents",label+".plist"):"/Library/LaunchDaemons/"+label+".plist";
    const exists=(await fileState(filename)).exists;
    const target=user?"gui/"+process.getuid()+"/"+label:"system/"+label;
    const result=exists?await run("launchctl",["print",target]):{ok:false};
    s.services[label]={plist:exists,loaded:result.ok};
  }
  if(cred && s.credentialFormat) {
    const r=await fetchCode(cred.workerUrl.replace(/\/$/,"")+"/v1/status",cred.coordinatorToken);
    s.cloudStatus=r?.status??"network";
    if(r?.ok){
      try{const data=await r.json();s.cloudPaused=data.paused;
        const seen=Number(data.mac?.lastSeen || 0);
        s.macOnline=seen>0 && Date.now()-seen<10*60_000;}catch{}
    }
    // Separate, read-only DeepSeek balance call; no model/credit-consuming endpoint.
    let dr=null;
    try{dr=await fetch("https://api.deepseek.com/user/balance",{headers:{Authorization:"Bearer "+cred.deepseekApiKey,Accept:"application/json"},signal:AbortSignal.timeout(8500)});}catch{}
    s.deepSeekStatus=dr?.status??"network";
    if(dr?.ok){try{const j=await dr.json();s.deepSeekAvailable=j.is_available===true;}catch{}}
  } else if(s.credentialFile && !s.credentialFormat) {
    s.cloudStatus=null;s.deepSeekStatus=null;
  }
  const files=[path.join(coordinator,"worker-errors.log"),path.join(qa,"launch-error.log")];
  s.logCodes=[];
  for(const name of files){try{s.logCodes.push(...logSignals(await readFile(name,"utf8")));}catch{}}
  return s;
}
async function main() {
  const s=await snapshot();
  const output=diagnoseSnapshot(s);
  // Output contains only fixed classifiers, counts, booleans and safe instructions.
  if(process.argv.includes("--json"))console.log(JSON.stringify(output,null,2));
  else {
    console.log("MP3 Shelf Mac setup diagnosis (read-only)");
    if(output.failedStage)console.log("Interrupted setup stage: "+output.failedStage);
    console.log(output.ok?"No setup problems detected. Real model/Xcode QA still unverified.":"Found "+output.issueCount+" actionable setup check(s).");
    output.issues.forEach((x,i)=>console.log("\n"+(i+1)+". "+x.code+": "+x.message+"\n   Fix: "+x.fix));
    console.log("\nCloudflare queue paused: "+(output.observations.cloudPaused===null?"unknown":output.observations.cloudPaused));
    console.log(output.safety);
  }
  process.exitCode=output.ok?0:1;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  main().catch(()=>{console.error("Diagnostic checks could not finish. No credentials were printed.");process.exitCode=2;});
}
