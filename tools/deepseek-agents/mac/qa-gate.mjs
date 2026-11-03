// Trusted (read-only) proof gate for the first MP3 Shelf autonomous batch.
// The DeepSeek child cannot edit these files. Both receipts are written by
// separate, root-installed macOS brokers after GitHub accepted the draft PR
// and the independent Mac simulator+Swift test status.
import { lstat, readFile } from "node:fs/promises";
import path from "node:path";

export const GATE_ROOT="/Library/Application Support/MP3ShelfGate";
export const FOLLOWUP_ROLES=Object.freeze(["mp3-sources","mp3-ui","mp3-qa","mp3-integration"]);
const SHA=/^[0-9a-f]{40}$/;

export function canUnlockFollowups(cloud, firstSha, publication, qa) {
  if(!SHA.test(firstSha||"") || !cloud?.paused || Number(cloud.counts?.leased||0)>0)
    return {ok:false,reason:"Awaiting safely paused Cloudflare queue"};
  const first=(cloud.recent||[]).find(x=>x.role==="mp3-playback"&&Number(x.cycle)===0);
  if(!first || first.state!=="done" || first.commit_sha!==firstSha)
    return {ok:false,reason:"First Playback cycle has not recorded its validated commit"};
  if(!publication || publication.schema!==1 || publication.role!=="mp3-playback" ||
     publication.sha!==firstSha || publication.draft!==true ||
     publication.localChecks!=="pass" ||
     !/^https:\/\/github\.com\/jonnyt123\/mp3-shelf\/pull\/[0-9]+$/.test(publication.prUrl||""))
    return {ok:false,reason:"Awaiting root-verified matching GitHub draft PR"};
  if(!qa || qa.schema!==1 || qa.role!=="mp3-playback" ||
     qa.sha!==firstSha || qa.status!=="success" ||
     qa.githubContext!=="mp3/mac-xcode" ||
     qa.check!=="unsigned-simulator-build-and-Swift-regressions")
    return {ok:false,reason:"Awaiting successful independent Mac simulator/Swift tests"};
  for(const role of FOLLOWUP_ROLES){
    const job=(cloud.recent||[]).find(x=>x.role===role && Number(x.cycle)===0);
    if(!job || job.state!=="queued" || Number(job.attempts)!==0)
      return {ok:false,reason:"Follow-up batch is not pristine: "+role};
  }
  return {ok:true,reason:"Draft PR and independent Mac QA match the Playback SHA"};
}

export function nextBatchAction(cloud) {
  // The cloud creates cycle-1 jobs on success; NEVER claim them in this batch.
  if (!cloud || cloud.paused) return {action:"wait",reason:"Queue paused"};
  if(Number(cloud.counts?.leased||0)>0)
    return {action:"halt",reason:"An existing lease needs inspection before further paid calls"};
  for(const role of FOLLOWUP_ROLES) {
    const j=(cloud.recent||[]).find(x=>x.role===role && Number(x.cycle)===0);
    if(!j) return {action:"halt",reason:"Missing original batch evidence for "+role};
    if(j.state==="done" && SHA.test(j.commit_sha||"")) continue;
    if(j.state==="queued" && Number(j.attempts)===0)
      return {action:"run",role,reason:"Next verified initial-cycle role"};
    return {action:"halt",reason:"Unsuccessful or previously attempted batch job: "+role};
  }
  return {action:"complete",reason:"All four initial follow-up roles reported verified commits"};
}

async function rootOwnedRead(name) {
  const dir=await lstat(GATE_ROOT);
  if(!dir.isDirectory() || dir.isSymbolicLink() || dir.uid!==0 || (dir.mode&0o022)!==0)
    throw Error("Unsafe root-owned gate directory");
  const target=path.join(GATE_ROOT,name);
  let st;
  try {st=await lstat(target);} catch(e) {if(e.code==="ENOENT")return null;throw e;}
  if(!st.isFile() || st.isSymbolicLink() || st.uid!==0 || (st.mode&0o022)!==0 ||
     st.size>8192) throw Error("Untrusted root gate receipt "+name);
  return JSON.parse(await readFile(target,"utf8"));
}
export async function readFirstGateProofs() {
  try {
    const [publication,qa]=await Promise.all([
      rootOwnedRead("published-mp3-playback.json"),
      rootOwnedRead("qa-mp3-playback.json")
    ]);
    return {publication,qa};
  } catch(e) {
    if(e.code==="ENOENT")return {publication:null,qa:null};
    throw e;
  }
}
