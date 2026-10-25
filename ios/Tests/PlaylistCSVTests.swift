import Foundation

func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
}

@main
enum PlaylistCSVTests {
    static func main() throws {
        let source = """
        Track Name,Artist Name(s),Album Name,Track URI
        "A Song, In Two Parts","Singer, Another",First,spotify:track:1TqHaKt6gS8L6bEx4JjUhy
        "Second \""Quoted\"" Song",Other,Next,https://open.spotify.com/track/abc
        """
        let wishes = try PlaylistCSV.parse(Data(source.utf8))
        check(wishes.count == 2, "quoted CSV row count")
        check(wishes[0].title == "A Song, In Two Parts", "embedded comma")
        check(wishes[1].title == "Second \"Quoted\" Song", "escaped quotes")
        check(wishes[0].spotifyURL?.contains("open.spotify.com/track/") == true, "Spotify URI conversion")

        let tab = "Track Name\tArtist Name\nHello\tA Singer\n"
        let tabRows = try PlaylistCSV.parse(Data(tab.utf8))
        check(tabRows.first?.artist == "A Singer", "TSV support")
        let owned = MusicTrack(title: "A Song, In Two Parts", artist: "Singer", album: "First", fileName: "1.mp3", originalFileName: "1.mp3", duration: 12)
        let savedWish = PlaylistWish(title: owned.title, artist: owned.artist,
                                     album: owned.album, spotifyURL: nil, durationSeconds: 12)
        check(MusicMatching.reusableOfflineTrack(for: savedWish, in: [owned])?.id == owned.id,
              "already downloaded identical recording can satisfy a second playlist")
        let wrongDuration = PlaylistWish(title: owned.title, artist: owned.artist,
                                         album: owned.album, spotifyURL: nil,
                                         durationSeconds: 185)
        check(MusicMatching.reusableOfflineTrack(for: wrongDuration, in: [owned]) == nil,
              "short previews never replace full-length playlist recordings")
        let smallDifference = PlaylistWish(title: owned.title, artist: owned.artist,
                                           album: owned.album, spotifyURL: nil,
                                           durationSeconds: 15.9)
        check(MusicMatching.reusableOfflineTrack(for: smallDifference, in: [owned])?.id == owned.id,
              "minor duration metadata rounding does not force a duplicate download")
        check(MusicMatching.reusableOfflineTrack(for: savedWish, in: [owned, owned]) == nil,
              "ambiguous duplicate library entries are never arbitrarily reused")
        check(MusicMatching.matchingTrack(for: wishes[0], in: [owned])?.id == owned.id, "artist list matching")
        check(MusicMatching.matchingTrack(for: wishes[0], in: []) == nil, "never claim an unowned song matched")
        let ambiguous = MusicTrack(title: owned.title, artist: owned.artist, album: owned.album, fileName: "2.mp3", originalFileName: "2.mp3", duration: 12)
        check(MusicMatching.matchingTrack(for: wishes[0], in: [owned, ambiguous]) == nil, "ambiguous recordings stay unmatched")
        let multilines = "Track Name,Artist Name\r\n\"A\nB\",Singer\r\n"
        let multilineRows = try PlaylistCSV.parse(Data(multilines.utf8))
        check(multilineRows.first?.title == "A\nB", "quoted multiline field")
        let bom = "\u{FEFF}Track Name,Artist Name\nExample,Someone\n"
        let bomRows = try PlaylistCSV.parse(Data(bom.utf8))
        check(bomRows.count == 1, "UTF-8 BOM")
        let saved = PersistedLibrary(tracks: [owned], playlists: [MusicPlaylist(name: "Test")])
        let restored = try JSONDecoder().decode(PersistedLibrary.self, from: JSONEncoder().encode(saved))
        check(restored.tracks.first?.id == owned.id, "library JSON roundtrip")
        check(restored.playlists.first?.name == "Test", "playlist JSON roundtrip")
        do {
            _ = try PlaylistCSV.parse(Data("Artist,Album\nA,B\n".utf8))
            fatalError("Missing title column should fail")
        } catch PlaylistCSVError.missingTitleColumn {
            print("PASS: invalid header rejected")
        }
        let requestedAudio = PlaylistWish(title: "Blue Sky", artist: "Eva Rivers",
                                          album: "First EP", spotifyURL: nil,
                                          durationSeconds: 188)
        check(SourceAudioIdentity.conflictingField(
            title: "Blue Sky", artist: "Eva Rivers", requested: requestedAudio) == nil,
            "matching MP3 metadata is accepted")
        check(SourceAudioIdentity.conflictingField(
            title: "Red Sunset", artist: "Eva Rivers",
            requested: requestedAudio) == .title,
            "contradictory embedded song title is rejected")
        check(SourceAudioIdentity.conflictingField(
            title: "Blue Sky", artist: "Different Performer",
            requested: requestedAudio) == .artist,
            "contradictory embedded artist is rejected")
        check(SourceAudioIdentity.conflictingField(
            title: nil, artist: nil, requested: requestedAudio) == nil,
            "untagged media is inconclusive, not falsely conflicting")
        check(SourceAudioIdentity.conflictingField(
            title: "Blue Sky", artist: "Eva Rivers ft. Guest",
            requested: requestedAudio) == nil,
            "credited collaborations retain the requested artist")
        check(SourceAudioIdentity.conflictingField(
            title: "Untitled", artist: "Unknown Artist",
            requested: requestedAudio) == nil,
            "generic metadata placeholders do not create false conflicts")
        let newTrack = PlaylistWish(title: "New Song", artist: "Fresh Artist",
                                    album: "New Album", spotifyURL: nil, durationSeconds: 201)
        let previous = [
            PlaylistWish(title: "First", artist: "Band", album: "Old",
                         spotifyURL: "https://open.spotify.com/track/1TqHaKt6gS8L6bEx4JjUhy",
                         durationSeconds: 180),
            PlaylistWish(title: "Second", artist: "Band", album: "Old",
                         spotifyURL: "https://open.spotify.com/track/0TqHaKt6gS8L6bEx4JjUhy",
                         durationSeconds: 190)
        ]
        let refreshed = [
            newTrack,
            PlaylistWish(title: "Second (updated)", artist: "Band", album: "New",
                         spotifyURL: previous[1].spotifyURL, durationSeconds: 191)
        ]
        let synced = SpotifyPlaylistSync.merge(previous: previous, latest: refreshed)
        check(synced.count == 2 && synced[0].id == newTrack.id &&
              synced[1].id == previous[1].id,
              "Spotify reimport preserves existing IDs, inserts new songs and removes old ones")
        check(synced[1].album == "New" && synced[1].durationSeconds == 191,
              "Spotify refresh updates metadata and preserves the original track identity")
        let duplicate = PlaylistWish(title: "Repeat", artist: "Band", album: "",
                                     spotifyURL: previous[0].spotifyURL, durationSeconds: 180)
        let duplicateOld = [previous[0], duplicate]
        let duplicateSync = SpotifyPlaylistSync.merge(
            previous: duplicateOld, latest: [duplicate, previous[0]])
        check(duplicateSync.map(\.id) == duplicateOld.map(\.id),
              "duplicate Spotify track occurrences keep distinct persisted IDs")
        let oldNoLink = PlaylistWish(title: "Unlinked Track", artist: "Band",
                                     album: "", spotifyURL: nil, durationSeconds: 222)
        let newNoLink = PlaylistWish(title: "Unlinked Track", artist: "Band",
                                     album: "Remastered", spotifyURL: nil, durationSeconds: 222.2)
        check(SpotifyPlaylistSync.merge(previous: [oldNoLink], latest: [newNoLink]).first?.id == oldNoLink.id,
              "CSV-origin entries use artist/title/duration for stable sync identity")
        let alternateCut = PlaylistWish(title: "Unlinked Track", artist: "Band",
                                         album: "", spotifyURL: nil, durationSeconds: 20)
        check(SpotifyPlaylistSync.merge(previous: [oldNoLink], latest: [alternateCut]).first?.id != oldNoLink.id,
              "preview-length alternate recordings cannot impersonate full track IDs")
        print("Playlist parser & matcher tests passed")
    }
}
