import test from "node:test";
import assert from "node:assert/strict";
import worker, { ROLES, safeEqual } from "./src/worker.mjs";
import { interpretRun, safeConfig } from "./mac-client.mjs";

// Small deterministic D1 stand-in for coordinator contract tests; no Cloudflare account required.
class FakeDB {
  constructor() { this.paused = 1; this.jobs = []; this.nextId = 1; }
  prepare(sql) {
    const db = this;
    let args = [];
    return {
      bind(...values) { args = values; return this; },
      async first() {
        if (sql.startsWith("SELECT paused")) return { paused: db.paused };
        throw Error("Unexpected first query: " + sql);
      },
      async all() {
        if (sql.startsWith("SELECT state, COUNT")) {
          const counts = new Map();
          for (const j of db.jobs) counts.set(j.state, (counts.get(j.state) || 0) + 1);
          return { results: [...counts].map(([state, count]) => ({ state, count })) };
        }
        if (sql.startsWith("SELECT id,role,cycle")) {
          return { results: [...db.jobs].reverse().slice(0, 10) };
        }
        throw Error("Unexpected all query: " + sql);
      },
      async run() {
        if (sql.startsWith("INSERT OR IGNORE INTO jobs")) {
          const [role, a, b, c] = args;
          const next = sql.includes("VALUES(?,0") ? 0 : args[1];
          const timestamps = next === 0 && sql.includes("VALUES(?,0") ? [a,b,c] : args.slice(2);
          if (!db.jobs.some(j => j.role === role && j.cycle === next)) {
            db.jobs.push({
              id: db.nextId++, role, cycle: next, state: "queued", attempts: 0,
              available_at: timestamps[0], created_at: timestamps[1], updated_at: timestamps[2]
            });
          }
          return { results: [] };
        }
        if (sql.startsWith("UPDATE control")) {
          db.paused = args[0];
          return { results: [] };
        }
        if (sql.startsWith("UPDATE jobs SET state='blocked'")) {
          for (const j of db.jobs) if (j.state === "leased" && j.lease_expires < args[1] && j.attempts >= args[2]) j.state = "blocked";
          return { results: [] };
        }
        if (sql.startsWith("UPDATE jobs SET state='queued'")) {
          for (const j of db.jobs) if (j.state === "leased" && j.lease_expires < args[2] && j.attempts < args[3]) {
            Object.assign(j, { state: "queued", lease_id: null, lease_expires: null, available_at: args[0], updated_at: args[1] });
          }
          return { results: [] };
        }
        if (sql.startsWith("UPDATE jobs SET state='leased'")) {
          const selected = db.jobs.filter(j => j.state === "queued" && j.available_at <= args[3])
            .sort((a, b) => a.id - b.id)[0];
          if (!selected) return { results: [] };
          Object.assign(selected, {state: "leased", lease_id: args[0], lease_expires: args[1], updated_at: args[2], attempts: selected.attempts + 1});
          return { results: [{...selected}] };
        }
        if (sql.startsWith("UPDATE jobs SET state=CASE")) {
          const [outcome, max, fallback, failed, failTime, available, delta, sha, outcomeAgain, now, id, lease, expiresNow] = args;
          const job = db.jobs.find(j => j.id === id && j.state === "leased" && j.lease_id === lease && j.lease_expires >= expiresNow);
          if (!job) return { results: [] };
          job.state = outcome === "failed" && job.attempts < max ? "queued" : fallback;
          Object.assign(job, { available_at: failed === "failed" ? failTime : available, attempts: Math.max(0,job.attempts + delta),
            lease_id: null, lease_expires: null, commit_sha: sha, outcome: outcomeAgain, updated_at: now });
          return { results: [{ ...job }] };
        }
        throw Error("Unexpected run query: " + sql);
      }
    };
  }
  async batch(stmts) { return Promise.all(stmts.map(s => s.run())); }
}
const token = "f".repeat(64);
function request(db, method, pathname, body = {}, authorized = true) {
  return worker.fetch(new Request("https://example.workers.dev" + pathname, {
    method,
    headers: authorized ? { authorization: "Bearer " + token } : {},
    body: method === "POST" ? JSON.stringify(body) : undefined
  }), { DB: db, COORDINATOR_TOKEN: token });
}
async function call(db, method, path, body, authorized) {
  const res = await request(db, method, path, body, authorized);
  return { status: res.status, data: await res.json() };
}
test("five roles, safe bearer authentication and public minimal health endpoint", async () => {
  assert.equal(ROLES.length, 5);
  assert.equal(safeEqual("correct", "correct"), true);
  assert.equal(safeEqual("correct", "wrong"), false);
  const db = new FakeDB();
  assert.equal((await call(db, "GET", "/health")).status, 200);
  assert.equal((await call(db, "GET", "/v1/status", {}, false)).status, 401);
  assert.equal((await call(db, "GET", "/v1/status")).data.paused, true);
});
test("seeding is idempotent; no jobs leased while paused", async () => {
  const db = new FakeDB();
  await call(db, "POST", "/v1/seed");
  await call(db, "POST", "/v1/seed");
  assert.equal(db.jobs.length, 5);
  assert.equal((await call(db, "POST", "/v1/lease")).data.job, null);
  await call(db, "POST", "/v1/pause", { paused: false });
  const first = (await call(db, "POST", "/v1/lease")).data.job;
  assert.equal(first.role, "mp3-playback");
  const second = (await call(db, "POST", "/v1/lease")).data.job;
  assert.notEqual(first.id, second.id);
});
test("success inserts exactly one next-cycle job; duplicate completion rejected", async () => {
  const db = new FakeDB();
  await call(db, "POST", "/v1/seed");
  await call(db, "POST", "/v1/pause", { paused: false });
  const { job } = (await call(db, "POST", "/v1/lease")).data;
  const payload = { jobId: job.id, leaseId: job.lease_id, outcome: "success", commitSha: "a".repeat(40) };
  assert.equal((await call(db, "POST", "/v1/complete", payload)).status, 200);
  assert.equal(db.jobs.length, 6);
  assert.equal(db.jobs.find(x=>x.role===job.role&&x.cycle===1).state,"queued");
  assert.equal((await call(db, "POST", "/v1/complete", payload)).status, 409);
  assert.equal(db.jobs.length, 6);
});
test("completed jobs without changes don't waste another DeepSeek session", async () => {
  const db = new FakeDB();
  await call(db, "POST", "/v1/seed");
  await call(db, "POST", "/v1/pause", {paused: false});
  const {job} = (await call(db, "POST", "/v1/lease")).data;
  assert.equal((await call(db,"POST","/v1/complete",
    { jobId:job.id, leaseId:job.lease_id, outcome:"no-change" })).status,200);
  assert.equal(db.jobs.length,5);
});
test("failed jobs retry once, then block instead of burning credits indefinitely", async () => {
  const db = new FakeDB();
  await call(db, "POST", "/v1/seed");
  await call(db, "POST", "/v1/pause", {paused: false});
  const first = (await call(db, "POST", "/v1/lease")).data.job;
  await call(db, "POST", "/v1/complete", {jobId:first.id,leaseId:first.lease_id,outcome:"failed"});
  db.jobs[0].available_at = 0;
  const second = (await call(db, "POST", "/v1/lease")).data.job;
  assert.equal(second.id, first.id);
  await call(db, "POST", "/v1/complete", {jobId:second.id,leaseId:second.lease_id,outcome:"failed"});
  assert.equal(db.jobs[0].state, "blocked");
});
test("bad completion cannot fake success", async () => {
  const db = new FakeDB();
  await call(db, "POST", "/v1/seed");
  await call(db, "POST", "/v1/pause", {paused: false});
  const {job} = (await call(db, "POST", "/v1/lease")).data;
  assert.equal((await call(db,"POST","/v1/complete",
    {jobId:job.id,leaseId:job.lease_id,outcome:"success",commitSha:"not-a-sha"})).status,400);
});
test("Mac result parser distinguishes commit, exhaustion, and no-change", () => {
  assert.deepEqual(interpretRun(0,"VALIDATED LOCAL commit "+"b".repeat(40)),
    {outcome:"success",commitSha:"b".repeat(40)});
  assert.deepEqual(interpretRun(0,"Local daily limit reached; no model request"),{outcome:"deferred"});
  assert.deepEqual(interpretRun(0,"No code edits; spending recorded"),{outcome:"no-change"});
  assert.deepEqual(interpretRun(1,"failed"),{outcome:"failed"});
  assert.throws(()=>safeConfig({workerUrl:"http://insecure",coordinatorToken:token,deepseekApiKey:"test-secret-123"}));
});
