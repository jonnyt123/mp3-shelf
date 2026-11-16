#!/usr/bin/env node
/** Deliberate, isolated draft GitHub Release smoke test: synthetic assets only, never publish. */
import { execFileSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const REPO='jonnyt123/mp3-shelf', SHA=/^[0-9a-f]{40}$/;
const TAG=/^mp3shelf-upload-smoke-[0-9a-f]{12}-[0-9]{13}-[0-9a-f]{6}$/;
const digest=b=>createHash('sha256').update(b).digest('hex');

export function smokePreflight({ tag, sha, existing, workflows }){
 const issues=[];
 if(!SHA.test(sha??'') || !TAG.test(tag??'') || !tag.includes(sha?.slice(0,12)??''))
   issues.push('Use a unique dedicated smoke namespace bound to an exact commit.');
 if(existing !== null) issues.push('Smoke tag or release already exists; refuse overwrite.');
 if(!Array.isArray(workflows) ||
     workflows.some(content=>typeof content!=='string' ||
       /(?:^|\n)\s*(?:push|release|create):/m.test(content) ||
       /(?:^|\n)\s*on\s*:\s*\[[^\]]*(?:push|release|create)/m.test(content)))
   issues.push('Workflows may trigger paid tag/release Actions; refuse remote smoke.');
 return issues;
}
function command(exe,args,options={}){
 return execFileSync(exe,args,{encoding:'utf8',timeout:120000,maxBuffer:2*1024*1024,
   stdio:['ignore','pipe','pipe'],...options}).trim();
}
function api(path){return JSON.parse(command('gh',['api','-H','Accept: application/vnd.github+json',path]));}
function readSmokeRelease(tag){
 try{return api('repos/'+REPO+'/releases/tags/'+tag);}
 catch(error){if(/404|Not Found/.test(String(error.stderr??error.message)))return null;throw error;}
}
function releaseRef(tag){
 try{return api('repos/'+REPO+'/git/ref/tags/'+tag);}
 catch(error){if(/404|Not Found/.test(String(error.stderr??error.message)))return null;throw error;}
}
export function verifiedDraftUpload(release, expected){
 const assets=release?.assets;
 if(release?.draft!==true || release?.tag_name!==expected.tag ||
    release?.target_commitish!==expected.sha || !Array.isArray(assets) ||
    assets.length!==2) return false;
 const hashes=new Map([[expected.zip,expected.zipSHA],[expected.manifest,expected.manifestSHA]]);
 for(const asset of assets){
   if(!hashes.has(asset.name) || asset.digest!=='sha256:'+hashes.get(asset.name))
     return false;
   hashes.delete(asset.name);
 }
 return hashes.size===0;
}
function workflowContents(root,sha){
 const names=command('git',['-C',root,'ls-tree','-r','--name-only',sha,'.github/workflows'])
   .split('\n').filter(Boolean);
 if(names.length>25)return null;
 return names.map(name=>command('git',['-C',root,'show',sha+':'+name]));
}
export async function runDraftSmoke({root=process.cwd(),platform=process.platform,
                                    allowLive=false}={}){
 if(platform!=='darwin')throw Error('MAC_AND_GH_REQUIRED: this is a real draft-upload test on a Mac.');
 if(!allowLive)throw Error('EXPLICIT_OPT_IN_REQUIRED: use --live-draft-smoke to create a disposable draft.');
 root=resolve(root);
 const sha=command('git',['-C',root,'rev-parse','HEAD']);
 const dirty=command('git',['-C',root,'status','--porcelain','--untracked-files=all']);
 const origin=command('git',['-C',root,'remote','get-url','origin']);
 if(dirty || !SHA.test(sha) ||
   !/^(https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)jonnyt123\/mp3-shelf(?:\.git)?\/?$/.test(origin))
   throw Error('Smoke test requires the clean authoritative MP3 Shelf checkout.');
 command('gh',['auth','status']);
 const tag='mp3shelf-upload-smoke-'+sha.slice(0,12)+'-'+Date.now()+'-'+randomBytes(3).toString('hex');
 const workflows=workflowContents(root,sha);
 if(workflows===null)throw Error('Workflow count was too high to audit safely.');
 const issues=smokePreflight({tag,sha,existing:readSmokeRelease(tag)??releaseRef(tag),workflows});
 if(issues.length)throw Error(issues.join('; '));
 const temp=mkdtempSync(join(tmpdir(),'mp3shelf-unpublished-smoke-'));
 const dir=join(temp,'source'),downloadDir=join(temp,'download');
 mkdirSync(dir);mkdirSync(downloadDir);
 const zipName='mp3shelf-draft-smoke-'+sha.slice(0,12)+'.zip';
 const jsonName='mp3shelf-draft-smoke-'+sha.slice(0,12)+'.manifest.json';
 const payload=Buffer.from('MP3 Shelf draft upload transport check ONLY\nSource '+sha+'\n');
 const source=join(dir,'fixture.txt'),archive=join(temp,zipName),manifest=join(temp,jsonName);
 writeFileSync(source,payload,{flag:'wx',mode:0o600});
 // Create a deliberately tiny, non-user-data test archive.
 command('zip',['-q','-X','-j',archive,source]);
 const zipSHA=digest(readFileSync(archive));
 writeFileSync(manifest,JSON.stringify({
   schema:'mp3shelf-draft-upload-smoke-v1',sourceCommit:sha,
   synthetic:true,neverPublish:true,zipSHA256:zipSHA
 },null,2)+'\n',{flag:'wx',mode:0o600});
 const manifestSHA=digest(readFileSync(manifest));
 const expected={tag,sha,zip:zipName,manifest:jsonName,zipSHA,manifestSHA};
 let created=false, verified=false, cleanupError=null;
 try{
   command('gh',['release','create',tag,'--repo',REPO,'--draft','--target',sha,
     '--title','UNPUBLISHED MP3 Shelf synthetic upload test '+sha.slice(0,12),
     '--notes','Synthetic archive only. Do not publish. Automatically deleted after checksum verification.',
     archive,manifest]);
   created=true;
   const remote=readSmokeRelease(tag);
   if(!verifiedDraftUpload(remote,expected))
     throw Error('Draft GitHub Release remote asset SHA-256 digests did not match.');
   command('gh',['release','download',tag,'--repo',REPO,'--dir',downloadDir]);
   if(digest(readFileSync(join(downloadDir,zipName)))!==zipSHA ||
      digest(readFileSync(join(downloadDir,jsonName)))!==manifestSHA)
     throw Error('Downloaded draft assets differ from locally generated synthetic bytes.');
   verified=true;
 }finally{
   // Cleanup is mandatory, including on a failed upload. Never touch an
   // existing release/tag: this unique name was verified absent above.
   try{
     if(created || readSmokeRelease(tag) || releaseRef(tag))
       command('gh',['release','delete',tag,'--repo',REPO,'--yes','--cleanup-tag']);
   }catch(error){cleanupError=String(error.message).slice(0,350);}
   rmSync(temp,{recursive:true,force:true});
 }
 if(cleanupError)throw Error('Draft smoke cleanup was not confirmed: '+cleanupError);
 if(!verified)throw Error('Draft Release verification was incomplete');
 if(readSmokeRelease(tag) || releaseRef(tag))
   throw Error('Disposable smoke Release or tag still exists after cleanup');
 return{status:'DRAFT_ASSET_UPLOAD_DOWNLOAD_VERIFIED_AND_CLEANED',sourceSha:sha,
   assetCount:2,tagWasNeverPublished:true,zipSHA256:zipSHA};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 const [flag,root,...extra]=process.argv.slice(2);
 if(flag!=='--live-draft-smoke'||extra.length){
   console.error('Usage: node scripts/smoke-draft-release.mjs --live-draft-smoke [LOCAL_REPO_ROOT]');
   process.exitCode=2;
 } else runDraftSmoke({root,allowLive:true})
   .then(out=>console.log(JSON.stringify(out,null,2)))
   .catch(error=>{console.error('DRAFT_RELEASE_SMOKE_BLOCKED: '+error.message);process.exitCode=1});
}
