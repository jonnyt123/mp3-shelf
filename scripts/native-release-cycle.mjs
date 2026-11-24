#!/usr/bin/env node
/** Hourly Mac release cycle: verified draft staging, then hardware-gated ZIP. */
import { existsSync, lstatSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pathToFileURL } from 'node:url';
import { executeNativePreflight } from './mac-native-candidate.mjs';
import { packageNativeXcode } from './package-verified-native.mjs';
import { deliverVerifiedNative } from './deliver-verified-native.mjs';

const SHA = /^[0-9a-f]{40}$/;
// Check ancestors too: a trusted leaf under redirected Logs is not trusted.
function safeExistingOutputAncestors(path, boundary) {
  const stop = resolve(boundary);
  let current = resolve(path);
  if (current !== stop && !current.startsWith(stop + '/')) return false;
  while (true) {
    // existsSync follows symlinks and returns false for dangling links.
    // lstat must inspect the directory entry itself before creating output.
    try {
      const stat = lstatSync(current);
      if (!stat.isDirectory() || stat.isSymbolicLink()) return false;
    } catch (error) {
      if (error.code !== 'ENOENT') return false;
    }
    if (current === stop) return true;
    const parent = dirname(current);
    if (parent === current) return false;
    current = parent;
  }
}
function safeDirectoryChain(path, boundary = path) {
  let current = resolve(path);
  const stop = resolve(boundary);
  if (current !== stop && !current.startsWith(stop + '/')) return false;
  while (true) {
    if (!existsSync(current)) return false;
    const stat = lstatSync(current);
    if (!stat.isDirectory() || stat.isSymbolicLink()) return false;
    if (current === stop) return true;
    const parent = dirname(current);
    if (parent === current) return false;
    current = parent;
  }
}
export function selectNativeEvidence(root, sha) {
  if (!SHA.test(sha ?? '')) return null;
  if (!safeDirectoryChain(root)) return null;
  const dir = join(root, sha);
  if (!safeDirectoryChain(dir, root))
    return null;
  const entries = readdirSync(dir, { withFileTypes: true });
  if (entries.length > 128) return null;
  // The newest run is authoritative. Never fall back to an older successful
  // receipt when a later run failed, is incomplete, or has redirected files.
  const runs = entries.filter(x => x.isDirectory() || x.isSymbolicLink())
    .sort((a, b) => b.name.localeCompare(a.name));
  if (runs.length === 0) return null;
  const path = join(dir, runs[0].name);
  if (!safeDirectoryChain(path, root)) return null;
  return ['native-baseline.json', 'native-QA_RECORD.md',
    'local-evidence.json', 'native-local-release.log',
    'post-native-checkout-integrity.log'].every(name => {
    const file = join(path, name);
    if (!existsSync(file)) return false;
    const stat = lstatSync(file);
    return stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1;
  }) ? path : null;
}
export async function runNativeReleaseCycle({ repo, preflight = executeNativePreflight,
  packageProject = packageNativeXcode, deliverArchive = deliverVerifiedNative,
  home = homedir() } = {}) {
  const root = resolve(repo ?? join(dirname(fileURLToPath(import.meta.url)), '..'));
  const integration = await preflight({ repo: root, promote: true });
  if (!SHA.test(integration?.sha ?? '')) throw Error('Native staging did not return an exact commit.');
  // Reject contradictory identities before inspecting or publishing artifacts.
  // A valid-looking staged SHA does not authorize packaging another source.
  if (integration.candidateSha != null && integration.candidateSha !== integration.sha)
    throw Error('Native preflight source identity disagrees with staged draft SHA.');
  if (integration.proposedSha != null && integration.proposedSha !== integration.sha)
    throw Error('Native preflight proposed source differs from staged draft SHA.');
  if (!['already-staged', 'staged-draft-only'].includes(integration.status))
    throw Error('Native preflight did not confirm staging to draft #29.');
  const sha = integration.sha;
  const evidenceRoot = join(home, 'Library', 'Logs', 'MP3Shelf', 'NativePreflight');
  // Never accept a caller-supplied evidence directory outside the exact-SHA
  // preflight tree; this also prevents following a symlinked SHA directory.
  const shaRoot = join(evidenceRoot, sha);
  const candidateEvidence = integration.evidence ? resolve(integration.evidence) : null;
  if (candidateEvidence && (dirname(candidateEvidence) !== shaRoot ||
      !safeDirectoryChain(shaRoot, home)))
    throw Error('Native evidence path is not inside the exact candidate SHA directory.');
  const selectedEvidence = safeDirectoryChain(evidenceRoot, home) ?
    selectNativeEvidence(evidenceRoot, sha) : null;
  // Never substitute an older complete receipt for the selected latest receipt.
  const nativeDir = candidateEvidence || selectedEvidence;
  const deviceDir = join(home, 'Library', 'Logs', 'MP3Shelf', 'DeviceAcceptance', sha);
  const deviceFiles = ['physical-inventory.json', 'hardware-acceptance.json'];
  const deviceSafe = safeDirectoryChain(deviceDir, home) &&
    deviceFiles.every(name => {
      const path = join(deviceDir, name);
      if (!existsSync(path)) return false;
      const meta = lstatSync(path);
      return meta.isFile() && !meta.isSymbolicLink() && meta.nlink === 1;
    });
  const nativeSafe = nativeDir && safeDirectoryChain(nativeDir, home) &&
    nativeDir === selectedEvidence &&
    ['native-baseline.json', 'native-QA_RECORD.md', 'local-evidence.json',
      'native-local-release.log', 'post-native-checkout-integrity.log'].every(name => {
      const file = join(nativeDir, name);
      return existsSync(file) && lstatSync(file).isFile() &&
        !lstatSync(file).isSymbolicLink() && lstatSync(file).nlink === 1;
    });
  if (!nativeSafe || !deviceSafe)
    return { candidateSha: sha, integration: integration.status,
      packaging: 'BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE' };
  const destination = join(home, 'Documents', 'MP3Shelf', 'VerifiedReleases');
  // A redirected Documents/VerifiedReleases path can send an otherwise
  // correctly gated archive outside the reviewed destination. Check every
  // existing ancestor before the packager creates any directories.
  if (!safeDirectoryChain(home) ||
      !safeExistingOutputAncestors(destination, home))
    return { candidateSha: sha, integration: integration.status,
      packaging: 'BLOCKED_UNSAFE_OUTPUT_DESTINATION' };
  const name = 'MP3-Shelf-Xcode-' + sha.slice(0, 12);
  const zip = join(destination, name + '.zip');
  const manifest = join(destination, name + '.manifest.json');
  const hasZip = existsSync(zip), hasManifest = existsSync(manifest);
  // Existing output is untrusted until checked: never hand a redirected,
  // hard-linked or non-regular archive to the GitHub delivery process.
  // lstat also detects dangling symlinks that existsSync would miss.
  const safeOutputFile = path => {
    try {
      const stat = lstatSync(path);
      return stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1;
    } catch (error) { return error.code === 'ENOENT' ? null : false; }
  };
  const zipState = safeOutputFile(zip), manifestState = safeOutputFile(manifest);
  if (zipState === false || manifestState === false ||
      (zipState === true) !== (manifestState === true))
    return { candidateSha: sha, integration: integration.status,
      packaging: 'INCOMPLETE_OUTPUT_REQUIRES_REVIEW' };
  // A correctly packaged archive may outlive a transient GitHub outage.
  // Re-verify the already-written ZIP+manifest and hardware authorization
  // rather than silently overwriting it or repeatedly creating archives.
  if (hasZip) {
    const delivery = await deliverArchive({ archive: zip, manifestPath: manifest });
    if (!['DELIVERED_VERIFIED_XCODE_ZIP', 'ALREADY_DELIVERED'].includes(delivery.status) ||
        delivery.sha !== sha || !/^[0-9a-f]{64}$/.test(delivery.sha256 ?? ''))
      throw Error('Existing archive delivery did not verify exact source/hash.');
    return { candidateSha: sha, integration: integration.status,
      packaging: 'EXISTING_VERIFIED_ARCHIVE', delivery: delivery.status,
      archive: zip, sha256: delivery.sha256, downloadURL: delivery.downloadURL ?? delivery.url };
  }
  const result = await packageProject({ root, candidateSha: sha,
    nativeEvidence: nativeDir, deviceEvidence: deviceDir,
    outputDirectory: destination });
  if (result.status !== 'PACKAGED_VERIFIED_NATIVE_SOURCE' ||
      result.sha !== sha || !/^[0-9a-f]{64}$/.test(result.archiveSHA256 ?? '') ||
      result.archive !== zip || result.manifest !== manifest)
    throw Error('Packager did not confirm exact-SHA verified local ZIP and manifest.');
  // Do not call delivery on a partial or unverified native package.
  const delivery = await deliverArchive({ archive: zip, manifestPath: manifest });
  if (!['DELIVERED_VERIFIED_XCODE_ZIP', 'ALREADY_DELIVERED'].includes(delivery.status) ||
      delivery.sha !== sha || delivery.sha256 !== result.archiveSHA256)
    throw Error('GitHub delivery did not confirm matching verified ZIP hash.');
  return { candidateSha: sha, integration: integration.status,
    packaging: result.status, delivery: delivery.status,
    archive: zip, sha256: delivery.sha256, downloadURL: delivery.downloadURL ?? delivery.url };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  if (args.length > 1 || (args[0] && args[0].startsWith('--'))) {
    console.error('Usage: node scripts/native-release-cycle.mjs [LOCAL_REPO_ROOT]');
    process.exitCode = 2;
  } else {
    runNativeReleaseCycle({ repo: args[0] }).then(result =>
      console.log(JSON.stringify(result, null, 2))).catch(error => {
      console.error('NATIVE_RELEASE_BLOCKED: ' + error.message);
      process.exitCode = 1;
    });
  }
}
