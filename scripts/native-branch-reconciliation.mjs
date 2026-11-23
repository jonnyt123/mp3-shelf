#!/usr/bin/env node
/**
 * Read-only native PR reconciliation audit. It never creates commits, moves refs
 * or grants release approval. A passing plan is permission to start a fresh
 * exact-SHA integration/test cycle, NOT permission to merge or publish.
 */
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const SHA = /^[0-9a-f]{40}$/;
const REPO = 'jonnyt123/mp3-shelf';
const PRS = [37, 35, 36];
const expectedBases = new Map([
  [37, 'feat/ios-consolidated-candidate'],
  [35, 'feat/ios-consolidated-candidate'],
  [36, 'agent/mp3-spotify-pagination-fix']
]);

export function auditNativeReconciliation({ candidateSha, proposals } = {}) {
  const blockers = [], overlap = [], drift = [];
  if (!SHA.test(candidateSha ?? ''))
    blockers.push('Consolidated draft must have an exact 40-character source SHA.');
  if (!Array.isArray(proposals) || proposals.length === 0 || proposals.length > 12)
    return { status: 'BLOCKED', compositionEligible: false, releaseAuthorized: false,
      blockers: [...blockers, 'Expected a bounded inventory of native PRs.'],
      overlap, drift, order: [] };
  const seenPRs = new Set(), visited = new Map(), order = [];
  for (const proposal of proposals) {
    const { number, headSha, mergeBaseSha, ahead, behind, changedFiles,
      draft, state, headRepo, baseRepo, baseRef } = proposal ?? {};
    if (!Number.isSafeInteger(number) || number < 1 || seenPRs.has(number)) {
      blockers.push('Malformed or repeated native pull request number.');
      continue;
    }
    seenPRs.add(number);
    order.push({ pr: number, sha: headSha ?? null });
    if (state !== 'open' || draft !== true ||
        headRepo !== REPO || baseRepo !== REPO ||
        baseRef !== expectedBases.get(number))
      blockers.push('PR #' + number + ' is not the expected reviewed draft/stack.');
    if (!SHA.test(headSha ?? '') || !SHA.test(mergeBaseSha ?? '') ||
        headSha === candidateSha)
      blockers.push('PR #' + number + ' has a missing, invalid or unchanged commit.');
    if (!Number.isSafeInteger(ahead) || ahead < 1 ||
        !Number.isSafeInteger(behind) || behind < 0)
      blockers.push('PR #' + number + ' lacks a valid ancestry comparison.');
    else if (behind !== 0) {
      drift.push({ pr: number, behind, ahead });
      blockers.push('PR #' + number + ' diverged from current draft; rebase/re-review required.');
    }
    if (!Array.isArray(changedFiles) || changedFiles.length === 0 ||
        changedFiles.length > 500 || new Set(changedFiles).size !== changedFiles.length ||
        changedFiles.some(path => typeof path !== 'string' ||
          !path.startsWith('ios/') || path.includes('..') || path.includes('\\')))
      blockers.push('PR #' + number + ' has missing or unexpected changed paths.');
    else {
      for (const path of changedFiles) {
        const owner = visited.get(path);
        if (owner !== undefined) {
          overlap.push({ path, previousPR: owner, pr: number });
        } else visited.set(path, number);
      }
    }
  }
  if (overlap.length)
    blockers.push('Cross-PR source overlap requires reviewed composition and new full Xcode verification.');
  // Unknown, omitted or reordered PRs must not turn an incomplete audit green.
  if (proposals.length !== PRS.length || PRS.some((n, i) => proposals[i]?.number !== n))
    blockers.push('Native proposal inventory is incomplete or out of integration order.');
  return {
    status: blockers.length ? 'BLOCKED' : 'COMPOSITION_ELIGIBLE',
    compositionEligible: blockers.length === 0,
    releaseAuthorized: false,
    blockers, overlap, drift, order
  };
}

function command(name, args, cwd) {
  return execFileSync(name, args, {
    cwd, encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe']
  }).trim();
}
function git(root, ...args) { return command('git', ['-C', root, ...args], root); }
function sourceIdentity(root) {
  const remote = git(root, 'remote', 'get-url', 'origin');
  if (!/^(?:https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)jonnyt123\/mp3-shelf(?:\.git)?\/?$/.test(remote))
    throw Error('Native integration audit requires the official repository origin.');
  if (resolve(git(root, 'rev-parse', '--show-toplevel')) !== root)
    throw Error('Native integration audit requires the repository root.');
  // Do not destroy or reset user work. Read-only Git operations are allowed.
}
function remoteRef(root, ref) {
  const lines = git(root, 'ls-remote', '--exit-code', 'origin', ref).split('\n');
  if (lines.length !== 1) throw Error('Ambiguous remote ref ' + ref);
  const [sha, actual] = lines[0].split('\t');
  if (!SHA.test(sha ?? '') || actual !== ref)
    throw Error('Invalid remote source identity for ' + ref);
  return sha;
}
function prMetadata(root, number) {
  const value = command('gh', ['api', 'repos/' + REPO + '/pulls/' + number], root);
  const data = JSON.parse(value);
  if (data.number !== number || !data.head?.sha || !data.base?.sha)
    throw Error('GitHub draft metadata did not identify PR #' + number);
  return data;
}
function distance(root, from, to) {
  const raw = git(root, 'rev-list', '--count', from + '..' + to);
  const n = Number(raw);
  if (!/^\d+$/.test(raw) || !Number.isSafeInteger(n)) throw Error('Invalid Git ancestry count.');
  return n;
}

