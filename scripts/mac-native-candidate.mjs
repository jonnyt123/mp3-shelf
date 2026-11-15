#!/usr/bin/env node
/**
 * Mac-only: verify an isolated exact-SHA native candidate; optionally fast-forward
 * ONLY the draft iOS candidate branch. Never pushes to main or runs GitHub Actions.
 * Requires a local authenticated git checkout and full Xcode. No secrets in logs.
 */
import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createWriteStream, mkdirSync, mkdtempSync, readFileSync,
         rmSync, writeFileSync, copyFileSync, statSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Transform } from 'node:stream';
import { buildLocalReceipt } from './local-evidence.mjs';
import { checkNativeStage } from './verify-native-stage.mjs';

const SHA = /^[0-9a-f]{40}$/;
export const BASE_REF = 'refs/heads/feat/ios-consolidated-candidate';
export const PREVIEW_REF = 'refs/heads/agent/mp3-native-integration-preflight';
const OWNED_PATHS = new Set([
  'ios/MP3Shelf/Services/AudioSourceFinder.swift',
  'ios/MP3Shelf/Services/BackgroundAudioDownloader.swift',
  'ios/MP3Shelf/Services/DownloadPathProof.swift',
  'ios/MP3Shelf/MP3ShelfApp.swift',
  'ios/scripts/verify-local-release.sh',
  'ios/scripts/test-native-preflight-policies.py',
  'ios/Tests/AudioCatalogRetryPolicyTests.swift',
  'ios/Tests/BackgroundRedirectNetworkPolicyTests.swift',
  'ios/Tests/CatalogResponseOriginTests.swift',
  'ios/Tests/DuplicateCompletionStagingRaceTests.swift'
]);
const MAX_NATIVE_SECONDS = 3600;
const MAX_NATIVE_LOG_BYTES = 32 * 1024 * 1024;

export function promotionPolicy({ base, proposed, current, latestPreview, changedFiles, gateErrors }) {
  const errors = [];
  if (![base, proposed, current, latestPreview].every(s => SHA.test(s ?? '')))
    errors.push('All branch references must resolve to full Git commit SHAs.');
  if (base === proposed) errors.push('Nothing new is ready to stage.');
  if (current !== base) errors.push('Consolidated candidate advanced since verification began.');
  if (latestPreview !== proposed) errors.push('Preflight HEAD advanced; regenerate and retest exact SHA.');
  if (!Array.isArray(changedFiles) || changedFiles.length === 0 ||
      changedFiles.some(path => !OWNED_PATHS.has(path)))
    errors.push('Preflight diff contains unexpected or missing owned source/test files.');
  if (!Array.isArray(gateErrors) || gateErrors.length)
    errors.push('Native compilation, regression or receipt integrity gate has not passed.');
  return errors;
}

export function verifyDraftPreflightPR(pr, { base, proposed }) {
  const errors = [];
  if (!pr || pr.number !== 37 || pr.state !== 'open' || pr.draft !== true)
    errors.push('Expected open draft preflight PR #37.');
  if (pr?.head?.sha !== proposed || pr?.head?.ref !==
      'agent/mp3-native-integration-preflight' ||
      pr?.head?.repo?.full_name !== 'jonnyt123/mp3-shelf')
    errors.push('Draft review head does not match exact proposed source SHA.');
  if (pr?.base?.sha !== base || pr?.base?.ref !==
      'feat/ios-consolidated-candidate' ||
      pr?.base?.repo?.full_name !== 'jonnyt123/mp3-shelf')
    errors.push('Draft PR target differs from the exact current iOS candidate.');
  return errors;
}

export function verifyConsolidatedDraftPR(pr, { base }) {
  const errors = [];
  if (!pr || pr.number !== 29 || pr.state !== 'open' || pr.draft !== true)
    errors.push('Expected open draft consolidated PR #29.');
  if (pr?.head?.sha !== base ||
      pr?.head?.ref !== 'feat/ios-consolidated-candidate' ||
      pr?.head?.repo?.full_name !== 'jonnyt123/mp3-shelf')
    errors.push('Consolidated draft head differs from the verified native baseline.');
  // #29 is deliberately stacked over the native download-finalization
  // branch, not main. Validate that exact reviewed base rather than
  // incorrectly rejecting every legitimate native preflight run.
  if (pr?.base?.ref !== 'fix/ios-download-finalization-and-conversion' ||
      pr?.base?.repo?.full_name !== 'jonnyt123/mp3-shelf')
    errors.push('Consolidated draft native stack base was unexpectedly retargeted.');
  return errors;
}

