// The scheduled workers load this expression by its immutable Git blob ID.
// GitHub owns the branch compare-and-swap. The issue comment is a restart receipt.
(async function scheduledDelivery(tools, catalog, lane, job = {}) {
  const repo = 'jonnyt123/mp3-shelf';
  const api = 'https://api.github.com/repos/' + repo;
  const roles = {
    playback: ['agent/mp3-playback-delivery', 7231802699, /^(PlaybackController|NativeAudioEngine|MusicLibrary|PortableShelfArchive|MusicModels|PlaybackOrder)$/, /^(Playback|PortableShelfArchive|MusicLibrary|NativeAudioEngine|MusicModels)/],
    downloads: ['agent/mp3-downloads-delivery', 7231803084, /^(SpotifyService|AudioSourceFinder|BackgroundAudioDownloader|DownloadPathProof|RecordingMatcher|SourceDiscoveryJob|DownloadedAudioSignature|DownloadManagerView|SpotifyViews)$/, /^(Spotify|Archive|AudioSource|Audius|Background|Download|Openverse|PCMConversion|RecordingMatcher|SourceDiscovery|WebAudio)/],
    ux: ['agent/mp3-ux-delivery', 7231802337, /^(LibraryViews|PlayerViews|MainView)$/, /^(LibraryViews|PlayerViews|MainView|Accessibility|QueueAccessibility)/],
    product: ['agent/mp3-native-product', 7231803447, /^(AppleMusicService|LyricsParser|PlaylistCSV|AppleMusicViews|LyricsView|ImportViews|OfflineReadinessService|OfflineReadinessView)$/, /^(AppleMusic|Lyrics|PlaylistCSV|ImportViews|OfflineReadiness)/],
    integration: ['agent/mp3-native-integration-delivery', 7231803816]
  };
  function requireValue(ok, reason) { if (!ok) throw new Error(reason); }
  requireValue(Object.hasOwn(roles, lane), 'Unknown delivery lane');
  const [branch, commentId] = roles[lane];
  const shaPattern = /^[a-f0-9]{40}$/;
  function body(result) {
    requireValue(result && !result.isError, JSON.stringify(result?.content ?? result).slice(0, 600));
    if (result.structuredContent != null) return result.structuredContent;
    if (result.result != null) return result.result;
    if (Array.isArray(result.content) && result.content[0]?.text) return JSON.parse(result.content[0].text);
    return result;
  }
  async function call(verb, args) {
    const tool = catalog.find(t => t.name.toLowerCase().replace('github__', 'github_').endsWith('__github_' + verb));
    requireValue(tool, 'Missing connected GitHub operation ' + verb);
    return body(await tools[tool.name](args));
  }
  async function get(path) {
    const reply = await call('fetch', {url: api + path});
    return typeof reply.content === 'string' ? JSON.parse(reply.content) : reply;
  }
  const ref = async name => {
    const result = await get('/git/ref/heads/' + name);
    requireValue(shaPattern.test(result.object?.sha), 'Branch read failed: ' + name);
    return result.object.sha;
  };
  async function treeAt(sha) {
    const data = await get('/git/trees/' + sha + '?recursive=1');
    requireValue(Array.isArray(data.tree) && !data.truncated, 'Incomplete Git tree');
    return new Map(data.tree.filter(e => e.type !== 'tree').map(e => [e.path, e]));
  }
  async function file(path, sha) {
    const f = await call('fetch_file', {repository_full_name: repo, ref: sha, path});
    requireValue(typeof f.content === 'string' && shaPattern.test(f.sha) && (!f.encoding || f.encoding === 'utf-8'), 'Incomplete text file: ' + path);
    return f;
  }
  function owns(owner, path) {
    if (owner === 'integration') return /^(?:ios\/scripts|scripts)\/(?:[\w-]+\/)*[\w.-]+\.(?:m?js|sh|py|swift)$/.test(path) || path === 'ios/MP3Shelf.xcodeproj/project.pbxproj';
    const source = /^ios\/MP3Shelf\/(?:Models|Services|Views)\/([A-Za-z0-9_]+)\.swift$/.exec(path);
    const test = /^ios\/Tests\/([A-Za-z0-9_]+Tests)\.swift$/.exec(path);
    return Boolean((source && roles[owner]?.[2]?.test(source[1])) || (test && roles[owner]?.[3]?.test(test[1])));
  }
  function bytes(text) {
    let length = 0;
    for (const char of text) {
      const point = char.codePointAt(0);
      length += point < 128 ? 1 : point < 2048 ? 2 : point < 65536 ? 3 : 4;
    }
    return length;
  }
  function isProduction(path, owner) {
    return path.startsWith('ios/MP3Shelf/') || (owner === 'integration' && owns(owner, path) && !/(?:\.test\.|\/test[_-])/.test(path));
  }
  function safeEvents(yaml, path) {
    // Accept the simple block syntax used by this repo. Unknown syntax needs review.
    const top = yaml.split(/\r?\n/).filter(line => line.trim() && !/^\s*#/.test(line));
    const starts = top.filter(line => /^(?:on|'on'|"on")\s*:/.test(line));
    if (starts.length !== 1 || !/^(?:on|'on'|"on"):\s*$/.test(starts[0])) return false;
    const below = top.slice(top.indexOf(starts[0]) + 1);
    const end = below.findIndex(line => !/^\s/.test(line));
    const section = end < 0 ? below : below.slice(0, end);
    if (path === '.github/workflows/mp3-shelf-delivery.yml' && section.join('\n') === [
      '  push:', '    branches: [agent/mp3-native-integration-delivery]', "    paths: ['ios/automation/requests/*.json']"
    ].join('\n')) return true;
    if (!section.length || !/^  \S/.test(section[0])) return false;
    return section.every(line => /^  (?:pull_request|workflow_dispatch):\s*$/.test(line) || /^    +\S/.test(line));
  }
  async function checkPublicationPolicy(head) {
    const defaultHead = await ref('main');
    const commits = [...new Set([head, defaultHead])];
    await Promise.all(commits.map(async sha => {
      const entries = await treeAt(sha);
      for (const [path, entry] of entries) {
        if (!/^\.github\/workflows\/[^/]+\.ya?ml$/i.test(path)) continue;
        const workflow = await file(path, sha);
        requireValue(entry.mode === '100644' && workflow.sha === entry.sha && safeEvents(workflow.content, path), 'Review workflow triggers: ' + path);
      }
    }));
    // Filtering by head AND by base also covers a draft with a different head.
    const queries = ['head=' + encodeURIComponent('jonnyt123:' + branch), 'base=' + encodeURIComponent(branch)];
    const lists = await Promise.all(queries.map(q => get('/pulls?state=open&per_page=1&' + q)));
    requireValue(lists.every(list => Array.isArray(list) && list.length === 0), 'Delivery branch participates in an open PR');
  }
  const marker = '<!-- MP3_SHELF_CHECKPOINT_V1:' + lane + ' -->';
  async function checkpoint() {
    const record = await get('/issues/comments/' + commentId);
    const match = record.body?.match(/```json\s*([\s\S]*?)```/);
    requireValue(record.body?.startsWith(marker) && match, 'Missing lane checkpoint');
    const cp = JSON.parse(match[1]);
    requireValue(cp.version === 1 && cp.lane === lane && cp.branch === branch && ['BASELINE','PREPARED','VERIFIED'].includes(cp.state), 'Wrong lane checkpoint');
    return cp;
  }
  async function save(cp) {
    const comment = marker + '\n### ' + lane + ' delivery checkpoint\n```json\n' + JSON.stringify(cp, null, 2) + '\n```';
    await call('update_issue_comment', {repo_full_name: repo, comment_id: commentId, comment});
    const read = await checkpoint();
    requireValue(read.state === cp.state && read.prepared === cp.prepared && read.remote === cp.remote, 'Checkpoint changed concurrently; reopen the lane');
    return read;
  }
  async function contains(tip, sha) {
    if (tip === sha) return true;
    return (await get('/compare/' + sha + '...' + tip)).status === 'ahead';
  }
  function sameSet(a, b) {
    return a.length === b.length && a.every(x => b.includes(x));
  }
  async function checkDiff(cp) {
    requireValue(shaPattern.test(cp.parent) && shaPattern.test(cp.prepared), 'Invalid checkpoint commit');
    const [commit, before, after] = await Promise.all([get('/git/commits/' + cp.prepared), treeAt(cp.parent), treeAt(cp.prepared)]);
    requireValue(commit.parents?.length === 1 && commit.parents[0].sha === cp.parent, 'Unexpected commit parent');
    const changed = [...new Set([...before.keys(), ...after.keys()])].filter(p =>
      before.get(p)?.sha !== after.get(p)?.sha || before.get(p)?.mode !== after.get(p)?.mode);
    requireValue(changed.length && sameSet(changed, cp.paths) && sameSet(changed, Object.keys(cp.blobs)), 'Unlisted change or empty commit');
    const owner = lane === 'integration' ? cp.sourceLane || (cp.tooling ? lane : undefined) : lane;
    requireValue(changed.some(p => isProduction(p, owner)), 'Production source required');
    for (const p of changed) {
      // Older integration checkpoints predate sourceLane. Their paths must still belong to a production lane.
      const allowed = owner ? owns(owner, p) : Object.keys(roles).some(r => owns(r, p));
      requireValue(allowed && after.get(p)?.mode === '100644' && (!before.has(p) || before.get(p).mode === '100644') && after.get(p).sha === cp.blobs[p], 'Path or blob mismatch: ' + p);
    }
  }
  async function publish(cp) {
    await checkDiff(cp);
    let live = await ref(branch);
    await checkPublicationPolicy(live);
    if (live === cp.parent) {
      const current = await checkpoint();
      requireValue(current.state === 'PREPARED' && current.prepared === cp.prepared, 'Prepared receipt was superseded');
      try {
        await call('update_ref', {repository_full_name: repo, branch_name: branch, expected_sha: cp.parent, sha: cp.prepared, force: false});
      } catch (err) {
        live = await ref(branch);
        if (!(await contains(live, cp.prepared))) throw err;
      }
      live = await ref(branch);
    }
    requireValue(await contains(live, cp.prepared), 'Branch moved; review saved work against ' + live);
    const latest = await checkpoint();
    if (latest.prepared === cp.prepared && latest.state === 'PREPARED') {
      await save({...cp, state:'VERIFIED', remote:live, lastVerifiedDelivery:cp.prepared});
    }
    return {status:'VERIFIED', lane, parent:cp.parent, commit:cp.prepared, remote:live, paths:cp.paths, tests:cp.tests, adoption:cp.adoption};
  }
  const [head, cp] = await Promise.all([ref(branch), checkpoint()]);
  if (cp.state === 'PREPARED' && (head === cp.parent || await contains(head, cp.prepared))) {
    if (job.dryRun && job.durableInbox && head !== cp.parent) {
      await checkDiff(cp);
      cp.state = 'VERIFIED'; // Git confirms earlier publication. This planner has read-only issue access.
    } else if (job.dryRun || job.prepareOnly) {
      await checkDiff(cp);
      await checkPublicationPolicy(head);
      return {status:'PREPARED', lane, branch, parent:cp.parent, commit:cp.prepared, paths:cp.paths, head};
    } else {
      return {...await publish(cp), recovered:true};
    }
  }
  if (!job.edits && !job.compose) {
    return {lane, branch, head, state:cp.state, prepared:cp.state === 'PREPARED' ? cp.prepared : null, lastVerified:cp.lastVerifiedDelivery};
  }
  requireValue(head === job.parent, 'Parent changed; refresh and reapply the scoped edit');
  requireValue(cp.state !== 'PREPARED' || job.supersedes === cp.prepared, 'Reconcile outstanding prepared commit ' + cp.prepared);
  requireValue(typeof job.message === 'string' && job.message.trim() && typeof job.tests === 'string' && job.tests.trim(), 'Supply a meaningful change summary and actual test evidence');
  const base = await treeAt(head);
  let editsToApply = job.edits;
  let owner = lane;
  let sourceBefore, sourceAfter;
  if (job.source || job.compose || job.sourceLane) {
    requireValue(lane === 'integration', 'Only integration composes worker changes');
    owner = job.sourceLane;
    requireValue(Object.hasOwn(roles, owner) && owner !== lane && shaPattern.test(job.source), 'Identify the reviewed source lane and commit');
    requireValue(await contains(await ref(roles[owner][0]), job.source), 'Source is outside worker history');
    const workerCommit = await get('/git/commits/' + job.source);
    requireValue(workerCommit.parents?.length === 1, 'Review single-parent worker commits individually');
    [sourceBefore, sourceAfter] = await Promise.all([treeAt(workerCommit.parents[0].sha), treeAt(job.source)]);
    if (job.compose) {
      const data = await get('/commits/' + job.source);
      const changedPaths = [...new Set([...sourceBefore.keys(), ...sourceAfter.keys()])].filter(p => sourceBefore.get(p)?.sha !== sourceAfter.get(p)?.sha || sourceBefore.get(p)?.mode !== sourceAfter.get(p)?.mode);
      requireValue(Array.isArray(data.files) && sameSet(changedPaths, data.files.map(f => f.filename)), 'Worker diff incomplete');
      editsToApply = [];
      for (const entry of data.files) {
        const path = entry.filename;
        const before = sourceBefore.get(path), after = sourceAfter.get(path), target = base.get(path);
        requireValue(owns(owner, path) && after?.mode === '100644' && (!before || before.mode === '100644'), 'Worker change needs manual composition: ' + path);
        if (target?.sha === after.sha) continue;
        const updated = await file(path, job.source);
        requireValue(updated.sha === after.sha && bytes(updated.content) === after.size, 'Incomplete worker content');
        if (!before) {
          requireValue(!target, 'New worker path conflicts: ' + path);
          editsToApply.push({path, before:null, after:updated.content});
          continue;
        }
        const old = await file(path, workerCommit.parents[0].sha);
        requireValue(old.sha === before.sha && bytes(old.content) === before.size && target, 'Worker preimage missing');
        if (target.sha === before.sha && old.content.length) {
          editsToApply.push({path, before:old.content, after:updated.content});
          continue;
        }
        // A diverged file is safe to compose only when every contextual hunk is
        // unique and replaying all hunks reconstructs the actual worker blob.
        requireValue(typeof entry.patch === 'string' && !entry.patch.includes('\\ No newline'), 'Review worker patch manually: ' + path);
        const hunks = [];
        for (const line of entry.patch.split('\n')) {
          if (line.startsWith('@@ ')) { hunks.push({path,before:'',after:''}); continue; }
          const hunk = hunks.at(-1);
          requireValue(hunk && [' ','+','-'].includes(line[0]), 'Incomplete patch: ' + path);
          if (line[0] !== '+') hunk.before += line.slice(1) + '\n';
          if (line[0] !== '-') hunk.after += line.slice(1) + '\n';
        }
        let replay = old.content;
        for (const hunk of hunks) {
          const at = replay.indexOf(hunk.before);
          requireValue(hunk.before && at >= 0 && replay.indexOf(hunk.before, at + 1) < 0, 'Ambiguous worker patch: ' + path);
          replay = replay.slice(0, at) + hunk.after + replay.slice(at + hunk.before.length);
        }
        requireValue(replay === updated.content, 'Incomplete worker patch: ' + path);
        const targetFile = await file(path, head);
        requireValue(targetFile.sha === target.sha && bytes(targetFile.content) === target.size, 'Incomplete integration target');
        for (const hunk of hunks) {
          const containsBefore = targetFile.content.includes(hunk.before);
          const firstAfter = hunk.after ? targetFile.content.indexOf(hunk.after) : -1;
          const applied = firstAfter >= 0 && targetFile.content.indexOf(hunk.after, firstAfter + 1) < 0;
          if (!containsBefore && applied) continue;
          requireValue(containsBefore && !applied, 'Worker hunk needs review on preview: ' + path);
          editsToApply.push(hunk);
        }
      }
      if (!editsToApply.length) return {status:'ALREADY_COMPOSED', head, source:job.source};
    }
  }
  const grouped = new Map();
  for (const edit of editsToApply) {
    requireValue(typeof edit.path === 'string' && typeof edit.after === 'string' && edit.after !== edit.before, 'Invalid edit');
    if (!grouped.has(edit.path)) grouped.set(edit.path, []);
    grouped.get(edit.path).push(edit);
  }
  requireValue([...grouped.keys()].some(p => isProduction(p, owner)), 'Tests alone do not deliver a product change');
  const updates = [];
  for (const [path, edits] of grouped) {
    requireValue(owns(owner, path), 'Outside assigned ownership: ' + path);
    const existing = base.get(path);
    requireValue(!existing || existing.mode === '100644', 'Unexpected file mode: ' + path);
    if (sourceAfter) requireValue(sourceAfter.get(path)?.mode === '100644' && sourceBefore.get(path)?.sha !== sourceAfter.get(path).sha, 'Worker commit did not change ' + path);
    let content = '';
    if (existing) {
      const f = await file(path, head);
      requireValue(f.sha === existing.sha && bytes(f.content) === existing.size, 'Incomplete pinned source: ' + path);
      content = f.content;
    }
    const original = content;
    for (const edit of edits) {
      if (edit.before === null) {
        requireValue(!existing && edits.length === 1 && edit.after.length > 0, 'New file already exists or is empty: ' + path);
        content = edit.after;
      } else {
        requireValue(typeof edit.before === 'string' && edit.before.length > 0, 'Empty edit anchor');
        const at = content.indexOf(edit.before);
        requireValue(at >= 0 && content.indexOf(edit.before, at + 1) === -1, 'Edit anchor missing or ambiguous: ' + path);
        content = content.slice(0, at) + edit.after + content.slice(at + edit.before.length);
      }
    }
    requireValue(content !== original, 'No change: ' + path);
    updates.push({path, content});
  }
  await checkPublicationPolicy(head);
  if (job.dryRun) return {status:'CHECKED', parent:head, paths:updates.map(u => u.path), ...(job.returnFiles ? {files:updates} : {})};
  const parentCommit = await get('/git/commits/' + head);
  const blobs = {};
  for (const update of updates) {
    const b = await call('create_blob', {repository_full_name:repo, content:update.content, encoding:'utf-8'});
    requireValue(shaPattern.test(b.sha), 'Blob creation failed');
    blobs[update.path] = b.sha;
  }
  const tree = await call('create_tree', {repository_full_name:repo, base_tree_sha:parentCommit.tree.sha,
    tree_elements:Object.entries(blobs).map(([path, sha]) => ({path, sha, type:'blob', mode:'100644'}))});
  requireValue(shaPattern.test(tree.sha), 'Tree creation failed');
  const created = await call('create_commit', {repository_full_name:repo, parent_sha:head, tree_sha:tree.sha, message:job.message});
  const next = {version:1, lane, branch, state:'PREPARED', parent:head, prepared:created.sha, paths:Object.keys(blobs), blobs,
    remote:head, tests:job.tests, adoption:job.source ? 'Composed from ' + job.source : (lane === 'integration' ? 'Integration tooling' : 'Pending integration'), lastVerifiedDelivery:cp.lastVerifiedDelivery};
  if (job.source) Object.assign(next, {sourceLane:owner, source:job.source});
  else if (lane === 'integration') next.tooling = true;
  if (cp.state === 'PREPARED') next.supersededPrepared = cp.prepared;
  await checkDiff(next);
  const fresh = await checkpoint();
  requireValue(fresh.state === cp.state && fresh.prepared === cp.prepared && await ref(branch) === head, 'Lane changed during preparation');
  await save(next);
  if (job.prepareOnly) return {status:'PREPARED', lane, branch, parent:head, commit:next.prepared, paths:next.paths, tests:next.tests};
  return publish(next);
})
