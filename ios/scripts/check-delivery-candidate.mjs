import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';

const temp = process.env.RUNNER_TEMP;
const checkout = join(temp,'mp3-candidate');
const files = JSON.parse(readFileSync(join(temp,'mp3-paths.json'),'utf8'));
const env = {PATH:process.env.PATH,HOME:process.env.HOME,TMPDIR:temp,LANG:'C.UTF-8'};
function run(command,args) {
  console.log('+',command,...args);
  execFileSync(command,args,{cwd:checkout,env,stdio:'inherit',timeout:120000});
}
run('swiftc',['--version']);
for (const path of files) run('swiftc',['-frontend','-parse',path]);
const suites = [
  ['ios/MP3Shelf/Models/PlaybackOrder.swift','ios/Tests/PlaybackOrderTests.swift'],
  ['ios/MP3Shelf/Services/LyricsParser.swift','ios/Tests/LyricsParserTests.swift']
];
for (const [source,test] of suites) {
  if (!files.includes(source) && !files.includes(test)) continue;
  const binary = join(temp,'mp3-' + test.split('/').pop().replace('.swift',''));
  run('swiftc',[source,test,'-o',binary]); run(binary,[]);
}
if (files.includes('ios/Tests/SpotifyRefreshTests.swift')) run('swift',['ios/Tests/SpotifyRefreshTests.swift']);
console.log('Linux checks complete. Xcode, VoiceOver and physical-device acceptance require separate evidence.');
