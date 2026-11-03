import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {spawnSync} from "node:child_process";
import path from "node:path";
import {fileURLToPath} from "node:url";

const file=path.join(path.dirname(fileURLToPath(import.meta.url)),"one-click-installer.command");
const script=readFileSync(file,"utf8");

test("Finder launcher passes bash syntax validation",()=>{
  const res=spawnSync("bash",["-n",file],{encoding:"utf8",timeout:10_000});
  assert.equal(res.status,0,res.stderr);
});
test("launcher connects to the trusted repository/branch and never overwrites changes",()=>{
  assert.match(script,/https:\/\/github\.com\/jonnyt123\/mp3-shelf\.git/);
  assert.match(script,/agent\/mp3-deepseek-low-cost-worker/);
  assert.match(script,/git clone --single-branch --branch/);
  assert.match(script,/git -C "\$INSTALL_DIR" pull --ff-only/);
  assert.match(script,/status --porcelain=v1 --untracked-files=all/);
  assert.match(script,/unexpected Git origin/);
  assert.doesNotMatch(script,/git (?:reset --hard|push --force|clean -fd)/);
});
test("all sensitive credentials remain in the existing guarded local installer",()=>{
  assert.match(script,/setup-all\.sh/);
  assert.doesNotMatch(script,/DEEPSEEK_API_KEY\s*=/);
  assert.doesNotMatch(script,/GITHUB_TOKEN\s*=/);
  assert.doesNotMatch(script,/Authorization:\s*Bearer/);
  assert.doesNotMatch(script,/--resume|\/v1\/lease|\/v1\/complete/);
});
test("private coordinator token only reaches the clipboard on user request",()=>{
  const approval=script.indexOf('if [[ "$choice" == "Copy Token & Open Dashboard" ]]');
  const copying=script.indexOf("/usr/bin/pbcopy");
  assert.ok(approval>0&&copying>approval);
  assert.match(script,/INSTALL_FAILED=1/);
  assert.match(script,/osascript/);
});
