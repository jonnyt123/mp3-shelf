import { test } from "node:test";
import { strict as assert } from "node:assert";
import { verifyReleaseEvidence } from "./verify-release-evidence.mjs";

const sha = "a".repeat(40);
const check = name => ({ name, sha, status: "passed", conclusion: "success", exitCode: 0, stepsExecuted: 1 });
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

test("rejects zero-step, cancelled, absent or nonzero-exit execution evidence", () => {
  for (const mutation of [
    { stepsExecuted: 0 },
    { stepsExecuted: -1 },
    { stepsExecuted: "1" },
    { stepsExecuted: 1.5 },
    { stepsExecuted: Number.MAX_SAFE_INTEGER + 1 },
    { stepsExecuted: undefined },
    { exitCode: 1 },
    { exitCode: null },
    { exitCode: "0" },
    { exitCode: undefined },
  ]) {
    const evidence = web();
    Object.assign(evidence.checks[0], mutation);
    assert.match(verifyReleaseEvidence(evidence, sha).join(" "), /nonempty execution evidence/);
  }
});

test("rejects missing execution evidence on every required target check", () => {
  for (const target of ["web", "ios"]) {
    const evidence = target === "web" ? web() : {
      ...web(), target: "ios", deviceAcceptance: true,
      checks: ["native-build", "native-tests", "device-acceptance"].map(check)
    };
    for (let index = 0; index < evidence.checks.length; index++) {
      const incomplete = structuredClone(evidence);
      delete incomplete.checks[index].stepsExecuted;
      assert.notDeepEqual(verifyReleaseEvidence(incomplete, sha), []);
    }
  }
});

test("CLI accepts valid bounded evidence and rejects unsafe persisted input", async () => {
  const { mkdtempSync, writeFileSync, symlinkSync, linkSync, truncateSync, rmSync, mkdirSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { spawnSync } = await import("node:child_process");
  const { fileURLToPath } = await import("node:url");
  const dir = mkdtempSync(join(tmpdir(), "mp3-release-gate-"));
  const script = fileURLToPath(new URL("./verify-release-evidence.mjs", import.meta.url));
  const invoke = path => spawnSync(process.execPath, [script, path, sha], {
    encoding: "utf8", timeout: 10000
  });
  try {
    const valid = join(dir, "evidence.json");
    writeFileSync(valid, JSON.stringify(web()));
    const good = invoke(valid);
    assert.equal(good.status, 0, good.stderr);
    assert.match(good.stdout, /Evidence gate PASS/);

    const symlink = join(dir, "symlink.json");
    symlinkSync(valid, symlink);
    const linked = invoke(symlink);
    assert.equal(linked.status, 1);
    assert.match(linked.stderr, /bounded, regular, unlinked/);

    const hardlink = join(dir, "hardlink.json");
    linkSync(valid, hardlink);
    assert.equal(invoke(valid).status, 1);
    assert.equal(invoke(hardlink).status, 1);

    const huge = join(dir, "huge.json");
    writeFileSync(huge, "{}");
    truncateSync(huge, 256 * 1024 + 1);
    const oversized = invoke(huge);
    assert.equal(oversized.status, 1);
    assert.match(oversized.stderr, /bounded, regular, unlinked/);

    const directory = join(dir, "directory");
    mkdirSync(directory);
    assert.equal(invoke(directory).status, 1);

    const malformed = join(dir, "malformed.json");
    writeFileSync(malformed, "{not-json");
    assert.equal(invoke(malformed).status, 1);

    // A complete-looking file still cannot authorize release without gates.
    const blocked = join(dir, "blocked.json");
    writeFileSync(blocked, JSON.stringify({ ...web(), rollbackReady: false }));
    const denied = invoke(blocked);
    assert.equal(denied.status, 1);
    assert.match(denied.stderr, /Rollback readiness/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("rejects extra checks, fabricated approvals and unknown metadata", () => {
  const extra = web();
  extra.checks.push(check("security-approved"));
  assert.match(verifyReleaseEvidence(extra, sha).join(" "), /exactly the mandatory checks|Unexpected check/);
  const topLevel = { ...web(), productionApproved: true };
  assert.match(verifyReleaseEvidence(topLevel, sha).join(" "), /Unexpected release evidence field/);
  const forged = web();
  forged.checks[0].deploymentApproved = true;
  assert.match(verifyReleaseEvidence(forged, sha).join(" "), /Unexpected metadata/);
  const missing = web();
  missing.checks = [check("test"), check("typecheck"), check("test")];
  assert.match(verifyReleaseEvidence(missing, sha).join(" "), /unique|Missing mandatory check/);
});

test("CLI rejects surplus positional arguments rather than ignoring them", async () => {
  const { mkdtempSync, writeFileSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { spawnSync } = await import("node:child_process");
  const { fileURLToPath } = await import("node:url");
  const dir = mkdtempSync(join(tmpdir(), "mp3-release-extra-"));
  try {
    const path = join(dir, "evidence.json");
    writeFileSync(path, JSON.stringify(web()));
    const script = fileURLToPath(new URL("./verify-release-evidence.mjs", import.meta.url));
    const result = spawnSync(process.execPath, [script, path, sha, "--approved"], { encoding: "utf8" });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /Usage:/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("web evidence cannot masquerade as physical-device acceptance", () => {
  for (const value of [true, false, null, "PASS", 1]) {
    const evidence = { ...web(), deviceAcceptance: value };
    assert.match(verifyReleaseEvidence(evidence, sha).join(" "), /Web evidence must not contain/);
  }
  assert.deepEqual(verifyReleaseEvidence(web(), sha), []);
});

test("iOS acceptance requires explicit boolean true and native checks", () => {
  for (const value of [false, null, "true", 1, undefined]) {
    const evidence = { ...web(), target: "ios", deviceAcceptance: value,
      checks: ["native-build", "native-tests", "device-acceptance"].map(check) };
    assert.match(verifyReleaseEvidence(evidence, sha).join(" "), /Physical-device acceptance/);
  }
  const validShape = { ...web(), target: "ios", deviceAcceptance: true,
    checks: ["native-build", "native-tests", "device-acceptance"].map(check) };
  assert.deepEqual(verifyReleaseEvidence(validShape, sha), []);
});
