#!/usr/bin/env node
// Mac-side executor for Cloudflare's free coordinator. Cloudflare stores no credentials or code.
import { spawn } from "node:child_process";
import { readFile, stat, writeFile, unlink, mkdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getBalance, balanceFromResponse } from "../runner.mjs";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const state = process.env.MP3_CLOUD_STATE_DIR ||
  path.join(os.homedir(), "Library/Application Support/MP3ShelfCloudCoordinator");
const secretsFile = path.join(state, "credentials.json");
const pendingFile = path.join(state, "pending-completion.json");
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
async function one(config) {
  await flushPending(config);  // Network interruptions never silently lose completion evidence.
  await request(config, "/v1/heartbeat", { stage: "idle" });
  if (!(await localBudgetAllows())) { console.log("Daily budget reached; leaving cloud jobs queued"); return; }
  const { job } = await request(config, "/v1/lease", {});
  if (!job) { console.log("No available cloud job"); return; }
  if (!roles.includes(job.role) || !Number.isSafeInteger(job.id) ||
      typeof job.lease_id !== "string") throw Error("Invalid cloud job; refusing model call");
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
  } else if (command === "--loop") {
    // A persistent local process, not a ChatGPT scheduled task or Cloudflare Cron Trigger.
    await request(config, "/v1/seed", {});
    while (true) {
      try { await one(config); } catch (e) { console.error(e.message); }
      await new Promise(resolve => setTimeout(resolve, 120_000));
    }
  } else throw Error("Use --doctor, --seed, --status, --pause, --resume, --once or --loop");
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(e => { console.error(e.message); process.exitCode = 1; });
}