/** Fetches only immutable PR commits into Git's object store; never checks out a file. */
export function auditLiveNativeBranches(root) {
  const project = resolve(root);
  sourceIdentity(project);
  const base = prMetadata(project, 29);
  const candidateSha = remoteRef(project, 'refs/heads/feat/ios-consolidated-candidate');
  if (base.state !== 'open' || base.draft !== true ||
      base.head?.sha !== candidateSha || base.head?.repo?.full_name !== REPO ||
      base.base?.repo?.full_name !== REPO)
    throw Error('Current consolidated PR #29 changed or lost draft status.');
  const snapshots = PRS.map(number => ({
    number, data: prMetadata(project, number),
    remoteSha: remoteRef(project, 'refs/pull/' + number + '/head')
  }));
  for (const snapshot of snapshots) {
    if (snapshot.data.head.sha !== snapshot.remoteSha)
      throw Error('Native PR head advanced while reading #'+snapshot.number);
  }
  // Fetch explicitly scoped remote PR refs. This does not update tracked
  // files, branches, the draft candidate or main.
  for (const sha of [candidateSha, ...snapshots.map(s => s.remoteSha)]) {
    git(project, 'fetch', '--no-tags', 'origin', sha);
    git(project, 'cat-file', '-e', sha + '^{commit}');
  }
  const proposals = snapshots.map(({ number, data, remoteSha }) => {
    const mergeBaseSha = git(project, 'merge-base', candidateSha, remoteSha);
    if (!SHA.test(mergeBaseSha)) throw Error('Invalid merge-base identity.');
    const changedRaw = command('git',
      ['-C', project, 'diff', '--name-only', '-z', mergeBaseSha, remoteSha], project);
    const changedFiles = changedRaw.split('\0').filter(Boolean);
    return {
      number, headSha: remoteSha, mergeBaseSha,
      ahead: distance(project, candidateSha, remoteSha),
      behind: distance(project, remoteSha, candidateSha),
      changedFiles, state: data.state, draft: data.draft,
      headRepo: data.head?.repo?.full_name,
      baseRepo: data.base?.repo?.full_name, baseRef: data.base?.ref
    };
  });
  // Refetch metadata, since any source race invalidates the audit.
  for (const { number, remoteSha } of snapshots) {
    const fresh = prMetadata(project, number);
    const original = snapshots.find(item => item.number === number).data;
    if (remoteRef(project, 'refs/pull/' + number + '/head') !== remoteSha ||
        fresh.head?.sha !== remoteSha || fresh.state !== original.state ||
        fresh.draft !== original.draft ||
        fresh.base?.ref !== original.base?.ref ||
        fresh.base?.sha !== original.base?.sha ||
        fresh.base?.repo?.full_name !== original.base?.repo?.full_name ||
        fresh.head?.repo?.full_name !== original.head?.repo?.full_name)
      throw Error('Native PR #' + number + ' advanced during reconciliation audit.');
  }
  const freshBase = prMetadata(project, 29);
  if (remoteRef(project, 'refs/heads/feat/ios-consolidated-candidate') !== candidateSha ||
      freshBase.head?.sha !== candidateSha || freshBase.state !== 'open' ||
      freshBase.draft !== true || freshBase.base?.ref !== base.base?.ref ||
      freshBase.base?.sha !== base.base?.sha ||
      freshBase.base?.repo?.full_name !== base.base?.repo?.full_name)
    throw Error('Consolidated native candidate metadata or source advanced during reconciliation audit.');
  return { candidateSha, ...auditNativeReconciliation({ candidateSha, proposals }) };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (process.argv.length !== 3) {
    console.error('Usage: node scripts/native-branch-reconciliation.mjs CLEAN_OR_DIRTY_REPO_ROOT');
    process.exitCode = 2;
  } else {
    try {
      const result = auditLiveNativeBranches(process.argv[2]);
      console.log(JSON.stringify(result, null, 2));
      if (result.status !== 'COMPOSITION_ELIGIBLE') process.exitCode = 1;
    } catch (error) {
      console.error('NATIVE_RECONCILIATION_BLOCKED: ' + error.message);
      process.exitCode = 2;
    }
  }
}
