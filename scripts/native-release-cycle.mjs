#!/usr/bin/env node
/** Hourly Mac release cycle: verified draft staging, then hardware-gated ZIP. */
import { existsSync, lstatSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pathToFileURL } from 'node:url';
import { executeNativePreflight } from './mac-native-candidate.mjs';
import { packageNativeXcode } from './package-verified-native.mjs';

const SHA = /^[0-9a-f]{40}$/;
// Check ancestors too: a trusted leaf under redirected Logs is not trusted.
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
  const runs = entries.filter(x => x.isDirectory() && !x.isSymbolicLink())
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
  packageProject = packageNativeXcode, home = homedir() } = {}) {
  const root = resolve(repo ?? join(dirname(fileURLToPath(import.meta.url)), '..'));
  const integration = await preflight({ repo: root, promote: true });
  if (!SHA.test(integration?.sha ?? '')) throw Error('Native staging did not return an exact commit.');
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
  const name = 'MP3-Shelf-Xcode-' + sha.slice(0, 12);
  if (existsSync(join(destination, name + '.zip')) ||
      existsSync(join(destination, name + '.manifest.json')))
    return { candidateSha: sha, integration: integration.status,
      packaging: 'EXISTING_OUTPUT_REQUIRES_HASH_REVIEW' };
  const result = await packageProject({ root, candidateSha: sha,
    nativeEvidence: nativeDir, deviceEvidence: deviceDir,
    outputDirectory: destination });
  return { candidateSha: sha, integration: integration.status,
    packaging: result.status, archive: result.archive, sha256: result.archiveSHA256 };
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
