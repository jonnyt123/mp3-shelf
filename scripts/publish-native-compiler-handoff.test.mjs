import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { COMMENT_ID, sourceErrorFingerprint, compilerHandoffBody,
  publishCompilerHandoff } from './publish-native-compiler-handoff.mjs';

const sha = 'a'.repeat(40);
const MARKER = '<!-- MP3SHELF_NATIVE_COMPILER_HANDOFF_V1 -->';
const privateLog = "/Users/example/Secret Private Project/ios/MP3Shelf/Services/MusicLibrary.swift:41:12: error: cannot convert value of type 'Int' to 'String' TOKEN=my-sensitive-token";
function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'mp3shelf-compiler-handoff-'));
  writeFileSync(join(root, 'native-diagnosis.json'),
    JSON.stringify({ category: 'swift-source', finalStatus: 'BLOCKED' }));
  writeFileSync(join(root, 'native-console.log'),
    privateLog + '\n' + privateLog + '\n' +
    '/private/tmp/ios/Tests/RecordingMatcherTests.swift:12:3: error: extra argument in call\n');
  return root;
}
test('extracts bounded, deduplicated repository locations without leaking errors or private paths', () => {
  const errors = sourceErrorFingerprint(privateLog + '\n' + privateLog);
  assert.equal(errors.length, 1);
  assert.deepEqual(errors[0], { path: 'ios/MP3Shelf/Services/MusicLibrary.swift',
    line: 41, column: 12, category: 'type-mismatch' });
  const body = compilerHandoffBody({ sha, diagnosis: { category: 'swift-source' }, locations: errors });
  assert(body.includes(sha));
  assert(body.includes('MusicLibrary.swift:41'));
  assert(!body.includes('TOKEN='));
  assert(!body.includes('/Users/'));
  assert(!body.includes("'Int'"));
});
test('rejects unsafe paths, non-Swift categories and missing candidate identities', () => {
  const sample = { sha, diagnosis: { category: 'swift-source' },
    locations: [{ path: 'ios/MP3Shelf/Services/MusicLibrary.swift', line: 12, category: 'syntax' }] };
  assert.throws(() => compilerHandoffBody({ ...sample, sha: 'wrong' }));
  assert.throws(() => compilerHandoffBody({ ...sample, diagnosis: { category: 'generated-cache' } }));
  for (const path of ['ios/MP3Shelf/../Secrets.swift', 'src/private.swift', 'ios/Tests/x.md']) {
    assert.throws(() => compilerHandoffBody({
      ...sample, locations: [{ ...sample.locations[0], path }] }));
  }
});
test('publishes one sanitized GitHub comment and deduplicates exact repeats', async () => {
  const root = fixture(); let patchCalls = 0, lastBody;
  try {
    const request = async (url, options) => {
      assert(url.endsWith('/issues/comments/' + COMMENT_ID));
      if (options.method === 'PATCH') {
        patchCalls++;
        const body = JSON.parse(options.body).body;
        assert(!body.includes('TOKEN='));
        lastBody = body;
        return { ok: true, json: async () => ({ body }) };
      }
      return { ok: true, json: async () => ({
        body: lastBody ?? MARKER + '\nAwaiting compilation',
        user: { login: 'jonnyt123' }
      }) };
    };
    const first = await publishCompilerHandoff({ sha, output: root, token: 'fixture-token', request });
    assert.equal(first.status, 'PUBLISHED');
    assert.equal(first.count, 2);
    const second = await publishCompilerHandoff({ sha, output: root, token: 'fixture-token', request });
    assert.equal(second.status, 'UNCHANGED');
    assert.equal(patchCalls, 1);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test('missing auth returns LOCAL_ONLY and never fabricates successful GitHub delivery', async () => {
  const root = fixture();
  try {
    const outcome = await publishCompilerHandoff({ sha, output: root, token: null,
      request: () => { throw Error('No GitHub request permitted'); } });
    assert.equal(outcome.status, 'LOCAL_ONLY_NO_GITHUB_AUTH');
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test('non-owner comment or non-source failure never authorizes a handoff patch', async () => {
  const root = fixture();
  try {
    await assert.rejects(publishCompilerHandoff({ sha, output: root, token: 'fixture',
      request: async () => ({ ok: true, json: async () => ({
        user: { login: 'different-user' }, body: MARKER + '\nprevious' }) })
    }), /unrelated/);
    writeFileSync(join(root, 'native-diagnosis.json'),
      JSON.stringify({ category: 'generated-cache', finalStatus: 'BLOCKED' }));
    const result = await publishCompilerHandoff({ sha, output: root, token: 'fixture',
      request: () => { throw Error('Must not publish cache failure'); } });
    assert.equal(result.status, 'NOT_SOURCE_FAILURE');
  } finally { rmSync(root, { recursive: true, force: true }); }
});
