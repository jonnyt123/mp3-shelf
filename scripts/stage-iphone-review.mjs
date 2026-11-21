#!/usr/bin/env node
/** Move independently reviewed physical-iPhone evidence into the exact-SHA release gate.
 * Never creates hardware-acceptance.json or posts owner-approval markers.
 */
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { validateSignedInstallRecord } from './run-iphone-playlist-acceptance.mjs';
const SHA=/^[0-9a-f]{40}$/;
const HASH=/^[0-9a-f]{64}$/;
const REVIEW=/^review-[0-9TZ-]+-[0-9a-f-]{36}\.json$/;
const FILENAME='review-handoff.json';
const NAMES=['sourceIdentity','recentCapture','deviceIdentity','fullPlaylist','copiedBytes',
 'offlinePlayback','backgroundCallbacks','signedMacBuild'];
function bounded(path,max=16*1024*1024) {
 const info=lstatSync(path);
 if(!info.isFile()||info.isSymbolicLink()||info.nlink!==1||info.size<1||info.size>max)
  throw Error('Unsafe or missing physical-iPhone review evidence');
 return readFileSync(path);
}
const hash=raw=>createHash('sha256').update(raw).digest('hex');
export function handoffErrors({handoff,review,sha,inventorySHA256,signedAppSHA256,reviewSHA256,
                             now=Date.now()}={}){
 const errors=[];
 if(!SHA.test(sha??'')||handoff?.schema!=='mp3shelf-physical-review-handoff-v1'||
   handoff.candidateSha!==sha||handoff.inventorySHA256!==inventorySHA256||
   !HASH.test(inventorySHA256??'')||
   handoff.signedAppSHA256!==signedAppSHA256||!HASH.test(signedAppSHA256??'')||
   handoff.reviewSHA256!==reviewSHA256||!HASH.test(reviewSHA256??''))
  errors.push('Exact native SHA and original inventory/review/signed-app hashes do not match.');
 if(!REVIEW.test(handoff?.reviewFile??'')||
   handoff?.ownerApproval!=='REQUIRED_NOT_GRANTED'||
   handoff?.physicalAcceptance!=='INCOMPLETE'||
   handoff?.signedBinaryProvenance!=='SIGNED_MAC_BUILD_ONLY'||
   handoff?.signedRecordFile!=='signed-install-QA_RECORD.md'||
   !HASH.test(handoff?.signedRecordSHA256??''))
  errors.push('Expected a bounded, non-approving physical evidence handoff.');
 const t=Date.parse(handoff?.createdAt??'');
 if(!Number.isFinite(t)||!Number.isFinite(now)||t>now+300000||now-t>7*86400000)
  errors.push('Physical evidence handoff is stale or future dated.');
 if(review?.schema!=='mp3shelf-independent-device-review-v1'||
   review.sourceSha!==sha||review.inventorySHA256!==inventorySHA256||
   review.result!=='EVIDENCE_CHECKS_PASSED_NOT_HARDWARE_APPROVED'||
   review.physicalAcceptance!=='INCOMPLETE'||review.issue6!=='OPEN_UNTIL_INDEPENDENT_REVIEW'||
   !Array.isArray(review.failures)||review.failures.length!==0||
   NAMES.some(n=>review.checks?.[n]?.status!=='PASS'))
  errors.push('A matching complete independent iPhone review has not passed.');
 return errors;
}
export function stagePhysicalReview({inventoryPath,reviewPath,signedRecordPath,expectedSha,
                                    now=Date.now()}={}){
 if(!SHA.test(expectedSha??''))throw Error('Expected exact native source commit SHA.');
 const inventory=resolve(inventoryPath),reviewFile=resolve(reviewPath),signed=resolve(signedRecordPath);
 const dir=dirname(inventory),name=basename(reviewFile);
 if(basename(inventory)!=='physical-inventory.json' ||
   basename(dir)!==expectedSha || dirname(reviewFile)!==join(dir,'reviews')||
   !REVIEW.test(name))
  throw Error('Review and physical inventory must reside within the same exact-SHA device directory.');
 const inventoryRaw=bounded(inventory),reviewRaw=bounded(reviewFile,512*1024),
   signedRaw=bounded(signed,256*1024);
 const inventoryData=JSON.parse(inventoryRaw.toString('utf8'));
 const reviewData=JSON.parse(reviewRaw.toString('utf8'));
 if(inventoryData?.schema!=='mp3shelf-physical-inventory-v1'||
   inventoryData.candidateSha!==expectedSha)
  throw Error('Inventory source SHA does not match native candidate.');
 const signedInfo=validateSignedInstallRecord(signedRaw.toString('utf8'),expectedSha);
 const packet={schema:'mp3shelf-physical-review-handoff-v1',
  createdAt:new Date(now).toISOString(),candidateSha:expectedSha,
  reviewFile:name,reviewSHA256:hash(reviewRaw),inventorySHA256:hash(inventoryRaw),
  signedRecordFile:'signed-install-QA_RECORD.md',
  signedRecordSHA256:hash(signedRaw),signedAppSHA256:signedInfo.signedAppSHA256,
  signedBinaryProvenance:'SIGNED_MAC_BUILD_ONLY',
  physicalAcceptance:'INCOMPLETE',ownerApproval:'REQUIRED_NOT_GRANTED'};
 const errs=handoffErrors({handoff:packet,review:reviewData,sha:expectedSha,
  inventorySHA256:packet.inventorySHA256,reviewSHA256:packet.reviewSHA256,
  signedAppSHA256:packet.signedAppSHA256,now});
 if(errs.length)throw Error('PHYSICAL_REVIEW_HANDOFF_BLOCKED: '+errs.join('; '));
 // Preserve the signed Mac build receipt in the same immutable exact-SHA
 // directory: the packager re-hashes and parses the original bytes. This
 // remains Mac signing evidence, not independent installed-phone attestation.
 const qaCopy=join(dir,'signed-install-QA_RECORD.md');
 try {
  const existing=bounded(qaCopy,256*1024);
  if(hash(existing)!==packet.signedRecordSHA256)
   throw Error('Conflicting signed iPhone installation record; review manually.');
 }catch(e){
  if(e.code!=='ENOENT')throw e;
  writeFileSync(qaCopy,signedRaw,{flag:'wx',mode:0o600});
 }
 const dest=join(dir,FILENAME);
 try{
  const existing=bounded(dest,65536);
  const current=JSON.parse(existing.toString('utf8'));
  const keys=['candidateSha','reviewFile','reviewSHA256','inventorySHA256',
   'signedRecordFile','signedRecordSHA256','signedAppSHA256','physicalAcceptance','ownerApproval'];
  if(keys.some(k=>current[k]!==packet[k])||
    handoffErrors({handoff:current,review:reviewData,sha:expectedSha,
     inventorySHA256:packet.inventorySHA256,reviewSHA256:packet.reviewSHA256,
     signedAppSHA256:packet.signedAppSHA256,now}).length)
   throw Error('Existing device handoff differs. Review conflicting proof; never overwrite.');
  return{status:'EXISTING_REVIEW_HANDOFF',path:dest,packet:current};
 }catch(e){if(e.code!=='ENOENT')throw e;}
 writeFileSync(dest,JSON.stringify(packet,null,2)+'\n',{flag:'wx',mode:0o600});
 return{status:'STAGED_OWNER_REVIEW_REQUIRED',path:dest,packet};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 const [inventory,review,signed,sha,...rest]=process.argv.slice(2);
 if(rest.length||!inventory||!review||!signed||!sha){
  console.error('Usage: node scripts/stage-iphone-review.mjs INVENTORY_JSON INDEPENDENT_REVIEW_JSON SIGNED_QA_RECORD EXACT_SHA');
  process.exitCode=2;
 }else try{
  const result=stagePhysicalReview({inventoryPath:inventory,reviewPath:review,
    signedRecordPath:signed,expectedSha:sha});
  console.log(JSON.stringify({status:result.status,sourceSha:sha,
   inventorySHA256:result.packet.inventorySHA256,ownerApproval:result.packet.ownerApproval},null,2));
 }catch(e){console.error('PHYSICAL_REVIEW_HANDOFF_BLOCKED: '+e.message);process.exitCode=1;}
}
