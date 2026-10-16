/**
 * Browser crossfade: equal-power Web Audio GainNodes provide audio transitions
 * without relying on HTMLMediaElement.volume (read-only in iOS Safari).
 * Playback itself remains on native audio elements so Media Session works.
 */
export const MAX_CROSSFADE_SECONDS = 8;

export function safeCrossfadeSeconds(value: unknown): number {
 const n = typeof value === "number" ? value : Number(value);
 return Number.isFinite(n) ? Math.max(0, Math.min(MAX_CROSSFADE_SECONDS, Math.round(n))) : 0;
}

export function crossfadeGains(progress: number): { outgoing: number; incoming: number } {
 const x = Math.max(0, Math.min(1, Number.isFinite(progress) ? progress : 0));
 return { outgoing: Math.cos(x * Math.PI / 2), incoming: Math.sin(x * Math.PI / 2) };
}

export function shouldBeginCrossfade(
 position: number, duration: number, seconds: number, hasNext: boolean
): boolean {
 return hasNext && seconds > 0 && Number.isFinite(position) &&
  Number.isFinite(duration) && duration > seconds + 1 &&
  position >= duration - seconds && position < duration;
}

export class BrowserCrossfadeMixer {
 readonly context: AudioContext;
 private readonly gains = new Map<HTMLAudioElement, GainNode>();
 constructor(context: AudioContext) { this.context = context; }

 private gainFor(media: HTMLAudioElement): GainNode {
  const existing = this.gains.get(media);
  if (existing) return existing;
  const node = this.context.createGain();
  const source = this.context.createMediaElementSource(media);
  source.connect(node);
  node.connect(this.context.destination);
  this.gains.set(media,node);
  return node;
 }

 enable(media: HTMLAudioElement) {
  const gain = this.gainFor(media).gain, at = this.context.currentTime;
  gain.cancelScheduledValues(at);
  gain.setValueAtTime(1,at);
 }

 fade(from: HTMLAudioElement, to: HTMLAudioElement, duration: number): boolean {
  if (this.context.state !== "running" || !Number.isFinite(duration) || duration <= 0) return false;
  const outgoing = this.gainFor(from).gain, incoming = this.gainFor(to).gain;
  const now = this.context.currentTime;
  outgoing.cancelScheduledValues(now);
  incoming.cancelScheduledValues(now);
  outgoing.setValueAtTime(1,now);
  incoming.setValueAtTime(0,now);
  const outCurve = new Float32Array(65);
  const inCurve = new Float32Array(65);
  for (let i=0;i<65;i++) {
   const gains = crossfadeGains(i/64);
   outCurve[i] = gains.outgoing; inCurve[i] = gains.incoming;
  }
  outgoing.setValueCurveAtTime(outCurve,now,duration);
  incoming.setValueCurveAtTime(inCurve,now,duration);
  return true;
 }

 reset(media: HTMLAudioElement) {
  const gain = this.gains.get(media)?.gain;
  if (!gain) return;
  const at = this.context.currentTime;
  gain.cancelScheduledValues(at);
  gain.setValueAtTime(1,at);
 }

 close() { void this.context.close().catch(()=>{}); this.gains.clear(); }
}
