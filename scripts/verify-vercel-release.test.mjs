import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { validateInputs, evaluateIdentity, classifyProbes, parseArguments } from './verify-vercel-release.mjs';
const sha = 'a'.repeat(40);
const valid = { deployment: 'dpl_Current123', previous: 'dpl_Previous123', project: 'prj_Shelf123', team: 'team_Account123', sha, domain: 'mp3-shelf.vercel.app' };
const identity = {
  current: { id: valid.deployment, projectId: valid.project, target: 'production', readyState: 'READY', meta: { githubCommitSha: sha, githubCommitRef: 'main', githubRepo: 'mp3-shelf', githubOrg: 'jonnyt123' } },
  previous: { id: valid.previous, projectId: valid.project, target: 'production', readyState: 'READY' },
  aliased: { id: valid.deployment }, project: valid.project, sha
};
test('accepts valid exact SHA-bound production identity', () => { validateInputs(valid); assert.deepEqual(evaluateIdentity(identity), []); });
test('rejects preview, stale or cross-project deployments', () => {
  assert.match(evaluateIdentity({ ...identity, current: { ...identity.current, target: 'preview' } }).join(' '), /production/);
  assert.match(evaluateIdentity({ ...identity, previous: { ...identity.previous, projectId: 'prj_Other' } }).join(' '), /project/);
  assert.match(evaluateIdentity({ ...identity, aliased: { id: 'dpl_Other' } }).join(' '), /alias/);
  assert.match(evaluateIdentity({ ...identity, sha: 'b'.repeat(40) }).join(' '), /Git source/);
});
test('rejects unsafe input and unknown arguments', () => {
  assert.throws(() => validateInputs({ ...valid, domain: 'https://evil.example/' }), /hostname/);
  assert.throws(() => validateInputs({ ...valid, previous: valid.deployment }), /distinct/);
  assert.throws(() => parseArguments(['--auto-rollback']), /deployment/);
  assert.throws(() => parseArguments(['--unknown', 'value']), /Invalid/);
});
test('healthy requires three complete checks', () => {
  const pass = { root: 200, worker: 200, marker: true };
  assert.equal(classifyProbes([pass, pass, pass]), 'healthy');
  assert.equal(classifyProbes([pass, pass]), 'unverified');
  assert.equal(classifyProbes([pass, { ...pass, marker: false }, pass]), 'unverified');
});
test('repeated 404 and 5xx are rollback-eligible; auth and transient failures are not', () => {
  assert.equal(classifyProbes(Array(3).fill({ root: 503, worker: 200, marker: false })), 'repeatable-server-failure');
  assert.equal(classifyProbes(Array(3).fill({ root: 200, worker: 404, marker: false })), 'repeatable-server-failure');
  assert.equal(classifyProbes(Array(3).fill({ root: 403, worker: 403, marker: false })), 'unverified');
  assert.equal(classifyProbes([{ root: 503, worker: 200 }, { root: 200, worker: 200 }, { root: 503, worker: 200 }]), 'unverified');
  assert.equal(classifyProbes(Array(3).fill({ root: 0, worker: 0 })), 'unverified');
});

import { runReleaseCheck } from './verify-vercel-release.mjs';

function fakeNetwork({ bad = false, auth = false, stale = false, rollback = false } = {}) {
  const calls = [];
  let routed = false;
  const fetcher = async (url, options = {}) => {
    const path = new URL(url).pathname;
    calls.push({ path, method: options.method ?? 'GET' });
    const json = x => ({ ok: true, status: 200, json: async () => x });
    const html = (status, body) => ({ ok: status === 200, status, text: async () => body });
    if (path === `/v13/deployments/${valid.deployment}`) return json({ ...identity.current, meta: { ...identity.current.meta, githubCommitSha: stale ? 'b'.repeat(40) : sha } });
    if (path === `/v13/deployments/${valid.previous}`) return json(identity.previous);
    if (path === `/v13/deployments/${valid.domain}`) return json({ id: routed ? valid.previous : valid.deployment });
    if (path === `/v9/projects/${valid.project}/rollback/${valid.previous}`) { routed = true; return json({ status: 'accepted' }); }
    if (path === '/') return html(auth ? 403 : bad ? 503 : 200, auth ? 'Forbidden' : bad ? 'Service unavailable' : '<title>MP3 Shelf</title>');
    if (path === '/sw.js') return html(200, 'self.addEventListener("fetch", () => { /* offline app */ });'.repeat(4));
    throw Error(`Unexpected request to ${url}`);
  };
  return { fetcher, calls };
}

test('integrated check passes with matching deployment and three successful smoke probes', async () => {
  const old = process.env.VERCEL_TOKEN; process.env.VERCEL_TOKEN = 'fixture';
  try {
    const net = fakeNetwork();
    const result = await runReleaseCheck(valid, { fetcher: net.fetcher, sleep: async () => {} });
    assert.equal(result.status, 'PASS');
    assert.equal(net.calls.filter(c => c.method === 'POST').length, 0);
    assert.equal(net.calls.filter(c => c.path === '/').length, 3);
  } finally { if (old === undefined) delete process.env.VERCEL_TOKEN; else process.env.VERCEL_TOKEN = old; }
});

test('repeated 5xx fails closed in dry-run, with no traffic mutation', async () => {
  const old = process.env.VERCEL_TOKEN; process.env.VERCEL_TOKEN = 'fixture';
  try {
    const net = fakeNetwork({ bad: true });
    assert.equal((await runReleaseCheck(valid, { fetcher: net.fetcher, sleep: async () => {} })).status, 'FAILED_DRY_RUN');
    assert.equal(net.calls.filter(c => c.method === 'POST').length, 0);
  } finally { if (old === undefined) delete process.env.VERCEL_TOKEN; else process.env.VERCEL_TOKEN = old; }
});

test('auto rollback only after three failure probes and rechecking alias', async () => {
  const old = process.env.VERCEL_TOKEN; process.env.VERCEL_TOKEN = 'fixture';
  try {
    const net = fakeNetwork({ bad: true });
    const result = await runReleaseCheck({ ...valid, autoRollback: true }, { fetcher: net.fetcher, sleep: async () => {} });
    assert.equal(result.status, 'ROLLED_BACK');
    assert.equal(net.calls.filter(c => c.method === 'POST').length, 1);
    assert.equal(net.calls.filter(c => c.path === `/v13/deployments/${valid.domain}`).length, 3);
  } finally { if (old === undefined) delete process.env.VERCEL_TOKEN; else process.env.VERCEL_TOKEN = old; }
});

test('auth barrier and stale SHA never cause rollback even with auto flag', async () => {
  const old = process.env.VERCEL_TOKEN; process.env.VERCEL_TOKEN = 'fixture';
  try {
    for (const params of [{ auth: true }, { stale: true }]) {
      const net = fakeNetwork(params);
      const result = await runReleaseCheck({ ...valid, autoRollback: true }, { fetcher: net.fetcher, sleep: async () => {} });
      assert.ok(result.status.startsWith('BLOCKED_'));
      assert.equal(net.calls.filter(c => c.method === 'POST').length, 0);
    }
  } finally { if (old === undefined) delete process.env.VERCEL_TOKEN; else process.env.VERCEL_TOKEN = old; }
});
