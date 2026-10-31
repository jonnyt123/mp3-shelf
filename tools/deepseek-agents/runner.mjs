#!/usr/bin/env node
// MP3 Shelf: five sequential DeepSeek/OpenCode agents with a shared soft budget.
import { spawn } from 'node:child_process';
import { mkdir, open, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const agents = [
  { id: 'mp3-playback', files: [/^ios\/MP3Shelf\/Services\/(PlaybackController|MusicLibrary|PortableShelfArchive)\.swift$/, /^ios\/MP3Shelf\/Models\/MusicModels\.swift$/, /^ios\/Tests\//, /^src\/lib\/(backup(\.test)?\.ts|tracks\.ts)$/] },
  { id: 'mp3-sources', files: [/^ios\/MP3Shelf\/Services\/(SpotifyService|AudioSourceFinder|BackgroundAudioDownloader)\.swift$/, /^ios\/MP3Shelf\/Models\/SourceDiscoveryJob\.swift$/, /^ios\/MP3Shelf\/Views\/DownloadManagerView\.swift$/, /^ios\/Tests\//] },
  { id: 'mp3-ui', files: [/^ios\/MP3Shelf\/Views\/(?!DownloadManagerView\.swift$)[^/]+\.swift$/, /^ios\/DESIGN_SYSTEM\.md$/] },
  { id: 'mp3-qa', files: [/^ios\/Tests\//, /^ios\/DEVICE_QA\.md$/, /^src\/lib\/[^/]+\.test\.ts$/] },
  { id: 'mp3-integration', files: [/^ios\/MP3Shelf\.xcodeproj\//, /^ios\/MP3Shelf\/MP3ShelfApp\.swift$/, /^ios\/README\.md$/, /^ios\/scripts\/(?!run-on-iphone\.sh$)[^/]+$/] }
];
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const stateDir = path.resolve(root, '../.mp3-shelf-agent-state');
const worktrees = path.resolve(root, '../mp3-shelf-agent-worktrees');
const ledgerFile = path.join(stateDir, 'ledger.json');
const lockFile = path.join(stateDir, 'runner.lock');
const approvalDir = path.join(stateDir, 'approved');

export function setting(name, fallback, min = 0, max = 100) {
  if (process.env[name] == null || process.env[name] === '') return fallback;
  const v = Number(process.env[name]);
  if (!Number.isFinite(v) || v < min || v > max) throw Error('Invalid ' + name);
  return v;
}
export function balanceFromResponse(data, existingCurrency) {
  if (!data || data.is_available !== true || !Array.isArray(data.balance_infos)) throw Error('DeepSeek balance unavailable');
  const rows = data.balance_infos.map(x => ({ currency: x.currency, amount: Number(x.total_balance) }))
    .filter(x => ['USD','CNY'].includes(x.currency) && Number.isFinite(x.amount) && x.amount >= 0);
  const row = rows.find(x => x.currency === existingCurrency) || rows.find(x => x.currency === 'USD') || rows[0];
  if (!row) throw Error('No supported balance currency');
  if (existingCurrency && row.currency !== existingCurrency) throw Error('Balance currency changed, cannot combine spend');
  return row;
}
export async function getBalance(apiKey, request = fetch) {
  if (!apiKey) throw Error('DEEPSEEK_API_KEY is not configured in the runner host');
  const response = await request('https://api.deepseek.com/user/balance', {
    headers: { Authorization: 'Bearer ' + apiKey, Accept: 'application/json' },
    signal: AbortSignal.timeout(15000)
  });
  if (!response.ok) throw Error('DeepSeek balance HTTP ' + response.status);
  return response.json();
}
export function filesInScope(paths, agent) {
  return paths.length > 0 && paths.every(p =>
    p && !p.startsWith('/') && !p.split('/').includes('..') && agent.files.some(x => x.test(p)));
}
export function pathsFromPorcelain(buf) {
  const entries = buf.split('\0').filter(Boolean);
  return entries.map(e => {
    if (e.length < 4 || e[2] !== ' ' || /[RC]/.test(e.slice(0,2))) throw Error('Unreviewed rename/copy or malformed git status');
    return e.slice(3);
  });
}
export function ledgerForDate(saved, date = new Date().toISOString().slice(0,10)) {
  const s = saved && typeof saved === 'object' ? saved : {};
  return {
    date,
    index: Number.isInteger(s.index) ? ((s.index % agents.length) + agents.length) % agents.length : 0,
    currency: typeof s.currency === 'string' ? s.currency : null,
    spent: s.date === date && Number.isFinite(s.spent) ? Math.max(0,s.spent) : 0
  };
}
function exec(command, args, cwd, ms = 90000, env = process.env) {
  return new Promise((resolve, reject) => {
    const p = spawn(command, args, {cwd, env, stdio:['ignore','pipe','pipe']});
    let output = '';
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; p.kill('SIGTERM'); setTimeout(() => p.kill('SIGKILL'), 5000).unref(); }, ms);
    const collect = b => { output = (output + b.toString()).slice(-12000); };
    p.stdout.on('data',collect); p.stderr.on('data',collect);
    p.once('error', err => {clearTimeout(timer);reject(err);});
    p.once('close', code => {
      clearTimeout(timer);
      if (code === 0 && !timedOut) resolve(output);
      else reject(Error(command + ' failed (' + (timedOut ? 'timeout' : code) + '): ' + output.slice(-1500)));
    });
  });
}
async function loadLedger() {
  try { return ledgerForDate(JSON.parse(await readFile(ledgerFile,'utf8'))); }
  catch (err) { if (err.code === 'ENOENT') return ledgerForDate(null); throw err; }
}
async function saveLedger(s) {
  await writeFile(ledgerFile + '.tmp', JSON.stringify(s,null,2) + '\n', {mode:0o600});
  await rename(ledgerFile + '.tmp',ledgerFile);
}
async function getLock() {
  await mkdir(stateDir,{recursive:true,mode:0o700});
  const lock = await open(lockFile,'wx',0o600).catch(err => {
    if (err.code === 'EEXIST') throw Error('Another agent supervisor may be running; inspect ' + lockFile);
    throw err;
  });
  await lock.writeFile(String(process.pid) + '\n');
  await lock.close();
  return () => rm(lockFile,{force:true});
}
async function getWorktree(agent) {
  const dir = path.join(worktrees, agent.id);
  const branch = 'agent/' + agent.id;
  if (existsSync(dir)) {
    const actual = (await exec('git',['branch','--show-current'],dir)).trim();
    if (actual !== branch) throw Error('Existing worktree branch mismatch: ' + dir);
    return dir;
  }
  await mkdir(worktrees,{recursive:true});
  const base = process.env.MP3_AGENT_BASE_REF || 'agent/mp3-deepseek-low-cost-worker';
  if (!/^[\w./-]+$/.test(base) || base.startsWith('-') || base.includes('..')) throw Error('Unsafe base branch');
  await exec('git',['fetch','origin','refs/heads/' + base + ':refs/remotes/origin/' + base],root);
  const found = (await exec('git',['branch','--list',branch],root)).trim();
  const args = found ? ['worktree','add',dir,branch] : ['worktree','add','-b',branch,dir,'refs/remotes/origin/' + base];
  await exec('git',args,root);
  return dir;
}
async function runOne() {
  const unlock = await getLock();
  try {
    const s = await loadLedger();
    const cap = setting('MP3_AGENT_DAILY_CAP',0.50,0,100);
    const minimum = setting('MP3_AGENT_MIN_BALANCE',0.25,0,100);
    const seconds = setting('MP3_AGENT_MAX_RUN_SECONDS',480,60,1800);
    const agent = process.env.MP3_AGENT_ROLE
      ? agents.find(x => x.id === process.env.MP3_AGENT_ROLE) : agents[s.index];
    if (!agent) throw Error('Unknown MP3_AGENT_ROLE');
    if (cap === 0 || s.spent >= cap) { console.log('Local daily limit reached; no model request'); return; }
    const key = process.env.DEEPSEEK_API_KEY;
    const before = balanceFromResponse(await getBalance(key),s.currency);
    if (before.amount < minimum) { console.log('Insufficient balance; no model request'); return; }
    const cwd = await getWorktree(agent);
    const startDirty = pathsFromPorcelain(await exec('git',['status','--porcelain=v1','-z','--untracked-files=all'],cwd));
    if (startDirty.length) throw Error('Worktree has unreviewed changes: ' + startDirty.join(', '));
    const env = {...process.env};
    for (const name of ['GH_TOKEN','GITHUB_TOKEN','GIT_ASKPASS','OPENAI_API_KEY','ANTHROPIC_API_KEY']) delete env[name];
    console.log('Running ' + agent.id + ' with one DeepSeek Flash session (no GitHub Actions)');
    let failure = null;
    try {
      await exec('opencode',['run','--auto','--standalone','--agent',agent.id,
        '--model','deepseek/deepseek-flash',
        'Implement one high-priority safe, testable MP3 Shelf feature or fix within your owned files. Read relevant code and issue #22 as local context permits. Keep output short. Do not commit, push, open PRs or merge. Run focused local tests when available. Release requires physical-iPhone gate #6.'],
        cwd, seconds*1000, env);
    } catch(err) { failure = err; }
    // Reconcile spending even for failures/timeouts. Account balance change is only a soft cost estimate.
    try {
      const after = balanceFromResponse(await getBalance(key),before.currency);
      s.spent += Math.max(0,before.amount - after.amount);
      s.currency = before.currency;
    } finally {
      s.index = (s.index + 1) % agents.length;
      await saveLedger(s);
    }
    const files = pathsFromPorcelain(await exec('git',['status','--porcelain=v1','-z','--untracked-files=all'],cwd));
    if (files.length && !filesInScope(files,agent)) throw Error('Out-of-scope changes; no commit: ' + files.join(', '));
    if (failure) throw Error('Agent failed; files retained but not committed: ' + failure.message);
    if (!files.length) { console.log('No code edits; spending recorded'); return; }
    await exec('git',['diff','--check'],cwd);
    await exec('git',['add','--',...files],cwd);
    await exec('git',['diff','--cached','--check'],cwd);
    // The trusted supervisor, rather than the model, runs available local checks.
    // Native iOS compilation is explicitly deferred to the independent Mac worker.
    const testEnv={...process.env};
    for(const k of ['DEEPSEEK_API_KEY','GH_TOKEN','GITHUB_TOKEN','OPENAI_API_KEY','ANTHROPIC_API_KEY'])delete testEnv[k];
    await exec('node',['--test','tools/deepseek-agents/runner.test.mjs','tools/deepseek-agents/publish.test.mjs','tools/deepseek-agents/mac/mac-publisher.test.mjs','tools/deepseek-agents/cloudflare/worker.test.mjs'],cwd,120000,testEnv);
    if(files.some(p=>/^(src\/|tests\/|package\.json$|package-lock\.json$|next\.config\.)/.test(p))) {
      await exec('npm',['test'],cwd,180000,testEnv);
      await exec('npm',['run','typecheck'],cwd,180000,testEnv);
    }
    const postFiles=pathsFromPorcelain(await exec('git',['status','--porcelain=v1','-z','--untracked-files=all'],cwd));
    if(postFiles.length!==files.length || postFiles.some(p=>!files.includes(p))) throw Error('Tests changed file inventory; refuse commit');
    await exec('git',['diff','--check'],cwd);
    await exec('git',['diff','--cached','--check'],cwd);
    await exec('git',['-c','user.name=MP3 Shelf Agent','-c','user.email=agent@users.noreply.github.com',
      'commit','-m','agent(' + agent.id + '): tested scoped milestone [skip ci]'],cwd);
    const sha = (await exec('git',['rev-parse','HEAD'],cwd)).trim();
    const approval={role:agent.id,sha,files,diffCheck:'pass',nodeGuardTests:'pass',
      webChecks:files.some(p=>/^(src\/|tests\/|package\.json$|package-lock\.json$|next\.config\.)/.test(p))?'pass':'not-applicable',
      macXcode:'pending',physicalIphone:'not-verified',createdAt:new Date().toISOString()};
    await mkdir(approvalDir,{recursive:true,mode:0o750});
    const pending=path.join(approvalDir,agent.id+'.json.tmp');
    await writeFile(pending,JSON.stringify(approval,null,2)+'\n',{mode:0o640});
    await rename(pending,path.join(approvalDir,agent.id+'.json'));
    console.log('VALIDATED LOCAL commit ' + sha + ' (broker may publish draft; Mac QA pending). Spend today ' + s.spent.toFixed(4) + ' ' + s.currency);
  } finally { await unlock(); }
}
async function main() {
  const mode = process.argv[2] || '--dry-run';
  if (mode === '--dry-run') {
    console.log(JSON.stringify({provider:'DeepSeek',model:'deepseek-flash',agents:agents.map(x=>x.id),
      concurrency:1,dailyCapInAccountCurrency:0.50,chatgptScheduledTasks:0,remoteServiceActivated:false},null,2));
  } else if (mode === '--status') {
    const b = balanceFromResponse(await getBalance(process.env.DEEPSEEK_API_KEY));
    const s = await loadLedger();
    console.log(JSON.stringify({balance:b,spentToday:s.spent,nextAgent:agents[s.index].id},null,2));
  } else if (mode === '--once') {
    await runOne();
  } else if (mode === '--loop') {
    const idle = setting('MP3_AGENT_IDLE_SECONDS',900,60,86400);
    for (;;) {
      try { await runOne(); } catch(err) { console.error('Worker paused on error: ' + err.message); }
      await new Promise(resolve => setTimeout(resolve,idle*1000));
    }
  } else throw Error('Use --dry-run, --status, --once or --loop');
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(err => {console.error(err.message);process.exitCode=1;});
}
