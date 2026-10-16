import{describe,it,expect}from"vitest";
import{BrowserCrossfadeMixer,crossfadeGains,safeCrossfadeSeconds,shouldBeginCrossfade}from"./crossfade";
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
 it("schedules both media decks on Web Audio while reusing each routed source",()=>{
  const gains:{scheduled:number[][];cancels:number[];values:number[]}[]=[];
  let sources=0;
  const ctx={
   state:"running",currentTime:15,
   destination:{},
   createGain:()=>{
    const result={scheduled:[] as number[][],cancels:[] as number[],values:[] as number[]};
    gains.push(result);
    return {gain:{
      cancelScheduledValues:(at:number)=>result.cancels.push(at),
      setValueAtTime:(value:number)=>result.values.push(value),
      setValueCurveAtTime:(curve:Float32Array,_at:number,_duration:number)=>result.scheduled.push([...curve])
    },connect:()=>{}};
   },
   createMediaElementSource:()=>{sources++;return{connect:()=>{}};},
   close:async()=>{}
  };
  const engine=new BrowserCrossfadeMixer(ctx as unknown as AudioContext);
  const a={} as HTMLAudioElement,b={} as HTMLAudioElement;
  expect(engine.fade(a,b,4)).toBe(true);
  expect(sources).toBe(2);
  expect(gains[0].scheduled[0][0]).toBeCloseTo(1);
  expect(gains[0].scheduled[0].at(-1)).toBeCloseTo(0);
  expect(gains[1].scheduled[0][0]).toBeCloseTo(0);
  expect(gains[1].scheduled[0].at(-1)).toBeCloseTo(1);
  engine.reset(b);
  engine.fade(b,a,2);
  expect(sources).toBe(2);
  expect(gains[1].cancels.length).toBeGreaterThan(0);
  engine.close();
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