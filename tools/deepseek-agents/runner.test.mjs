import test from 'node:test';
import assert from 'node:assert/strict';
import {agents, balanceFromResponse, getBalance, filesInScope, pathsFromPorcelain, ledgerForDate, setting} from './runner.mjs';

test('five distinct agents with domain-specific permissions', () => {
  assert.deepEqual(agents.map(a => a.id), ['mp3-playback','mp3-sources','mp3-ui','mp3-qa','mp3-integration']);
  assert.equal(filesInScope(['ios/MP3Shelf/Services/PlaybackController.swift'],agents[0]), true);
  assert.equal(filesInScope(['ios/MP3Shelf/Views/PlayerViews.swift'],agents[2]), true);
  assert.equal(filesInScope(['ios/MP3Shelf/Views/DownloadManagerView.swift'],agents[2]), false);
  assert.equal(filesInScope(['ios/MP3Shelf/Services/BackgroundAudioDownloader.swift'],agents[1]), true);
  assert.equal(filesInScope(['.github/workflows/ios-build.yml'],agents[4]), false);
});
test('path guard rejects traversal and wrong agent ownership', () => {
  assert.equal(filesInScope(['ios/Tests/example.swift','../secret'],agents[3]),false);
  assert.equal(filesInScope([],agents[3]),false);
  assert.equal(filesInScope(['ios/MP3Shelf/Views/MainView.swift'],agents[0]),false);
  assert.deepEqual(pathsFromPorcelain(' M ios/Tests/Test.swift\0?? ios/Tests/New.swift\0'),
    ['ios/Tests/Test.swift','ios/Tests/New.swift']);
  assert.throws(() => pathsFromPorcelain('R  ios/Tests/New.swift\0ios/Tests/Old.swift\0'),/rename\/copy/);
});
test('API balance refuses exhausted or unsupported account', () => {
  const data={is_available:true,balance_infos:[{currency:'USD',total_balance:'3.70'}]};
  assert.deepEqual(balanceFromResponse(data),{currency:'USD',amount:3.7});
  assert.throws(() => balanceFromResponse(data,'CNY'),/currency changed/);
  assert.throws(() => balanceFromResponse({is_available:false,balance_infos:[]}),/unavailable/);
});
test('daily budget resets with date, rotation persists', () => {
  assert.deepEqual(ledgerForDate({date:'2026-10-30',index:2,currency:'USD',spent:0.2},'2026-10-30'),
    {date:'2026-10-30',index:2,currency:'USD',spent:0.2});
  assert.equal(ledgerForDate({date:'2026-10-30',index:2,spent:0.2},'2026-10-31').spent,0);
  assert.equal(ledgerForDate({index:8}).index,3);
});
test('invalid environment caps do not permit a run', () => {
  assert.equal(setting('MP3_AGENT_TEST_UNSET',0.5,0,1),0.5);
  process.env.MP3_AGENT_TEST_BAD='Infinity';
  assert.throws(() => setting('MP3_AGENT_TEST_BAD',0.5,0,1),/Invalid/);
  delete process.env.MP3_AGENT_TEST_BAD;
});
test('read-only balance call attaches provider key without a paid model request',async()=>{
  let called;
  const result=await getBalance('test-value',async (url,options)=>{
    called={url,header:options.headers.Authorization};
    return {ok:true,json:async()=>({is_available:true,balance_infos:[]})};
  });
  assert.equal(called.url,'https://api.deepseek.com/user/balance');
  assert.equal(called.header,'Bearer test-value');
  assert.equal(result.is_available,true);
});
