import test from "node:test";
import assert from "node:assert/strict";
import { roles, safeBranch, validEvidence, ownedFiles, repository, base } from "./mac-publisher.mjs";
const sha = "a".repeat(40);
const approved = { role:"mp3-ui", sha, diffCheck:"pass", nodeGuardTests:"pass",
 files:["ios/MP3Shelf/Views/MainView.swift"] };
test("publishing is limited to five fixed agent branches", () => {
  assert.equal(repository, "jonnyt123/mp3-shelf");
  assert.equal(base, "agent/mp3-deepseek-low-cost-worker");
  assert.equal(roles.length,5);
  for (const role of roles) assert.equal(safeBranch(role), "agent/"+role);
  for(const forbidden of ["main","master","feat/ios-premium-visual-refresh","../../../main","agent/mp3-ui"]) {
    assert.throws(()=>safeBranch(forbidden));
  }
});
test("commit evidence must match role, full SHA, file set and local checks", () => {
  assert.equal(validEvidence(approved,"mp3-ui",sha,approved.files),true);
  assert.equal(validEvidence(approved,"mp3-ui","b".repeat(40),approved.files),false);
  assert.equal(validEvidence(approved,"mp3-qa",sha,approved.files),false);
  assert.equal(validEvidence({...approved,diffCheck:"fail"},"mp3-ui",sha,approved.files),false);
  assert.equal(validEvidence(approved,"mp3-ui",sha,[]),false);
  assert.equal(validEvidence(approved,"mp3-ui",sha,["../secret"]),false);
  assert.equal(validEvidence(approved,"mp3-ui",sha,["ios/MP3Shelf/Views/OtherView.swift"]),false);
});
test("independent file policies deny inappropriate changes",()=>{
  assert.equal(ownedFiles("mp3-ui",approved.files),true);
  assert.equal(ownedFiles("mp3-ui",["ios/MP3Shelf/Views/DownloadManagerView.swift"]),false);
  assert.equal(ownedFiles("mp3-integration",["ios/MP3Shelf.xcodeproj/project.pbxproj"]),true);
  assert.equal(ownedFiles("mp3-playback",["src/lib/backup.ts"]),true);
  assert.equal(ownedFiles("mp3-playback",[".github/workflows/ios-build.yml"]),false);
  assert.equal(ownedFiles("mp3-qa",["ios/Tests/LyricsParserTests.swift"]),true);
});
