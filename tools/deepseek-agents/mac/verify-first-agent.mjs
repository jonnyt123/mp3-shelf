#!/usr/bin/env node
/**
 * MP3 Shelf first-cycle verification. Read-only: NEVER leases a job, calls a
 * model, pushes to Git, or resumes the Cloudflare coordinator.
 */
import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import os from "node:os";

const privateFolder = path.join(os.homedir(), "Library/Application Support/MP3ShelfCloudCoordinator");
const credentials = path.join(privateFolder, "credentials.json");
const firstRole = "mp3-playback";
const repository = "jonnyt123/mp3-shelf";

export function classifyFirstAgent(status, now = Date.now()) {
  const events = (status?.recent || []).filter(x => x.role === firstRole);
  const first = events.find(x => x.cycle === 0);
  const macTime = Number(status?.mac?.lastSeen || 0);
  const macOnline = Number.isFinite(macTime) && macTime > 0 && now - macTime < 10 * 60_000;
  if (!macTime) return {code:"mac-not-connected",message:"Cloudflare has never received a Mac heartbeat."};
  if (!macOnline) return {code:"mac-offline",message:"Mac heartbeat is stale; ensure the Mac is awake and launchd is running."};
  if (status.paused) return {code:"queue-paused",message:"Mac is connected but the Cloudflare queue is paused."};
  if (!first) return {code:"not-seeded",message:"The initial Playback agent job is not in the recent queue records."};
  if (first.state === "blocked") return {code:"blocked",message:"Playback job blocked after failed attempts. Inspect local worker-errors.log."};
  if (first.state === "leased") return {code:"running",message:"Playback job is leased to the Mac and coding may be in progress."};
  if (first.state === "done" && /^[a-f0-9]{40}$/.test(first.commit_sha || "")) {
    return {code:"committed",message:"Playback agent completed its first locally validated Git commit.",sha:first.commit_sha};
  }
  if (first.state === "done") return {code:"finished-without-commit",message:"The first cycle completed without a validated code commit."};
  if (first.state === "queued" && Number(first.attempts) > 0) {
    return {code:"retry-queued",message:"The first coding attempt failed or expired and is queued for a retry."};
  }
  return {code:"waiting",message:"Mac has checked in. Playback job is queued and has not been claimed."};
}

async function config() {
  const file = await stat(credentials);
  if ((file.mode & 0o077) !== 0) throw Error("Unsafe local credential permissions (must be 0600)");
  const v = JSON.parse(await readFile(credentials, "utf8"));
  if(!/^https:\/\/[a-z0-9.-]+$/i.test(v.workerUrl) || !/^[a-f0-9]{64}$/.test(v.coordinatorToken)) {
    throw Error("Incomplete Cloudflare Mac connection (run setup-all.sh first)");
  }
  return v;
}
async function status(auth) {
  const res = await fetch(auth.workerUrl + "/v1/status", {
    headers:{authorization:"Bearer "+auth.coordinatorToken,accept:"application/json"},
    signal:AbortSignal.timeout(15_000)
  });
  if(!res.ok) throw Error("Cloudflare status HTTP "+res.status);
  return res.json();
}
async function draftPR(sha) {
  // No GitHub token: public repository's read-only PR listing only.
  const url="https://api.github.com/repos/"+repository+"/pulls?state=open&per_page=100";
  const r=await fetch(url,{headers:{accept:"application/vnd.github+json","user-agent":"mp3-shelf-first-cycle-verifier"},
    signal:AbortSignal.timeout(15_000)});
  if (!r.ok) return {verified:false,reason:"GitHub PR listing unavailable ("+r.status+")"};
  const prs=await r.json();
  const target=prs.find(p=>p.head?.ref==="agent/"+firstRole);
  if (!target) return {verified:false,reason:"Agent draft PR not yet published"};
  const matches=target.head?.sha===sha;
  return {verified:matches,draft:target.draft===true,url:target.html_url,
    reason:matches?"Verified matching branch HEAD":"Remote draft PR has not caught up to local commit"};
}
async function checkOnce() {
  const auth=await config();
  const current=await status(auth);
  const result=classifyFirstAgent(current);
  const summary={observation:new Date().toISOString(),macLastSeen:current.mac?.lastSeen || null,
    paused:current.paused,
    state:result.code,
    explanation:result.message,
    firstAgentCommit:result.sha || null};
  if(result.sha) summary.github=await draftPR(result.sha);
  console.log(JSON.stringify(summary,null,2));
  return summary;
}
async function main() {
  const watch=process.argv.includes("--watch");
  const limit=watch ? 5 * 60_000 : 0;
  const start=Date.now();
  while(true){
    let x;
    try {x=await checkOnce();}
    catch(e){console.error("Verification unavailable:",e.message);process.exitCode=1;return;}
    if(x.github?.verified && x.github?.draft) return;
    if(!watch || Date.now()-start>=limit || ["mac-not-connected","queue-paused","mac-offline","blocked","finished-without-commit"].includes(x.state)) {
      process.exitCode=1; return;
    }
    await new Promise(resolve=>setTimeout(resolve,15_000));
  }
}
if(process.argv[1] && path.resolve(process.argv[1])===new URL(import.meta.url).pathname){
  main().catch(e=>{console.error(e.message);process.exitCode=1;});
}
