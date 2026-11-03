import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";
import path from "node:path";
import {firstCycleDecision} from "../cloudflare/mac-client.mjs";

const here=path.dirname(fileURLToPath(import.meta.url));
const command=path.join(here,"start-first-agent.command");
const script=readFileSync(command,"utf8");
function state(overrides={}) {
  return {paused:true,counts:{leased:0},roleStates:[
    {role:"mp3-playback",cycle:0,state:"queued",attempts:0},
    {role:"mp3-sources",cycle:0,state:"queued",attempts:0}
  ],...overrides};
}
const balance={currency:"USD",amount:0.50};

test("one-shot decision accepts only untouched first Playback job and paused coordinator",()=>{
  assert.equal(firstCycleDecision(state(),balance,true),null);
  assert.match(firstCycleDecision(state({paused:false}),balance,true),/Pause/);
  assert.match(firstCycleDecision(state({counts:{leased:1}}),balance,true),/already leased/);
  assert.match(firstCycleDecision(state({roleStates:[{role:"mp3-sources",cycle:0,state:"queued",attempts:0}]}),balance,true),/first Playback/i);
});
test("minimum balance and daily budget fail closed before any model request",()=>{
  assert.match(firstCycleDecision(state(),{currency:"USD",amount:0.24},true),/Insufficient/);
  assert.match(firstCycleDecision(state(),balance,false),/budget exhausted/);
  assert.match(firstCycleDecision(state(),balance,true,0),/Invalid minimum/);
  assert.match(firstCycleDecision(state(),balance,true,Infinity),/Invalid minimum/);
});
test("do not start an already attempted first agent or subsequent cycle",()=>{
  for(const attempt of [{role:"mp3-playback",cycle:0,state:"leased",attempts:1},
    {role:"mp3-playback",cycle:0,state:"queued",attempts:1},
    {role:"mp3-playback",cycle:1,state:"queued",attempts:0}]) {
    assert.notEqual(firstCycleDecision(state({roleStates:[attempt]}),balance,true),null);
  }
});
test("Finder one-shot launcher passes Bash syntax check",()=>{
  const p=spawnSync("bash",["-n",command],{encoding:"utf8",timeout:10_000});
  assert.equal(p.status,0,p.stderr);
});
test("Finder first agent requires visible paid approval and guarded exclusive process",()=>{
  assert.match(script,/--doctor/);
  assert.match(script,/--status/);
  assert.match(script,/Run One Agent/);
  assert.match(script,/MP3_FIRST_CYCLE_EXCLUSIVE=1 node "\$CLIENT" --first-only/);
  assert.match(script,/launchctl bootout/);
  assert.match(script,/PAUSED_BY_US=1/);
  assert.match(script,/node "\$CLIENT" --pause/);
  assert.match(script,/trap exit_handler EXIT/);
  assert.doesNotMatch(script,/git (push|reset --hard)/);
  assert.doesNotMatch(script,/--loop|npm run|xcodebuild/);
});
