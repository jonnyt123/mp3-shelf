#!/usr/bin/env node
// Fail closed on missing or stale release evidence. This tool never deploys.
import { readPersistedReceipt } from "./local-evidence.mjs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export function verifyReleaseEvidence(evidence, expectedSha) {
  const errors = [];
  if (!/^[0-9a-f]{40}$/i.test(expectedSha ?? "")) errors.push("Expected commit SHA must be 40 hexadecimal characters.");
  if (!evidence || typeof evidence !== "object" || Array.isArray(evidence)) return ["Missing release evidence object."];
  // This JSON is a narrow release-gate input, not a free-form approval record.
  // Unknown fields and additional check records must never be silently accepted.
  const topLevelFields = new Set(["sha", "target", "checks", "branchProtectionSatisfied", "rollbackReady", "deviceAcceptance"]);
  if (Object.keys(evidence).some(field => !topLevelFields.has(field)))
    errors.push("Unexpected release evidence field.");
  if (evidence.sha !== expectedSha) errors.push("Evidence SHA does not match the candidate commit.");
  if (!["web", "ios"].includes(evidence.target)) errors.push("Unknown release target.");
  if (!Array.isArray(evidence.checks) || evidence.checks.length === 0) {
    errors.push("No checks supplied.");
  } else {
    const names = new Set();
    const requiredNames = evidence.target === "web" ? ["test", "typecheck", "build"] :
      evidence.target === "ios" ? ["native-build", "native-tests", "device-acceptance"] : [];
    if (evidence.checks.length !== requiredNames.length)
      errors.push("Release evidence must contain exactly the mandatory checks.");
    for (const check of evidence.checks) {
      // Never allow whitespace aliases or malformed objects to masquerade as
      // required checks. Every mandatory name must match its exact contract.
      if (!check || typeof check !== "object" || Array.isArray(check) ||
          typeof check.name !== "string" || !check.name.trim() ||
          check.name !== check.name.trim() || names.has(check.name.trim())) {
        errors.push("Check names must be unique, exact, nonempty strings.");
        continue;
      }
      names.add(check.name);
      if (!requiredNames.includes(check.name)) errors.push(`Unexpected check: ${check.name}.`);
      if (Object.keys(check).some(field => !["name", "sha", "status", "conclusion", "exitCode", "stepsExecuted"].includes(field)))
        errors.push(`Unexpected metadata on check ${check.name}.`);
      if (check.sha !== expectedSha || check.status !== "passed" || check.conclusion !== "success") {
        errors.push(`Check ${check.name} is missing, stale, or not successful.`);
      }
      // A successful conclusion without any executed steps (for example an
      // empty, skipped or cancelled CI workflow) is not release evidence.
      // Require the executor's actual process exit code and a positive count
      // of completed checks, rather than trusting a display-only PASS label.
      if (check.exitCode !== 0 || !Number.isSafeInteger(check.stepsExecuted) ||
          check.stepsExecuted < 1) {
        errors.push(`Check ${check.name} lacks successful nonempty execution evidence.`);
      }
    }
    const required = requiredNames;
    for (const name of required) if (!names.has(name)) errors.push(`Missing mandatory check: ${name}.`);
  }
  if (evidence.target === "ios" && evidence.deviceAcceptance !== true) errors.push("Physical-device acceptance is required for iOS.");
  if (evidence.branchProtectionSatisfied !== true) errors.push("Branch protection and review requirements are not verified.");
  if (evidence.rollbackReady !== true) errors.push("Rollback readiness is not verified.");
  return errors;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [path, sha, ...extra] = process.argv.slice(2);
  if (!path || !sha || extra.length) {
    console.error("Usage: node scripts/verify-release-evidence.mjs evidence.json <40-character-candidate-sha>");
    process.exitCode = 2;
  } else {
    try {
      const errors = verifyReleaseEvidence(readPersistedReceipt(path), sha);
      if (errors.length) {
        for (const error of errors) console.error(`BLOCKED: ${error}`);
        process.exitCode = 1;
      } else {
        console.log(`Evidence gate PASS for ${sha}. Verify authenticity of supplied evidence independently before merging or deploying.`);
      }
    } catch (error) {
      console.error(`BLOCKED: ${error.message}`);
      process.exitCode = 1;
    }
  }
}
