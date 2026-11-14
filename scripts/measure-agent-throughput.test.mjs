import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { classifyPath, collectThroughput, formatThroughput } from './measure-agent-throughput.mjs';

const one = 'a'.repeat(40), two = 'b'.repeat(40);
const now = Date.parse('2026-11-13T17:00:00Z');
const recent = '2026-11-13T16:30:00Z', old = '2026-11-13T15:00:00Z';
function mock(records) {
  return async path => {
    if (!(path in records)) throw Error('Unexpected API request ' + path);
    return records[path];
  };
}
test('separates production changes from test additions and non-code churn', async () => {
  const api = mock({
    '/pulls/30': { head: { sha: two }, commits: 2 },
    '/pulls/30/commits?per_page=100&page=1': [
      { sha: one, commit: { committer: { date: old } } },
      { sha: two, commit: { committer: { date: recent } } }
    ],
    [`/commits/${two}`]: { files: [
      { filename: 'ios/MP3Shelf/Services/MusicLibrary.swift', additions: 30, deletions: 4 },
      { filename: 'ios/Tests/PortableShelfArchiveTests.swift', additions: 12, deletions: 2 },
      { filename: 'README.md', additions: 30, deletions: 0 }
    ] }
  });
  const report = await collectThroughput({ api, now, lanes: [{ name: 'playback', pr: 30 }] });
  assert.equal(report.results[0].codeCommits, 1);
  assert.equal(report.results[0].testCommits, 1);
  assert.equal(report.results[0].sourceAdditions, 30);
  assert.equal(report.results[0].sourceDeletions, 4);
  assert.equal(report.results[0].testAdditions, 12);
  assert.match(formatThroughput(report), /NOT test passes/);
  assert.equal(report.nativeReleaseGate, 'NOT_VERIFIED');
});
test('commits with only documents are not presented as code progress', async () => {
  const api = mock({
    '/pulls/32': { head: { sha: one }, commits: 1 },
    '/pulls/32/commits?per_page=100&page=1': [{ sha: one, commit: { committer: { date: recent } } }],
    [`/commits/${one}`]: { files: [{ filename: 'README.md', additions: 100, deletions: 0 }] }
  });
  const r = await collectThroughput({ api, now, lanes: [{ name: 'ui', pr: 32 }] });
  assert.equal(r.results[0].codeCommits, 0);
  assert.equal(r.results[0].commitsWithoutCode, 1);
});
test('rejects missing API information rather than inventing hourly throughput', async () => {
  await assert.rejects(collectThroughput({ api: mock({ '/pulls/30': { commits: 1 } }),
    now, lanes: [{ name: 'playback', pr: 30 }] }), /invalid head/);
});
test('classifies fixtures and scripts without crediting documentation', () => {
  assert.equal(classifyPath('src/lib/backup.test.ts'), 'test');
  assert.equal(classifyPath('ios/Tests/ArchiveTests.swift'), 'test');
  assert.equal(classifyPath('scripts/verify-vercel-release.test.mjs'), 'test');
  assert.equal(classifyPath('ios/MP3Shelf/Views/LibraryViews.swift'), 'source');
  assert.equal(classifyPath('src/components/music-library.tsx'), 'source');
  assert.equal(classifyPath('ios/DEVICE_QA.md'), 'other');
});
test('unrelated merged source is not misattributed to the owner lane', async () => {
  const api = mock({
    '/pulls/30': { head: { sha: one }, commits: 1 },
    '/pulls/30/commits?per_page=100&page=1': [{ sha: one, commit: { committer: { date: recent } } }],
    [`/commits/${one}`]: { files: [
      { filename: 'ios/MP3Shelf/Services/SpotifyService.swift', additions: 900, deletions: 3 },
      { filename: 'ios/MP3Shelf/Services/MusicLibrary.swift', additions: 7, deletions: 2 }
    ] }
  });
  const r = await collectThroughput({ api, now, lanes: [{ name: 'playback', pr: 30 }] });
  assert.equal(r.results[0].codeCommits, 1);
  assert.equal(r.results[0].sourceAdditions, 7);
  assert.equal(r.results[0].sourceDeletions, 2);
});
test('bounded pagination and missing file statistics fail closed', async () => {
  const api = mock({
    '/pulls/31': { head: { sha: one }, commits: 1 },
    '/pulls/31/commits?per_page=100&page=1': [{ sha: one, commit: { committer: { date: recent } } }],
    [`/commits/${one}`]: { files: [{ filename: 'ios/MP3Shelf/Services/SpotifyService.swift' }] }
  });
  await assert.rejects(collectThroughput({ api, now, lanes: [{ name: 'downloads', pr: 31 }] }),
    /incomplete diff statistics/);
});

