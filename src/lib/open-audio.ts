import { allowedAudioURL } from "./direct-audio";

/**
 * Strictly normalize Openverse results: only records with a known
 * open license and an HTTPS landing page may be presented.
 * The media URL is a candidate, not a promise of an MP3 download.
 */
export type OpenAudioResult = {
  id: string;
  title: string;
  artist: string;
  provider: string;
  license: string;
  licenseURL: string;
  sourceURL: string;
  downloadURL?: string;
};

const LICENSES = new Set(["cc0", "pdm", "by", "by-sa"]);
const DOWNLOAD_EXTENSIONS = /\.mp3(?:$|[?#])/i;

function publicHTTPS(value: unknown): string | undefined {
  if (typeof value !== "string") return;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password ? url.href : undefined;
  } catch { return; }
}

export function normalizeOpenverseAudio(input: unknown): OpenAudioResult[] {
  if (!input || typeof input !== "object") return [];
  const obj = input as { results?: unknown };
  if (!Array.isArray(obj.results)) return [];
  const list: OpenAudioResult[] = [];
  const seen = new Set<string>();
  for (const item of obj.results.slice(0, 24)) {
    if (!item || typeof item !== "object") continue;
    const row = item as Record<string, unknown>;
    const license = typeof row.license === "string" ? row.license.toLowerCase() : "";
    const licenseURL = publicHTTPS(row.license_url);
    const sourceURL = publicHTTPS(row.foreign_landing_url);
    const url = publicHTTPS(row.url);
    const id = typeof row.id === "string" ? row.id : "";
    const title = typeof row.title === "string" ? row.title.trim() : "";
    if (!LICENSES.has(license) || !licenseURL || !sourceURL ||
        !id || !title || seen.has(id)) continue;
    seen.add(id);
    let downloadURL: string | undefined;
    const type = typeof row.filetype === "string" ? row.filetype.toLowerCase() : "";
    if (url && (DOWNLOAD_EXTENSIONS.test(url) || ["mp3", "audio/mpeg"].includes(type))) {
      try { downloadURL = allowedAudioURL(url).href; } catch { /* link-only result */ }
    }
    list.push({
      id,
      title: title.slice(0, 180),
      artist: typeof row.creator === "string" ? row.creator.slice(0, 140) : "Unknown creator",
      provider: typeof row.provider === "string" ? row.provider.slice(0, 80) : "Openverse",
      license: license.toUpperCase(),
      licenseURL,
      sourceURL,
      ...(downloadURL ? { downloadURL } : {})
    });
  }
  return list;
}

export function discoveryQuery(value: unknown): string {
  if (typeof value !== "string") throw new Error("Enter a song or artist.");
  const query = value.replace(/\s+/g, " ").trim();
  if (query.length < 2 || query.length > 100)
    throw new Error("Search must be 2 to 100 characters long.");
  return query;
}
