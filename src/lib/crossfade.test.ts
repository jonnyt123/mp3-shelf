import{describe,it,expect}from"vitest";
import{crossfadeGains,safeCrossfadeSeconds,shouldBeginCrossfade}from"./crossfade";
describe("equal-power crossfade policy",()=>{
 it("starts loudness-preserving curves at the correct endpoints",()=>{
  expect(crossfadeGains(0).outgoing).toBeCloseTo(1);
  expect(crossfadeGains(0).incoming).toBeCloseTo(0);
  expect(crossfadeGains(1).outgoing).toBeCloseTo(0);
  expect(crossfadeGains(1).incoming).toBeCloseTo(1);
  const midpoint=crossfadeGains(0.5);
  expect(midpoint.outgoing**2+midpoint.incoming**2).toBeCloseTo(1);
 });
 it("clamps invalid settings and out-of-range progress",()=>{
  expect(safeCrossfadeSeconds(999)).toBe(8);
  expect(safeCrossfadeSeconds(-3)).toBe(0);
  expect(safeCrossfadeSeconds("not a number")).toBe(0);
  expect(crossfadeGains(-2).outgoing).toBe(1);
  expect(crossfadeGains(2).incoming).toBe(1);
 });
 it("will not overlap tracks if there is no next song or the file is too short",()=>{
  expect(shouldBeginCrossfade(97,100,4,true)).toBe(true);
  expect(shouldBeginCrossfade(98,100,4,false)).toBe(false);
  expect(shouldBeginCrossfade(1,5,4,true)).toBe(false);
  expect(shouldBeginCrossfade(99,100,0,true)).toBe(false);
  expect(shouldBeginCrossfade(NaN,100,4,true)).toBe(false);
  expect(shouldBeginCrossfade(100,100,4,true)).toBe(false);
 });
});