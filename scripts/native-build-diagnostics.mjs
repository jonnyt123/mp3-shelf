#!/usr/bin/env node
/** Deterministic, fail-closed native build diagnosis; no source-file rewrites. */
import { openSync, readSync, closeSync, statSync, lstatSync, rmSync } from 'node:fs';
import { resolve, join, relative, sep } from 'node:path';

const MAX_READ = 1024 * 1024;
const TRANSIENT = [
  /unable to initiate PIF transfer session/i,
  /build service could not create build operation/i,
  /database is locked.*build\.db/i,
  /database is locked.*XCBuildData/i,
  /build service connection interrupted/i,
  /CoreSimulatorService connection became invalid/i
];
// Machine prerequisites must not be interpreted as recoverable generated-cache
// faults, even when the same log also mentions a damaged module cache.
const MACHINE_BLOCKER = [
  /no space left on device/i,
  /disk (?:is )?full/i,
  /xcode-select: error:/i,
  /dyld_shared_cache_extract_dylibs failed/i,
  /(?:^|\n)[^\n]*(?:permission denied|operation not permitted)/i
];
const GENERATED_CACHE = [
  /malformed compiled module file/i,
  /malformed (?:PCM|PCH) file/i,
  /module cache.*(?:corrupt|malformed)/i,
  /error:.*(?:modulecache|ModuleCache\.noindex).*(?:corrupt|malformed)/i
];
const SOURCE_FAILURE = [
  /(?:^|\n)[^\n]*\berror: (?:cannot find|no such module|type .* has no member|ambiguous use of|missing argument|extra argument|cannot convert|invalid redeclaration|expression is ambiguous|expected .* declaration|consecutive statements)/i,
  /Swift Compiler Error/i,
  /(?:^|\n)[^\n]*CompileSwift .* failed/i
];

/** This result cannot grant a build PASS. Only a fresh full runner exit=0 can. */
export function diagnoseNativeLog(log) {
  const value = typeof log === 'string' ? log.slice(-MAX_READ) : '';
  if (!value) return { category: 'unavailable', retryable: false, repair: 'none' };
  // A recoverable cache/service message can accompany an unrelated compiler
  // error in the same failed build. Never retry a mixed failure: only a clean
  // infrastructure-only failure may receive the one bounded retry.
  const errorLines = value.split(/\r?\n/).filter(line => /(?:^|\s)error:|\bfatal error:/i.test(line));
  const infrastructureError = line =>
    [...GENERATED_CACHE, ...TRANSIENT].some(re => re.test(line));
  // A disk-full, permissions or toolchain prerequisite failure must take
  // precedence over generic "error:" lines. Otherwise an actionable host
  // failure is incorrectly handed to the Swift source-repair lane.
  // Both classes remain non-retryable; neither may clear user-owned caches.
  if (MACHINE_BLOCKER.some(re => re.test(value))) {
    return { category: 'machine-precondition', retryable: false, repair: 'none' };
  }
  if (SOURCE_FAILURE.some(re => re.test(value)) ||
      errorLines.some(line => !infrastructureError(line))) {
    return { category: 'swift-source', retryable: false, repair: 'none' };
  }
  if (GENERATED_CACHE.some(re => re.test(value))) {
    return { category: 'generated-cache', retryable: true, repair: 'clear-isolated-derived-data' };
  }
  if (TRANSIENT.some(re => re.test(value))) {
    return { category: 'transient-xcode-service', retryable: true, repair: 'retry-isolated-build' };
  }
  return { category: 'unclassified', retryable: false, repair: 'none' };
}
export function readNativeLogTail(path) {
  const metadata = lstatSync(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > 32 * 1024 * 1024)
    throw Error('Native build log is missing or unsafe to inspect');
  const fd = openSync(path, 'r');
  try {
    const opened = statSync(path);
    if (opened.size !== metadata.size || opened.ino !== metadata.ino)
      throw Error('Native build log changed during diagnosis');
    const n = Math.min(metadata.size, MAX_READ), buffer = Buffer.alloc(n);
    if (readSync(fd, buffer, 0, n, metadata.size - n) !== n)
      throw Error('Native build log shortened during diagnosis');
    return buffer.toString('utf8');
  } finally { closeSync(fd); }
}
export function clearIsolatedDerivedData(worktree) {
  const root = resolve(worktree);
  const rootInfo = lstatSync(root);
  if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink())
    throw Error('Refusing generated-cache cleanup through a linked worktree root');
  const generated = resolve(root, 'ios/build/local-release/DerivedData');
  const rel = relative(root, generated);
  if (rel.startsWith('..' + sep) || rel === '..' || !rel)
    throw Error('Refusing to repair a generated path outside isolated worktree');
  // A symlink at ANY parent level could redirect cleanup outside the
  // temporary candidate and destroy user-owned files. Refuse all such paths.
  let segment = root;
  for (const name of ['ios', 'build', 'local-release', 'DerivedData']) {
    segment = join(segment, name);
    const entry = lstatSync(segment, { throwIfNoEntry: false });
    if (!entry) return false;
    if (!entry.isDirectory() || entry.isSymbolicLink())
      throw Error('Refusing generated-cache cleanup through symlink or non-directory');
  }
  rmSync(generated, { recursive: true, force: true });
  return true;
}
