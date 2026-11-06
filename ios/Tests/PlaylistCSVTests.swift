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

        let namespace = UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!
        let appleSong = AppleMusicTrackSnapshot(id: 10, title: " First ", artist: "Band, Inc.", album: "Album", duration: 201.5)
        let appleSnapshot = AppleMusicPlaylistSnapshot(id: 42, name: "Apple playlist", items: [
            appleSong,
            AppleMusicTrackSnapshot(id: 11, title: "Second", artist: "Artist", album: "Next", duration: 180),
            appleSong
        ])
        let appleWishes = try appleSnapshot.wishes(namespace: namespace)
        check(appleWishes.map(\.title) == ["First", "Second", "First"] && Set(appleWishes.map(\.id)).count == 3,
              "Apple Music keeps source order and distinct duplicate occurrences")
        check(appleWishes[0].artistNames == ["Band, Inc."] && appleWishes[0].durationSeconds == 201.5 &&
              appleWishes[0].spotifyURL == nil && appleWishes[0].appleMusicItemID == namespace.uuidString + ":10",
              "Apple Music keeps fractional duration, band names and provider identity")
        var renamedApple = appleWishes[0]
        renamedApple.id = UUID()
        renamedApple.title = "Corrected title"
        let syncedApple = SpotifyPlaylistSync.merge(previous: appleWishes, latest: [renamedApple, appleWishes[2]])
        check(syncedApple.map(\.id) == [appleWishes[0].id, appleWishes[2].id] && syncedApple[0].title == "Corrected title",
              "Apple Music refresh preserves occurrence IDs while updating metadata")
        let anotherDevice = try appleSnapshot.wishes(namespace: UUID())
        check(SpotifyPlaylistSync.merge(previous: appleWishes, latest: anotherDevice).map(\.id) == anotherDevice.map(\.id),
              "device-local media IDs cannot collide with another installation")
        let appleID = AppleMusicLibraryIdentity.key(namespace: namespace, persistentID: UInt64.max)
        check(AppleMusicLibraryIdentity.canonical(appleID) == appleID &&
              AppleMusicLibraryIdentity.canonical(namespace.uuidString + ":0") == nil &&
              AppleMusicLibraryIdentity.canonical("invalid:42") == nil,
              "source IDs preserve UInt64 precision and reject invalid identities")
        check(ImportedPlaylistIdentity.key(sourceURL: nil, appleMusicLibraryID: appleID) !=
              ImportedPlaylistIdentity.key(sourceURL: "https://open.spotify.com/playlist/0123456789ABCDEFGHIJKL", appleMusicLibraryID: nil),
              "Apple Music and Spotify source identities stay separate")
        let unknownDuration = try AppleMusicPlaylistSnapshot(id: 42, name: "Unknown duration", items: [
            AppleMusicTrackSnapshot(id: 10, title: "Song", artist: "Artist", album: "", duration: .nan)
        ]).wishes(namespace: namespace)
        check(unknownDuration[0].durationSeconds == nil, "unknown duration cannot become a false zero-length match")
        var rejectedAppleSnapshots = 0
        for bad in [
            AppleMusicPlaylistSnapshot(id: 42, name: "Empty", items: []),
            AppleMusicPlaylistSnapshot(id: 42, name: "Incomplete", items: [
                appleSong, AppleMusicTrackSnapshot(id: 11, title: "", artist: "Artist", album: "", duration: 180)]),
            AppleMusicPlaylistSnapshot(id: 42, name: "Podcast", items: [
                AppleMusicTrackSnapshot(id: 11, title: "Episode", artist: "Host", album: "", duration: 180, isMusic: false)])
        ] {
            do {
                _ = try bad.wishes(namespace: namespace)
                fatalError("FAIL: incomplete or unsupported Apple Music playlist was silently imported")
            } catch is AppleMusicPlaylistSnapshot.ImportFailure { rejectedAppleSnapshots += 1 }
        }
        check(rejectedAppleSnapshots == 3, "invalid Apple Music snapshots fail atomically rather than dropping entries")
        var appleList = MusicPlaylist(name: "Apple library list")
        appleList.appleMusicLibraryID = appleID
        appleList.sourceOrder = appleWishes
        appleList.missingTracks = appleWishes
        let restoredApple = try JSONDecoder().decode(MusicPlaylist.self, from: JSONEncoder().encode(appleList))
        check(restoredApple.appleMusicLibraryID == appleID && restoredApple.sourceOrder == appleWishes,
              "Apple Music source identities survive app persistence")
        let appleCopy = appleList.localCopy()
        check(appleCopy.appleMusicLibraryID == nil && appleCopy.sourceOrder[0].appleMusicItemID == appleWishes[0].appleMusicItemID &&
              appleCopy.sourceOrder[0].artistNames == appleWishes[0].artistNames,
              "local copies preserve Apple Music matching metadata with independent playlist identity")

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
        let preview = MusicTrack(title: owned.title, artist: owned.artist, album: owned.album,
                                 fileName: "preview.mp3", originalFileName: "preview.mp3",
                                 duration: 28)
        check(MusicMatching.reusableOfflineTrack(for: savedWish, in: [preview, owned])?.id == owned.id,
              "a compatible full recording is reused despite a same-name short edit")
        check(MusicMatching.reusableOfflineTrack(for: wrongDuration, in: [preview, owned]) == nil,
              "wrong duration is not counted as downloaded by playlist reconciliation")
        let fullLength = PlaylistWish(title: owned.title, artist: owned.artist,
                                      album: owned.album, spotifyURL: nil, durationSeconds: 185)
        let previewLength = PlaylistWish(title: owned.title, artist: owned.artist,
                                         album: owned.album, spotifyURL: nil, durationSeconds: 28)
        check(!MusicMatching.sameRequestedRecording(fullLength, previewLength),
              "different song versions must retain independent download tickets")
        check(MusicMatching.sameRequestedRecording(savedWish, smallDifference),
              "same recording tolerates minor duration metadata differences")
        let withoutDuration = PlaylistWish(title: owned.title, artist: owned.artist,
                                           album: owned.album, spotifyURL: nil)
        check(!MusicMatching.sameRequestedRecording(savedWish, withoutDuration),
              "unknown duration cannot silently take over a known-duration transfer")
        check(MusicMatching.sameRequestedRecording(withoutDuration, withoutDuration),
              "legacy CSV wishes without duration still deduplicate exact requests")
        let differentArtist = PlaylistWish(title: owned.title, artist: "A Different Band",
                                           album: owned.album, spotifyURL: nil, durationSeconds: 12)
        check(!MusicMatching.sameRequestedRecording(savedWish, differentArtist),
              "artist mismatch cannot deduplicate independent recordings")
        let otherFull = MusicTrack(title: owned.title, artist: owned.artist, album: owned.album,
                                   fileName: "full2.mp3", originalFileName: "full2.mp3", duration: 12.5)
        check(MusicMatching.reusableOfflineTrack(for: savedWish, in: [owned, otherFull]) == nil,
              "two compatible full-length recordings remain ambiguous")
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
        let missingEntry = PlaylistWish(title: "Missing", artist: "Artist", album: "Album", spotifyURL: nil, durationSeconds: 180)
        var originalPlaylist = MusicPlaylist(name: "Original")
        originalPlaylist.trackIDs = [owned.id, owned.id]
        originalPlaylist.sourceOrder = [missingEntry]
        originalPlaylist.missingTracks = [missingEntry]
        originalPlaylist.sourceURL = "https://open.spotify.com/playlist/example"
        originalPlaylist.portableBackupID = "restored-playlist"
        var localCopy = originalPlaylist.localCopy()
        check(localCopy.id != originalPlaylist.id && localCopy.trackIDs == originalPlaylist.trackIDs,
              "local copy has independent identity and preserves exact audio order")
        check(localCopy.sourceURL == nil && localCopy.portableBackupID == nil,
              "local copy cannot collide with Spotify refresh or archive restore identity")
        check(localCopy.sourceOrder.first?.id != missingEntry.id &&
              localCopy.missingTracks.first?.id == localCopy.sourceOrder.first?.id &&
              localCopy.sourceOrder.first?.durationSeconds == 180,
              "copied missing wishes retain duration and use consistent fresh identities")
        var legacyPlaylist = MusicPlaylist(name: "Legacy")
        legacyPlaylist.missingTracks = [missingEntry]
        let legacyCopy = legacyPlaylist.localCopy()
        check(legacyCopy.missingTracks.count == 1 && legacyCopy.sourceOrder.count == 1,
              "local copy preserves legacy missing entries without source order")
        let copiedRoundtrip = try JSONDecoder().decode(MusicPlaylist.self, from: JSONEncoder().encode(localCopy))
        check(copiedRoundtrip.id == localCopy.id && copiedRoundtrip.sourceOrder == localCopy.sourceOrder,
              "local copy identities survive persistence")
        localCopy.trackIDs.removeAll()
        check(originalPlaylist.trackIDs.count == 2, "editing copied playlist does not modify original")
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
        // A large imported Spotify playlist must match exactly the same
        // recordings as the old strict full-library scan, without repeatedly
        // walking every unrelated title for each entry.
        let largeLibrary: [MusicTrack] = (0..<3_000).map { number in
            MusicTrack(title: "Offline Song \(number)",
                       artist: "Performer \(number % 31)",
                       album: "Collection", fileName: "track-\(number).mp3",
                       originalFileName: "track-\(number).mp3",
                       duration: Double(175 + number % 40))
        }
        let largeIndex = OfflineTrackIndex(tracks: largeLibrary)
        for number in stride(from: 0, to: 3_000, by: 137) {
            let wish = PlaylistWish(title: "Offline Song \(number)",
                                    artist: "Performer \(number % 31)",
                                    album: "", spotifyURL: nil,
                                    durationSeconds: Double(175 + number % 40))
            check(largeIndex.reusableTrack(for: wish)?.id ==
                  MusicMatching.reusableOfflineTrack(for: wish, in: largeLibrary)?.id,
                  "indexed large-library match exactly preserves strict metadata rules")
        }
        let twoCuts = [
            MusicTrack(title: "Same Song", artist: "One Band", album: "",
                       fileName: "long.mp3", originalFileName: "long.mp3", duration: 240),
            MusicTrack(title: "Same Song", artist: "One Band", album: "",
                       fileName: "short.mp3", originalFileName: "short.mp3", duration: 90)
        ]
        let versioned = OfflineTrackIndex(tracks: twoCuts)
        let longWish = PlaylistWish(title: "Same Song", artist: "One Band",
                                    album: "", spotifyURL: nil, durationSeconds: 241)
        check(versioned.reusableTrack(for: longWish)?.id == twoCuts[0].id,
              "index rejects a different-duration cut rather than picking either")
        check(versioned.reusableTrack(for: longWish, isAvailable: { $0.id != twoCuts[0].id }) == nil,
              "missing long recording cannot be replaced by an available short cut")
        check(versioned.reusableTrack(for: longWish, isAvailable: { _ in true })?.id == twoCuts[0].id,
              "available exact recording retains the expected match")
        let unknownDuration = PlaylistWish(title: "Same Song", artist: "One Band",
                                           album: "", spotifyURL: nil)
        check(versioned.reusableTrack(for: unknownDuration) == nil,
              "ambiguous same-name recordings remain unmatched")
        let missingWish = PlaylistWish(title: "Absent track", artist: "One Band",
                                       album: "", spotifyURL: nil)
        check(largeIndex.reusableTrack(for: missingWish) == nil,
              "unknown tracks never get guessed from another artist/title")
        print("Playlist parser & matcher tests passed")
    }
}
