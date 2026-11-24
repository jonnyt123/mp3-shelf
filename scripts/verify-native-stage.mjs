#!/usr/bin/env node
/** Blocks draft #29 staging unless the proposed tree passed full native Xcode verification. */
import { execFileSync } from 'node:child_process';
import { constants as fsConstants, closeSync, fstatSync, lstatSync, openSync, readSync } from 'node:fs';
import { resolve } from 'node:path';

const SHA = /^[0-9a-f]{40}$/;
const QA_MAX_BYTES = 256 * 1024;
const QA_FIELDS = ['Checked commit', 'Source provenance', 'Uncommitted changes',
  'Mode', 'Simulator smoke requested', 'Overall execution', 'Exit status',
  'Failure reason', 'Completed checks', 'Apple signing / physical iPhone acceptance',
  'GitHub Actions used'];

export function readNativeQaRecord(path) {
  const before = lstatSync(path);
  if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1 ||
      before.size < 1 || before.size > QA_MAX_BYTES)
    throw Error('Native QA record must be a bounded regular file without links.');
  const fd = openSync(path, fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0));
  try {
    const opened = fstatSync(fd);
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino ||
        opened.nlink !== 1 || opened.size !== before.size)
      throw Error('Native QA record changed while opening.');
    const chunks = [];
    const buffer = Buffer.allocUnsafe(16 * 1024);
    let bytes = 0, count;
    while ((count = readSync(fd, buffer, 0, buffer.length, null)) !== 0) {
      bytes += count;
      if (bytes > QA_MAX_BYTES) throw Error('Native QA record exceeds size limit.');
      chunks.push(Buffer.from(buffer.subarray(0, count)));
    }
    const after = fstatSync(fd);
    const named = lstatSync(path);
    if (bytes !== opened.size || after.size !== opened.size ||
        after.mtimeMs !== opened.mtimeMs || after.ctimeMs !== opened.ctimeMs ||
        named.dev !== opened.dev || named.ino !== opened.ino ||
        named.mtimeMs !== after.mtimeMs || named.ctimeMs !== after.ctimeMs ||
        named.nlink !== 1 || named.isSymbolicLink())
      throw Error('Native QA record changed during reading.');
    return new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, bytes));
  } finally { closeSync(fd); }
}

const CHECKS = [
  'playback-order', 'playback-interruptions', 'downloaded-audio-signature',
  'downloaded-audio-format', 'playlist-parser', 'lyrics-parser',
  'authorized-audio-sources', 'catalog-retry-policy', 'catalog-origin-safety',
  'downloader-policy-runtime', 'discovery-resume', 'portable-backup',
  'recording-matching-core', 'recording-matcher',
  'simulator-debug', 'simulator-release', 'iphoneos-arm64-release'
];

