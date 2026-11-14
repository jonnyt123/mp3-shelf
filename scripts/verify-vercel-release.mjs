#!/usr/bin/env node
/** Verify an MP3 Shelf Vercel production release; fail closed before any rollback. */
import { pathToFileURL } from 'node:url';

const SHA = /^[0-9a-f]{40}$/i;
const ID = /^(?:dpl|prj|team)_[A-Za-z0-9]+$/;

export function validateInputs({ deployment, previous, project, team, sha, domain }) {
  if (!ID.test(deployment ?? '') || !deployment.startsWith('dpl_')) throw Error('Expected a Vercel deployment ID.');
  if (!ID.test(previous ?? '') || !previous.startsWith('dpl_') || previous === deployment) throw Error('Previous production deployment must be a distinct ID.');
  if (!ID.test(project ?? '') || !project.startsWith('prj_')) throw Error('Invalid project ID.');
  if (!ID.test(team ?? '') || !team.startsWith('team_')) throw Error('Invalid team ID.');
  if (!SHA.test(sha ?? '')) throw Error('Expected exact 40-character Git SHA.');
  // Never probe a caller-selected hostname to authorize changes to this project's production alias.
  // A healthy or failing unrelated host is not evidence about MP3 Shelf.
  if (domain !== 'mp3-shelf.vercel.app') throw Error('Expected the canonical MP3 Shelf production hostname.');
}

export function evaluateIdentity({ current, previous, aliased, project, sha, deployment, previousDeployment }) {
  const errors = [];
  const deploymentId = d => d?.id ?? d?.uid;
  const target = d => d?.target;
  const ready = d => d?.readyState ?? d?.state;
  const ownedProject = d => d?.projectId ?? d?.project?.id;
  const repo = current?.meta ?? {};
  const priorRepo = previous?.meta ?? {};
  // The Vercel API response must match the exact IDs that were requested.
  // A proxy, stale cache or incorrect fixture must not substitute another
  // deployment as the current release or the rollback destination.
  if (deployment && deploymentId(current) !== deployment) errors.push('Current deployment response ID does not match the requested release.');
  if (previousDeployment && deploymentId(previous) !== previousDeployment) errors.push('Previous deployment response ID does not match the requested rollback target.');
  if (deploymentId(aliased) !== deploymentId(current)) errors.push('Production alias does not point to expected deployment.');
  if (ownedProject(current) !== project || ownedProject(previous) !== project) errors.push('Deployment project does not match.');
  if (target(current) !== 'production' || target(previous) !== 'production') errors.push('Both deployments must be production builds.');
  if (ready(current) !== 'READY' || ready(previous) !== 'READY') errors.push('Both deployments must be READY.');
  if (repo.githubCommitSha !== sha || repo.githubCommitRef !== 'main' || repo.githubRepo !== 'mp3-shelf' || repo.githubOrg !== 'jonnyt123') errors.push('Current production deployment has incorrect Git source identity.');
  // A READY deployment in the same Vercel project is not necessarily a safe
  // rollback target; it must be an earlier build of this repository's main.
  if (!SHA.test(priorRepo.githubCommitSha ?? '') || priorRepo.githubCommitSha === sha ||
      priorRepo.githubCommitRef !== 'main' || priorRepo.githubRepo !== 'mp3-shelf' ||
      priorRepo.githubOrg !== 'jonnyt123') {
    errors.push('Rollback target has missing, incorrect or identical Git source identity.');
  }
  // A distinct main SHA alone does not prove the deployment predates this release.
  // Never roll traffic "back" to a newer or chronologically ambiguous build.
  const currentCreated = current?.createdAt ?? current?.created;
  const previousCreated = previous?.createdAt ?? previous?.created;
  if (!Number.isSafeInteger(currentCreated) || !Number.isSafeInteger(previousCreated) ||
      currentCreated <= 0 || previousCreated <= 0 || previousCreated >= currentCreated) {
    errors.push('Rollback target must have a verified earlier deployment creation time.');
  }
  if (deploymentId(previous) === deploymentId(current)) errors.push('Rollback target is current deployment.');
  return errors;
}

export function classifyProbes(probes) {
  if (!Array.isArray(probes) || probes.length !== 3 ||
      probes.some(p => !p || typeof p !== 'object' || Array.isArray(p) ||
        !Number.isInteger(p.root) || !Number.isInteger(p.worker))) return 'unverified';
  // A caller-provided marker is not proof that either endpoint's content was
  // validated. Require independent, explicit validation of both responses.
  if (probes.every(p => p.root === 200 && p.worker === 200 &&
      p.rootValid === true && p.workerValid === true && p.marker === true)) return 'healthy';
  // Only a persistent failure of the SAME endpoint can justify rollback.
  // Auth/SSO, network failures, or alternating transient errors on either
  // endpoint make the entire probe sequence inconclusive.
  const serverError = status => [404, 500, 502, 503, 504].includes(status);
  const acceptable = status => status === 200 || serverError(status);
  // A 200 on the other endpoint must be validated content, not an SSO page
  // or unrelated JavaScript. Such ambiguity cannot authorize rollback.
  if (probes.every(p => acceptable(p.root) && acceptable(p.worker) &&
      (p.root !== 200 || p.rootValid === true) &&
      (p.worker !== 200 || p.workerValid === true)) &&
      (probes.every(p => serverError(p.root)) || probes.every(p => serverError(p.worker)))) {
    return 'repeatable-server-failure';
  }
  return 'unverified'; // Includes auth/SSO, network errors, content mismatches and transient failures.
}

