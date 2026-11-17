#!/usr/bin/env node
/**
 * LaunchAgent entrypoint: execute the existing exact-SHA native release cycle
 * and atomically publish honest last-run diagnostics. No GitHub Actions.
 */
import { mkdirSync, writeFileSync, renameSync, lstatSync, openSync, closeSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
import { runNativeReleaseCycle } from './native-release-cycle.mjs';
import { writeReadiness } from './release-readiness.mjs';

const SHA = /^[0-9a-f]{40}$/;
export function nativeAgentRunRecord({ startedAt, finishedAt, result, error }) {
  const status = error ? 'FAILED' :
    ['already-staged','staged-draft-only'].includes(result?.integration) ||
    ['already-staged','staged-draft-only'].includes(result?.status)
      ? 'COMPLETED' : 'BLOCKED';
  const candidateSha = result?.candidateSha ?? result?.sha ?? null;
  const categories = ['BLOCKED_AWAITING_NATIVE_OR_HARDWARE_EVIDENCE',
    'INCOMPLETE_OUTPUT_REQUIRES_REVIEW','BLOCKED_UNSAFE_OUTPUT_DESTINATION'];
  const packaging = categories.includes(result?.packaging)
    ? result.packaging : 'NOT_VERIFIED';
  // Arbitrary compiler/CLI errors may contain credentials, paths or user data.
  // Persist only a bounded, fixed category; raw diagnostics remain local.
  const reason = error ? 'NATIVE_CYCLE_FAILED_REVIEW_LOCAL_LOGS' : null;
  return {
    schema: 'mp3shelf-native-agent-run-v1',
    startedAt, finishedAt,
    status,
    candidateSha: SHA.test(candidateSha ?? '') ? candidateSha : null,
    integration: ['already-staged','staged-draft-only'].includes(result?.integration ?? result?.status)
      ? (result?.integration ?? result?.status) : 'NOT_VERIFIED',
    packaging,
    delivery: !error && SHA.test(candidateSha ?? '') &&
      ['already-staged','staged-draft-only'].includes(result?.integration ?? result?.status) &&
      ['DELIVERED_VERIFIED_XCODE_ZIP','ALREADY_DELIVERED'].includes(result?.delivery)
      ? result.delivery : 'NOT_VERIFIED',
    failureReason: reason,
    // Staging metadata is not a cryptographically verified native receipt.
    // The independent native evidence verifier owns the COMPILED verdict.
    xcodeVerification: 'NOT_VERIFIED',
    physicalIPhoneAcceptance: 'REQUIRES_SEPARATE_REAL_DEVICE_REVIEW',
    githubActions: 'NOT_INVOKED'
  };
}
export async function executeNativeAgent({ root=process.cwd(), home=homedir(),
  run=runNativeReleaseCycle, now=()=>new Date() } = {}) {
  // A native build may exceed the hourly interval. A second invocation must
  // never race the first one for Git worktrees, device state or status files.
  // The exclusive lock is deliberately not auto-reclaimed on age alone:
  // a slow Xcode build is not proof that the owner process has died.
  const lockDirectory=join(home,'Library','Logs','MP3Shelf','NativeAgent');
  for(const directory of [join(home,'Library'),join(home,'Library','Logs'),
    join(home,'Library','Logs','MP3Shelf'),lockDirectory]) {
    try {
      const info=lstatSync(directory);
      if(!info.isDirectory()||info.isSymbolicLink())
        throw Error('Native agent status directory was redirected');
    } catch(error) {
      if(error.code!=='ENOENT')throw error;
      mkdirSync(directory,{mode:0o700});
    }
  }
  const lockPath=join(lockDirectory,'native-cycle.lock');
  let lock;
  try { lock=openSync(lockPath,'wx',0o600); }
  catch(error) {
    if(error.code==='EEXIST')throw Error('NATIVE_CYCLE_ALREADY_RUNNING: exclusive lock exists; inspect the active Mac process before removing a stale lock');
    throw error;
  }
  try {
  const startedAt=now().toISOString();
  let result=null, failure=null;
  try { result=await run({repo:resolve(root),home}); }
  catch(error){ failure=error; }
  const record=nativeAgentRunRecord({startedAt,finishedAt:now().toISOString(),result,error:failure});
  const destination=join(home,'Library','Logs','MP3Shelf','NativeAgent');
  try {
    // Refuse symlinked or non-directory parents before writing any status receipt.
    for(const directory of [join(home,'Library'),join(home,'Library','Logs'),join(home,'Library','Logs','MP3Shelf'),destination]) {
      try {
        const info=lstatSync(directory);
        if(!info.isDirectory() || info.isSymbolicLink())
          throw Error('Native agent status directory was redirected');
      } catch(error) {
        if(error.code!=='ENOENT') throw error;
        mkdirSync(directory,{mode:0o700});
      }
    }
    const state=join(destination,'latest-run.json');
    let old=null;
    try {old=lstatSync(state);}catch(e){if(e.code!=='ENOENT')throw e;}
    if(old && (!old.isFile() || old.isSymbolicLink() || old.nlink!==1))
      throw Error('Native agent status destination was redirected');
    const temp=join(destination,'.latest-run-'+randomUUID()+'.tmp');
    writeFileSync(temp,JSON.stringify(record,null,2)+'\n',{flag:'wx',mode:0o600});
    renameSync(temp,state);
  } catch(error) {
    if(failure) throw new AggregateError([failure,error],
      'Native run failed and status receipt was not saved');
    throw error;
  }
  // Update the locally viewable readiness dashboard at every execution,
  // including failed Xcode runs. Its absence is NOT a release authorization.
  try {writeReadiness({home});}
  catch(error){
    console.error('RELEASE_READINESS_UNVERIFIED: inspect private local diagnostics');
  }
  if(failure)throw failure;
  return record;
  } finally {
    // Retain ownership through receipt and dashboard writes, including errors.
    closeSync(lock);
    unlinkSync(lockPath);
  }
}
if(process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
  const [root,...rest]=process.argv.slice(2);
  if(rest.length){console.error('Usage: node scripts/native-agent-run.mjs [REPOSITORY]');process.exitCode=2;}
  else executeNativeAgent({root})
    .then(record=>console.log(JSON.stringify(record,null,2)))
    .catch(error=>{console.error('MP3_SHELF_NATIVE_AGENT_BLOCKED: inspect private local diagnostics');process.exitCode=1;});
}
