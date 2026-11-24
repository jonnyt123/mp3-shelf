import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync,writeFileSync,rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { completedOfflineStatus, validateSignedInstallRecord,
  playlistProgressFromCatalog, runCompleteIPhoneJourney } from './run-iphone-playlist-acceptance.mjs';
const id='12345678-1234-1234-1234-123456789012';
const playlist='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const hash='b'.repeat(64);
function repo(){
  const root=mkdtempSync(join(tmpdir(),'mp3shelf-iphone-journey-'));
  execFileSync('git',['init','-q',root]);
  writeFileSync(join(root,'README.md'),'fixture source\n');
  execFileSync('git',['-C',root,'add','README.md']);
  execFileSync('git',['-C',root,'-c','user.name=QA','-c','user.email=qa@example.test',
    'commit','-qm','fixture']);
  const sha=execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim();
  return {root,sha};
}
function record(sha){
  return [
    '- Result: PASS','- Mode: install','- Checked commit: '+sha,
    '- Signed app executable SHA256: '+hash,
    '- Signed development build: PASS','- Signature verification: PASS',
    '- Device app installation: PASS','- Process launch request: PASS'
  ].join('\n');
}
test('requires exact clean source SHA and successful real signed install metadata',()=>{
  const sha='a'.repeat(40);
  assert.deepEqual(validateSignedInstallRecord(record(sha),sha),{sha,signedAppSHA256:hash});
  assert.throws(()=>validateSignedInstallRecord(record(sha),'c'.repeat(40)));
  assert.throws(()=>validateSignedInstallRecord(record(sha).replace('Device app installation: PASS','Device app installation: FAIL'),sha));
  assert.throws(()=>validateSignedInstallRecord(record(sha).replace(hash,'NOT_VERIFIED'),sha));
});
test('a real native on-device proof is required, not a pending report',()=>{
  assert.equal(completedOfflineStatus({schema:'mp3shelf-physical-offline-v1',status:'OFFLINE_PLAYBACK_PASS'}),'PASS');
  assert.equal(completedOfflineStatus({schema:'mp3shelf-physical-offline-v1',status:'FAIL'}),'WAITING');
  assert.equal(completedOfflineStatus({schema:'mp3shelf-physical-offline-v1',status:'FAIL',error:'failed'}),'FAILED');
  assert.equal(completedOfflineStatus({schema:'mock',status:'OFFLINE_PLAYBACK_PASS'}),'WAITING');
});
test('single guided run installs, arms, restarts offline, and collects without claiming hardware approval',async()=>{
  const x=repo(), phases=[], events=[];
  try{
    const result=await runCompleteIPhoneJourney({
      deviceID:id,playlistID:playlist,sha:x.sha,cwd:x.root,platform:'darwin',
      install:async(root,device,sha)=>{events.push('install');assert.equal(device,id);return validateSignedInstallRecord(record(sha),sha)},
      phase:async info=>{
        events.push(info.phase);phases.push(info.phase);
        return info.phase==='collect'?{
          offlinePlayback:'APP_INSTRUMENTED_PHYSICAL_PASS',
          backgroundTransfer:'APP_RECORDED_STAGING_AND_BACKGROUND_WAKE',
          physicalAcceptance:'INCOMPLETE',output:'/tmp/fixture-private-report'
        }: {physicalAcceptance:'INCOMPLETE'}
      },
      playlistStatus:async()=>{events.push('playlist');return events.filter(e=>e==='playlist').length<2
        ?{status:'WAITING',total:2,imported:1}:{status:'COMPLETE',total:2,imported:2};},
      offlinePrompt:async()=>{events.push('airplane-confirmation');},
      offlineStatus:async()=>{events.push('poll');return events.filter(e=>e==='poll').length<2?'WAITING':'PASS'},
      sleep:async()=>{events.push('sleep')}
    });
    assert.deepEqual(phases,['arm','offline','collect']);
    assert.deepEqual(events,['install','arm','playlist','sleep','playlist',
      'airplane-confirmation','offline','poll','sleep','poll','collect']);
    assert.equal(result.status,'OFFLINE_AND_CALLBACK_EVIDENCE_COLLECTED_NOT_APPROVED');
    assert.equal(result.physicalAcceptance,'INCOMPLETE');
    assert.equal(result.signedAppSHA256,hash);
  }finally{rmSync(x.root,{recursive:true,force:true})}
});
test('missing real playback or no background callback never yields false complete acceptance',async()=>{
 const x=repo();
 try{
  const calls=[];
  const common={
    deviceID:id,playlistID:playlist,sha:x.sha,cwd:x.root,platform:'darwin',
    install:async()=>({sha:x.sha,signedAppSHA256:hash}),
    phase:async ({phase})=>{
      calls.push(phase);
      return phase==='collect'?{offlinePlayback:'APP_INSTRUMENTED_PHYSICAL_PASS',
        backgroundTransfer:'NOT_VERIFIED',physicalAcceptance:'INCOMPLETE'}:{}
    },
    offlinePrompt:async()=>{},sleep:async()=>{},
    playlistStatus:async()=>({status:'COMPLETE',total:2,imported:2})
  };
  await assert.rejects(runCompleteIPhoneJourney({...common,offlineStatus:async()=> 'FAILED'}),/not verified/);
  assert(!calls.includes('collect'));
  calls.length=0;
  const pending=await runCompleteIPhoneJourney({...common,maxChecks:1,offlineStatus:async()=> 'PASS'});
  assert.equal(pending.status,'OFFLINE_EVIDENCE_COLLECTED_BACKGROUND_UNVERIFIED');
  assert.equal(pending.physicalAcceptance,'INCOMPLETE');
  assert(calls.includes('collect'));
 }finally{rmSync(x.root,{recursive:true,force:true})}
});
test('reject dirty checkout, Linux simulator mode and forged app identity',async()=>{
 const x=repo();
 try{
  await assert.rejects(runCompleteIPhoneJourney({deviceID:id,playlistID:playlist,sha:x.sha,platform:'linux'}),
    /REAL_IPHONE_REQUIRED/);
  writeFileSync(join(x.root,'untracked'),'not clean');
  await assert.rejects(runCompleteIPhoneJourney({deviceID:id,playlistID:playlist,sha:x.sha,
    cwd:x.root,platform:'darwin',install:async()=>{throw Error('must not install')}}),/dirty or stale/);
  rmSync(join(x.root,'untracked'));
  await assert.rejects(runCompleteIPhoneJourney({deviceID:id,playlistID:playlist,sha:x.sha,
    cwd:x.root,platform:'darwin',install:async()=>({sha:x.sha,signedAppSHA256:'NOT_VERIFIED'})}),
    /Signed install did not confirm/);
 }finally{rmSync(x.root,{recursive:true,force:true})}
});