export function parseArguments(argv) {
  const result = { autoRollback: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--auto-rollback') { result.autoRollback = true; continue; }
    const key = ({ '--deployment': 'deployment', '--previous': 'previous', '--project': 'project', '--team': 'team', '--sha': 'sha', '--domain': 'domain' })[argv[i]];
    if (!key || !argv[i + 1] || argv[i + 1].startsWith('--') || result[key]) throw Error(`Invalid or repeated argument: ${argv[i]}`);
    result[key] = argv[++i];
  }
  validateInputs(result);
  return result;
}

// Read only the first bounded bytes of a health response. A broken deployment
// can serve arbitrarily large HTML/JS; response.text() buffers it all first.
export async function readProbeBody(response, limit = 120000) {
  if (!response.ok) {
    // Failed health endpoints can stream arbitrarily large error pages.
    // Stop the response body immediately; status alone is sufficient evidence.
    if (response.body?.cancel) await response.body.cancel().catch(() => {});
    return '';
  }
  const declared = response.headers?.get?.('content-length');
  if (declared !== null && declared !== undefined && declared !== '') {
    const size = Number(declared);
    if (!Number.isSafeInteger(size) || size < 0 || size > limit) {
      // A rejected Content-Length must also stop the underlying network
      // stream; otherwise repeated health probes can leave open downloads.
      if (response.body?.cancel) await response.body.cancel().catch(() => {});
      throw Error('Oversized or invalid health response.');
    }
  }
  if (!response.body?.getReader) {
    // Compatibility with lightweight injected test responses only.
    const body = await response.text();
    if (Buffer.byteLength(body, 'utf8') > limit) throw Error('Oversized health response.');
    return body;
  }
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) throw Error('Oversized health response.');
      chunks.push(value);
    }
    return new TextDecoder('utf-8', { fatal: true }).decode(
      Buffer.concat(chunks.map(chunk => Buffer.from(chunk)), total)
    );
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

