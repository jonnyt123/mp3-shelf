import { describe, expect, it } from "vitest";
import { parsePlaylistText, resolvePlaylist, spotifyPlaylistLink, type ShelfPlaylist } from "./playlist-import";

describe("Spotify metadata playlist importer", () => {
  it("parses Spotify exported CSV with quotes, commas, escaped quotes and track links", () => {
    const text = '\uFEFFTrack Name,Artist Name,Album Name,Track URI\r\n' +
      '"Look, ""Again""","Artist, Jr.",An Album,spotify:track:0123456789ABCDEFGHIJKL\r\n' +
      'Second,Another,Album,';
    const wishes = parsePlaylistText(text);
    expect(wishes).toHaveLength(2);
    expect(wishes[0]).toEqual({
      title: 'Look, "Again"', artist: "Artist, Jr.", album: "An Album",
      spotifyURL: "https://open.spotify.com/track/0123456789ABCDEFGHIJKL"
    });
    expect(wishes[1].title).toBe("Second");
  });

  it("parses TSV and ignores blank lines", () => {
    expect(parsePlaylistText("Title\tArtist\tAlbum\nSong\tCreator\tRelease\n\n")).toEqual([
      { title: "Song", artist: "Creator", album: "Release", spotifyURL: undefined }
    ]);
  });

  it("rejects files without headers or with unclosed quoted values", () => {
    expect(() => parsePlaylistText("Foo,Bar\nx,y")).toThrow("Track Name");
    expect(() => parsePlaylistText('Track Name,Artist\n"broken,artist')).toThrow("unfinished");
    expect(() => parsePlaylistText("Track Name\n")).toThrow("No song titles");
  });

  it("accepts only valid Spotify playlist links", () => {
    expect(spotifyPlaylistLink("spotify:playlist:0123456789ABCDEFGHIJKL")).toBe(
      "https://open.spotify.com/playlist/0123456789ABCDEFGHIJKL"
    );
    expect(spotifyPlaylistLink("https://open.spotify.com/playlist/0123456789ABCDEFGHIJKL?si=abc")).toBe(
      "https://open.spotify.com/playlist/0123456789ABCDEFGHIJKL"
    );
    expect(spotifyPlaylistLink("https://open.spotify.com.evil.invalid/playlist/0123456789ABCDEFGHIJKL")).toBeUndefined();
    expect(spotifyPlaylistLink("http://open.spotify.com/playlist/0123456789ABCDEFGHIJKL")).toBeUndefined();
  });

  it("matches local tracks conservatively and leaves ambiguous songs missing", () => {
    const playlist: ShelfPlaylist = {
      id: "p", name: "List", trackIds: [],
      wishes: [
        { title: "Blue (feat. Guest)", artist: "SINGER", album: "" },
        { title: "Two", artist: "", album: "" },
        { title: "Unknown", artist: "Nobody", album: "" }
      ]
    };
    const tracks = [
      { id: "1", name: "Blue", artist: "Singer" },
      { id: "2", name: "Two", artist: "One" },
      { id: "3", name: "Two", artist: "Other" }
    ];
    const result = resolvePlaylist(playlist, tracks);
    expect(result.trackIds).toEqual(["1"]);
    expect(result.missing.map(x => x.title)).toEqual(["Two", "Unknown"]);
  });

  it("retains manually assigned tracks and does not duplicate matched IDs", () => {
    const playlist: ShelfPlaylist = { id: "p", name: "List", trackIds: ["a"],
      wishes: [{ title: "Song", artist: "Artist", album: "" }] };
    expect(resolvePlaylist(playlist, [{ id: "a", name: "Song", artist: "Artist" }]))
      .toEqual({ trackIds: ["a"], missing: [] });
  });
});
