#!/usr/bin/env node
// Immutable, root-installed macOS GitHub broker. DeepSeek/OpenCode never sees this token.
import { spawn } from "node:child_process";
import { readFile, lstat } from "node:fs/promises";
import path from "node:path";

export const roles = Object.freeze(["mp3-playback","mp3-sources","mp3-ui","mp3-qa","mp3-integration"]);
export const repository = "jonnyt123/mp3-shelf";
export const base = "agent/mp3-deepseek-low-cost-worker";
const remote = "https://github.com/" + repository + ".git";
const root = "/Library/Application Support/MP3ShelfPublisher";
const tokenPath = path.join(root, "publisher.token");
const askpass = path.join(root, "askpass.sh");
const source = process.env.MP3_SOURCE_REPO;
const evidencePath = process.env.MP3_EVIDENCE_DIR;

export function safeBranch(role) {
  if (!roles.includes(role)) throw Error("Invalid agent role");
  return "agent/" + role;
}
export function validEvidence(e, role, sha, files) {
  return !!e && e.role === role && e.sha === sha &&
    e.diffCheck === "pass" && e.nodeGuardTests === "pass" &&
    e.macXcode !== "pass" && Array.isArray(e.files) &&
    files.length > 0 && e.files.length === files.length &&
    files.every(f => typeof f === "string" &&
      !f.startsWith("/") && !f.split("/").includes("..") && e.files.includes(f));
}
const filePolicy = {
  "mp3-playback": [/^ios\/MP3Shelf\/Services\/(PlaybackController|MusicLibrary|PortableShelfArchive)\.swift$/, /^ios\/MP3Shelf\/Models\/MusicModels\.swift$/, /^ios\/Tests\/[^/]+\.swift$/, /^src\/lib\/(backup(\.test)?\.ts|tracks\.ts)$/],
  "mp3-sources": [/^ios\/MP3Shelf\/Services\/(SpotifyService|AudioSourceFinder|BackgroundAudioDownloader)\.swift$/, /^ios\/MP3Shelf\/Models\/SourceDiscoveryJob\.swift$/, /^ios\/MP3Shelf\/Views\/DownloadManagerView\.swift$/, /^ios\/Tests\/[^/]+\.swift$/],
  "mp3-ui": [/^ios\/MP3Shelf\/Views\/(?!DownloadManagerView\.swift$)[^/]+\.swift$/, /^ios\/DESIGN_SYSTEM\.md$/],
  "mp3-qa": [/^ios\/Tests\/[^/]+\.swift$/, /^ios\/DEVICE_QA\.md$/, /^src\/lib\/[^/]+\.test\.ts$/],
  "mp3-integration": [/^ios\/MP3Shelf\.xcodeproj\/[^/]+\/.*$/, /^ios\/MP3Shelf\/MP3ShelfApp\.swift$/, /^ios\/README\.md$/, /^ios\/scripts\/(?!run-on-iphone\.sh$)[^/]+$/]
};
export function ownedFiles(role, files) {
  if (!roles.includes(role) || !files.length) return false;
  return files.every(p => filePolicy[role].some(re => re.test(p)));
}
async function exec(bin,args,secret=false) {
  const env = {PATH:process.env.PATH || "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
    HOME:"/var/root", GIT_TERMINAL_PROMPT:"0", GIT_CONFIG_GLOBAL:"/dev/null",
    GIT_CONFIG_NOSYSTEM:"1", GIT_LFS_SKIP_SMUDGE:"1"};
  if (secret) env.GIT_ASKPASS=askpass;
  return new Promise((resolve,reject) => {
    const p=spawn(bin,args,{cwd:root,env,stdio:["ignore","pipe","pipe"]});
    let out="",err="";
    const timer=setTimeout(()=>p.kill("SIGKILL"),120000);
    p.stdout.on("data",d=>{out=(out+d.toString()).slice(-15000)});
    p.stderr.on("data",d=>{err=(err+d.toString()).slice(-3000)});
    p.once("error",e=>{clearTimeout(timer);reject(e)});
    p.once("close",code=>{clearTimeout(timer);code===0?resolve(out.trim()):reject(Error(bin+" exit "+code+": "+err))});
  });
}
async function git(args,auth=false) {
  if (!source || !path.isAbsolute(source)) throw Error("Trusted source repository not configured");
  return exec("git",["-c","core.hooksPath=/dev/null","-c","protocol.ext.allow=never",
    "-c","credential.helper=","-c","safe.directory="+source,"-C",source,...args],auth);
}
async function github(endpoint,method="GET",body) {
  const token=(await readFile(tokenPath,"utf8")).trim();
  if (!/^[A-Za-z0-9_]{25,}$/.test(token)) throw Error("Invalid publisher credential");
  const r=await fetch("https://api.github.com/repos/"+repository+endpoint,{
    method,headers:{authorization:"Bearer "+token,accept:"application/vnd.github+json",
      "x-github-api-version":"2022-11-28","user-agent":"mp3-shelf-mac-publisher",
      ...(body?{"content-type":"application/json"}:{})},
    body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(20000)});
  if (!r.ok) throw Error("GitHub API "+method+" "+endpoint+" returned "+r.status);
  return r.json();
}
async function publish(role) {
  const branch=safeBranch(role);
  const evidenceFile=path.join(evidencePath,role+".json");
  const stat=await lstat(evidenceFile);
  if (!stat.isFile() || stat.isSymbolicLink()) throw Error("Non-regular evidence");
  const approval=JSON.parse(await readFile(evidenceFile,"utf8"));
  const origin=(await git(["remote","get-url","origin"])).trim();
  if (origin!==remote) throw Error("Unexpected Git origin URL");
  const sha=(await git(["rev-parse","refs/heads/"+branch])).trim();
  if (!/^[a-f0-9]{40}$/.test(sha)) throw Error("Invalid local HEAD");
  const commitMessage=await git(["show","-s","--format=%B",sha]);
  if (!commitMessage.includes("[skip ci]")) throw Error("Missing CI-skip marker");
  const parent=await git(["rev-parse",sha+"^"]);
  const status=await git(["diff","--name-status",parent,sha]);
  const entries=status.split("\n").filter(Boolean).map(line=>line.split("\t"));
  if(entries.some(row=>row[0]!=="M"&&row[0]!=="A")) throw Error("Deleted/renamed/unexpected files");
  const files=entries.map(row=>row[1]);
  if(!validEvidence(approval,role,sha,files)||!ownedFiles(role,files)) throw Error("Unapproved file set or commit");
  await git(["fetch","--no-tags",remote,"refs/heads/"+base]);
  const currentBase=await git(["rev-parse","FETCH_HEAD"]);
  await git(["merge-base","--is-ancestor",currentBase,sha]);
  const heads=await git(["ls-remote","--heads",remote,"refs/heads/"+branch]);
  if(heads) {
    const old=heads.split(/\s+/)[0];
    if(old===sha) return {role,sha,alreadyPublished:true};
    await git(["fetch","--no-tags",remote,"refs/heads/"+branch]);
    if ((await git(["rev-parse","FETCH_HEAD"]))!==old) throw Error("Remote moved; retry");
    await git(["merge-base","--is-ancestor",old,sha]);
  }
  await git(["push",remote,sha+":refs/heads/"+branch],true); // Non-force, one allowlisted ref.
  const prs=await github("/pulls?state=open&head=jonnyt123:"+encodeURIComponent(branch)+"&base="+encodeURIComponent(base));
  if(!Array.isArray(prs)) throw Error("Unexpected PR search result");
  if (!prs.length) {
    await github("/pulls","POST",{
      title:"MP3 Shelf agent: "+role+" (native Mac QA pending)",
      head:branch,base,draft:true,
      body:"Automatically published a locally guard-tested source change. Unsigned macOS Xcode verification and independent review are pending. Physical iPhone gate #6 NOT satisfied. No automatic merge into main. Coordination issue #22."
    });
  }
  return {role,sha,uploaded:true};
}
export async function run() {
  if (typeof process.getuid === "function" && process.getuid()!==0) throw Error("Root-only separate broker");
  if (!source || !evidencePath || !path.isAbsolute(evidencePath)) throw Error("Trusted paths not configured");
  for(const role of roles) {
    try {console.log(JSON.stringify(await publish(role)));}
    catch(e) {if (e.code!=="ENOENT") console.error(role+": "+e.message);}
  }
}
if(process.argv[1]&&path.resolve(process.argv[1])===new URL(import.meta.url).pathname){
  run().catch(e=>{console.error(e.message);process.exitCode=1});
}
