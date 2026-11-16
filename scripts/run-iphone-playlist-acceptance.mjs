#!/usr/bin/env node
/** Guided physical iPhone playlist run: signed install -> QA arm -> genuine offline restart -> read-only evidence.
 * This cannot switch iPhone radios or approve issue #6 for the user.
 */
import { spawnSync, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { pathToFileURL } from 'node:url';
import { runIPhonePhase } from './iphone-qa-session.mjs';
const SHA = /^[a-f0-9]{40}$/;
const UUID = /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i;
const DEVICE = /^[A-Za-z0-9-]{8,120}$/;
const BUNDLE = 'com.jonnyt.mp3shelf';
const HASH = /^[a-f0-9]{64}$/;

export function validateSignedInstallRecord(record, sha) {
  if (!SHA.test(sha ?? '') || typeof record !== 'string') throw Error('Missing signed app build evidence');
  const fields = Object.fromEntries([...record.matchAll(/^- ([\w /-]+): (.+)$/gm)]
    .map(([,key,value])=>[key,value.trim()]));
  const hash = fields['Signed app executable SHA256'];
  if (fields.Result !== 'PASS' || fields.Mode !== 'install' ||
      fields['Checked commit'] !== sha || !HASH.test(hash ?? '') ||
      fields['Signed development build'] !== 'PASS' ||
      fields['Signature verification'] !== 'PASS' ||
      fields['Device app installation'] !== 'PASS' ||
      fields['Process launch request'] !== 'PASS')
    throw Error('Signed install was not fully verified at the exact source commit');
  return { sha, signedAppSHA256: hash };
}

export function completedOfflineStatus(data) {
  if (data?.schema !== 'mp3shelf-physical-offline-v1') return 'WAITING';
  if (data.status === 'OFFLINE_PLAYBACK_PASS') return 'PASS';
  if (data.status === 'FAIL' && typeof data.error === 'string' && data.error.length)
    return 'FAILED';
  return 'WAITING';
}

function git(root, ...args) {
  return execFileSync('git', ['-C', root, ...args], { encoding:'utf8', timeout: 10000,
    stdio:['ignore','pipe','pipe'] }).trim();
}
function signedInstall(root, deviceID, expectedSha) {
  if (!process.env.MP3SHELF_TEAM_ID ||
      !/^[A-Za-z0-9]{10}$/.test(process.env.MP3SHELF_TEAM_ID))
    throw Error('Set a valid MP3SHELF_TEAM_ID for the signed physical-iPhone build.');
  const installed = spawnSync('bash', ['ios/scripts/run-on-iphone.sh', deviceID],
    { cwd: root, stdio: 'inherit', timeout: 40 * 60 * 1000 });
  if (installed.error || installed.status !== 0)
    throw Error('Signed build, installation or device launch did not pass.');
  const record = readFileSync(join(root, 'ios/build/iphone-device/QA_RECORD.md'), 'utf8');
  return validateSignedInstallRecord(record, expectedSha);
}
function copyOfflineProof(deviceID) {
  const root = mkdtempSync(join(tmpdir(), 'mp3shelf-offline-poll-'));
  try {
    const output = join(root, 'offline.json');
    const result = spawnSync('xcrun', [
      'devicectl','device','copy','from','--device',deviceID,
      '--domain-type','appDataContainer','--domain-identifier',BUNDLE,
      '--source','Documents/MP3ShelfPhysicalOfflineQA.json',
      '--destination',output
    ], { timeout:30000,stdio:'ignore' });
    if (result.status !== 0) return 'WAITING';
    const doc = readFileSync(output, 'utf8');
    if (doc.length > 256 * 1024) return 'FAILED';
    return completedOfflineStatus(JSON.parse(doc));
  } catch { return 'WAITING'; }
  finally { rmSync(root,{recursive:true,force:true}); }
}
async function confirmOfflinePrompt() {
  if (!process.stdin.isTTY) throw Error('An interactive Mac session is required to physically disable iPhone networking.');
  const ui = createInterface({ input: process.stdin, output: process.stdout });
  try {
    await ui.question('Turn on iPhone Airplane Mode and turn OFF Wi-Fi (including Control Center Wi-Fi). Press Return when offline: ');
  } finally { ui.close(); }
}
const delay = ms => new Promise(resolvePromise => setTimeout(resolvePromise,ms));

/** Hook parameters support isolated deterministic tests, not a production evidence override. */
export async function runCompleteIPhoneJourney({
  deviceID, playlistID, sha, cwd=process.cwd(), platform=process.platform,
  install=signedInstall, phase=runIPhonePhase, offlinePrompt=confirmOfflinePrompt,
  offlineStatus=copyOfflineProof, sleep=delay, maxChecks=180
}={}) {
  if (platform !== 'darwin') throw Error('REAL_IPHONE_REQUIRED: Mac, signed app and physical iPhone needed');
  if (!DEVICE.test(deviceID ?? '') || !UUID.test(playlistID ?? '') || !SHA.test(sha ?? ''))
    throw Error('Device, playlist UUID and full candidate SHA are required');
  const root = resolve(cwd);
  if (git(root,'rev-parse','HEAD') !== sha ||
      git(root,'status','--porcelain','--untracked-files=all') !== '')
    throw Error('Refusing to test a dirty or stale native source checkout');
  const signed = await install(root,deviceID,sha);
  if (signed?.sha !== sha || !HASH.test(signed?.signedAppSHA256 ?? ''))
    throw Error('Signed install did not confirm exact source and binary digest');

  await phase({phase:'arm',deviceID,bundleID:BUNDLE,playlistID,sha,cwd:root,platform});
  await offlinePrompt();
  await phase({phase:'offline',deviceID,bundleID:BUNDLE,playlistID,sha,cwd:root,platform});
  let observed = 'WAITING';
  for (let i=0;i<maxChecks;i++) {
    observed=await offlineStatus(deviceID);
    if (observed==='PASS'||observed==='FAILED') break;
    await sleep(5000);
  }
  if (observed!=='PASS') throw Error('Physical offline playback was not verified by the app: '+observed);
  const inventory=await phase({phase:'collect',deviceID,bundleID:BUNDLE,playlistID,sha,cwd:root,platform});
  if (inventory?.offlinePlayback!=='APP_INSTRUMENTED_PHYSICAL_PASS' ||
      inventory?.physicalAcceptance!=='INCOMPLETE')
    throw Error('Host-collected iPhone playback receipt did not corroborate on-device results');
  return {
    status: inventory.backgroundTransfer==='APP_RECORDED_STAGING_AND_BACKGROUND_WAKE'
      ? 'OFFLINE_AND_CALLBACK_EVIDENCE_COLLECTED_NOT_APPROVED'
      : 'OFFLINE_EVIDENCE_COLLECTED_BACKGROUND_UNVERIFIED',
    sha, signedAppSHA256: signed.signedAppSHA256,
    evidencePath: inventory.output,
    offlinePlayback: inventory.offlinePlayback,
    backgroundTransfer: inventory.backgroundTransfer,
    physicalAcceptance:'INCOMPLETE',
    issue6:'OPEN_UNTIL_INDEPENDENT_REVIEW'
  };
}
if(process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
  const [deviceID,playlistID,sha,...rest]=process.argv.slice(2);
  if(rest.length || !deviceID || !playlistID || !sha){
    console.error('Usage: node scripts/run-iphone-playlist-acceptance.mjs DEVICE_UDID LOCAL_SPOTIFY_PLAYLIST_UUID EXACT_GIT_SHA');
    process.exitCode=2;
  } else runCompleteIPhoneJourney({deviceID,playlistID,sha})
    .then(report=>console.log(JSON.stringify(report,null,2)))
    .catch(error=>{console.error('PHYSICAL_IPHONE_ACCEPTANCE_BLOCKED: '+error.message);process.exitCode=1});
}