async function githubDraftReview(base, proposed) {
  const urls = [29, 37].map(number =>
    'https://api.github.com/repos/jonnyt123/mp3-shelf/pulls/' + number);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);
  try {
    const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
    // Validate BOTH open draft PRs before any source promotion. A closed or
    // retargeted consolidated PR must not be silently pushed by its branch name.
    for (const [index, url] of urls.entries()) {
      const response = await fetch(url, {
        headers: { Accept: 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          ...(token ? { Authorization: 'Bearer ' + token } : {}) },
        signal: controller.signal
      });
      if (!response.ok) throw Error('Unable to verify live draft PR status (HTTP ' + response.status + ')');
      const snapshot = await response.json();
      const errors = index === 0
        ? verifyConsolidatedDraftPR(snapshot, { base })
        : verifyDraftPreflightPR(snapshot, { base, proposed });
      if (errors.length) throw Error(errors.join('; '));
    }
  } finally { clearTimeout(timeout); }
}

function git(repo, ...args) {
  return execFileSync('git', ['-C', repo, ...args], {
    encoding: 'utf8', timeout: 90_000, maxBuffer: 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe']
  }).trim();
}
function remoteSHA(repo, ref) {
  const lines = git(repo, 'ls-remote', '--exit-code', 'origin', ref).split('\n');
  if (lines.length !== 1) throw Error('Remote ref has ambiguous result: ' + ref);
  const [sha, found] = lines[0].split('\t');
  if (found !== ref || !SHA.test(sha)) throw Error('Unexpected Git remote ref identity: ' + ref);
  return sha;
}
function officialOrigin(url) {
  return /^(?:https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)jonnyt123\/mp3-shelf(?:\.git)?\/?$/.test(url);
}
function assertWorktreeClean(repo, sha) {
  if (git(repo, 'rev-parse', 'HEAD') !== sha ||
      git(repo, 'status', '--porcelain', '--untracked-files=all') !== '')
    throw Error('Candidate worktree is not clean at the expected SHA.');
}
export function runLogged(command, args, cwd, logPath, { timeoutMs = MAX_NATIVE_SECONDS * 1000, killGraceMs = 5000, maxLogBytes = MAX_NATIVE_LOG_BYTES } = {}) {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 ||
      !Number.isSafeInteger(killGraceMs) || killGraceMs < 1 ||
      !Number.isSafeInteger(maxLogBytes) || maxLogBytes < 1)
    throw Error('Native runner timeouts must be positive safe integers.');
  return new Promise((resolvePromise, reject) => {
    let settled = false;
    let child;
    const finish = error => {
      if (settled) return;
      settled = true;
      if (error) reject(error);
      else resolvePromise();
    };
    const output = createWriteStream(logPath, { flags: 'wx', mode: 0o600 });
    let streamFailure = null;
    let loggedBytes = 0;
    const boundedLog = new Transform({ transform(chunk, _encoding, callback) {
      loggedBytes += chunk.length;
      if (loggedBytes > maxLogBytes) {
        callback(Error('Native verification log exceeded ' + maxLogBytes + ' bytes'));
      } else callback(null, chunk);
    } });
    let processClosed = false;
    let watchdog, escalation;
    // Native verification launches bash -> xcodebuild -> test runners. Killing
    // only bash can leave descendants modifying the detached worktree after
    // verification has failed. Own a POSIX process group and signal the group.
    const signalGroup = signal => {
      if (!child?.pid) return;
      try {
        if (process.platform !== 'win32') process.kill(-child.pid, signal);
        else child.kill(signal);
      } catch (error) {
        if (error.code !== 'ESRCH') throw error;
      }
    };
    const terminate = () => {
      if (!child?.pid) return;
      signalGroup('SIGTERM');
      if (!escalation) {
        escalation = setTimeout(() => signalGroup('SIGKILL'), killGraceMs);
        escalation.unref();
      }
    };
    // Do not settle while a failed native command is still running: callers
    // remove the detached worktree immediately after this promise settles.
    // A late log error must also override a successful process exit.
    const failStream = (kind, error) => {
      if (!streamFailure)
        streamFailure = Error(kind + ': ' + error.message);
      terminate();
      if (processClosed) finish(streamFailure);
    };
    output.on('error', error => failStream('Native verification log could not be written', error));
    boundedLog.on('error', error => failStream('Native verification log limit or stream failure', error));
    boundedLog.pipe(output, { end: false });
    try {
      child = spawn(command, args, {
        cwd, stdio: ['ignore', 'pipe', 'pipe'],
        detached: process.platform !== 'win32',
        env: { ...process.env, LC_ALL: 'C' }
      });
    } catch (error) {
      output.destroy();
      finish(error);
      return;
    }
    watchdog = setTimeout(() => {
      if (!streamFailure) streamFailure = Error('Native verification exceeded timeout of ' + timeoutMs + 'ms');
      terminate();
    }, timeoutMs);
    child.on('error', error => {
      failStream('Native verification process failed to start', error);
      output.destroy();
    });
    // A readable stream failure is not equivalent to a successful native run:
    // otherwise a truncated Xcode log could be hashed as complete evidence.
    for (const stream of [child.stdout, child.stderr]) {
      stream.on('error', error => {
        failStream('Native verification output stream failed', error);
        output.destroy();
      });
      stream.pipe(boundedLog, { end: false });
    }
    child.on('close', (code, signal) => {
      processClosed = true;
      clearTimeout(watchdog);
      // Keep escalation armed after the parent exits: descendants can outlive bash.
      if (!streamFailure) clearTimeout(escalation);
      if (settled) return;
      if (streamFailure) { finish(streamFailure); return; }
      // Register before end(): small buffered logs may finish synchronously.
      output.once('finish', () => {
        if (streamFailure) finish(streamFailure);
        else if (code === 0 && signal === null) finish();
        else finish(Error('Native runner failed (exit ' + code +
          ', signal ' + (signal ?? 'none') + '); see ' + logPath));
      });
      boundedLog.end();
      // The shared transform must flush before the evidence log is finalized.
      // The transform's finish event is not sufficient: its readable side can
      // still hold buffered data while the destination is backpressured.
      boundedLog.once('end', () => output.end());
    });
  });
}
async function hashFile(path) {
  const file = readFileSync(path);
  return createHash('sha256').update(file).digest('hex');
}

