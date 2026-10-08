import test from 'node:test';
import assert from 'node:assert/strict';
import {releasePlan, compareVersions} from './release-plan.mjs';
const prefix = '';
const input = {version:'1.2.0', refType:'branch', refName:'main', commit:'a', tags:[]};
test('new reviewed source version creates a tag', () => {
  assert.deepEqual(releasePlan(input), {version:'1.2.0', tag:`${prefix}1.2.0`, commit:'a', release:true, createTag:true});
});
test('unchanged version at a later main commit does not move its tag', () => {
  assert.equal(releasePlan({...input,tags:[{tag:`${prefix}1.2.0`,commit:'old'}]}).release,false);
});
test('unpublished same-commit tag resumes; published release is immutable', () => {
  const retry={...input,refType:'tag',refName:`${prefix}1.2.0`,tags:[{tag:`${prefix}1.2.0`,commit:'a'}]};
  assert.equal(releasePlan(retry).createTag,false);
  assert.equal(releasePlan(retry).release,true);
  assert.equal(releasePlan({...retry,published:true}).release,false);
});
test('mismatch, absent/wrong-commit tag, downgrade and other branches fail', () => {
  assert.throws(()=>releasePlan({...input,refType:'tag',refName:`${prefix}1.1.0`}), /match/);
  assert.throws(()=>releasePlan({...input,refType:'tag',refName:`${prefix}1.2.0`}), /commit/);
  assert.throws(()=>releasePlan({...input,refType:'tag',refName:`${prefix}1.2.0`,tags:[{tag:`${prefix}1.2.0`,commit:'old'}]}), /commit/);
  assert.throws(()=>releasePlan({...input,tags:[{tag:`${prefix}2.0.0`,commit:'b'}]}), /older/);
  assert.throws(()=>releasePlan({...input,refName:'feature'}), /main/);
});
test('strict stable semver and numeric order', () => {
  for(const version of ['01.0.0','1.2','1.2.0-01','1.2.0+build',' 1.2.0']) assert.throws(()=>releasePlan({...input,version}));
  assert.equal(compareVersions('1.10.0','1.9.0'),1);
});
test('SwiftPM prereleases precede stable', () => {
  assert.equal(compareVersions('1.2.0-rc.1','1.2.0'),-1);
  assert.equal(releasePlan({...input,version:'1.2.0-rc.1'}).tag,'1.2.0-rc.1');
});
