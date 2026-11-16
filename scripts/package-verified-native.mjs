#!/usr/bin/env node
/** Exact-source native Xcode ZIP; ALL native + real-device gates must pass. */
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream, copyFileSync, constants as fsConstants, existsSync,
  lstatSync, mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve, basename } from 'node:path';
import { pathToFileURL } from 'node:url';
import { readPersistedReceipt, verifyLocalReceipt } from './local-evidence.mjs';
import { nativeStageErrors, readNativeQaRecord } from './verify-native-stage.mjs';
import { verifyConsolidatedDraftPR } from './mac-native-candidate.mjs';

const SHA = /^[0-9a-f]{40}$/;
const HASH = /^[0-9a-f]{64}$/;
const CHECKS = ['signingInstallation', 'offlinePlayback', 'backgroundDownloads',
  'failureHandling', 'spotifyMetadata', 'backupInterop', 'accessibility',
  'sourcePolicy', 'finalAcceptance'];
const ISSUE_LABELS = ['Signing / installation', 'Offline playback',
  'Background licensed downloads', 'Failure handling', 'Spotify metadata integration',
  'Portable backup interoperability', 'Accessible responsive UI',
  'Policy/source audit', 'Final acceptance'];
const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
export function hardwareInventoryErrors(inventory, hardware, now = Date.now()) {
  const errors = [];
  const captured = Date.parse(inventory?.capturedAt ?? '');
  const reviewed = Date.parse(hardware?.reviewedAt ?? '');
  if (!Number.isFinite(captured) || !Number.isFinite(reviewed) ||
      captured < now - 7 * 86400000 || captured > now + 300000 ||
      reviewed < captured || reviewed > now + 300000)
    errors.push('Device inventory is stale, future dated or reviewed before it was captured.');
  if (!HASH.test(inventory?.device?.identifierSha256 ?? '') ||
      inventory?.bundleID !== 'com.jonnyt.mp3shelf' ||
      !UUID.test(inventory?.playlistID ?? '') ||
      inventory?.source !== 'Spotify metadata only' ||
      inventory?.device?.productType !== hardware?.deviceModel ||
      inventory?.device?.osVersion !== hardware?.iOSVersion ||
      !/^\d{1,2}\.\d{1,2}(?:\.\d{1,2})?$/.test(inventory?.device?.osVersion ?? ''))
    errors.push('Hardware approval does not identify the exact inventoried app, device and playlist.');
  if (!Number.isSafeInteger(inventory?.requested) || inventory.requested < 2 ||
      inventory.requested > 20000 ||
      !Number.isSafeInteger(inventory?.unavailable) || inventory.unavailable < 0 ||
      inventory.unavailable > inventory.requested ||
      !Number.isSafeInteger(inventory?.copiedTracks) || inventory.copiedTracks < 0 ||
      inventory.copiedTracks + inventory.unavailable !== inventory.requested ||
      !Array.isArray(inventory.files) ||
      inventory.files.some(row => !UUID.test(row?.trackID ?? '')) ||
      new Set(inventory.files.map(row => row.trackID)).size !== inventory.files.length)
    errors.push('Playlist inventory is incomplete, duplicated or inconsistent with source order.');
  return errors;
}

