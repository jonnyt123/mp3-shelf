#!/usr/bin/env node
// Read-only GitHub contribution ledger. Counts source/test deltas, NOT passing tests or releases.
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

export const LANES = Object.freeze([
  { name: 'playback', pr: 30 },
  { name: 'downloads', pr: 31 },
  { name: 'iphone-ux', pr: 32 },
  { name: 'web-qa', pr: 33 },
  { name: 'integration-staging', pr: 29 },
  { name: 'release-tooling', pr: 34 }
]);
const SHA = /^[0-9a-f]{40}$/i;
const SOURCE = /\.(?:swift|ts|tsx|js|mjs|py|sh)$/i;
export function classifyPath(path) {
  if (typeof path !== 'string' || !SOURCE.test(path)) return 'other';
  if (/^(?:ios\/Tests\/|src\/.*\.(?:test|spec)\.|scripts\/.*\.(?:test|spec)\.|ios\/scripts\/test[-_])/.test(path)) return 'test';
  if (/^(?:ios\/MP3Shelf\/|src\/|scripts\/|ios\/scripts\/)/.test(path)) return 'source';
  return 'other';
}
// Prevent a merge of the consolidated candidate from being credited as new
// source development in every worker lane. Paths are matched to owned surfaces.
export function laneOwnsPath(lane, path) {
  if (lane === 'playback') return /^ios\/MP3Shelf\/(?:Services\/(?:PlaybackController|MusicLibrary|PortableShelfArchive)\.swift|Models\/)/.test(path) ||
    path === 'ios/Tests/PortableShelfArchiveTests.swift';
  if (lane === 'downloads') return /^ios\/MP3Shelf\/Services\/(?:SpotifyService|AudioSourceFinder|BackgroundAudioDownloader|SourceDiscoveryJob|DownloadPathProof)\.swift$/.test(path) ||
    path === 'ios/MP3Shelf/Views/DownloadManagerView.swift' || /^ios\/Tests\//.test(path);
  if (lane === 'iphone-ux') return /^ios\/MP3Shelf\/Views\//.test(path) &&
    path !== 'ios/MP3Shelf/Views/DownloadManagerView.swift';
  if (lane === 'web-qa') return /^src\//.test(path) || /^ios\/Tests\//.test(path);
  if (lane === 'integration-staging') return /^ios\/(?:MP3Shelf\/|Tests\/)/.test(path);
  if (lane === 'release-tooling') return /^scripts\//.test(path);
  return false;
}
function validDate(value) {
  const date = typeof value === 'string' ? Date.parse(value) : NaN;
  return Number.isFinite(date) ? date : null;
}
async function readCommitSummaries(api, pr, since, now) {
  const meta = await api(`/pulls/${pr}`);
  if (!SHA.test(meta?.head?.sha ?? '') || !Number.isSafeInteger(meta?.commits) || meta.commits < 0) {
    throw Error(`PR #${pr} has invalid head/commit metadata`);
  }
  let page = Math.max(1, Math.ceil(meta.commits / 100));
  const selected = [];
  let finished = false;
  let pages = 0;
  while (page > 0 && pages < 5 && !finished) {
    const commits = await api(`/pulls/${pr}/commits?per_page=100&page=${page}`);
    if (!Array.isArray(commits)) throw Error(`PR #${pr} commit list unavailable`);
    for (const commit of [...commits].reverse()) {
      const timestamp = validDate(commit?.commit?.committer?.date ?? commit?.commit?.author?.date);
      if (timestamp === null || !SHA.test(commit?.sha ?? '')) {
        throw Error(`PR #${pr} contains malformed commit metadata`);
      }
      if (timestamp < since) { finished = true; break; }
      if (timestamp <= now) selected.push(commit.sha);
    }
    pages += 1;
    page -= 1;
  }
  if (!finished && page > 0) throw Error(`PR #${pr} exceeded bounded history; metrics incomplete`);
  return { head: meta.head.sha, commits: selected };
}
export async function collectThroughput({ api, now = Date.now(), hours = 1, lanes = LANES }) {
  if (typeof api !== 'function' || !Number.isFinite(now) ||
      !Number.isInteger(hours) || hours < 1 || hours > 24) throw Error('Invalid throughput query');
  const since = now - hours * 3_600_000;
  const results = [];
  for (const lane of lanes) {
    const commits = await readCommitSummaries(api, lane.pr, since, now);
    const paths = new Set(), testPaths = new Set();
    let sourceAdditions = 0, sourceDeletions = 0, testAdditions = 0;
    let codeCommits = 0, testCommits = 0, commitsWithoutCode = 0;
    for (const sha of [...new Set(commits.commits)]) {
      const info = await api(`/commits/${sha}`);
      if (!Array.isArray(info?.files)) throw Error(`Commit ${sha} lacks file statistics`);
      let sourceTouched = false, testsTouched = false;
      for (const file of info.files) {
        if (!Number.isSafeInteger(file.additions) || file.additions < 0 ||
            !Number.isSafeInteger(file.deletions) || file.deletions < 0) {
          throw Error(`Commit ${sha} has incomplete diff statistics`);
        }
        if (!laneOwnsPath(lane.name, file.filename)) continue;
        const kind = classifyPath(file.filename);
        if (kind === 'source') {
          sourceTouched = true;
          paths.add(file.filename);
          sourceAdditions += file.additions;
          sourceDeletions += file.deletions;
        } else if (kind === 'test') {
          testsTouched = true;
          testPaths.add(file.filename);
          testAdditions += file.additions;
        }
      }
      if (sourceTouched) codeCommits += 1;
      if (testsTouched) testCommits += 1;
      if (!sourceTouched && !testsTouched) commitsWithoutCode += 1;
    }
    results.push({ lane: lane.name, pr: lane.pr, head: commits.head,
      commitsObserved: commits.commits.length, codeCommits, testCommits,
      commitsWithoutCode, sourceFilesChanged: paths.size,
      testFilesChanged: testPaths.size, sourceAdditions, sourceDeletions,
      testAdditions, mergedToMain: false });
  }
  return { repository: 'jonnyt123/mp3-shelf', from: new Date(since).toISOString(),
    to: new Date(now).toISOString(), hours, measurement: 'GitHub commit file diffs; tests not executed or verified',
    nativeReleaseGate: 'NOT_VERIFIED', results };
}
export function formatThroughput(result) {
  return [
    `MP3 Shelf throughput (${result.hours}h, ending ${result.to}) — GitHub source/test deltas, NOT test passes`,
    ...result.results.map(r =>
      `${r.lane} PR#${r.pr} ${r.head.slice(0, 12)}: code commits ${r.codeCommits}, source +${r.sourceAdditions}/-${r.sourceDeletions}, source files ${r.sourceFilesChanged}, test-file commits ${r.testCommits}, test lines +${r.testAdditions}`),
    'PR#29 counts staging commits, not a merge to main; physical iPhone acceptance is still unverified.'
  ].join('\n');
}
export async function githubAPI(path, options = {}) {
  const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(`https://api.github.com/repos/jonnyt123/mp3-shelf${path}`, {
      headers: { Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      signal: controller.signal, ...options
    });
    if (!response.ok) throw Error(`GitHub HTTP ${response.status} for a throughput read`);
    return await response.json();
  } finally { clearTimeout(timer); }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const raw = process.argv.slice(2);
  if (raw.length > 2 || raw.some(a => a !== '--json' && !/^--hours=(?:[1-9]|1[0-9]|2[0-4])$/.test(a))) {
    console.error('Usage: node scripts/measure-agent-throughput.mjs [--hours=1..24] [--json]');
    process.exitCode = 2;
  } else {
    const hours = Number(raw.find(s => s.startsWith('--hours='))?.split('=')[1] ?? 1);
    try {
      const report = await collectThroughput({ api: githubAPI, hours });
      console.log(raw.includes('--json') ? JSON.stringify(report, null, 2) : formatThroughput(report));
    } catch (error) {
      console.error(`THROUGHPUT UNVERIFIED: ${error.message}`);
      process.exitCode = 1;
    }
  }
}
