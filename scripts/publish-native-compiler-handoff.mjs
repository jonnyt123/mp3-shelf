#!/usr/bin/env node
/** Safe, deduplicated Swift compiler failure handoff. Never uploads raw logs. */
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { readNativeLogTail } from './native-build-diagnostics.mjs';

const SHA = /^[0-9a-f]{40}$/;
export const COMMENT_ID = 6905376101;
const MARKER = '<!-- MP3SHELF_NATIVE_COMPILER_HANDOFF_V1 -->';
const SOURCE_LOCATION = /(?:^|\n)[^\n]*?(ios\/(?:MP3Shelf|Tests)\/[A-Za-z0-9_./-]+\.swift):(\d{1,6}):(?:(\d{1,4}):)?\s*error:\s*([^\n]*)/g;
const CATEGORIES = [
  ['missing-symbol', /cannot find|has no member|no such module/i],
  ['type-mismatch', /cannot convert|cannot assign|ambiguous use|type of expression/i],
  ['argument-contract', /missing argument|extra argument|incorrect argument label/i],
  ['concurrency', /actor-isolated|sendable|non-sendable|main actor/i],
  ['syntax', /expected|consecutive statements|invalid redeclaration/i]
];
export function sourceErrorFingerprint(log) {
  const source = typeof log === 'string' ? log.slice(-1024 * 1024) : '';
  const unique = new Map();
  for (const match of source.matchAll(SOURCE_LOCATION)) {
    const path = match[1];
    if (path.includes('..') || path.includes('//') || path.length > 180) continue;
    const line = Number(match[2]);
    const column = match[3] ? Number(match[3]) : null;
    if (line < 1 || line > 999999 || (column !== null && column < 1)) continue;
    const category = CATEGORIES.find(([, regex]) => regex.test(match[4]))?.[0] ?? 'compiler-error';
    const key = path + ':' + line + ':' + (column ?? '-') + ':' + category;
    unique.set(key, { path, line, column, category });
    if (unique.size >= 12) break;
  }
  return [...unique.values()];
}
export function compilerHandoffBody({ sha, diagnosis, locations }) {
  if (!SHA.test(sha ?? '') || diagnosis?.category !== 'swift-source' ||
      !Array.isArray(locations) || locations.length > 12)
    throw Error('An exact SHA and real Swift source failure are required');
  for (const row of locations) {
    if (!/^ios\/(?:MP3Shelf|Tests)\/[A-Za-z0-9_./-]+\.swift$/.test(row?.path ?? '') ||
        row.path.includes('..') || row.path.includes('//') ||
        !Number.isSafeInteger(row.line) || row.line < 1 ||
        ![...CATEGORIES.map(x => x[0]), 'compiler-error'].includes(row.category))
      throw Error('Unsafe source location');
  }
  const rows = locations.length
    ? locations.map(row => '- ' + row.path + ':' + row.line + ' (' + row.category + ')').join('\n')
    : 'No safe source locations available; examine the local Mac logs.';
  return MARKER + '\n### MP3 Shelf — Native Swift compilation handoff\n\n' +
    'Exact candidate: ' + sha + '\n' +
    'Result: SOURCE_COMPILATION_FAILED; NOT built or integrated.\n' +
    'Only sanitized repository paths, line numbers and error categories appear below.\n\n' +
    rows + '\n\n' +
    'Fixes require reviewed Git commits in the source-owning lane, followed by a full new exact-SHA Xcode run. ' +
    'The physical-iPhone gate #6 remains blocked.\n';
}
function availableToken() {
  if (process.env.GITHUB_TOKEN || process.env.GH_TOKEN)
    return process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  try {
    return execFileSync('gh', ['auth', 'token'],
      { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { return null; }
}
export async function publishCompilerHandoff({ sha, output, token = availableToken(), request = fetch } = {}) {
  if (!SHA.test(sha ?? '')) throw Error('Missing exact source commit');
  const path = join(resolve(output), 'native-diagnosis.json');
  const info = lstatSync(path);
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 || info.size > 16384)
    throw Error('Unsafe or missing native diagnosis');
  const diagnosis = JSON.parse(readFileSync(path, 'utf8'));
  if (diagnosis.category !== 'swift-source' || diagnosis.finalStatus !== 'BLOCKED')
    return { status: 'NOT_SOURCE_FAILURE' };
  const locations = sourceErrorFingerprint(readNativeLogTail(join(resolve(output), 'native-console.log')));
  const body = compilerHandoffBody({ sha, diagnosis, locations });
  const digest = createHash('sha256').update(body).digest('hex');
  if (!token) return { status: 'LOCAL_ONLY_NO_GITHUB_AUTH', digest, count: locations.length };
  const url = 'https://api.github.com/repos/jonnyt123/mp3-shelf/issues/comments/' + COMMENT_ID;
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), 12000);
  const headers = { Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28', Authorization: 'Bearer ' + token };
  try {
    const old = await request(url, { headers, signal: abort.signal });
    if (!old.ok) throw Error('Compiler handoff read failed: ' + old.status);
    const previous = await old.json();
    if (typeof previous?.body !== 'string' ||
        !previous.body.startsWith(MARKER + '\n') ||
        previous.user?.login !== 'jonnyt123')
      throw Error('Refusing to overwrite an unrelated coordination comment');
    if (previous.body === body) return { status: 'UNCHANGED', digest, count: locations.length };
    const next = await request(url, { method: 'PATCH', headers: {
      ...headers, 'Content-Type': 'application/json'
    }, body: JSON.stringify({ body }), signal: abort.signal });
    if (!next.ok) throw Error('Compiler handoff write failed: ' + next.status);
    const saved = await next.json();
    if (saved.body !== body) throw Error('Compiler handoff write not confirmed');
    return { status: 'PUBLISHED', digest, count: locations.length };
  } finally { clearTimeout(timer); }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [sha, directory, ...extra] = process.argv.slice(2);
  if (!sha || !directory || extra.length) {
    console.error('Usage: node scripts/publish-native-compiler-handoff.mjs SHA NATIVE_LOG_DIRECTORY');
    process.exitCode = 2;
  } else {
    publishCompilerHandoff({ sha, output: directory })
      .then(result => console.log(JSON.stringify(result)))
      .catch(error => { console.error('HANDOFF_UNVERIFIED: ' + error.message); process.exitCode = 1; });
  }
}
