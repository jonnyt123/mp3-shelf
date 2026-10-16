/** Browser-side import of audio the listener is authorized to download.
 * Browser CORS requirements apply; this does not download Spotify streams.
 */
const MAX_MP3_BYTES = 100 * 1024 * 1024;
const DENIED_HOSTS = ["spotify.com","spotifycdn.com","scdn.co","youtube.com","youtu.be","googlevideo.com","soundcloud.com"];

export function allowedAudioURL(input: string): URL {
  let url: URL;
  try { url = new URL(input.trim()); }
  catch { throw new Error("Enter a complete HTTPS direct audio file URL."); }
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password)
    throw new Error("Only public HTTPS audio file URLs are supported.");
  const host = url.hostname.toLowerCase();
  if (DENIED_HOSTS.some(part => host === part || host.endsWith("." + part)))
    throw new Error("Streaming service URLs are not direct MP3 downloads.");
  if (/^(localhost|127\.|10\.|192\.168\.|169\.254\.|0\.|::1$)/i.test(host))
    throw new Error("Local or private network URLs are not supported.");
  return url;
}

export type AudioDownloadOptions = {
  signal?: AbortSignal;
  onProgress?: (bytesReceived: number, totalBytes?: number) => void;
};

export async function downloadAuthorizedMP3(
  input: string, request: typeof fetch = fetch, options: AudioDownloadOptions = {}
): Promise<File> {
  const url = allowedAudioURL(input);
  let response: Response;
  try { response = await request(url.toString(), {
    redirect: "follow", cache: "no-store", signal: options.signal
  }); }
  catch (error) {
    if (options.signal?.aborted) throw new Error("Download cancelled.");
    throw new Error("Could not download this file. The source may block browser CORS requests.");
  }
  if (!response.ok) throw new Error(`The download failed (HTTP ${response.status}).`);
  allowedAudioURL(response.url || url.toString());
  const mime = response.headers.get("content-type")?.split(";")[0].trim().toLowerCase() ?? "";
  if (!["audio/mpeg","audio/mp3","audio/x-mpeg","application/octet-stream"].includes(mime))
    throw new Error("That link did not return a direct MP3 audio file.");
  const length = Number(response.headers.get("content-length") || "0");
  if (Number.isFinite(length) && length > MAX_MP3_BYTES)
    throw new Error("Audio files over 100 MB are not supported.");

  const reader = response.body?.getReader();
  if (!reader) throw new Error("Your browser could not read the audio response.");
  const chunks: Uint8Array<ArrayBuffer>[] = [];
  let bytes = 0;
  try {
    while (true) {
      if (options.signal?.aborted) throw new Error("Download cancelled.");
      const {done, value} = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > MAX_MP3_BYTES) throw new Error("Audio files over 100 MB are not supported.");
      chunks.push(new Uint8Array(value));
      options.onProgress?.(bytes, length > 0 ? length : undefined);
    }
    if (options.signal?.aborted) throw new Error("Download cancelled.");
  } catch (error) {
    await reader.cancel().catch(() => {});
    if (options.signal?.aborted) throw new Error("Download cancelled.");
    throw error;
  } finally {
    reader.releaseLock();
  }
  if (bytes < 128) throw new Error("The audio file is empty or incomplete.");
  const first = chunks[0] ?? new Uint8Array();
  // Simple MP3 container validation: ID3 header or MPEG frame sync.
  const id3 = first.length >= 3 && first[0] === 0x49 && first[1] === 0x44 && first[2] === 0x33;
  const frame = first.length >= 2 && first[0] === 0xff && (first[1] & 0xe0) === 0xe0;
  if (!id3 && !frame) throw new Error("The downloaded file does not appear to be MP3 audio.");

  let name = url.pathname.split("/").at(-1) || "downloaded-audio.mp3";
  try { name = decodeURIComponent(name); } catch { /* Keep safe escaped name. */ }
  name = name.replace(/[^a-zA-Z0-9.()_ -]/g, "_").slice(0, 120);
  const fileName = /\.mp3$/i.test(name) ? name : name.replace(/\.[^.]+$/, "") + ".mp3";
  return new File(chunks, fileName, { type: "audio/mpeg", lastModified: Date.now() });
}
