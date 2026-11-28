import assert from 'node:assert/strict';
import {test} from 'node:test';
import {validateRequest} from './delivery-inbox.mjs';

const parent='a'.repeat(40), source='b'.repeat(40);
const request={lane:'ux',kind:'edit',message:'Name queue actions',parent,edits:[{path:'ios/MP3Shelf/Views/PlayerViews.swift',before:'label',after:'songLabel'}]};
test('a work order carries text edits or a reviewed source identity',()=>{
  validateRequest(request);
  validateRequest({kind:'compose',lane:'integration',sourceLane:'ux',source,message:'Compose the queue accessibility change'});
  validateRequest({kind:'resume',lane:'playback',parent,commit:source});
});
test('request data cannot select a release branch, command or workflow target',()=>{
  for (const change of [
    {lane:'main'}, {kind:'command'}, {parent:'main'}, {lane:'integration'}, {message:'headline\nsecond'},
    {edits:[{...request.edits[0],path:'.github/workflows/ci.yml'}]},
    {edits:[{...request.edits[0],path:'ios/MP3Shelf/Views/../../scripts/run.swift'}]}
  ]) assert.throws(()=>validateRequest({...request,...change}));
  assert.throws(()=>validateRequest({kind:'compose',lane:'ux',sourceLane:'playback',source,message:'Compose'}));
});
