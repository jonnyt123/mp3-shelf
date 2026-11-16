#!/usr/bin/env node
/** Publish ONLY an independently hardware-approved, checksummed native Xcode ZIP. */
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream, lstatSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const REPO = 'jonnyt123/mp3-shelf';
const SHA = /^[0-9a-f]{40}$/;
const HASH = /^[0-9a-f]{64}$/;
const TAG = /^mp3-shelf-ios-[0-9a-f]{40}$/;
const MAX_BYTES = 512 * 1024 * 1024;
const CHECKS = ['Signing / installation', 'Offline playback', 'Background licensed downloads',
  'Failure handling', 'Spotify metadata integration', 'Portable backup interoperability',
  'Accessible responsive UI', 'Policy/source audit', 'Final acceptance'];

export function deliveryManifestErrors({ manifest, sha, archiveName, archiveHash, bytes,
                                         deviceIssue, ownerApproved }) {
  const errors = [];
  const tag = 'mp3-shelf-ios-' + sha;
  if (!SHA.test(sha ?? '') || !TAG.test(tag) ||
      manifest?.schema !== 'mp3shelf-verified-xcode-project-v1' ||
      manifest?.candidateSha !== sha ||
      manifest?.archive !== archiveName ||
      manifest?.sha256 !== archiveHash ||
      !HASH.test(archiveHash ?? '') ||
      !Number.isSafeInteger(bytes) || bytes < 1024 || bytes > MAX_BYTES ||
      manifest?.bytes !== bytes ||
      !SHA.test(manifest?.nativeBaselineSha ?? '') ||
      !HASH.test(manifest?.nativeReceiptSha256 ?? '') ||
      !HASH.test(manifest?.deviceEvidenceSha256 ?? '') ||
      !HASH.test(manifest?.hardwareApprovalSha256 ?? '') ||
      !HASH.test(manifest?.signedAppSHA256 ?? '') ||
      manifest?.hardwareIssue !== 6 || manifest?.hardwareIssueClosed !== true ||
      manifest?.buildType !== 'Xcode project sources, NOT signed IPA' ||
      !Number.isFinite(Date.parse(manifest?.reviewedAt ?? '')))
    errors.push('ZIP and immutable manifest do not describe one verified source/hardware release.');
  if (deviceIssue?.number !== 6 || deviceIssue.state !== 'closed' ||
      typeof deviceIssue.body !== 'string' ||
      CHECKS.some(label => !deviceIssue.body.includes('- [x] **' + label + ':**')) ||
      /- \[ \]/.test(deviceIssue.body))
    errors.push('Physical iPhone acceptance issue #6 has not passed all nine hardware checks.');
  if (ownerApproved !== true)
    errors.push('Missing authenticated owner approval binding source, inventory and signed app.');
  return errors;
}
export function releaseAssetsMatch(release, zipName, zipHash, manifestName, manifestHash) {
  if (!release || !Array.isArray(release.assets) || release.assets.length !== 2)
    return false;
  const expected = new Map([[zipName, zipHash], [manifestName, manifestHash]]);
  return release.assets.every(asset => expected.has(asset.name) &&
    asset.digest === 'sha256:' + expected.get(asset.name) && expected.delete(asset.name)) &&
    expected.size === 0;
}
// Retry an interrupted draft upload without replacing any existing asset.
// A mismatched existing asset is never repaired automatically: it may indicate
// concurrent modification or an approval/release identity problem.
export function missingDraftAssets(release, zipName, zipHash, manifestName, manifestHash) {
  if (!release?.draft || !Array.isArray(release.assets))
    throw Error('Only an existing draft with readable assets may be resumed.');
  const expected = new Map([[zipName, zipHash], [manifestName, manifestHash]]);
  if (expected.size !== 2) throw Error('Verified artifact names must be distinct.');
  const seen = new Set();
  for (const asset of release.assets) {
    if (!expected.has(asset?.name) || seen.has(asset.name) ||
        asset.digest !== 'sha256:' + expected.get(asset.name))
      throw Error('Existing draft contains an unexpected, duplicate or corrupted asset.');
    seen.add(asset.name);
  }
  return [...expected.keys()].filter(name => !seen.has(name));
}
async function sha256(path) {
  const hash = createHash('sha256');
  for await (const bytes of createReadStream(path, { highWaterMark: 64 * 1024 })) hash.update(bytes);
  return hash.digest('hex');
}
function boundedFile(path, max) {
  const info = lstatSync(path);
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 ||
      info.size < 1 || info.size > max) throw Error('Unsafe or oversized verified artifact: ' + basename(path));
  return info.size;
}
function cli(...args) {
  return execFileSync('gh', args, { encoding: 'utf8', timeout: 120000,
    maxBuffer: 2 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}
function ghJSON(path) {
  return JSON.parse(cli('api', '-H', 'Accept: application/vnd.github+json', path));
}
async function ownerApproval(sha, manifest, issue) {
  if (!SHA.test(sha) || issue?.state !== 'closed') return false;
  const marker = 'MP3SHELF_DEVICE_GATE_APPROVED SHA=' + sha +
    ' INVENTORY_SHA256=' + manifest.deviceEvidenceSha256 +
    ' SIGNED_APP_SHA256=' + manifest.signedAppSHA256;
  for (let page = 1; page <= 20; page++) {
    const comments = ghJSON('repos/' + REPO + '/issues/6/comments?per_page=100&page=' + page);
    if (!Array.isArray(comments)) throw Error('GitHub issue comment pagination failed');
    if (comments.some(c => c?.user?.login === 'jonnyt123' &&
      typeof c.body === 'string' && c.body.split(/\r?\n/).some(line => line.trim() === marker))) return true;
    if (comments.length < 100) break;
  }
  return false;
}
function tagPointsToCandidate(tag, sha) {
  const ref = ghJSON('repos/' + REPO + '/git/ref/tags/' + tag);
  // A lightweight tag directly points to the reviewed candidate commit.
  // Refuse annotated/unknown tags rather than trusting release metadata alone.
  return ref?.ref === 'refs/tags/' + tag &&
    ref?.object?.type === 'commit' && ref.object.sha === sha;
}
function checkedRelease(tag) {
  try { return ghJSON('repos/' + REPO + '/releases/tags/' + tag); }
  catch (error) {
    if (String(error.stderr ?? error.message).includes('404')) return null;
    throw error;
  }
}
export async function deliverVerifiedNative({ archive, manifestPath, platform = process.platform } = {}) {
  if (platform !== 'darwin') throw Error('VERIFIED_MAC_REQUIRED: use the approved native Mac runner.');
  if (!archive || !manifestPath) throw Error('Verified archive and manifest paths required.');
  const zip = resolve(archive), metadata = resolve(manifestPath);
  if (dirname(zip) !== dirname(metadata)) throw Error('ZIP and manifest must share a trusted output directory.');
  const size = boundedFile(zip, MAX_BYTES), manifestSize = boundedFile(metadata, 65536);
  const m = JSON.parse(readFileSync(metadata, 'utf8'));
  const sha = m.candidateSha;
  if (!SHA.test(sha ?? '') ||
      basename(zip) !== 'MP3-Shelf-Xcode-' + sha.slice(0, 12) + '.zip' ||
      basename(metadata) !== 'MP3-Shelf-Xcode-' + sha.slice(0, 12) + '.manifest.json')
    throw Error('ZIP names do not identify the approved source SHA.');
  const zipHash = await sha256(zip), manifestHash = await sha256(metadata);
  if (statSync(zip).size !== size || statSync(metadata).size !== manifestSize)
    throw Error('Verified artifacts changed while hashing.');
  const ref = cli('api', 'repos/' + REPO + '/git/ref/heads/feat/ios-consolidated-candidate');
  if (JSON.parse(ref).object?.sha !== sha)
    throw Error('Consolidated native candidate advanced since the signed build.');
  const issue = ghJSON('repos/' + REPO + '/issues/6');
  const approved = await ownerApproval(sha, m, issue);
  const errors = deliveryManifestErrors({ manifest: m, sha, archiveName: basename(zip),
    archiveHash: zipHash, bytes: size, deviceIssue: issue, ownerApproved: approved });
  if (errors.length) throw Error('ZIP_DELIVERY_BLOCKED: ' + errors.join('; '));
  const tag = 'mp3-shelf-ios-' + sha;
  const directZIP = 'https://github.com/' + REPO + '/releases/download/' +
    tag + '/' + basename(zip);
  let current = checkedRelease(tag);
  if (current) {
    if (!tagPointsToCandidate(tag, sha))
      throw Error('Existing published tag does not point to the reviewed source SHA.');
    if (current.tag_name !== tag || current.target_commitish !== sha)
      throw Error('Existing GitHub release does not match the approved source.');
    if (!current.draft) {
      if (!releaseAssetsMatch(current, basename(zip), zipHash, basename(metadata), manifestHash))
        throw Error('Published release assets do not match approved checksums.');
      return { status: 'ALREADY_DELIVERED', sha,
        url: current.html_url, downloadURL: directZIP, sha256: zipHash };
    }
    const missing = missingDraftAssets(current, basename(zip), zipHash,
      basename(metadata), manifestHash);
    if (missing.length) {
      // Never use --clobber: an interrupted delivery can resume, but no
      // existing GitHub-hosted asset may be silently replaced.
      cli('release', 'upload', tag, '--repo', REPO,
        ...missing.map(name => name === basename(zip) ? zip : metadata));
      current = checkedRelease(tag);
    }
  } else {
    // Create a DRAFT first. No public artifact until downloaded assets match.
    cli('release', 'create', tag, '--repo', REPO, '--draft', '--target', sha,
      '--title', 'MP3 Shelf — verified iOS Xcode project ' + sha.slice(0,12),
      '--notes', 'Native build and physical iPhone acceptance: issue #6. Exact source: ' + sha +
        '. This is Xcode source, not a signed IPA.', zip, metadata);
    current = checkedRelease(tag);
  }
  if (!tagPointsToCandidate(tag, sha))
    throw Error('Git tag does not reference the exact approved candidate commit.');
  if (!current || !current.draft || current.tag_name !== tag ||
      current.target_commitish !== sha ||
      !releaseAssetsMatch(current, basename(zip), zipHash, basename(metadata), manifestHash))
    throw Error('Draft GitHub release asset digests are not verified; release was not published.');
  // Recheck latest branch and owner issue before public publication, so a
  // revoked approval or updated candidate cannot authorize a stale release.
  if (!tagPointsToCandidate(tag, sha) ||
      JSON.parse(cli('api','repos/' + REPO + '/git/ref/heads/feat/ios-consolidated-candidate')).object?.sha !== sha ||
      !(await ownerApproval(sha, m, ghJSON('repos/' + REPO + '/issues/6'))))
    throw Error('Release eligibility changed after artifact upload; draft remains private.');
  cli('release', 'edit', tag, '--repo', REPO, '--draft=false');
  const published = checkedRelease(tag);
  if (!published || published.draft ||
      !releaseAssetsMatch(published, basename(zip), zipHash, basename(metadata), manifestHash))
    throw Error('Published release asset integrity or visibility is unverified.');
  return { status: 'DELIVERED_VERIFIED_XCODE_ZIP', sha, url: published.html_url,
    downloadURL: directZIP, sha256: zipHash, manifest: basename(metadata) };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (process.argv.length !== 4) {
    console.error('Usage: node scripts/deliver-verified-native.mjs ARCHIVE_ZIP VERIFIED_MANIFEST_JSON');
    process.exitCode = 2;
  } else {
    deliverVerifiedNative({ archive: process.argv[2], manifestPath: process.argv[3] })
      .then(result => console.log(JSON.stringify(result, null, 2)))
      .catch(error => { console.error('VERIFIED_ZIP_DELIVERY_BLOCKED: ' + error.message); process.exitCode = 1; });
  }
}
