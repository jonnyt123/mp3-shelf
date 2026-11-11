import { test } from "node:test";
import { strict as assert } from "node:assert";
import { verifyReleaseEvidence } from "./verify-release-evidence.mjs";

const sha = "a".repeat(40);
const check = name => ({ name, sha, status: "passed", conclusion: "success" });
const web = () => ({
  sha, target: "web", checks: ["test", "typecheck", "build"].map(check),
  branchProtectionSatisfied: true, rollbackReady: true
});

test("accepts complete SHA-bound web evidence", () => {
  assert.deepEqual(verifyReleaseEvidence(web(), sha), []);
});
test("rejects stale commit or check evidence", () => {
  const stale = web();
  stale.checks[0].sha = "b".repeat(40);
  assert.match(verifyReleaseEvidence(stale, sha).join(" "), /stale/);
  stale.sha = "b".repeat(40);
  assert.match(verifyReleaseEvidence(stale, sha).join(" "), /Evidence SHA/);
});
test("rejects missing, skipped, pending and failed checks", () => {
  for (const status of ["skipped", "pending", "failed", "cancelled"]) {
    const evidence = web();
    evidence.checks[0].status = status;
    assert.notDeepEqual(verifyReleaseEvidence(evidence, sha), []);
  }
  const evidence = web();
  evidence.checks.pop();
  assert.match(verifyReleaseEvidence(evidence, sha).join(" "), /Missing mandatory check: build/);
});
test("rejects missing reviews or rollback", () => {
  const evidence = web();
  evidence.branchProtectionSatisfied = false;
  evidence.rollbackReady = false;
  assert.equal(verifyReleaseEvidence(evidence, sha).length, 2);
});
test("requires iOS native and real-device acceptance", () => {
  const evidence = { ...web(), target: "ios" };
  assert.match(verifyReleaseEvidence(evidence, sha).join(" "), /device-acceptance/);
  evidence.checks = ["native-build", "native-tests", "device-acceptance"].map(check);
  assert.match(verifyReleaseEvidence(evidence, sha).join(" "), /Physical-device/);
  evidence.deviceAcceptance = true;
  assert.deepEqual(verifyReleaseEvidence(evidence, sha), []);
});
test("rejects duplicate check names and invalid evidence", () => {
  const evidence = web();
  evidence.checks.push(check("test"));
  assert.match(verifyReleaseEvidence(evidence, sha).join(" "), /unique/);
  assert.notDeepEqual(verifyReleaseEvidence(null, sha), []);
});

test("rejects whitespace check aliases and malformed check records without throwing", () => {
  for (const bad of [
    { ...check("test"), name: " test" },
    { ...check("build"), name: "build " },
    { ...check("typecheck"), name: "\\ttypecheck" },
    "test",
    ["test"],
    null,
  ]) {
    const evidence = web();
    evidence.checks[0] = bad;
    const errors = verifyReleaseEvidence(evidence, sha);
    assert.ok(errors.length > 0, "Malformed check must block release");
  }
  const duplicate = web();
  duplicate.checks.push(check("test "));
  assert.match(verifyReleaseEvidence(duplicate, sha).join(" "), /unique, exact/);
});
