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
export function selectNativeEvidence(root, sha) {
  if (!SHA.test(sha ?? '')) return null;
  const dir = join(root, sha);
  if (!existsSync(dir) || !lstatSync(dir).isDirectory() || lstatSync(dir).isSymbolicLink())
    return null;
  const entries = readdirSync(dir, { withFileTypes: true });
  if (entries.length > 128) return null;
  for (const item of entries.filter(x => x.isDirectory() && !x.isSymbolicLink())
      .sort((a, b) => b.name.localeCompare(a.name))) {
    const path = join(dir, item.name);
    if (['native-baseline.json', 'native-QA_RECORD.md',
      'local-evidence.json', 'native-local-release.log',
      'post-native-checkout-integrity.log'].every(name =>
      existsSync(join(path, name)) && lstatSync(join(path, name)).isFile() &&
      !lstatSync(join(path, name)).isSymbolicLink())) return path;
  }
  return null;
}
export async function runNativeReleaseCycle({ repo, preflight = executeNativePreflight,
  packageProject = packageNativeXcode, home = homedir() } = {}) {
  const root = resolve(repo ?? join(dirname(fileURLToPath(import.meta.url)), '..'));
  const integration = await preflight({ repo: root, promote: true });
  if (!SHA.test(integration?.sha ?? '')) throw Error('Native staging did not return an exact commit.');
  const sha = integration.sha;
  const nativeDir = integration.evidence ||
    selectNativeEvidence(join(home, 'Library', 'Logs', 'MP3Shelf', 'NativePreflight'), sha);
  const deviceDir = join(home, 'Library', 'Logs', 'MP3Shelf', 'DeviceAcceptance', sha);
  if (!nativeDir || !existsSync(join(deviceDir, 'physical-inventory.json')) ||
      !existsSync(join(deviceDir, 'hardware-acceptance.json')))
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
