import test from "node:test";
import assert from "node:assert/strict";
import { classifyFirstAgent } from "./verify-first-agent.mjs";
const now=Date.parse("2026-10-31T22:00:00Z");
function data(job, props={}) {
  return {paused:false,mac:{lastSeen:now-1000,stage:"idle"},recent:job?[{role:"mp3-playback",cycle:0,state:"queued",attempts:0,...job}]:[],...props};
}
test("unconnected Mac does not imply a coding attempt",()=>{
 const r=classifyFirstAgent(data({state:"queued"},{mac:{lastSeen:null,stage:"offline"}}),now);
 assert.equal(r.code,"mac-not-connected");
});
test("paused Mac and unseeded roles are reported separately",()=>{
 assert.equal(classifyFirstAgent(data(null),now).code,"not-seeded");
 assert.equal(classifyFirstAgent(data({state:"queued"},{paused:true}),now).code,"queue-paused");
});
test("active lease means coding may be underway, not completed",()=>{
 assert.equal(classifyFirstAgent(data({state:"leased",attempts:1}),now).code,"running");
});
test("first code commit requires SHA and completed state",()=>{
 const sha="a".repeat(40);
 assert.equal(classifyFirstAgent(data({state:"done",commit_sha:sha}),now).sha,sha);
 assert.notEqual(classifyFirstAgent(data({state:"queued",commit_sha:sha}),now).code,"committed");
 assert.equal(classifyFirstAgent(data({state:"done",commit_sha:"garbage"}),now).code,"finished-without-commit");
});
test("recorded completion stays verified even when Mac goes offline",()=>{
 const sha="b".repeat(40);
 assert.equal(classifyFirstAgent(data({state:"done",commit_sha:sha},{mac:{lastSeen:null}}),now).code,"committed");
});
test("blocked and retry states have distinct explanations",()=>{
 assert.equal(classifyFirstAgent(data({state:"blocked",attempts:2}),now).code,"blocked");
 assert.equal(classifyFirstAgent(data({state:"queued",attempts:1}),now).code,"retry-queued");
});
