export type LyricLine = { id: number; time?: number; text: string };

/** Native-compatible LRC parser. Multiple timestamps on one line are supported. */
export function parseLyrics(input: string): LyricLine[] {
  const items: { time?: number; text: string }[] = [];
  const stamps = /\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]/g;
  for (const original of input.split(/\r?\n/)) {
    const found = Array.from(original.matchAll(stamps));
    const text = original.replace(stamps, "").trim();
    if (!text || text.startsWith("[")) continue;
    if (!found.length) {
      items.push({ text });
      continue;
    }
    for (const stamp of found) {
      const minutes = Number(stamp[1]), seconds = Number(stamp[2]);
      if (seconds >= 60) continue;
      const fraction = stamp[3] ? Number(stamp[3]) / Math.pow(10, stamp[3].length) : 0;
      items.push({ time: minutes * 60 + seconds + fraction, text });
    }
  }
  if (items.some(item => item.time !== undefined))
    items.sort((a,b) => (a.time ?? Infinity) - (b.time ?? Infinity));
  return items.map((item,id) => ({id,...item}));
}

export function currentLyricIndex(lines: LyricLine[], seconds: number): number {
  let result = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].time === undefined || lines[i].time! > seconds) break;
    result = i;
  }
  return result;
}