export async function runReleaseCheck(args, { fetcher = fetch, sleep = ms => new Promise(r => setTimeout(r, ms)) } = {}) {
  validateInputs(args);
  const token = process.env.VERCEL_TOKEN;
  if (!token) throw Error('VERCEL_TOKEN must be set in the execution environment (never in source).');
  const api = async (path, options = {}) => {
    const url = `https://api.vercel.com${path}${path.includes('?') ? '&' : '?'}teamId=${encodeURIComponent(args.team)}`;
    const response = await fetcher(url, { ...options, redirect: 'error', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(15000) });
    if (!response.ok) {
      // API failures may include large streaming HTML/error bodies. The status
      // is sufficient to block release; cancel without buffering the payload.
      if (response.body?.cancel) await response.body.cancel().catch(() => {});
      throw Error(`Vercel API returned HTTP ${response.status} for ${options.method ?? 'GET'}.`);
    }
    // A successful rollback request may return HTTP 204 (no JSON body).
    // Only the mutation endpoint may omit metadata; subsequent alias readback
    // remains mandatory before claiming that traffic actually moved.
    if (options.method === 'POST' && response.status === 204) {
      if (response.body?.cancel) await response.body.cancel().catch(() => {});
      return null;
    }
    // Deployment metadata is untrusted network input. Bound its bytes before
    // JSON parsing just as we bound public health responses; an unexpectedly
    // large API payload must never exhaust the release guard's memory.
    const limit = 1024 * 1024;
    if (response.body?.getReader) {
      const raw = await readProbeBody(response, limit);
      return JSON.parse(raw);
    }
    // Native fetch responses always expose a readable body. Never use the
    // unbounded response.json() fallback with authenticated production traffic.
    if (fetcher === fetch) throw Error('Vercel metadata response has no readable stream.');
    // Only injected test fixtures may omit a stream. Bound their declared and
    // serialized sizes too, so fixtures cannot silently bypass the release gate.
    const declared = response.headers?.get?.('content-length');
    if (declared !== null && declared !== undefined && declared !== '') {
      const size = Number(declared);
      if (!Number.isSafeInteger(size) || size < 0 || size > limit) throw Error('Oversized or invalid Vercel metadata response.');
    }
    if (typeof response.json !== 'function') throw Error('Missing Vercel metadata response body.');
    const fixture = await response.json();
    if (Buffer.byteLength(JSON.stringify(fixture) ?? '', 'utf8') > limit) throw Error('Oversized Vercel metadata response.');
    return fixture;
  };
  const current = await api(`/v13/deployments/${args.deployment}`);
  const previous = await api(`/v13/deployments/${args.previous}`);
  const aliased = await api(`/v13/deployments/${args.domain}`);
  const errors = evaluateIdentity({ current, previous, aliased, project: args.project, sha: args.sha,
    deployment: args.deployment, previousDeployment: args.previous });
  if (errors.length) return { status: 'BLOCKED_IDENTITY', errors };

  const probe = async (path) => {
    try {
      const response = await fetcher(`https://${args.domain}${path}`, { redirect: 'error', cache: 'no-store', signal: AbortSignal.timeout(10000) });
      const type = response.headers?.get?.('content-type')?.split(';', 1)[0]?.trim()?.toLowerCase() ?? '';
      return { status: response.status, type, body: await readProbeBody(response) };
    } catch { return { status: 0, type: '', body: '' }; }
  };
  const probes = [];
  for (let attempt = 0; attempt < 3; attempt++) {
    const [root, worker] = await Promise.all([probe('/'), probe('/sw.js')]);
    const rootValid = root.type === 'text/html' && root.body.includes('MP3 Shelf');
    const workerValid = ['text/javascript', 'application/javascript'].includes(worker.type) &&
      worker.body.includes('mp3-shelf-v2') && worker.body.includes('precacheAppShell');
    probes.push({ root: root.status, worker: worker.status,
      rootValid, workerValid, marker: rootValid && workerValid });
    if (attempt < 2) await sleep(1500);
  }
  const classification = classifyProbes(probes);
  if (classification === 'healthy') {
    // A production alias can move while the three health probes run. Health
    // from a different deployment must never validate the requested SHA.
    const verifiedAlias = await api(`/v13/deployments/${args.domain}`);
    if ((verifiedAlias.id ?? verifiedAlias.uid) !== args.deployment) {
      return { status: 'BLOCKED_RACE', probes, reason: 'Production alias changed during health verification.' };
    }
    return { status: 'PASS', deployment: args.deployment, sha: args.sha, probes };
  }
  if (classification !== 'repeatable-server-failure') return { status: 'BLOCKED_UNVERIFIED', probes, reason: 'Authentication, network or content evidence is inconclusive; no rollback attempted.' };
  if (!args.autoRollback) return { status: 'FAILED_DRY_RUN', probes, reason: 'Repeatable HTTP errors; --auto-rollback not set.' };

  // The initial three failures may have recovered while the release guard waited.
  // Require a fresh, independently observed failure before changing traffic.
  const [latestRoot, latestWorker] = await Promise.all([probe('/'), probe('/sw.js')]);
  const latestRootValid = latestRoot.type === 'text/html' && latestRoot.body.includes('MP3 Shelf');
  const latestWorkerValid = ['text/javascript', 'application/javascript'].includes(latestWorker.type) &&
    latestWorker.body.includes('mp3-shelf-v2') && latestWorker.body.includes('precacheAppShell');
  const latest = { root: latestRoot.status, worker: latestWorker.status,
    rootValid: latestRootValid, workerValid: latestWorkerValid,
    marker: latestRootValid && latestWorkerValid };
  const persistentEndpoint = endpoint =>
    probes.every(p => [404, 500, 502, 503, 504].includes(p[endpoint])) &&
    [404, 500, 502, 503, 504].includes(latest[endpoint]);
  const acceptable = status => status === 200 || [404, 500, 502, 503, 504].includes(status);
  if ((!persistentEndpoint('root') && !persistentEndpoint('worker')) ||
      !acceptable(latest.root) || !acceptable(latest.worker) ||
      (latest.root === 200 && !latest.rootValid) ||
      (latest.worker === 200 && !latest.workerValid)) {
    return { status: 'BLOCKED_RECOVERED_OR_UNVERIFIED', probes: [...probes, latest] };
  }
  // Re-check the alias immediately before routing traffic away. Never roll back if changed.
  const live = await api(`/v13/deployments/${args.domain}`);
  if ((live.id ?? live.uid) !== args.deployment) return { status: 'BLOCKED_RACE', probes: [...probes, latest] };
  await api(`/v9/projects/${args.project}/rollback/${args.previous}`, { method: 'POST', body: '{}' });
  for (let attempt = 0; attempt < 10; attempt++) {
    await sleep(2000);
    const after = await api(`/v13/deployments/${args.domain}`);
    if ((after.id ?? after.uid) === args.previous) return { status: 'ROLLED_BACK', previous: args.previous, probes, autoAssignmentPaused: true };
  }
  return { status: 'ROLLBACK_REQUESTED_UNVERIFIED', previous: args.previous, probes, autoAssignmentPaused: true };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const args = parseArguments(process.argv.slice(2));
    runReleaseCheck(args).then(result => {
      console.log(JSON.stringify(result, null, 2));
      if (result.status !== 'PASS') process.exitCode = 1;
    }).catch(error => { console.error(`BLOCKED: ${error.message}`); process.exitCode = 2; });
  } catch (error) {
    console.error(`BLOCKED: ${error.message}`);
    console.error('Usage: VERCEL_TOKEN=... node scripts/verify-vercel-release.mjs --deployment dpl_ID --previous dpl_ID --project prj_ID --team team_ID --sha 40_HEX --domain mp3-shelf.vercel.app [--auto-rollback]');
    process.exitCode = 2;
  }
}
