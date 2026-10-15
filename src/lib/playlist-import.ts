import type { Track } from "./tracks";

/** Portable playlist metadata, never Spotify streaming audio. */
export type PlaylistWish = {
  title: string;
  artist: string;
  album: string;
  spotifyURL?: string;
};

export type ShelfPlaylist = {
  id: string;
  name: string;
  trackIds: string[];
  sourceURL?: string;
  wishes?: PlaylistWish[];
};

const MAX_PLAYLIST_BYTES = 2 * 1024 * 1024;
const MAX_SONGS = 5000;

function canonical(value: string): string {
  return value.toLowerCase().normalize("NFKD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]/g, "");
}

function key(value: string): string {
  return canonical(value.replace(/\s*[\[(]\s*(?:feat\.?|ft\.?|featuring)\b[^\])]*[\])]/gi, ""));
}

function rowsOf(text: string, delimiter: string): string[][] {
  const rows: string[][] = [];
  let field = "", row: string[] = [], quoted = false;
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    if (char === '"') {
      if (quoted && text[index + 1] === '"') { field += '"'; index++; }
      else if (!quoted && !field.trim()) { quoted = true; }
      else if (quoted) { quoted = false; }
      else { field += char; }
    } else if (char === delimiter && !quoted) {
      row.push(field.trim()); field = "";
    } else if ((char === "\r" || char === "\n") && !quoted) {
      if (char === "\r" && text[index + 1] === "\n") index++;
      row.push(field.trim()); field = "";
      if (row.some(Boolean)) rows.push(row);
      row = [];
    } else {
      field += char;
    }
  }
  if (quoted) throw new Error("The playlist has an unfinished quoted field.");
  if (field || row.length) {
    row.push(field.trim());
    if (row.some(Boolean)) rows.push(row);
  }
  return rows;
}

export function spotifyPlaylistLink(value: string): string | undefined {
  if (!value.trim()) return undefined;
  const raw = value.trim();
  const uri = /^spotify:playlist:([a-zA-Z0-9]{22})$/.exec(raw);
  if (uri) return `https://open.spotify.com/playlist/${uri[1]}`;
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:" || url.hostname !== "open.spotify.com") return undefined;
    const match = /^\/playlist\/([a-zA-Z0-9]{22})\/?$/.exec(url.pathname);
    return match ? `https://open.spotify.com/playlist/${match[1]}` : undefined;
  } catch { return undefined; }
}

function spotifyTrackLink(value: string): string | undefined {
  const id = /^(?:spotify:track:|https:\/\/open\.spotify\.com\/track\/)([a-zA-Z0-9]{22})(?:[/?#].*)?$/.exec(value);
  return id ? `https://open.spotify.com/track/${id[1]}` : undefined;
}

/** Spotify CSV exports from common playlist exporters, and tab-separated track lists. */
export function parsePlaylistText(input: string): PlaylistWish[] {
  if (new TextEncoder().encode(input).length > MAX_PLAYLIST_BYTES)
    throw new Error("Playlist files must be smaller than 2 MB.");
  const text = input.replace(/^\uFEFF/, "");
  const headerLine = text.split(/\r?\n/, 1)[0] ?? "";
  const delimiter = (headerLine.match(/\t/g)?.length ?? 0) > (headerLine.match(/,/g)?.length ?? 0) ? "\t" : ",";
  const rows = rowsOf(text, delimiter);
  if (!rows.length) throw new Error("This playlist file is empty.");
  const fields = rows[0].map(canonical);
  const column = (names: string[]) => fields.findIndex(item => names.includes(item));
  const titleCol = column(["trackname", "songtitle", "name", "title", "song", "track"]);
  if (titleCol < 0) throw new Error("A Track Name, Title or Name column is required.");
  const artistCol = column(["artistname", "artistnames", "artist", "artists"]);
  const albumCol = column(["albumname", "album", "release"]);
  const uriCol = column(["trackuri", "spotifyuri", "trackurl", "spotifyurl", "url"]);
  const cell = (row: string[], index: number) => index < 0 ? "" : (row[index] ?? "").trim();
  const wishes = rows.slice(1).map(row => ({
    title: cell(row, titleCol),
    artist: cell(row, artistCol),
    album: cell(row, albumCol),
    spotifyURL: spotifyTrackLink(cell(row, uriCol))
  })).filter(item => item.title);
  if (!wishes.length) throw new Error("No song titles were found in this playlist.");
  if (wishes.length > MAX_SONGS) throw new Error("Import up to 5,000 playlist entries at a time.");
  return wishes;
}

/** Never substitute the wrong recording when matching results are ambiguous. */
export function resolvePlaylist(playlist: ShelfPlaylist, tracks: Pick<Track,"id"|"name"|"artist">[]) {
  const byID = new Map(tracks.map(track => [track.id, track]));
  const ids = playlist.trackIds.filter((id, index) => byID.has(id) && playlist.trackIds.indexOf(id) === index);
  const used = new Set(ids);
  const missing: PlaylistWish[] = [];
  for (const wish of playlist.wishes ?? []) {
    const title = key(wish.title);
    const artist = key(wish.artist);
    if (!title) continue;
    const matches = tracks.filter(track => key(track.name) === title &&
      (!artist || (key(track.artist ?? "") !== "" &&
        (key(track.artist ?? "") === artist ||
         key(track.artist ?? "").includes(artist) || artist.includes(key(track.artist ?? ""))))));
    if (matches.some(track => used.has(track.id))) continue;
    if (matches.length === 1 && !used.has(matches[0].id)) {
      used.add(matches[0].id);
      ids.push(matches[0].id);
    } else {
      missing.push(wish);
    }
  }
  return { trackIds: ids, missing };
}
