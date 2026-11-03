// Cloudflare Workers Free control plane for MP3 Shelf (D1-backed, no AI execution here).
// No GitHub token or DeepSeek key is stored in Cloudflare. Worker only leases role IDs.
export const ROLES = Object.freeze([
  "mp3-playback", "mp3-sources", "mp3-ui", "mp3-qa", "mp3-integration"
]);
const LEASE_MS = 45 * 60 * 1000;
const MAX_ATTEMPTS = 2;
const jsonHeaders = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff"
};
function response(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: jsonHeaders });
}
export function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || !a || !b) return false;
  let diff = a.length ^ b.length;
  const end = Math.max(a.length, b.length);
  for (let i = 0; i < end; i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}
function authenticate(request, env) {
  return typeof env.COORDINATOR_TOKEN === "string" &&
    env.COORDINATOR_TOKEN.length >= 32 &&
    safeEqual(request.headers.get("authorization"), "Bearer " + env.COORDINATOR_TOKEN);
}
async function bodyObject(request) {
  if (Number(request.headers.get("content-length") || 0) > 4096) throw Error("invalid_body");
  const text = await request.text();
  if (text.length > 4096) throw Error("invalid_body");
  const data = JSON.parse(text || "{}");
  if (!data || Array.isArray(data) || typeof data !== "object") throw Error("invalid_body");
  return data;
}
function time() { return Date.now(); }
async function paused(env) {
  const row = await env.DB.prepare("SELECT paused FROM control WHERE id=1").first();
  return !row || row.paused === 1;
}
async function seed(env) {
  const now = time();
  await env.DB.batch(ROLES.map(role =>
    env.DB.prepare(
      "INSERT OR IGNORE INTO jobs(role,cycle,state,attempts,available_at,created_at,updated_at) VALUES(?,0,'queued',0,?,?,?)"
    ).bind(role, now, now, now)));
  return response({ seeded: ROLES.length });
}
async function status(env) {
  const [control, rows, recent, roles] = await Promise.all([
    env.DB.prepare("SELECT paused, runner_last_seen, runner_stage FROM control WHERE id=1").first(),
    env.DB.prepare("SELECT state, COUNT(*) AS count FROM jobs GROUP BY state").all(),
    env.DB.prepare("SELECT id,role,cycle,state,attempts,commit_sha,updated_at FROM jobs ORDER BY id DESC LIMIT 20").all(),
    env.DB.prepare("SELECT id,role,cycle,state,attempts,commit_sha,updated_at FROM jobs WHERE id IN (SELECT MAX(id) FROM jobs GROUP BY role) ORDER BY role").all()
  ]);
  return response({
    paused: control?.paused !== 0,
    counts: Object.fromEntries((rows.results || []).map(x => [x.state, x.count])),
    recent: recent.results || [],
    roles: ROLES,
    roleStates: roles.results || [],
    mac: { lastSeen: control?.runner_last_seen || null, stage: control?.runner_stage || "offline" }
  });
}
async function lease(env) {
  if (await paused(env)) return response({ job: null, reason: "paused" });
  const now = time();
  // Recover crashed Mac processes without giving one job to two active agents.
  await env.DB.prepare(
    "UPDATE jobs SET state='blocked', lease_id=NULL, lease_expires=NULL, updated_at=? WHERE state='leased' AND lease_expires<? AND attempts>=?"
  ).bind(now, now, MAX_ATTEMPTS).run();
  await env.DB.prepare(
    "UPDATE jobs SET state='queued', lease_id=NULL, lease_expires=NULL, available_at=?, updated_at=? WHERE state='leased' AND lease_expires<? AND attempts<?"
  ).bind(now + 60_000, now, now, MAX_ATTEMPTS).run();
  const token = crypto.randomUUID();
  // UPDATE...RETURNING is atomic on D1 SQLite, including against simultaneous pollers.
  const result = await env.DB.prepare(
    "UPDATE jobs SET state='leased',lease_id=?,lease_expires=?,attempts=attempts+1,updated_at=? " +
    "WHERE id=(SELECT id FROM jobs WHERE state='queued' AND available_at<=? ORDER BY id LIMIT 1) AND state='queued' " +
    "RETURNING id,role,cycle,attempts,lease_id,lease_expires"
  ).bind(token, now + LEASE_MS, now, now).run();
  const job = result.results?.[0] || null;
  return response({ job, retryAfterSeconds: job ? 0 : 120 });
}
function validCompletion(data) {
  if (!Number.isSafeInteger(data.jobId) || data.jobId < 1 ||
      typeof data.leaseId !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f-]{27,36}$/i.test(data.leaseId) ||
      !["success", "no-change", "failed", "deferred"].includes(data.outcome)) return false;
  if (data.outcome === "success" && !/^[0-9a-f]{40}$/.test(data.commitSha || "")) return false;
  return !data.commitSha || /^[0-9a-f]{40}$/.test(data.commitSha);
}
async function complete(env, data) {
  if (!validCompletion(data)) return response({ error: "invalid_completion" }, 400);
  const now = time();
  let state = "done", availableAt = now, attemptedDelta = 0;
  if (data.outcome === "deferred") {
    state = "queued";
    availableAt = now + 60 * 60_000;
    attemptedDelta = -1; // A budget deferral is not a failed coding attempt.
  } else if (data.outcome === "failed") {
    state = "blocked"; // Mark as blocked after two failures; no wasteful infinite AI retries.
  }
  const result = await env.DB.prepare(
    "UPDATE jobs SET state=CASE WHEN ?='failed' AND attempts<? THEN 'queued' ELSE ? END, " +
    "available_at=CASE WHEN ?='failed' THEN ? ELSE ? END, " +
    "attempts=MAX(0,attempts+?), lease_id=NULL,lease_expires=NULL,last_lease_id=?,commit_sha=?,outcome=?,updated_at=? " +
    "WHERE id=? AND state='leased' AND lease_id=? AND lease_expires>=? " +
    "RETURNING id,role,cycle,state,attempts"
  ).bind(data.outcome, MAX_ATTEMPTS, state, data.outcome,
    now + 10 * 60_000, availableAt, attemptedDelta, data.leaseId, data.commitSha || null,
    data.outcome, now, data.jobId, data.leaseId, now).run();
  const updated = result.results?.[0];
  if (!updated) {
    // The Mac may resend a completion if the response was lost in transit.
    const prior = await env.DB.prepare(
      "SELECT role,cycle,state,outcome,commit_sha,last_lease_id FROM jobs WHERE id=?"
    ).bind(data.jobId).first();
    if (prior && prior.last_lease_id === data.leaseId &&
        prior.outcome === data.outcome &&
        (prior.commit_sha || null) === (data.commitSha || null)) {
      return response({ accepted: true, replay: true, state: prior.state,
        role: prior.role, cycle: prior.cycle });
    }
    return response({ error: "lease_expired_or_mismatch" }, 409);
  }
  if (data.outcome === "success") {
    // Successful code milestones automatically advance; no ChatGPT task scheduler.
    await env.DB.prepare(
      "INSERT OR IGNORE INTO jobs(role,cycle,state,attempts,available_at,created_at,updated_at) " +
      "VALUES(?,?,'queued',0,?,?,?)"
    ).bind(updated.role, updated.cycle + 1, now + 60_000, now, now).run();
  }
  return response({ accepted: true, state: updated.state, role: updated.role, cycle: updated.cycle });
}
async function heartbeat(env, data) {
  if (!["idle","running","checking"].includes(data.stage)) return response({ error:"invalid_stage" },400);
  const now=time();
  await env.DB.prepare("UPDATE control SET runner_last_seen=?,runner_stage=? WHERE id=1")
    .bind(now,data.stage).run();
  return response({ seenAt:now });
}
async function retryBlocked(env, data) {
  if (!Number.isSafeInteger(data.jobId) || data.jobId < 1) return response({error:"invalid_job_id"},400);
  const now=time();
  const result=await env.DB.prepare(
    "UPDATE jobs SET state='queued', attempts=0,available_at=?,updated_at=?,lease_id=NULL,lease_expires=NULL WHERE id=? AND state='blocked' RETURNING id,role,cycle"
  ).bind(now,now,data.jobId).run();
  const updated=result.results?.[0];
  return updated ? response({retried:true,job:updated}) : response({error:"job_not_blocked"},409);
}
async function setPause(env, data) {
  if (typeof data.paused !== "boolean") return response({ error: "paused_must_be_boolean" }, 400);
  await env.DB.prepare("UPDATE control SET paused=?, updated_at=? WHERE id=1")
    .bind(data.paused ? 1 : 0, time()).run();
  return response({ paused: data.paused });
}
export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      if (url.pathname === "/health" && request.method === "GET") return response({ healthy: true });
      if (!env.DB || !authenticate(request, env)) return response({ error: "unauthorized" }, 401);
      if (url.pathname === "/v1/status" && request.method === "GET") return await status(env);
      if (request.method !== "POST") return response({ error: "not_found" }, 404);
      const data = await bodyObject(request);
      if (url.pathname === "/v1/seed") return await seed(env);
      if (url.pathname === "/v1/lease") return await lease(env);
      if (url.pathname === "/v1/complete") return await complete(env, data);
      if (url.pathname === "/v1/pause") return await setPause(env, data);
      if (url.pathname === "/v1/heartbeat") return await heartbeat(env, data);
      if (url.pathname === "/v1/retry") return await retryBlocked(env, data);
      return response({ error: "not_found" }, 404);
    } catch (error) {
      if (error instanceof SyntaxError || error?.message === "invalid_body") return response({ error: "invalid_json" }, 400);
      console.error("MP3 coordinator request failed:", error?.name || "Error");
      return response({ error: "internal_error" }, 500);
    }
  }
};
