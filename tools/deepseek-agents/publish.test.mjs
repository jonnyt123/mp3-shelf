import test from 'node:test';
import assert from 'node:assert/strict';
import {agentIds,safeBranch,validApproval} from './publish.mjs';

test('five dedicated branches and no main or protected release branch',()=>{
 assert.equal(agentIds.length,5);
 for (const id of agentIds) assert.equal(safeBranch(id),'agent/'+id);
 for (const name of ['main','master','feat/ios-premium-visual-refresh','../../main','mp3-hacker']) {
   assert.throws(()=>safeBranch(name));
 }
});
test('missing approval never permits uploading worker code',()=>{
 assert.equal(validApproval(null,'mp3-ui','a'.repeat(40)),null);
 assert.equal(validApproval({role:'mp3-ui',sha:'a'.repeat(40),diffCheck:'fail',nodeGuardTests:'pass',files:['ios/DESIGN_SYSTEM.md']},'mp3-ui','a'.repeat(40)),false);
});
test('approval is bound to exact role and commit',()=>{
 const a={role:'mp3-ui',sha:'a'.repeat(40),diffCheck:'pass',nodeGuardTests:'pass',files:['ios/DESIGN_SYSTEM.md']};
 assert.equal(validApproval(a,'mp3-ui','a'.repeat(40)),true);
 assert.equal(validApproval(a,'mp3-qa','a'.repeat(40)),false);
 assert.equal(validApproval(a,'mp3-ui','b'.repeat(40)),false);
});
test('approval path traversal fails',()=>{
 for(const bad of ['/etc/passwd','../token.env','ios/../../secret']) {
  assert.equal(validApproval({role:'mp3-ui',sha:'a'.repeat(40),diffCheck:'pass',nodeGuardTests:'pass',files:[bad]},'mp3-ui','a'.repeat(40)),false);
 }
});
