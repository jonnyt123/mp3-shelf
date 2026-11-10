import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { validateInputs, evaluateIdentity, classifyProbes, parseArguments } from './verify-vercel-release.mjs';
const sha = 'a'.repeat(40);
const valid = { deployment: 'dpl_Current123', previous: 'dpl_Previous123', project: 'prj_Shelf123', team: 'team_Account123', sha, domain: 'mp3-shelf.vercel.app' };
const identity = {
  current: { id: valid.deployment, createdAt: 2000, projectId: valid.project, target: 'production', readyState: 'READY', meta: { githubCommitSha: sha, githubCommitRef: 'main', githubRepo: 'mp3-shelf', githubOrg: 'jonnyt123' } },
  previous: { id: valid.previous, createdAt: 1000, projectId: valid.project, target: 'production', readyState: 'READY', meta: { githubCommitSha: 'b'.repeat(40), githubCommitRef: 'main', githubRepo: 'mp3-shelf', githubOrg: 'jonnyt123' } },
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
  assert.throws(() => validateInputs({ ...valid, domain: 'unrelated.example.com' }), /hostname/);
  assert.throws(() => validateInputs({ ...valid, domain: 'mp3-shelf.vercel.app.evil.example' }), /hostname/);
  assert.throws(() => validateInputs({ ...valid, domain: 'MP3-SHELF.VERCEL.APP' }), /hostname/);
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
  assert.equal(classifyProbes(Array(3).fill({ root: 503, worker: 200, workerValid: true, marker: false })), 'repeatable-server-failure');
  assert.equal(classifyProbes(Array(3).fill({ root: 200, worker: 404, rootValid: true, marker: false })), 'repeatable-server-failure');
  assert.equal(classifyProbes(Array(3).fill({ root: 403, worker: 403, marker: false })), 'unverified');
  assert.equal(classifyProbes([{ root: 503, worker: 200 }, { root: 200, worker: 200 }, { root: 503, worker: 200 }]), 'unverified');
  assert.equal(classifyProbes(Array(3).fill({ root: 0, worker: 0 })), 'unverified');
  // Never route production away because one endpoint is failing while the
  // other is behind SSO or unreachable; never conflate alternating failures.
  assert.equal(classifyProbes(Array(3).fill({ root: 403, worker: 503 })), 'unverified');
  assert.equal(classifyProbes(Array(3).fill({ root: 503, worker: 401 })), 'unverified');
  assert.equal(classifyProbes(Array(3).fill({ root: 503, worker: 0 })), 'unverified');
  assert.equal(classifyProbes([
    { root: 503, worker: 200 }, { root: 200, worker: 503 }, { root: 503, worker: 200 },
  ]), 'unverified');
});

import { runReleaseCheck } from './verify-vercel-release.mjs';

