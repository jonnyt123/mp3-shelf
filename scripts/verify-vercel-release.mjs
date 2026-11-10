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

export function evaluateIdentity({ current, previous, aliased, project, sha }) {
  const errors = [];
  const deploymentId = d => d?.id ?? d?.uid;
  const target = d => d?.target;
  const ready = d => d?.readyState ?? d?.state;
  const ownedProject = d => d?.projectId ?? d?.project?.id;
  const repo = current?.meta ?? {};
  const priorRepo = previous?.meta ?? {};
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
  if (probes.every(p => p.root === 200 && p.worker === 200 && p.marker === true)) return 'healthy';
  // Only a persistent failure of the SAME endpoint can justify rollback.
  // Auth/SSO, network failures, or alternating transient errors on either
  // endpoint make the entire probe sequence inconclusive.
  const serverError = status => [404, 500, 502, 503, 504].includes(status);
  const acceptable = status => status === 200 || serverError(status);
  if (probes.every(p => acceptable(p.root) && acceptable(p.worker)) &&
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

export async function runReleaseCheck(args, { fetcher = fetch, sleep = ms => new Promise(r => setTimeout(r, ms)) } = {}) {
  validateInputs(args);
  const token = process.env.VERCEL_TOKEN;
  if (!token) throw Error('VERCEL_TOKEN must be set in the execution environment (never in source).');
  const api = async (path, options = {}) => {
    const url = `https://api.vercel.com${path}${path.includes('?') ? '&' : '?'}teamId=${encodeURIComponent(args.team)}`;
    const response = await fetcher(url, { ...options, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw Error(`Vercel API returned HTTP ${response.status} for ${options.method ?? 'GET'}.`);
    return response.json();
  };
  const current = await api(`/v13/deployments/${args.deployment}`);
  const previous = await api(`/v13/deployments/${args.previous}`);
  const aliased = await api(`/v13/deployments/${args.domain}`);
  const errors = evaluateIdentity({ current, previous, aliased, project: args.project, sha: args.sha });
  if (errors.length) return { status: 'BLOCKED_IDENTITY', errors };

  const probe = async (path) => {
    try {
      const response = await fetcher(`https://${args.domain}${path}`, { redirect: 'error', cache: 'no-store', signal: AbortSignal.timeout(10000) });
      return { status: response.status, body: response.ok ? (await response.text()).slice(0, 120000) : '' };
    } catch { return { status: 0, body: '' }; }
  };
  const probes = [];
  for (let attempt = 0; attempt < 3; attempt++) {
    const [root, worker] = await Promise.all([probe('/'), probe('/sw.js')]);
    probes.push({ root: root.status, worker: worker.status, marker: root.body.includes('MP3 Shelf') && worker.body.length > 50 });
    if (attempt < 2) await sleep(1500);
  }
  const classification = classifyProbes(probes);
  if (classification === 'healthy') return { status: 'PASS', deployment: args.deployment, sha: args.sha, probes };
  if (classification !== 'repeatable-server-failure') return { status: 'BLOCKED_UNVERIFIED', probes, reason: 'Authentication, network or content evidence is inconclusive; no rollback attempted.' };
  if (!args.autoRollback) return { status: 'FAILED_DRY_RUN', probes, reason: 'Repeatable HTTP errors; --auto-rollback not set.' };

  // The initial three failures may have recovered while the release guard waited.
  // Require a fresh, independently observed failure before changing traffic.
  const [latestRoot, latestWorker] = await Promise.all([probe('/'), probe('/sw.js')]);
  const latest = { root: latestRoot.status, worker: latestWorker.status,
    marker: latestRoot.body.includes('MP3 Shelf') && latestWorker.body.length > 50 };
  const persistentEndpoint = endpoint =>
    probes.every(p => [404, 500, 502, 503, 504].includes(p[endpoint])) &&
    [404, 500, 502, 503, 504].includes(latest[endpoint]);
  const acceptable = status => status === 200 || [404, 500, 502, 503, 504].includes(status);
  if ((!persistentEndpoint('root') && !persistentEndpoint('worker')) ||
      !acceptable(latest.root) || !acceptable(latest.worker)) {
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