export function nativeStageErrors({ proposed, current, receipt, qaRecord }) {
  const errors = [];
  if (!SHA.test(proposed ?? '') || !SHA.test(current ?? '') || proposed === current)
    errors.push('Require distinct, full proposed and current candidate SHA values.');
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt) ||
      !['native', 'all'].includes(receipt.mode) ||
      receipt.candidateSha !== proposed || receipt.status !== 'local-checks-passed' ||
      receipt.cleanCheckout !== true || receipt.exitCode !== 0)
    errors.push('A successful SHA-bound native/all local receipt is required.');
  const nativeSteps = Array.isArray(receipt?.steps) ? receipt.steps : [];
  // A successful step cannot cancel out a second failed or duplicated attempt.
  // The integrity check must follow the native build, never precede it.
  const nativeNames = nativeSteps.map(step => step?.name);
  const buildIndex = nativeNames.indexOf('native-local-release');
  const integrityIndex = nativeNames.indexOf('post-native-checkout-integrity');
  if (buildIndex < 0 || integrityIndex <= buildIndex ||
      nativeSteps[buildIndex]?.success !== true ||
      nativeSteps[integrityIndex]?.success !== true)
    errors.push('Native Xcode execution and subsequent post-build Git checkout integrity are required.');
  if (new Set(nativeNames).size !== nativeNames.length ||
      nativeSteps.some(step => !step || typeof step.name !== 'string' ||
        step.success !== true))
    errors.push('Native receipt contains duplicate, malformed or unsuccessful verification steps.');
  const lines = typeof qaRecord === 'string' ? qaRecord : '';
  const fields = new Map();
  for (const line of lines.split(/\r?\n/)) {
    const match = /^- ([^:]+): (.*)$/.exec(line);
    if (!match || !QA_FIELDS.includes(match[1])) continue;
    if (fields.has(match[1])) errors.push('Duplicate native QA field: ' + match[1]);
    fields.set(match[1], match[2].trim());
  }
  for (const name of QA_FIELDS) if (!fields.has(name))
    errors.push('Missing native QA field: ' + name);
  const field = name => fields.get(name);
  if (field('Checked commit') !== proposed || field('Source provenance') !== 'repository HEAD' ||
      field('Uncommitted changes') !== 'no' || field('Mode') !== 'all' ||
      field('Simulator smoke requested') !== 'false' ||
      field('Overall execution') !== 'PASS' || field('Exit status') !== '0' ||
      field('Failure reason') !== 'none' ||
      field('Apple signing / physical iPhone acceptance') !== 'NOT TESTED' ||
      field('GitHub Actions used') !== 'NO')
    errors.push('Native QA record is not a successful full-suite execution at the proposed clean SHA.');
  const observed = (field('Completed checks') ?? '').split(/\s+/).filter(Boolean);
  if (observed.length !== CHECKS.length ||
      observed.some((name, index) => name !== CHECKS[index])) {
    errors.push('Native compile/build checklist differs from the full runner sequence.');
    for (const required of CHECKS) if (!observed.includes(required))
      errors.push('Missing native compile/build step: ' + required);
  }
  return errors;
}

export async function checkNativeStage({ proposed, current, receiptPath, logDir, qaPath, cwd = process.cwd(),
                                        evidenceModule = new URL('./local-evidence.mjs', import.meta.url) }) {
  if (!SHA.test(proposed ?? '') || !SHA.test(current ?? ''))
    return ['Missing or invalid full Git commit SHA.'];
  const { readPersistedReceipt, verifyCheckoutIdentity, verifyLocalReceipt } = await import(evidenceModule.href);
  const errors = verifyCheckoutIdentity(proposed, cwd);
  if (errors.length) return errors;
  try {
    execFileSync('git', ['merge-base', '--is-ancestor', current, proposed],
      { cwd, timeout: 10000, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch { errors.push('Proposed commit is not a descendant of the current draft candidate.'); }
  let receipt, qaRecord;
  try { receipt = readPersistedReceipt(receiptPath); qaRecord = readNativeQaRecord(qaPath); }
  catch (error) { return [...errors, 'Native evidence is unavailable: ' + error.message]; }
  errors.push(...nativeStageErrors({ proposed, current, receipt, qaRecord }));
  errors.push(...verifyLocalReceipt(receipt, { expectedSha: proposed, logDir }));
  return errors;
}

if (process.argv[1] && import.meta.url === new URL('file://' + resolve(process.argv[1])).href) {
  if (process.argv.length !== 7) {
    console.error('Usage: node scripts/verify-native-stage.mjs proposedSHA currentDraftSHA receipt.json logsDir native-QA_RECORD.md');
    process.exitCode = 2;
  } else {
    const [, , proposed, current, receiptPath, logDir, qaPath] = process.argv;
    checkNativeStage({ proposed, current, receiptPath, logDir, qaPath }).then(errors => {
      if (errors.length) { for (const error of errors) console.error('BLOCKED: ' + error); process.exitCode = 1; }
      else console.log('Native staging gate PASS for ' + proposed + '; source staging ONLY, not device or production approval.');
    }).catch(error => { console.error('BLOCKED: ' + error.message); process.exitCode = 1; });
  }
}