function fakeNetwork({ bad = false, auth = false, stale = false, rollback = false } = {}) {
  const calls = [];
  let routed = false;
  const fetcher = async (url, options = {}) => {
    const path = new URL(url).pathname;
    calls.push({ path, method: options.method ?? 'GET' });
    const json = x => ({ ok: true, status: 200, json: async () => x });
    const html = (status, body, type) => ({ ok: status === 200, status, headers: { get: name => name.toLowerCase() === 'content-type' ? type : null }, text: async () => body });
    if (path === `/v13/deployments/${valid.deployment}`) return json({ ...identity.current, meta: { ...identity.current.meta, githubCommitSha: stale ? 'b'.repeat(40) : sha } });
    if (path === `/v13/deployments/${valid.previous}`) return json(identity.previous);
    if (path === `/v13/deployments/${valid.domain}`) return json({ id: routed ? valid.previous : valid.deployment });
    if (path === `/v9/projects/${valid.project}/rollback/${valid.previous}`) { routed = true; return json({ status: 'accepted' }); }
    if (path === '/') return html(auth ? 403 : bad ? 503 : 200, auth ? 'Forbidden' : bad ? 'Service unavailable' : '<title>MP3 Shelf</title>', 'text/html; charset=utf-8');
    if (path === '/sw.js') return html(200, 'const CACHE_NAME = "mp3-shelf-v2"; function precacheAppShell() {} self.addEventListener("fetch", () => {});', 'text/javascript; charset=utf-8');
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

test('accepts Vercel deployment responses with nested project id', () => {
  const fromVercel = { ...identity,
    current: { ...identity.current, projectId: undefined, project: { id: valid.project } },
    previous: { ...identity.previous, projectId: undefined, project: { id: valid.project } } };
  assert.deepEqual(evaluateIdentity(fromVercel), []);
});

test('rejects rollback targets from another repo, branch, missing source or identical SHA', () => {
  for (const prior of [
    { ...identity.previous, meta: { ...identity.previous.meta, githubOrg: 'other-owner' } },
    { ...identity.previous, meta: { ...identity.previous.meta, githubRepo: 'other-repo' } },
    { ...identity.previous, meta: { ...identity.previous.meta, githubCommitRef: 'feature/unreviewed' } },
    { ...identity.previous, meta: { ...identity.previous.meta, githubCommitSha: sha } },
    { ...identity.previous, meta: {} },
    { ...identity.previous, meta: undefined },
  ]) {
    assert.match(evaluateIdentity({ ...identity, previous: prior }).join(' '), /Rollback target.*Git source/);
  }
});
test('rejects unsafe rollback identity before probing or making production writes', async () => {
  const old = process.env.VERCEL_TOKEN; process.env.VERCEL_TOKEN = 'fixture';
  try {
    const calls = [];
    const fetcher = async (url, options = {}) => {
      calls.push({ url, method: options.method ?? 'GET' });
      if (url.includes(valid.deployment)) return { ok: true, json: async () => identity.current };
      if (url.includes(valid.previous)) return { ok: true, json: async () => ({ ...identity.previous, meta: { ...identity.previous.meta, githubOrg: 'other-owner' } }) };
      if (url.includes(valid.domain)) return { ok: true, json: async () => identity.aliased };
      throw Error('Production probe or rollback must not be reached');
    };
    const result = await runReleaseCheck({ ...valid, autoRollback: true }, { fetcher, sleep: async () => {} });
    assert.equal(result.status, 'BLOCKED_IDENTITY');
    assert.match(result.errors.join(' '), /Rollback target/);
    assert.equal(calls.length, 3);
    assert.equal(calls.filter(c => c.method === 'POST').length, 0);
  } finally {
    if (old === undefined) delete process.env.VERCEL_TOKEN; else process.env.VERCEL_TOKEN = old;
  }
});

test('rejects newer, same-age and missing-timestamp rollback targets', () => {
  for (const createdAt of [2000, 3000, undefined, null, '1000', -1]) {
    const prior = { ...identity.previous, createdAt };
    assert.match(evaluateIdentity({ ...identity, previous: prior }).join(' '), /earlier deployment creation time/);
  }
  assert.match(evaluateIdentity({ ...identity, current: { ...identity.current, createdAt: undefined } }).join(' '), /earlier deployment creation time/);
});

test('malformed health probes fail closed without throwing or authorizing rollback', () => {
  for (const probes of [null, [], [null, null, null], [undefined, {}, {}],
    [{ root: '503', worker: 200 }, { root: 503, worker: 200 }, { root: 503, worker: 200 }],
    Array(3).fill({ root: NaN, worker: 200 }), Array(3).fill({ root: 503, worker: undefined })]) {
    assert.equal(classifyProbes(probes), 'unverified');
  }
});

test('recovered production failure cannot trigger automatic rollback', async () => {
  const old = process.env.VERCEL_TOKEN; process.env.VERCEL_TOKEN = 'fixture';
  try {
    const net = fakeNetwork({ bad: true });
    let rootProbes = 0;
    const fetcher = async (url, options) => {
      if (new URL(url).pathname === '/') {
        rootProbes++;
        if (rootProbes === 4) return { ok: true, status: 200, headers: { get: () => 'text/html' }, text: async () => '<title>MP3 Shelf</title>' };
      }
      return net.fetcher(url, options);
    };
    const result = await runReleaseCheck({ ...valid, autoRollback: true }, { fetcher, sleep: async () => {} });
    assert.equal(result.status, 'BLOCKED_RECOVERED_OR_UNVERIFIED');
    assert.equal(rootProbes, 4);
    assert.equal(net.calls.filter(c => c.method === 'POST').length, 0);
  } finally { if (old === undefined) delete process.env.VERCEL_TOKEN; else process.env.VERCEL_TOKEN = old; }
});

test('auth barrier appearing on final pre-rollback probe blocks traffic mutation', async () => {
  const old = process.env.VERCEL_TOKEN; process.env.VERCEL_TOKEN = 'fixture';
  try {
    const net = fakeNetwork({ bad: true });
    let rootProbes = 0;
    const fetcher = async (url, options) => {
      if (new URL(url).pathname === '/') {
        rootProbes++;
        if (rootProbes === 4) return { ok: false, status: 403, text: async () => 'Forbidden' };
      }
      return net.fetcher(url, options);
    };
    const result = await runReleaseCheck({ ...valid, autoRollback: true }, { fetcher, sleep: async () => {} });
    assert.equal(result.status, 'BLOCKED_RECOVERED_OR_UNVERIFIED');
    assert.equal(net.calls.filter(c => c.method === 'POST').length, 0);
  } finally { if (old === undefined) delete process.env.VERCEL_TOKEN; else process.env.VERCEL_TOKEN = old; }
});

test('a login HTML response masquerading as the service worker never passes production health', async () => {
  const old = process.env.VERCEL_TOKEN; process.env.VERCEL_TOKEN = 'fixture';
  try {
    const net = fakeNetwork();
    const fetcher = async (url, options) => {
      if (new URL(url).pathname === '/sw.js') {
        return { ok: true, status: 200, headers: { get: () => 'text/html' },
          text: async () => '<html><title>MP3 Shelf</title><body>Sign in to continue</body></html>' };
      }
      return net.fetcher(url, options);
    };
    const result = await runReleaseCheck({ ...valid, autoRollback: true }, { fetcher, sleep: async () => {} });
    assert.equal(result.status, 'BLOCKED_UNVERIFIED');
    assert.equal(net.calls.filter(c => c.method === 'POST').length, 0);
  } finally { if (old === undefined) delete process.env.VERCEL_TOKEN; else process.env.VERCEL_TOKEN = old; }
});

test('JavaScript with unrelated content cannot impersonate the MP3 Shelf offline worker', async () => {
  const old = process.env.VERCEL_TOKEN; process.env.VERCEL_TOKEN = 'fixture';
  try {
    const net = fakeNetwork();
    const fetcher = async (url, options) => {
      if (new URL(url).pathname === '/sw.js') {
        return { ok: true, status: 200, headers: { get: () => 'application/javascript' },
          text: async () => 'self.addEventListener("fetch", () => {});' };
      }
      return net.fetcher(url, options);
    };
    const result = await runReleaseCheck(valid, { fetcher, sleep: async () => {} });
    assert.equal(result.status, 'BLOCKED_UNVERIFIED');
    assert.equal(net.calls.filter(c => c.method === 'POST').length, 0);
  } finally { if (old === undefined) delete process.env.VERCEL_TOKEN; else process.env.VERCEL_TOKEN = old; }
});

test('a persistent 5xx with an invalid 200 sibling endpoint never authorizes rollback', () => {
  assert.equal(classifyProbes(Array(3).fill({ root: 503, worker: 200, workerValid: false })), 'unverified');
  assert.equal(classifyProbes(Array(3).fill({ root: 200, worker: 404, rootValid: false })), 'unverified');
  assert.equal(classifyProbes(Array(3).fill({ root: 503, worker: 200 })), 'unverified');
});

test('a fake worker returning HTTP 200 during a persistent homepage failure blocks rollback', async () => {
  const old = process.env.VERCEL_TOKEN; process.env.VERCEL_TOKEN = 'fixture';
  try {
    const net = fakeNetwork({ bad: true });
    const fetcher = async (url, options) => {
      if (new URL(url).pathname === '/sw.js') {
        return { ok: true, status: 200, headers: { get: () => 'text/html' },
          text: async () => '<title>MP3 Shelf</title><body>Sign in</body>' };
      }
      return net.fetcher(url, options);
    };
    const result = await runReleaseCheck({ ...valid, autoRollback: true }, { fetcher, sleep: async () => {} });
    assert.equal(result.status, 'BLOCKED_UNVERIFIED');
    assert.equal(net.calls.filter(c => c.method === 'POST').length, 0);
  } finally { if (old === undefined) delete process.env.VERCEL_TOKEN; else process.env.VERCEL_TOKEN = old; }
});


test('health probes reject oversized content-length without reading the body', async () => {
  const { readProbeBody } = await import('./verify-vercel-release.mjs');
  let read = false;
  const response = { ok: true, headers: { get: () => '120001' },
    text: async () => { read = true; return 'MP3 Shelf'; } };
  await assert.rejects(readProbeBody(response), /Oversized/);
  assert.equal(read, false);
});

test('streamed health responses are capped and cancelled on overflow', async () => {
  const { readProbeBody } = await import('./verify-vercel-release.mjs');
  let cancelled = false;
  const stream = new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(120001)); },
    cancel() { cancelled = true; }
  });
  const response = { ok: true, headers: { get: () => null }, body: stream };
  await assert.rejects(readProbeBody(response), /Oversized/);
  assert.equal(cancelled, true);
});

