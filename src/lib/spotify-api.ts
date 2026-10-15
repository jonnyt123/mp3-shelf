import type { PlaylistWish } from "./playlist-import";

export const spotifyClientID = process.env.NEXT_PUBLIC_SPOTIFY_CLIENT_ID?.trim() ?? "";

export type SpotifyPlaylistSummary = { id: string; name: string; collaborative: boolean; sourceURL: string };
type OAuthState = { verifier: string; state: string; redirect: string; started: number };
const KEY = "mp3-shelf.spotify-auth";

function urlSafe(bytes: Uint8Array): string {
  return btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join(""))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function beginSpotifyAuthorization(): Promise<void> {
  if (!spotifyClientID) throw new Error("Spotify connection needs the site's Spotify Client ID to be configured.");
  if (!crypto?.subtle || !crypto.getRandomValues) throw new Error("Secure browser access is required to connect Spotify.");
  const verifier = urlSafe(crypto.getRandomValues(new Uint8Array(48)));
  const state = urlSafe(crypto.getRandomValues(new Uint8Array(24)));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  const redirect = window.location.origin + "/";
  sessionStorage.setItem(KEY, JSON.stringify({ verifier, state, redirect, started: Date.now() } satisfies OAuthState));
  const url = new URL("https://accounts.spotify.com/authorize");
  url.searchParams.set("client_id", spotifyClientID);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("redirect_uri", redirect);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("code_challenge", urlSafe(digest));
  url.searchParams.set("scope", "playlist-read-private playlist-read-collaborative");
  url.searchParams.set("state", state);
  window.location.assign(url.toString());
}

/** Returns undefined if the current URL is not an OAuth return. Tokens remain in memory only. */
export async function finishSpotifyAuthorization(): Promise<string | undefined> {
  const locationURL = new URL(window.location.href);
  if (!locationURL.searchParams.has("code") && !locationURL.searchParams.has("error")) return;
  const code = locationURL.searchParams.get("code");
  const returnedState = locationURL.searchParams.get("state");
  const error = locationURL.searchParams.get("error");
  for (const key of ["code", "state", "error"]) locationURL.searchParams.delete(key);
  window.history.replaceState(null, "", locationURL.pathname + locationURL.search + locationURL.hash);
  const saved = sessionStorage.getItem(KEY);
  sessionStorage.removeItem(KEY);
  if (error) throw new Error("Spotify sign-in was cancelled or denied.");
  if (!code || !saved) throw new Error("Spotify sign-in was interrupted. Please connect again.");
  let context: OAuthState;
  try { context = JSON.parse(saved) as OAuthState; }
  catch { throw new Error("Spotify sign-in data was lost. Please connect again."); }
  if (!returnedState || returnedState !== context.state || Date.now() - context.started > 10 * 60_000)
    throw new Error("Spotify sign-in expired or failed security verification. Please connect again.");
  const response = await fetch("https://accounts.spotify.com/api/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: spotifyClientID, grant_type: "authorization_code", code,
      redirect_uri: context.redirect, code_verifier: context.verifier
    })
  });
  if (!response.ok) throw new Error("Spotify could not complete sign-in. Check the registered redirect URL.");
  const result: { access_token?: string } = await response.json();
  if (!result.access_token) throw new Error("Spotify returned no access token.");
  return result.access_token;
}

async function spotifyGet<T>(token: string, path: string): Promise<T> {
  const response = await fetch(`https://api.spotify.com/v1${path}`, {
    headers: { Authorization: `Bearer ${token}` }, cache: "no-store"
  });
  if (!response.ok) {
    if (response.status === 403) throw new Error(
      "Spotify only permits access to playlists you own or collaborate on for this app. Use CSV export for other playlists."
    );
    if (response.status === 401) throw new Error("Spotify sign-in expired. Connect again.");
    if (response.status === 429) throw new Error("Spotify rate limit reached. Try again later.");
    throw new Error(`Spotify could not load this playlist (HTTP ${response.status}).`);
  }
  return response.json() as Promise<T>;
}

export async function listSpotifyPlaylists(token: string): Promise<SpotifyPlaylistSummary[]> {
  const list: SpotifyPlaylistSummary[] = [];
  for (let offset = 0; offset < 1000; offset += 50) {
    const page = await spotifyGet<{items?: {id:string;name:string;collaborative?:boolean}[];total?:number}>(
      token, `/me/playlists?limit=50&offset=${offset}`
    );
    for (const item of page.items ?? []) {
      if (/^[A-Za-z0-9]{22}$/.test(item.id)) list.push({
        id: item.id, name: item.name, collaborative: Boolean(item.collaborative),
        sourceURL: `https://open.spotify.com/playlist/${item.id}`
      });
    }
    if ((page.items?.length ?? 0) < 50 || offset + 50 >= (page.total ?? 0)) break;
  }
  return list;
}

type SpotifyTrackObject = {
  type?: string;
  name?: string;
  artists?: { name?: string }[];
  album?: { name?: string };
  external_urls?: { spotify?: string };
};
export function spotifyItemsToWishes(items: {
  item?: SpotifyTrackObject | null;
  track?: SpotifyTrackObject | null;
}[]): PlaylistWish[] {
  return items.map(row => row.item ?? row.track).filter((track): track is SpotifyTrackObject =>
    track?.type === "track" && Boolean(track.name?.trim())
  ).map(track => ({
    title: track.name!.trim(),
    artist: (track.artists ?? []).map(artist => artist.name).filter(Boolean).join(", "),
    album: track.album?.name ?? "",
    spotifyURL: /^https:\/\/open\.spotify\.com\/track\/[a-zA-Z0-9]{22}(?:\?.*)?$/.test(track.external_urls?.spotify ?? "")
      ? track.external_urls!.spotify!.split("?")[0] : undefined
  }));
}

export async function importSpotifyPlaylist(token: string, id: string): Promise<PlaylistWish[]> {
  if (!/^[A-Za-z0-9]{22}$/.test(id)) throw new Error("Invalid Spotify playlist ID.");
  const wishes: PlaylistWish[] = [];
  for (let offset = 0; offset < 5000; offset += 50) {
    const page = await spotifyGet<{items?: {item?: SpotifyTrackObject|null;track?: SpotifyTrackObject|null}[];total?:number}>(
      token, `/playlists/${id}/items?limit=50&offset=${offset}`
    );
    wishes.push(...spotifyItemsToWishes(page.items ?? []));
    if ((page.items?.length ?? 0) < 50 || offset + 50 >= (page.total ?? 0)) break;
  }
  if (!wishes.length) throw new Error("Spotify returned no usable song metadata for this playlist.");
  return wishes;
}
