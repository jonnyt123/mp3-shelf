#!/usr/bin/env node
// Mac-side executor for Cloudflare's free coordinator. Cloudflare stores no credentials or code.
import { spawn } from "node:child_process";
import { readFile, stat, writeFile, unlink, mkdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getBalance, balanceFromResponse } from "../runner.mjs";
import {canUnlockFollowups,nextBatchAction,readFirstGateProofs} from "../mac/qa-gate.mjs";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const state = process.env.MP3_CLOUD_STATE_DIR ||
  path.join(os.homedir(), "Library/Application Support/MP3ShelfCloudCoordinator");
const secretsFile = path.join(state, "credentials.json");
const pendingFile = path.join(state, "pending-completion.json");
const followupsFile=path.join(state,"approved-followups.json");
const roles = ["mp3-playback", "mp3-sources", "mp3-ui", "mp3-qa", "mp3-integration"];

export function interpretRun(exit, stdout) {
  const match = stdout.match(/VALIDATED LOCAL commit ([0-9a-f]{40})/);
  if (exit === 0 && match) return { outcome: "success", commitSha: match[1] };
  if (/Local daily limit reached|Insufficient balance/.test(stdout)) return { outcome: "deferred" };
  if (exit === 0 && /No code edits/.test(stdout)) return { outcome: "no-change" };
  return { outcome: "failed" };
}
export function safeConfig(config) {
  if (!config || typeof config !== "object" ||
      !/^https:\/\/[a-z0-9.-]+(?:\/)?$/i.test(config.workerUrl || "") ||
      !/^[a-f0-9]{64}$/i.test(config.coordinatorToken || "") ||
      !/^[A-Za-z0-9_.-]{12,}$/.test(config.deepseekApiKey || "")) {
    throw Error("Invalid private coordinator credentials/configuration");
  }
  return { ...config, workerUrl: config.workerUrl.replace(/\/$/, "") };
}
async function readPrivateJson(file) {
  const info = await stat(file);
  if ((info.mode & 0o077) !== 0) throw Error("Refusing a secret file readable by other users: " + file);
  return JSON.parse(await readFile(file, "utf8"));
}
async function request(config, method, body) {
  const response = await fetch(config.workerUrl + method, {
    method: method === "/v1/status" ? "GET" : "POST",
    headers: {
      authorization: "Bearer " + config.coordinatorToken,
      "content-type": "application/json"
    },
    body: method === "/v1/status" ? undefined : JSON.stringify(body || {}),
    signal: AbortSignal.timeout(20_000)
  });
  if (!response.ok) throw Error("Cloudflare coordinator HTTP " + response.status);
  return response.json();
}
async function childRun(role, key) {
  if (!roles.includes(role)) throw Error("Unexpected role from coordinator");
  const env = { ...process.env, DEEPSEEK_API_KEY: key, MP3_AGENT_ROLE: role };
  for (const id of ["GH_TOKEN", "GITHUB_TOKEN", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
                     "MP3_COORDINATOR_TOKEN", "CLOUDFLARE_API_TOKEN"]) delete env[id];
  return new Promise(resolve => {
    const worker = spawn(process.execPath, ["tools/deepseek-agents/runner.mjs", "--once"],
      { cwd: repo, env, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    worker.stdout.on("data", d => { output = (output + d.toString()).slice(-12_000); });
    worker.stderr.on("data", d => { output = (output + d.toString()).slice(-12_000); });
    const timer = setTimeout(() => worker.kill("SIGTERM"), 25 * 60_000);
    worker.once("error", () => { clearTimeout(timer); resolve({ code: 1, output }); });
    worker.once("close", code => { clearTimeout(timer); resolve({ code: code ?? 1, output }); });
  });
}
async function flushPending(config) {
  let previous;
  try { previous = await readPrivateJson(pendingFile); }
  catch (e) { if (e.code === "ENOENT") return; throw e; }
  await request(config, "/v1/complete", previous);
  await unlink(pendingFile);
}
async function localBudgetAllows() {
  // Do not claim expensive work while the existing DeepSeek daily budget is exhausted.
  try {
    const ledger = JSON.parse(await readFile(
      path.resolve(repo, "../.mp3-shelf-agent-state/ledger.json"), "utf8"));
    const day = new Date().toISOString().slice(0, 10);
    const cap = Number(process.env.MP3_AGENT_DAILY_CAP || 0.50);
    return Number.isFinite(cap) && cap > 0 && (ledger.date !== day || ledger.spent < cap);
  } catch (e) {
    if (e.code === "ENOENT") return true;
    throw e;
  }
}
export function firstCycleDecision(status, balance, budgetOk, minimum = 0.25) {
  if (!status || status.paused !== true) return "Pause the queue before starting a one-shot cycle";
  if (Number(status.counts?.leased || 0) > 0) return "Another job is already leased; refusing parallel work";
  const first = (status.roleStates || []).find(x => x.role === "mp3-playback" && Number(x.cycle) === 0);
  if (!first || first.state !== "queued" || Number(first.attempts) !== 0)
    return "First Playback job is not a fresh queued cycle; refusing a different role";
  if (!budgetOk) return "Local daily budget exhausted; no model request";
  if (!Number.isFinite(minimum) || minimum < 0.25 || minimum > 100)
    return "Invalid minimum DeepSeek balance threshold";
  if (!balance || !Number.isFinite(balance.amount) || balance.amount < minimum)
    return "Insufficient DeepSeek balance for the first agent";
  return null;
}
async function writeFollowupState(obj) {
  await mkdir(state,{recursive:true,mode:0o700});
  const temp=followupsFile+"."+process.pid+".tmp";
  await writeFile(temp,JSON.stringify(obj)+"\n",{mode:0o600,flag:"wx"});
  await rename(temp,followupsFile);
}
async function readFollowupState() {
  try {return await readPrivateJson(followupsFile);}
  catch(e) {if(e.code==="ENOENT")return null;throw e;}
}
async function manageFollowups(config) {
  const saved=await readFollowupState();
  if(!saved)return {managed:false};
  if(saved.schema!==1 || !/^[a-f0-9]{40}$/.test(saved.firstSha||"") ||
    !["awaiting_qa","active","completed","halted"].includes(saved.state))
    throw Error("Unsafe follow-up approval record. New agent sessions are disabled");
  const status=await request(config,"/v1/status");
  if(saved.state==="completed" || saved.state==="halted") {
    if(!status.paused) await request(config,"/v1/pause",{paused:true});
    return {managed:true};
  }
  if(saved.state==="awaiting_qa") {
    if(!status.paused) {
      await request(config,"/v1/pause",{paused:true});
      console.log("Follow-up gate disallowed a resumed queue before first Mac QA passed");
      return {managed:true};
    }
    const {publication,qa}=await readFirstGateProofs();
    const outcome=canUnlockFollowups(status,saved.firstSha,publication,qa);
    if(!outcome.ok) {console.log("First agent QA gate: "+outcome.reason);return {managed:true};}
    // This approval is limited to the initial four jobs. Do not unlock cycle 1.
    await writeFollowupState({...saved,state:"active"});
    await request(config,"/v1/pause",{paused:false});
    console.log("Verified first draft PR and independent Mac QA. Four follow-up agents authorized.");
    return {managed:true,role:"mp3-sources"};
  }
  const next=nextBatchAction(status);
  if(next.action==="run")return {managed:true,role:next.role};
  if(next.action==="wait")return {managed:true};
  await request(config,"/v1/pause",{paused:true});
  await writeFollowupState({...saved,state:next.action==="complete"?"completed":"halted",
    finishReason:next.reason});
  console.log("Follow-up batch "+next.action+": "+next.reason+"; cloud queue paused.");
  return {managed:true};
}
async function finishFollowup(config,role,result) {
  if(result?.outcome==="success" && /^[a-f0-9]{40}$/.test(result.commitSha||"")) {
    if(role==="mp3-integration") {
      await request(config,"/v1/pause",{paused:true});
      const saved=await readFollowupState();
      if(saved)await writeFollowupState({...saved,state:"completed"});
      console.log("Four initial follow-up milestones committed locally; cloud queue paused before cycle-1.");
    }
    return;
  }
  await request(config,"/v1/pause",{paused:true});
  const saved=await readFollowupState();
  if(saved)await writeFollowupState({...saved,state:"halted",
    finishReason:"Follow-up agent did not produce a validated commit: "+role});
  console.error("Follow-up batch halted after "+role+"; no more paid sessions authorized");
}
async function firstOnly(config) {
  if (process.env.MP3_FIRST_CYCLE_EXCLUSIVE !== "1")
    throw Error("Open Start First Agent.command to stop the background worker safely first");
  const cloud = await request(config, "/v1/status");
  const balance = balanceFromResponse(await getBalance(config.deepseekApiKey));
  const budgetOk = await localBudgetAllows();
  const minimum = Number(process.env.MP3_AGENT_MIN_BALANCE || 0.25);
  const blocker = firstCycleDecision(cloud, balance, budgetOk, minimum);
  if (blocker) throw Error(blocker);
  console.log("DeepSeek read-only balance check: " + balance.amount.toFixed(2) + " " + balance.currency);
  console.log("Authorizing precisely one initial Playback coding cycle; queue is paused after lease");
  await request(config, "/v1/pause", { paused: false });
  try {
    const result = await one(config, { pauseAfterLease: true, expectedRole: "mp3-playback" });
    if (!result || result.outcome !== "success" || !/^[a-f0-9]{40}$/.test(result.commitSha||""))
      throw Error("First cycle did not produce a validated code commit (outcome: " + (result?.outcome || "none") + ")");
    if(process.env.MP3_AUTO_FOLLOWUPS_AFTER_QA==="1") {
      await writeFollowupState({schema:1,state:"awaiting_qa",firstSha:result.commitSha,
        approvedAt:new Date().toISOString()});
      console.log("Auto-followups approved: waiting for matching draft PR + independent Mac Xcode QA.");
    }
    return result;
  } finally {
    await request(config, "/v1/pause", { paused: true });
  }
}
async function one(config, options = {}) {
  await flushPending(config);  // Network interruptions never silently lose completion evidence.
  await request(config, "/v1/heartbeat", { stage: "idle" });
  if (!(await localBudgetAllows())) { console.log("Daily budget reached; leaving cloud jobs queued"); return; }
  const { job } = await request(config, "/v1/lease", {});
  if (!job) {
    if (options.expectedRole) throw Error("First agent was not available for leasing");
    console.log("No available cloud job"); return;
  }
  if (!roles.includes(job.role) || !Number.isSafeInteger(job.id) ||
      typeof job.lease_id !== "string") throw Error("Invalid cloud job; refusing model call");
  if (options.pauseAfterLease) {
    // Fail closed BEFORE any paid model request; even a Mac crash leaves new work paused.
    await request(config, "/v1/pause", { paused: true });
  }
  if (options.expectedRole && (job.role !== options.expectedRole || Number(job.cycle) !== 0)) {
    await request(config, "/v1/complete", {jobId:job.id, leaseId:job.lease_id, outcome:"deferred"});
    throw Error("Different role was leased; no DeepSeek request was made");
  }
  console.log("Claimed", job.role, "cycle", job.cycle);
  await request(config, "/v1/heartbeat", { stage: "running" });
  const result = await childRun(job.role, config.deepseekApiKey);
  const final = interpretRun(result.code, result.output);
  const report = { jobId: job.id, leaseId: job.lease_id, ...final };
  await mkdir(state, { recursive: true, mode: 0o700 });
  await writeFile(pendingFile, JSON.stringify(report) + "\n", { mode: 0o600 });
  await flushPending(config);
  await request(config, "/v1/heartbeat", { stage: "idle" });
  console.log(job.role + ": " + final.outcome +
    (final.commitSha ? " local commit " + final.commitSha.slice(0, 12) : ""));
  return final;
}
export async function main(args = process.argv.slice(2)) {
  const config = safeConfig(await readPrivateJson(secretsFile));
  const command = args[0] || "--status";
  if (command === "--doctor") {
    const cloud = await request(config, "/v1/status");
    const balance = balanceFromResponse(await getBalance(config.deepseekApiKey));
    const details = { coordinatorConnected: true, paused: cloud.paused,
      macLastSeen: cloud.mac?.lastSeen || null,
      roles: cloud.roles?.length || 0,
      apiAvailable: balance.amount > 0, apiBalance: balance.amount,
      balanceCurrency: balance.currency,
      note: "Read-only diagnostics. No DeepSeek model request, GitHub push or Xcode build." };
    console.log(JSON.stringify(details,null,2));
  } else if (command === "--status") {
    console.log(JSON.stringify(await request(config, "/v1/status"), null, 2));
  } else if (command === "--seed") {
    console.log(await request(config, "/v1/seed", {}));
  } else if (command === "--pause" || command === "--resume") {
    console.log(await request(config, "/v1/pause", { paused: command === "--pause" }));
  } else if (command === "--once") {
    await one(config);
  } else if (command === "--first-only") {
    await firstOnly(config);
  } else if (command === "--loop") {
    // A persistent local process, not a ChatGPT scheduled task or Cloudflare Cron Trigger.
    await request(config, "/v1/seed", {});
    while (true) {
      try {
        await request(config,"/v1/heartbeat",{stage:"idle"});
        const control=await manageFollowups(config);
        if(!control.managed) await one(config);
        else if(control.role) {
          const result=await one(config,{expectedRole:control.role});
          await finishFollowup(config,control.role,result);
        }
      } catch (e) {
        console.error("Coordinator iteration halted: "+e.message);
        const approved=await readFollowupState().catch(()=>null);
        if(approved?.state==="active") {
          await request(config,"/v1/pause",{paused:true}).catch(()=>{});
          await writeFollowupState({...approved,state:"halted",finishReason:"Runner exception; review required"}).catch(()=>{});
        }
      }
      await new Promise(resolve => setTimeout(resolve, 120_000));
    }
  } else throw Error("Use --doctor, --seed, --status, --pause, --resume, --once, --first-only or --loop");
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(e => { console.error(e.message); process.exitCode = 1; });
}
