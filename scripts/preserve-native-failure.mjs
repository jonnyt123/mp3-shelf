#!/usr/bin/env node
/**
 * Preserve failed Swift/Xcode step evidence before the disposable worktree is
 * deleted. No cache, audio, project sources, full logs, or private absolute
 * filesystem paths leave this Mac. This is not a passing-build receipt.
 */
import { createHash } from 'node:crypto';
import { closeSync, copyFileSync, lstatSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, writeFileSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';

const SHA = /^[0-9a-f]{40}$/;
const MAX_FILES = 60;
const MAX_EACH = 4 * 1024 * 1024;
const MAX_TOTAL = 24 * 1024 * 1024;
const ALLOWED = /^(?:QA_RECORD\.md|[A-Za-z0-9_-]{1,90}(?:-compile)?\.log|xcode-version\.txt)$/;
const SAFE_RUN = /^[0-9]{8}T[0-9]{6}Z-[0-9]{1,10}$/;

export function failureEvidencePlan({ runs, sourceSHA }) {
  if (!SHA.test(sourceSHA ?? '') || !Array.isArray(runs)) throw Error('Expected exact Git SHA and native run names.');
  const unique = new Set(), plans = [];
  for (const run of runs) {
    if (typeof run !== 'string' || !SAFE_RUN.test(run) || unique.has(run))
      throw Error('Unsafe or duplicate native run directory');
    unique.add(run);
    plans.push({ name: run, prefix: 'run-' + (plans.length + 1) });
  }
  if (plans.length > 2) throw Error('Native runner used unexpected number of attempts.');
  return plans;
}
function normalFile(path) {
  const s = lstatSync(path);
  return s.isFile() && !s.isSymbolicLink() && s.nlink === 1 && s.size >= 0;
}
function sha(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}
export function preserveNativeFailure({ worktree, output, sourceSHA }) {
  if (!SHA.test(sourceSHA ?? '')) throw Error('Missing native source SHA');
  const root = resolve(worktree, 'ios', 'build', 'local-release');
  const destination = resolve(output, 'failed-native-steps');
  const runsRoot = join(root, 'runs');
  let dirs = [];
  try {
    const available = readdirSync(runsRoot, { withFileTypes: true });
    dirs = available.filter(item => item.isDirectory() && SAFE_RUN.test(item.name))
      .map(item => item.name).sort();
    if (available.some(item => item.isSymbolicLink()))
      throw Error('Native run evidence directory contains a symlink');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const plans = failureEvidencePlan({ runs: dirs, sourceSHA });
  mkdirSync(destination, { recursive: false, mode: 0o700 });
  const copied = [];
  let budget = MAX_TOTAL, skipped = 0;
  function save(from, name, run) {
    if (!ALLOWED.test(basename(from))) return;
    if (!normalFile(from)) { skipped++; return; }
    const size = lstatSync(from).size;
    if (copied.length >= MAX_FILES || budget <= 0) { skipped++; return; }
    const target = join(destination, name);
    let persisted = Math.min(size, MAX_EACH, budget), truncated = persisted < size;
    if (!Number.isSafeInteger(persisted) || persisted < 0) { skipped++; return; }
    if (truncated && persisted < 64 * 1024) { skipped++; return; }
    if (!truncated) copyFileSync(from, target);
    else {
      // Copy the bounded tail so the compiler's final error survives even if
      // Xcode produced a log larger than the per-file evidence budget.
      const descriptor = openSync(from, 'r');
      try {
        const tail = Buffer.alloc(persisted);
        let position = 0;
        while (position < persisted) {
          const count = readSync(descriptor, tail, position, persisted - position,
            size - persisted + position);
          if (count <= 0) throw Error('Native failure log changed during snapshot.');
          position += count;
        }
        writeFileSync(target, tail, { flag: 'wx', mode: 0o600 });
      } finally { closeSync(descriptor); }
    }
    budget -= persisted;
    if (truncated) skipped++;
    copied.push({ file: name, sourceRun: run, bytes: persisted,
      originalBytes: size, truncated, sha256: sha(target) });
  }
  // The latest top-level QA file points to a failed step even when Xcode
  // failed before a suite created an individual compile log.
  try { save(join(root, 'QA_RECORD.md'), 'last-QA_RECORD.md', 'latest'); }
  catch (e) { if (e.code !== 'ENOENT') throw e; }
  for (const entry of plans) {
    const directory = join(runsRoot, entry.name);
    const stat = lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw Error('Unsafe native run log directory');
    const files = readdirSync(directory).filter(name => ALLOWED.test(name)).sort();
    for (const filename of files) {
      save(join(directory, filename), entry.prefix + '-' + filename, entry.name);
    }
  }
  const status = { schema: 'mp3shelf-failed-native-evidence-v1',
    sourceSHA, result: 'FAILED_NATIVE_RUN_NOT_RELEASE_APPROVED',
    attempts: plans.length, preserved: copied, truncated: skipped > 0, skipped };
  writeFileSync(join(destination, 'failure-evidence.json'),
    JSON.stringify(status, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  return status;
}