test('playlist completion tracks all Spotify recordings without accepting unavailable entries',()=>{
  const p={id:playlist,sourceURL:'https://open.spotify.com/playlist/'+ 'A'.repeat(22)+'?si=share',
    sourceOrder:[{title:'One'},{title:'Two'}],
    trackIDs:['one','two'],missingTracks:[]};
  const library={playlists:[p],tracks:[{id:'one'},{id:'two'}]};
  assert.equal(playlistProgressFromCatalog(library,playlist).status,'COMPLETE');
  const downloading={...p,trackIDs:['one']};
  assert.equal(playlistProgressFromCatalog({...library,playlists:[downloading]},playlist).status,'WAITING');
  const unavailable={...p,missingTracks:['second']};
  assert.equal(playlistProgressFromCatalog({...library,playlists:[unavailable]},playlist).status,'UNAVAILABLE');
  const duplicate={...p,trackIDs:['one','one']};
  assert.equal(playlistProgressFromCatalog({...library,playlists:[duplicate]},playlist).status,'INVALID');
  const ghost={...p,trackIDs:['one','ghost']};
  assert.equal(playlistProgressFromCatalog({...library,playlists:[ghost]},playlist).status,'INVALID');
  const other={...p,sourceURL:'https://spotify-example.evil/playlist/'+ 'A'.repeat(22)};
  assert.equal(playlistProgressFromCatalog({...library,playlists:[other]},playlist).status,'WAITING');
});
test('no airplane-mode transition is requested for unavailable or incomplete playlist',async()=>{
  const x=repo(),events=[];
  try {
    const params={deviceID:id,playlistID:playlist,sha:x.sha,cwd:x.root,platform:'darwin',
      install:async()=>({sha:x.sha,signedAppSHA256:hash}),
      phase:async({phase})=>{events.push(phase);return{};},
      offlinePrompt:async()=>{throw Error('offline prompt must not appear');},
      sleep:async()=>{},maxChecks:2};
    await assert.rejects(runCompleteIPhoneJourney({...params,
      playlistStatus:async()=>({status:'UNAVAILABLE',total:2,imported:1,unavailable:1})}),/unavailable/);
    assert.deepEqual(events,['arm']);
    events.length=0;
    await assert.rejects(runCompleteIPhoneJourney({...params,
      playlistStatus:async()=>({status:'WAITING',total:2,imported:1})}),/Timed out/);
    assert.deepEqual(events,['arm']);
  } finally {rmSync(x.root,{recursive:true,force:true});}
});
