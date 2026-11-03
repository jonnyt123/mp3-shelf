import test from "node:test";
import assert from "node:assert/strict";
import {canUnlockFollowups,nextBatchAction,FOLLOWUP_ROLES} from "./qa-gate.mjs";
import {publishProof,validEvidence} from "./mac-publisher.mjs";
const sha="a".repeat(40);
const evidence={role:"mp3-playback",sha,diffCheck:"pass",nodeGuardTests:"pass",
  files:["ios/MP3Shelf/Services/PlaybackController.swift"],webChecks:"not-applicable"};
const pr={number:84,state:"open",draft:true,
  head:{ref:"agent/mp3-playback",sha},base:{ref:"agent/mp3-deepseek-low-cost-worker"}};
const pub=publishProof("mp3-playback",sha,pr,evidence);
const qa={schema:1,role:"mp3-playback",sha,status:"success",
  githubContext:"mp3/mac-xcode",check:"unsigned-simulator-build-and-Swift-regressions"};
function job(role,i,state="queued",commit=null,attempts=0) {
 return {id:i,role,cycle:0,state,attempts,commit_sha:commit};
}
function cloud(opts={}){
 return {paused:true,counts:{leased:0},recent:[
   job("mp3-playback",1,"done",sha,1),
   ...FOLLOWUP_ROLES.map((r,i)=>job(r,i+2))],...opts};
}
test("publisher generates proof only for matching original draft PR and local pass",()=>{
 assert.equal(pub.draft,true);assert.equal(pub.localChecks,"pass");
 assert.equal(pub.prUrl,"https://github.com/jonnyt123/mp3-shelf/pull/84");
 assert.throws(()=>publishProof("mp3-playback",sha,{...pr,draft:false},evidence));
 assert.throws(()=>publishProof("mp3-playback",sha,{...pr,head:{...pr.head,sha:"b".repeat(40)}},evidence));
 assert.throws(()=>publishProof("mp3-playback",sha,{...pr,base:{ref:"main"}},evidence));
 assert.throws(()=>publishProof("mp3-playback",sha,pr,{...evidence,nodeGuardTests:"fail"}));
});
test("QA gate unlocks only when draft PR, local checks and independent Mac QA match",()=>{
 assert.equal(canUnlockFollowups(cloud(),sha,pub,qa).ok,true);
 assert.equal(canUnlockFollowups(cloud(),sha,null,qa).ok,false);
 assert.equal(canUnlockFollowups(cloud(),sha,pub,null).ok,false);
 assert.equal(canUnlockFollowups(cloud(),sha,pub,{...qa,status:"failure"}).ok,false);
 assert.equal(canUnlockFollowups(cloud(),sha,pub,{...qa,sha:"b".repeat(40)}).ok,false);
 assert.equal(canUnlockFollowups(cloud(),sha,{...pub,draft:false},qa).ok,false);
});
test("queue cannot advance if resumed, leased, or first unverified",()=>{
 assert.equal(canUnlockFollowups(cloud({paused:false}),sha,pub,qa).ok,false);
 assert.equal(canUnlockFollowups(cloud({counts:{leased:1}}),sha,pub,qa).ok,false);
 assert.equal(canUnlockFollowups(cloud({recent:cloud().recent.slice(1)}),sha,pub,qa).ok,false);
});
test("follow-up gate refuses already attempted or completed unrelated initial jobs",()=>{
 const c=cloud();
 c.recent[2]={...c.recent[2],attempts:1};
 assert.equal(canUnlockFollowups(c,sha,pub,qa).ok,false);
});
test("follow-up roles are sequential and only initial cycle is eligible",()=>{
 const c=cloud({paused:false});
 assert.deepEqual(FOLLOWUP_ROLES,["mp3-sources","mp3-ui","mp3-qa","mp3-integration"]);
 for(let i=0;i<FOLLOWUP_ROLES.length;i++){
   assert.equal(nextBatchAction(c).role,FOLLOWUP_ROLES[i]);
   c.recent.find(x=>x.role===FOLLOWUP_ROLES[i]).state="done";
   c.recent.find(x=>x.role===FOLLOWUP_ROLES[i]).commit_sha=sha;
   c.recent.push({...c.recent.find(x=>x.role===FOLLOWUP_ROLES[i]),id:20+i,cycle:1,state:"queued",commit_sha:null});
 }
 assert.equal(nextBatchAction(c).action,"complete");
});
test("stale leases, failures and missing reports halt rather than start more paid jobs",()=>{
 assert.equal(nextBatchAction(cloud({paused:false,counts:{leased:1}})).action,"halt");
 const c=cloud({paused:false});c.recent.find(x=>x.role==="mp3-sources").attempts=1;
 assert.equal(nextBatchAction(c).action,"halt");
 c.recent=c.recent.filter(x=>x.role!=="mp3-sources");
 assert.equal(nextBatchAction(c).action,"halt");
});
test("paused coordinator and incomplete first-run receipts do not authorize coding",()=>{
 assert.equal(nextBatchAction(cloud()).action,"wait");
 assert.equal(canUnlockFollowups(cloud(),"invalid",pub,qa).ok,false);
});