test('bounded streamed health responses decode normally', async () => {
  const { readProbeBody } = await import('./verify-vercel-release.mjs');
  const response = new Response('MP3 Shelf', { headers: { 'content-type': 'text/html' } });
  assert.equal(await readProbeBody(response), 'MP3 Shelf');
});

test('authenticated Vercel metadata requests explicitly refuse redirects', async () => {
  const old = process.env.VERCEL_TOKEN;
  process.env.VERCEL_TOKEN = 'fixture';
  try {
    const calls = [];
    const network = fakeNetwork();
    const fetcher = async (url, options = {}) => {
      if (new URL(url).host === 'api.vercel.com') {
        calls.push(options);
        assert.equal(options.redirect, 'error');
        assert.equal(options.headers.Authorization, 'Bearer fixture');
      }
      return network.fetcher(url, options);
    };
    const result = await runReleaseCheck(valid, { fetcher, sleep: async () => {} });
    assert.equal(result.status, 'PASS');
    assert.equal(calls.length, 3);
  } finally {
    if (old === undefined) delete process.env.VERCEL_TOKEN;
    else process.env.VERCEL_TOKEN = old;
  }
});

test('Vercel API redirects fail closed before any production health probe or rollback', async () => {
  const old = process.env.VERCEL_TOKEN;
  process.env.VERCEL_TOKEN = 'fixture';
  try {
    const requests = [];
    const fetcher = async (url, options = {}) => {
      requests.push({ url, options });
      assert.equal(options.redirect, 'error');
      return { ok: false, status: 302 };
    };
    await assert.rejects(
      runReleaseCheck({ ...valid, autoRollback: true }, { fetcher, sleep: async () => {} }),
      /HTTP 302/
    );
    assert.equal(requests.length, 1);
    assert.equal(requests[0].options.method ?? 'GET', 'GET');
  } finally {
    if (old === undefined) delete process.env.VERCEL_TOKEN;
    else process.env.VERCEL_TOKEN = old;
  }
});
