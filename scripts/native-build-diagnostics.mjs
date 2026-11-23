#!/usr/bin/env node
/** Deterministic, fail-closed native build diagnosis; no source-file rewrites. */
import { openSync, readSync, closeSync, statSync, lstatSync, rmSync } from 'node:fs';
import { resolve, join, relative, sep } from 'node:path';

const MAX_READ = 1024 * 1024;
const TRANSIENT = [
  /unable to initiate PIF transfer session/i,
  /build service could not create build operation/i,
  /database is locked.*build\.db/i,
  /database is locked.*XCBuildData/i
];
const GENERATED_CACHE = [
  /malformed compiled module file/i,
  /malformed (?:PCM|PCH) file/i,
  /module cache.*(?:corrupt|malformed)/i,
  /error:.*(?:modulecache|ModuleCache\.noindex).*(?:corrupt|malformed)/i
];
// Fatal environment failures override retryable phrases even when Xcode prints
// an earlier transient error. Never retry disk-full, toolchain or permissions.
const FATAL_ENVIRONMENT = [
  /(?:no space left on device|disk (?:is )?full|ENOSPC)/i,
  /(?:permission denied|operation not permitted|EACCES|EPERM)/i,
  /(?:xcode-select: error|active developer directory.*(?:invalid|does not exist)|requires Xcode)/i,
  /(?:dyld:.*(?:library not loaded|symbol not found)|dyld\\[[0-9]+\\]:.*(?:library not loaded|symbol not found))/i,
  /(?:code signing is required|provisioning profile.*(?:missing|not found))/i
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
  if (FATAL_ENVIRONMENT.some(re => re.test(value))) {
    return { category: 'fatal-environment', retryable: false, repair: 'none' };
  }
  if (SOURCE_FAILURE.some(re => re.test(value))) {
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
  const rootEntry = lstatSync(root);
  if (!rootEntry.isDirectory() || rootEntry.isSymbolicLink())
    throw Error('Refusing generated-cache cleanup in redirected worktree root');
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