export function nativePackageGate({ sha, base, receipt, qa, inventory, inventoryHash,
  hardware, issue, comments, pr }) {
  const errors = [...nativeStageErrors({ proposed: sha, current: base, receipt, qaRecord: qa })];
  if (!SHA.test(sha ?? '') || !SHA.test(base ?? '') || sha === base)
    errors.push('Full distinct candidate/source baseline SHAs are required.');
  errors.push(...verifyConsolidatedDraftPR(pr, { base: sha }));
  if (inventory?.schema !== 'mp3shelf-physical-inventory-v1' ||
      inventory.candidateSha !== sha || !/^iPhone\d+,\d+$/.test(inventory.device?.productType ?? '') ||
      inventory.offlinePlaybackAfterRestart !== 'APP_INSTRUMENTED_PHYSICAL_PASS' ||
      inventory.backgroundTransfer !== 'APP_RECORDED_STAGING_AND_BACKGROUND_WAKE' ||
      inventory.copiedTracks < 2 || !Number.isSafeInteger(inventory.copiedTracks) ||
      !Array.isArray(inventory.files) ||
      inventory.files.length !== inventory.copiedTracks ||
      inventory.files.some(row => !HASH.test(row?.sha256 ?? '') ||
        !Number.isSafeInteger(row.bytes) || row.bytes < 1024))
    errors.push('Required real-device playback, background callbacks and audio hashes not verified.');
  if (!hardware || hardware.schema !== 'mp3shelf-hardware-acceptance-v1' ||
      hardware.candidateSha !== sha || hardware.installedSourceSha !== sha ||
      !HASH.test(hardware.signedAppSHA256 ?? '') ||
      !HASH.test(inventoryHash ?? '') || hardware.inventorySHA256 !== inventoryHash ||
      hardware.reviewer !== 'jonnyt123' ||
      !Number.isFinite(Date.parse(hardware.reviewedAt ?? '')) ||
      Date.parse(hardware.reviewedAt) > Date.now() + 300000 ||
      Date.now() - Date.parse(hardware.reviewedAt) > 60 * 86400000 ||
      !hardware.deviceModel || !hardware.iOSVersion ||
      CHECKS.some(key => hardware.checks?.[key] !== 'PASS'))
    errors.push('Signed-install and independent hardware QA approval incomplete or wrong SHA.');
  errors.push(...hardwareInventoryErrors(inventory, hardware));
  if (issue?.number !== 6 || issue.state !== 'closed' ||
      typeof issue.body !== 'string' ||
      ISSUE_LABELS.some(label => !issue.body.includes('- [x] **' + label + ':**')) ||
      /- \[ \]/.test(issue.body))
    errors.push('GitHub iPhone acceptance issue #6 is not completely checked and closed.');
  // Approve the *same signed app binary* as the inventory and exact source.
  // The hardware approval file alone is self-asserted; the authenticated owner
  // must explicitly bind its binary digest to the accepted GitHub issue.
  const marker = 'MP3SHELF_DEVICE_GATE_APPROVED SHA=' + sha +
    ' INVENTORY_SHA256=' + inventoryHash +
    ' SIGNED_APP_SHA256=' + hardware?.signedAppSHA256;
  if (!Array.isArray(comments) || !comments.some(c =>
      c?.user?.login === 'jonnyt123' && typeof c.body === 'string' &&
      c.body.split(/\r?\n/).some(line => line.trim() === marker)))
    errors.push('Current exact-SHA hardware acceptance has no owner-issued GitHub approval.');
  return errors;
}
function git(root, ...args) {
  return execFileSync('git', ['-C', root, ...args], {
    encoding: 'utf8', timeout: 90000, maxBuffer: 2 * 1024 * 1024
  }).trim();
}
function boundedJSON(path, maxBytes = 1024 * 1024) {
  const meta = lstatSync(path);
  if (!meta.isFile() || meta.isSymbolicLink() || meta.nlink !== 1 ||
      meta.size < 1 || meta.size > maxBytes)
    throw Error('Missing, oversized or linked verification record: ' + basename(path));
  return JSON.parse(readFileSync(path, 'utf8'));
}
function fingerprint(bytes) { return createHash('sha256').update(bytes).digest('hex'); }
// Validate the destination independently of the hourly orchestrator: the
// packager also has a direct CLI entrypoint. Never follow redirected ancestors.
export function assertSafeArchiveDestination(destination) {
  const target = resolve(destination);
  const root = resolve(homedir());
  if (target === root || !target.startsWith(root + '/'))
    throw Error('Archive destination must be a subdirectory of the current home.');
  let cursor = target;
  while (true) {
    // lstat, not stat: dangling symlinks must also be rejected.
    try {
      const info = lstatSync(cursor);
      if (info.isSymbolicLink() || !info.isDirectory())
        throw Error('Archive destination has a linked or non-directory ancestor.');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (cursor === root) break;
    const parent = resolve(cursor, '..');
    if (parent === cursor) throw Error('Archive destination escaped the home directory.');
    cursor = parent;
  }
  return target;
}
async function shaFile(path) {
  const h = createHash('sha256');
  for await (const data of createReadStream(path, { highWaterMark: 64 * 1024 })) h.update(data);
  return h.digest('hex');
}
async function githubJSON(url) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);
  try {
    const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
    const response = await fetch(url, {
      headers: { Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        ...(token ? { Authorization: 'Bearer ' + token } : {}) },
      signal: controller.signal
    });
    if (!response.ok) throw Error('GitHub release gate read failed (HTTP ' + response.status + ')');
    return response.json();
  } finally { clearTimeout(timeout); }
}
// Approval can be older than GitHub's first 100 comments. Fail closed on
// truncated pagination, malformed pages, or a repository that changes mid-read.
export async function fetchAllIssueComments(url, read = githubJSON, maxPages = 20) {
  const all = [];
  const seenIds = new Set();
  for (let page = 1; page <= maxPages; page++) {
    const separator = url.includes('?') ? '&' : '?';
    const records = await read(url + separator + 'per_page=100&page=' + page);
    if (!Array.isArray(records) || records.length > 100)
      throw Error('Malformed GitHub hardware approval comment page.');
    for (const record of records) {
      if (!Number.isSafeInteger(record?.id) || record.id < 0 ||
          seenIds.has(record.id) || typeof record.body !== 'string' ||
          typeof record.user?.login !== 'string')
        throw Error('Malformed or repeated GitHub hardware approval comment.');
      seenIds.add(record.id);
      all.push(record);
    }
    if (records.length < 100) return all;
  }
  throw Error('Hardware approval comment history exceeds bounded pagination.');
}
export async function packageNativeXcode({ root, candidateSha, nativeEvidence,
  deviceEvidence, outputDirectory } = {}) {
  if (process.platform !== 'darwin') throw Error('MAC_HARDWARE_GATE_REQUIRED');
  const project = resolve(root ?? process.cwd());
  const sha = candidateSha;
  if (!SHA.test(sha ?? '') || git(project, 'rev-parse', '--show-toplevel') !== project ||
      git(project, 'status', '--porcelain', '--untracked-files=all') !== '')
    throw Error('Expected a clean MP3 Shelf repository and an exact candidate SHA.');
  const origin = git(project, 'remote', 'get-url', 'origin');
  if (!/^(?:https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)jonnyt123\/mp3-shelf(?:\.git)?\/?$/.test(origin))
    throw Error('Git remote does not match official MP3 Shelf source.');
  const remote = git(project, 'ls-remote', '--exit-code', 'origin',
    'refs/heads/feat/ios-consolidated-candidate');
  if (remote !== sha + '\trefs/heads/feat/ios-consolidated-candidate')
    throw Error('Draft native candidate changed or is not at verified SHA.');
  // Fetching objects does not modify source files, the candidate branch, or main.
  git(project, 'fetch', '--no-tags', 'origin', 'refs/heads/feat/ios-consolidated-candidate');
  git(project, 'cat-file', '-e', sha + '^{commit}');
  const native = resolve(nativeEvidence);
  const device = resolve(deviceEvidence);
  const baseline = boundedJSON(join(native, 'native-baseline.json'), 4096);
  if (baseline.schema !== 'mp3shelf-native-baseline-v1' ||
      baseline.candidateSha !== sha || baseline.verifiedForDraft !== 29 ||
      !SHA.test(baseline.baseSha ?? '') ||
      git(project, 'merge-base', baseline.baseSha, sha) !== baseline.baseSha)
    throw Error('Native build ancestry was not verified against the exact staged candidate.');
  const receipt = readPersistedReceipt(join(native, 'local-evidence.json'));
  const qa = readNativeQaRecord(join(native, 'native-QA_RECORD.md'));
  const nativeErrors = verifyLocalReceipt(receipt, { expectedSha: sha, logDir: native });
  if (nativeErrors.length) throw Error('Source native log integrity failure: ' + nativeErrors.join('; '));
  const inventoryPath = join(device, 'physical-inventory.json');
  const inventory = boundedJSON(inventoryPath, 2 * 1024 * 1024);
  const inventoryBytes = readFileSync(inventoryPath);
  const inventoryHash = fingerprint(inventoryBytes);
  const hardware = boundedJSON(join(device, 'hardware-acceptance.json'), 32 * 1024);
  const endpoint = 'https://api.github.com/repos/jonnyt123/mp3-shelf';
  const [issue, comments, pr] = await Promise.all([
    githubJSON(endpoint + '/issues/6'),
    fetchAllIssueComments(endpoint + '/issues/6/comments'),
    githubJSON(endpoint + '/pulls/29')
  ]);
  const errors = nativePackageGate({
    sha, base: baseline.baseSha, receipt, qa, inventory,
    inventoryHash, hardware, issue, comments, pr
  });
  if (errors.length) throw Error('NATIVE_ZIP_BLOCKED: ' + errors.join('; '));
  const dest = resolve(outputDirectory ?? join(homedir(), 'Documents', 'MP3Shelf', 'VerifiedReleases'));
  assertSafeArchiveDestination(dest);
  mkdirSync(dest, { recursive: true, mode: 0o700 });
  // Detect a destination swapped while the directory tree was created.
  assertSafeArchiveDestination(dest);
  const prefix = 'MP3-Shelf-Xcode-' + sha.slice(0, 12) + '/';
  const name = 'MP3-Shelf-Xcode-' + sha.slice(0, 12);
  const archive = join(dest, name + '.zip'), manifest = join(dest, name + '.manifest.json');
  if (existsSync(archive) || existsSync(manifest)) throw Error('Verified output already exists; refusing overwrite.');
  const temp = mkdtempSync(join(dest, '.mp3-shelf-archive-'));
  let zipCopied = false;
  try {
    const draftZip = join(temp, 'candidate.zip');
    execFileSync('git', ['-C', project, 'archive', '--format=zip',
      '--prefix=' + prefix, '--output=' + draftZip, sha, 'ios'],
      { timeout: 120000, maxBuffer: 1024 * 1024 });
    execFileSync('unzip', ['-tqq', draftZip], { timeout: 120000, maxBuffer: 1024 * 1024 });
    const files = execFileSync('unzip', ['-Z', '-1', draftZip],
      { encoding: 'utf8', timeout: 120000, maxBuffer: 4 * 1024 * 1024 }).split(/\r?\n/).filter(Boolean);
    // Git archive may emit explicit ZIP directory entries for the prefix and
    // ios/ folder. Accept those directories without allowing path traversal.
    if (files.length < 15 || !files.includes(prefix + 'ios/MP3Shelf.xcodeproj/project.pbxproj') ||
        !files.includes(prefix + 'ios/MP3Shelf/MP3ShelfApp.swift') ||
        files.some(p =>
          !(p === prefix || p === prefix + 'ios/' || p.startsWith(prefix + 'ios/')) ||
          p.includes('../') || p.includes('/.git/') || p.includes('\\')))
      throw Error('Archive is not a complete, safe native Xcode project tree.');
    const meta = { schema: 'mp3shelf-verified-xcode-project-v1',
      candidateSha: sha, nativeBaselineSha: baseline.baseSha,
      archive: name + '.zip', sha256: await shaFile(draftZip),
      bytes: statSync(draftZip).size, trackedPaths: files.length,
      nativeReceiptSha256: await shaFile(join(native, 'local-evidence.json')),
      deviceEvidenceSha256: inventoryHash, hardwareApprovalSha256:
        await shaFile(join(device, 'hardware-acceptance.json')),
      hardwareIssue: 6, hardwareIssueClosed: true,
      reviewedAt: hardware.reviewedAt, buildType: 'Xcode project sources, NOT signed IPA',
      createdAt: new Date().toISOString() };
    const draftManifest = join(temp, 'manifest.json');
    writeFileSync(draftManifest, JSON.stringify(meta, null, 2) + '\n',
      { flag: 'wx', mode: 0o600 });
    // CREATE EXCLUSIVE: never overwrite an old verified archive.
    copyFileSync(draftZip, archive, fsConstants.COPYFILE_EXCL);
    zipCopied = true;
    copyFileSync(draftManifest, manifest, fsConstants.COPYFILE_EXCL);
    return { status: 'PACKAGED_VERIFIED_NATIVE_SOURCE', sha, archive, manifest,
      archiveSHA256: meta.sha256, trackedPaths: files.length };
  } catch (error) {
    if (zipCopied && !existsSync(manifest)) rmSync(archive, { force: true });
    throw error;
  } finally { rmSync(temp, { recursive: true, force: true }); }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [sha, native, device, output, ...rest] = process.argv.slice(2);
  if (!sha || !native || !device || !output || rest.length) {
    console.error('Usage: node scripts/package-verified-native.mjs SHA NATIVE_EVIDENCE_DIR DEVICE_EVIDENCE_DIR OUTPUT_DIR');
    process.exitCode = 2;
  } else {
    packageNativeXcode({ candidateSha: sha, nativeEvidence: native,
      deviceEvidence: device, outputDirectory: output }).then(result =>
      console.log(JSON.stringify(result, null, 2))).catch(error => {
      console.error('NATIVE_ZIP_BLOCKED: ' + error.message);
      process.exitCode = 1;
    });
  }
}
