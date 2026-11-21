#!/usr/bin/env node
/**
 * Independent read-only review of real iPhone evidence. Automated checks are
 * useful triage, never a substitute for owner-signed hardware acceptance #6.
 */
import { createHash, randomUUID } from 'node:crypto';
import { lstatSync, readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const SHA=/^[0-9a-f]{40}$/;
const HASH=/^[0-9a-f]{64}$/;
const UUID=/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
function safeFile(path,max=16*1024*1024) {
 const s=lstatSync(path);
 if(!s.isFile()||s.isSymbolicLink()||s.nlink!==1||s.size<1||s.size>max)
   throw Error('Unsafe or oversized device evidence file');
 return readFileSync(path);
}
function sha(raw){return createHash('sha256').update(raw).digest('hex');}
export function independentlyReviewDevice({inventory, signedRecord, inventorySHA256, expectedSha, now=Date.now()}={}){
 const checks={};
 const fail=(id,pass,description)=>{checks[id]={status:pass?'PASS':'BLOCKED',description};};
 const validSource=SHA.test(expectedSha??'')&&inventory?.schema==='mp3shelf-physical-inventory-v1'&&
   inventory.candidateSha===expectedSha;
 fail('sourceIdentity',validSource,'Collected physical device data matches the expected source commit.');
 const stamp=Date.parse(inventory?.capturedAt??'');
 fail('recentCapture',Number.isFinite(stamp)&&Number.isFinite(now)&&stamp<=now+300000&&stamp>=now-72*3600000,
   'Physical capture is within 72 hours and is not future dated.');
 fail('deviceIdentity',/^iPhone\d+,\d+$/.test(inventory?.device?.productType??'')&&
   HASH.test(inventory?.device?.identifierSha256??'')&&
   /^\d{1,2}\.\d{1,2}(?:\.\d{1,2})?$/.test(inventory?.device?.osVersion??'')&&
   inventory?.bundleID==='com.jonnyt.mp3shelf','Captured a paired iPhone model and MP3 Shelf bundle.');
 const requested=inventory?.requested,files=inventory?.files;
 const full=Number.isSafeInteger(requested)&&requested>=2&&requested<=20000&&
   inventory.unavailable===0&&inventory.copiedTracks===requested&&
   Array.isArray(files)&&files.length===requested&&
   new Set(files.map(x=>x?.trackID)).size===requested&&
   files.every(x=>UUID.test(x?.trackID??'')&&HASH.test(x?.sha256??'')&&
     Number.isSafeInteger(x.bytes)&&x.bytes>=1024);
 fail('fullPlaylist',full,'Every Spotify playlist entry has a unique locally hashed audio recording.');
 fail('copiedBytes',inventory?.fileByteIntegrity==='HOST_HASHED_FROM_PHYSICAL_IPHONE'&&full,
   'Host SHA-256 of every actual iPhone audio copy is recorded.');
 fail('offlinePlayback',inventory?.offlinePlaybackAfterRestart==='APP_INSTRUMENTED_PHYSICAL_PASS',
   'Physical iPhone DEBUG player clock advanced after an offline app restart.');
 fail('backgroundCallbacks',inventory?.backgroundTransfer==='APP_RECORDED_STAGING_AND_BACKGROUND_WAKE',
   'Genuine background URLSession staging/wake callback events were correlated.');
 // Reject ambiguous QA receipts: duplicate fields could otherwise overwrite a
 // real FAIL with a forged later PASS when converted with Object.fromEntries.
 const entries=typeof signedRecord==='string'?
   [...signedRecord.matchAll(/^- ([\w /-]+): ([^\n\r]+)$/gm)].map(x=>[x[1],x[2].trim()]):[];
 const required=['Result','Mode','Checked commit','Signed app executable SHA256',
   'Signature verification','Device app installation','Process launch request'];
 const fields=Object.fromEntries(entries);
 const unambiguous=typeof signedRecord==='string'&&
   entries.length===new Set(entries.map(([key])=>key)).size&&
   required.every(key=>entries.filter(([name])=>name===key).length===1);
 fail('signedMacBuild',unambiguous&&fields['Result']==='PASS'&&fields['Mode']==='install'&&
   fields['Checked commit']===expectedSha&&HASH.test(fields['Signed app executable SHA256']??'')&&
   fields['Signature verification']==='PASS'&&fields['Device app installation']==='PASS'&&
   fields['Process launch request']==='PASS',
   'Signed local build, code signing and installation request were recorded.');
 const unresolved={
   installedOnDeviceBinary:'NOT_INDEPENDENTLY_HASH_VERIFIED',
   recordingSourceAndPermission:'NOT_INDEPENDENTLY_VERIFIED',
   cellularConsent:'NOT_VERIFIED',
   accessibilityAndFailureHandling:'REQUIRES_MANUAL_HARDWARE_REVIEW',
   hardwareIssue6:'REQUIRES_OWNER_REVIEW_AND_CLOSED_GITHUB_ISSUE'
 };
 const failures=Object.entries(checks).filter(([,value])=>value.status!=='PASS').map(([key])=>key);
 return{schema:'mp3shelf-independent-device-review-v1',sourceSha:validSource?expectedSha:null,
   inventorySHA256:HASH.test(inventorySHA256??'')?inventorySHA256:null,
   result:failures.length?'COLLECTED_EVIDENCE_INCOMPLETE':'EVIDENCE_CHECKS_PASSED_NOT_HARDWARE_APPROVED',
   checks,failures,unresolved,physicalAcceptance:'INCOMPLETE',issue6:'OPEN_UNTIL_INDEPENDENT_REVIEW'};
}
export function writeIndependentDeviceReview({inventoryPath,signedRecordPath,expectedSha,outputDirectory}={}){
 if(!SHA.test(expectedSha??''))throw Error('Exact native checkout source SHA required');
 const inventoryRaw=safeFile(resolve(inventoryPath));
 const signedRaw=safeFile(resolve(signedRecordPath),256*1024);
 const report=independentlyReviewDevice({inventory:JSON.parse(inventoryRaw.toString('utf8')),
   signedRecord:signedRaw.toString('utf8'),inventorySHA256:sha(inventoryRaw),expectedSha});
 const output=resolve(outputDirectory??join(dirname(resolve(inventoryPath)),'reviews'));
 mkdirSync(output,{recursive:true,mode:0o700});
 const target=join(output,'review-'+new Date().toISOString().replace(/[:.]/g,'-')+'-'+randomUUID()+'.json');
 writeFileSync(target,JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});
 return{path:target,report};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 const [inventoryPath,signedRecordPath,expectedSha,outputDirectory,...extra]=process.argv.slice(2);
 if(extra.length||!inventoryPath||!signedRecordPath||!expectedSha){
   console.error('Usage: node scripts/review-iphone-evidence.mjs PHYSICAL_INVENTORY_JSON SIGNED_INSTALL_QA_RECORD SOURCE_SHA [OUTPUT_DIR]');
   process.exitCode=2;
 }else{
   try{const x=writeIndependentDeviceReview({inventoryPath,signedRecordPath,expectedSha,outputDirectory});
     console.log(JSON.stringify({path:x.path,result:x.report.result,failures:x.report.failures,
       physicalAcceptance:x.report.physicalAcceptance},null,2));}
   catch(e){console.error('INDEPENDENT_DEVICE_REVIEW_UNVERIFIED: '+e.message);process.exitCode=1;}
 }
}
