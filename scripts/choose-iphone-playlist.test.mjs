import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync,writeFileSync,rmSync,symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spotifyPlaylistChoices, selectPlaylist, choosePlaylistFromFile }
  from './choose-iphone-playlist.mjs';
const id1='11111111-1111-1111-1111-111111111111';
const id2='22222222-2222-2222-2222-222222222222';
const source='https://open.spotify.com/playlist/'+ 'A'.repeat(22) + '?si=shared';
function catalog() {
 return {playlists:[{id:id1,name:'Drive Mix',sourceURL:source,
   sourceOrder:[{title:'A'},{title:'B'}],trackIDs:[id1]}]};
}
test('the one valid playlist is selected without prompting for a UUID',()=>{
 const choices=spotifyPlaylistChoices(catalog());
 assert.equal(choices.length,1);
 assert(choices[0].label.includes('Drive Mix (1/2 downloaded)'));
 assert.equal(selectPlaylist(choices,{chooser:()=>{throw Error('No prompt required')}}),id1);
});
test('multiple playlists offer human readable labels, not hidden UUID entry',()=>{
 const data=catalog();
 data.playlists.push({...data.playlists[0],id:id2,name:'Evening Set',trackIDs:[]});
 const choices=spotifyPlaylistChoices(data);
 assert.equal(choices.length,2);
 assert.equal(selectPlaylist(choices,{chooser:labels=>{
   assert(labels[0].includes('Evening Set'));
   return labels[0];
 }}),id2);
 assert.throws(()=>selectPlaylist(choices,{chooser:()=>null}),/selected/);
});
test('untrusted source or duplicate playlist identity never enters selection',()=>{
 const data=catalog();
 data.playlists.push({...data.playlists[0]});
 data.playlists.push({...data.playlists[0],id:id2,sourceURL:'https://open.spotify.com.evil/playlist/'+'A'.repeat(22)});
 assert.equal(spotifyPlaylistChoices(data).length,1);
 data.playlists[0].sourceURL='http://open.spotify.com/playlist/'+'A'.repeat(22);
 assert.equal(spotifyPlaylistChoices(data).length,0);
});
test('catalog selection is read-only and refuses symlinks and unusable files',()=>{
 const tmp=mkdtempSync(join(tmpdir(),'mp3shelf-choice-'));
 try {
   const file=join(tmp,'library.json'),link=join(tmp,'linked.json');
   const data=JSON.stringify(catalog());
   writeFileSync(file,data);
   symlinkSync(file,link);
   assert.equal(choosePlaylistFromFile(file),id1);
   assert.equal(JSON.stringify(catalog()),data);
   assert.throws(()=>choosePlaylistFromFile(link),/Unsafe/);
   assert.throws(()=>choosePlaylistFromFile(join(tmp,'missing.json')));
 } finally {rmSync(tmp,{recursive:true,force:true});}
});