/** Recover only an orphaned verifier lock older than two full run windows. */
function acquireLock(path) {
  function claim() {
    mkdirSync(path, { mode: 0o700 });
    writeFileSync(join(path, 'owner.json'),
      JSON.stringify({ pid: process.pid, started: Date.now() }) + '\n',
      { flag: 'wx', mode: 0o600 });
  }
  try { claim(); return; }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }
  const age = Date.now() - statSync(path).mtimeMs;
  if (age < 2 * MAX_NATIVE_SECONDS * 1000) throw Error('Another Mac native verification owns the active lock.');
  let pid = null;
  try { pid = JSON.parse(readFileSync(join(path, 'owner.json'), 'utf8')).pid; }
  catch { /* Unfinished lock creation; use the longer age threshold. */ }
  if (Number.isSafeInteger(pid) && pid > 0) {
    try { process.kill(pid, 0); throw Error('Existing native verifier is still running; refusing overlapping build.'); }
    catch (error) { if (error.code !== 'ESRCH') throw error; }
  }
  rmSync(path, { recursive: true, force: true });
  claim();
}

export async function executeNativePreflight({ repo, promote = false, evidenceRoot } = {}) {
  if (process.platform !== 'darwin') throw Error('MAC_XCODE_REQUIRED: this host is not macOS.');
  const project = resolve(repo ?? join(dirname(fileURLToPath(import.meta.url)), '..'));
  if (resolve(git(project, 'rev-parse', '--show-toplevel')) !== project)
    throw Error('Pass the repository root, not a parent or subdirectory.');
  if (!officialOrigin(git(project, 'remote', 'get-url', 'origin')))
    throw Error('Origin is not the expected jonnyt123/mp3-shelf repository.');
  execFileSync('xcodebuild', ['-version'], { timeout: 15000, stdio: 'pipe' });
  // Fetch only the two native branches, never alter the user's checked-out files.
  git(project, 'fetch', '--no-tags', 'origin', BASE_REF, PREVIEW_REF);
  const base = remoteSHA(project, BASE_REF);
  const proposed = remoteSHA(project, PREVIEW_REF);
  if (base === proposed) return { status: 'already-staged', sha: proposed };
  git(project, 'cat-file', '-e', base + '^{commit}');
  git(project, 'cat-file', '-e', proposed + '^{commit}');
  git(project, 'merge-base', '--is-ancestor', base, proposed);
  const changedFiles = git(project, 'diff', '--name-only', base, proposed).split('\n').filter(Boolean);
  const scopeErrors = promotionPolicy({ base, proposed, current: base, latestPreview: proposed,
    changedFiles, gateErrors: [] });
  if (scopeErrors.length) throw Error(scopeErrors.join('; '));
  git(project, 'diff', '--check', base, proposed);
  await githubDraftReview(base, proposed);

  // A single lock avoids overlapping local Xcode sessions on the same Mac.
  const lock = join(tmpdir(), 'mp3shelf-exact-native-preflight.lock');
  let acquiredLock = false, workspace = null, installedWorktree = false;
  let worktree, output;
  try {
    acquireLock(lock);
    acquiredLock = true;
    workspace = mkdtempSync(join(tmpdir(), 'mp3shelf-xcode-preflight-'));
    worktree = join(workspace, 'candidate');
    const logs = resolve(evidenceRoot ?? join(homedir(), 'Library', 'Logs', 'MP3Shelf', 'NativePreflight'));
    output = join(logs, proposed, new Date().toISOString().replace(/[:.]/g, '-'));
    mkdirSync(output, { recursive: true, mode: 0o700 });
    git(project, 'worktree', 'add', '--detach', worktree, proposed);
    installedWorktree = true;
    assertWorktreeClean(worktree, proposed);
    const consoleLog = join(output, 'native-console.log');
    await runLogged('bash', ['ios/scripts/verify-local-release.sh'], worktree, consoleLog);
    const qaPath = join(worktree, 'ios', 'build', 'local-release', 'QA_RECORD.md');
    if (statSync(qaPath).size > 256 * 1024) throw Error('Native QA record exceeds size limit.');
    const preservedQA = join(output, 'native-QA_RECORD.md');
    copyFileSync(qaPath, preservedQA);
    assertWorktreeClean(worktree, proposed);
    const checkedDigest = await hashFile(preservedQA);
    writeFileSync(join(output, 'native-local-release.log'),
      'PASS: bash ios/scripts/verify-local-release.sh exited 0 at ' + proposed +
      '\nNative QA record SHA256: ' + checkedDigest + '\nFull console log: native-console.log\n',
      { flag: 'wx', mode: 0o600 });
    writeFileSync(join(output, 'post-native-checkout-integrity.log'),
      'PASS: clean detached worktree still points at ' + proposed + '\n',
      { flag: 'wx', mode: 0o600 });
    const receipt = buildLocalReceipt({ sha: proposed, dirty: 'no', mode: 'native',
      steps: [{ name: 'native-local-release', success: 1 },
        { name: 'post-native-checkout-integrity', success: 1 }],
      exitCode: 0, logDir: output });
    const receiptPath = join(output, 'local-evidence.json');
    writeFileSync(receiptPath, JSON.stringify(receipt, null, 2) + '\n',
      { flag: 'wx', mode: 0o600 });
    // Verify the REAL log hashes, checkout and full Xcode suite before any write.
    const gateErrors = await checkNativeStage({ proposed, current: base,
      receiptPath, logDir: output, qaPath: preservedQA, cwd: worktree });
    if ((await hashFile(preservedQA)) !== checkedDigest)
      gateErrors.push('QA record changed during evidence validation.');
    const current = remoteSHA(project, BASE_REF);
    const latestPreview = remoteSHA(project, PREVIEW_REF);
    const errors = promotionPolicy({ base, proposed, current, latestPreview, changedFiles, gateErrors });
    if (errors.length) throw Error(errors.join('; '));
    if (!promote) return { status: 'verified-not-staged', sha: proposed, evidence: output };
    // A draft PR may have been closed, superseded or retargeted during Xcode.
    await githubDraftReview(base, proposed);
    assertWorktreeClean(worktree, proposed);
    // NEVER force-push: GitHub refuses non-fast-forward and protected updates.
    git(worktree, 'push', '--porcelain', 'origin', proposed + ':' + BASE_REF);
    const confirmed = remoteSHA(project, BASE_REF);
    if (confirmed !== proposed) throw Error('Remote candidate did not advance to the verified SHA.');
    return { status: 'staged-draft-only', sha: proposed, evidence: output };
  } finally {
    if (installedWorktree) {
      try { git(project, 'worktree', 'remove', '--force', worktree); }
      catch { /* leave evidence intact; report cleanup separately */ }
    }
    if (workspace) rmSync(workspace, { recursive: true, force: true });
    if (acquiredLock) rmSync(lock, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  const promote = args.includes('--promote');
  const provided = args.filter(s => s !== '--promote');
  if (provided.length > 1 || (provided.length && provided[0].startsWith('--'))) {
    console.error('Usage: node scripts/mac-native-candidate.mjs [LOCAL_REPO_PATH] [--promote]');
    process.exitCode = 2;
  } else {
    executeNativePreflight({ repo: provided[0], promote }).then(result => {
      console.log(JSON.stringify(result, null, 2));
    }).catch(error => {
      console.error('NATIVE_STAGING_BLOCKED: ' + error.message);
      process.exitCode = 1;
    });
  }
}