test('counts recent commits even when an older commit appears later in ancestry', async () => {
  const third = 'c'.repeat(40);
  const api = mock({
    '/pulls/31': { head: { sha: third }, commits: 3 },
    '/pulls/31/commits?per_page=100&page=1': [
      { sha: one, commit: { committer: { date: recent } } },
      { sha: two, commit: { committer: { date: old } } },
      { sha: third, commit: { committer: { date: recent } } }
    ],
    [`/commits/${one}`]: { files: [
      { filename: 'ios/MP3Shelf/Services/SpotifyService.swift', additions: 4, deletions: 1 }
    ] },
    [`/commits/${third}`]: { files: [
      { filename: 'ios/MP3Shelf/Services/AudioSourceFinder.swift', additions: 8, deletions: 2 }
    ] }
  });
  const r = await collectThroughput({ api, now, lanes: [{ name: 'downloads', pr: 31 }] });
  assert.equal(r.results[0].codeCommits, 2);
  assert.equal(r.results[0].sourceAdditions, 12);
  assert.equal(r.results[0].sourceDeletions, 3);
});

test('refuses incomplete history and missing commit pages rather than reporting partial metrics', async () => {
  await assert.rejects(collectThroughput({
    api: mock({ '/pulls/31': { head: { sha: one }, commits: 501 } }),
    now, lanes: [{ name: 'downloads', pr: 31 }]
  }), /exceeded bounded history/);
  await assert.rejects(collectThroughput({
    api: mock({
      '/pulls/31': { head: { sha: one }, commits: 1 },
      '/pulls/31/commits?per_page=100&page=1': []
    }),
    now, lanes: [{ name: 'downloads', pr: 31 }]
  }), /commit list incomplete/);
});

test('empty PR history reports zero without requesting nonexistent pages', async () => {
  const r = await collectThroughput({
    api: mock({ '/pulls/34': { head: { sha: one }, commits: 0 } }),
    now, lanes: [{ name: 'release-tooling', pr: 34 }]
  });
  assert.equal(r.results[0].commitsObserved, 0);
  assert.equal(r.results[0].codeCommits, 0);
});


test('rejects truncated last page rather than undercounting recent commits', async () => {
  const api = mock({
    '/pulls/31': { head: { sha: two }, commits: 2 },
    '/pulls/31/commits?per_page=100&page=1': [
      { sha: one, commit: { committer: { date: recent } } }
    ]
  });
  await assert.rejects(collectThroughput({ api, now, lanes: [{ name: 'downloads', pr: 31 }] }),
    /commit list incomplete/);
});

test('rejects branch movement between paginated reads and final snapshot', async () => {
  let calls = 0;
  const api = async path => {
    if (path === '/pulls/31') return { head: { sha: ++calls === 1 ? one : two }, commits: 1 };
    if (path === '/pulls/31/commits?per_page=100&page=1')
      return [{ sha: one, commit: { committer: { date: old } } }];
    throw Error('Unexpected API request ' + path);
  };
  await assert.rejects(collectThroughput({ api, now, lanes: [{ name: 'downloads', pr: 31 }] }),
    /changed during measurement/);
});

test('rejects GitHub commit-file truncation instead of publishing partial totals', async () => {
  const api = mock({
    '/pulls/34': { head: { sha: one }, commits: 1 },
    '/pulls/34/commits?per_page=100&page=1': [
      { sha: one, commit: { committer: { date: recent } } }
    ],
    [`/commits/${one}`]: { files: Array.from({ length: 300 }, (_, i) => ({
      filename: `scripts/fixture-${i}.mjs`, additions: 1, deletions: 0
    })) }
  });
  await assert.rejects(collectThroughput({ api, now, lanes: [{ name: 'release-tooling', pr: 34 }] }),
    /truncated file statistics/);
});
