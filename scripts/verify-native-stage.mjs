#!/usr/bin/env node
/** Blocks draft #29 staging unless the proposed tree passed full native Xcode verification. */
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const SHA = /^[0-9a-f]{40}$/;
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
  if (!nativeSteps.some(s => s?.name === 'native-local-release' && s.success === true) ||
      !nativeSteps.some(s => s?.name === 'post-native-checkout-integrity' && s.success === true))
    errors.push('Native Xcode execution and post-build Git checkout integrity are required.');
  const lines = typeof qaRecord === 'string' ? qaRecord : '';
  const field = name => lines.match(new RegExp('^- ' + name + ': (.+)$', 'm'))?.[1]?.trim();
  if (field('Checked commit') !== proposed || field('Source provenance') !== 'repository HEAD' ||
      field('Uncommitted changes') !== 'no' || field('Mode') !== 'all' ||
      field('Overall execution') !== 'PASS' || field('Exit status') !== '0')
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
  try { receipt = readPersistedReceipt(receiptPath); qaRecord = readFileSync(qaPath, 'utf8'); }
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
