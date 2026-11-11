import Foundation

@main
struct PortableShelfArchiveTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp3shelf-archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let audio = folder.appendingPathComponent("my-song.mp3")
        let originalBytes = Data([0x49, 0x44, 0x33, 0, 1, 2, 3, 4, 5, 6, 7])
        try originalBytes.write(to: audio)
        let song = MusicTrack(
            id: UUID(), title: "Test song", artist: "Local artist",
            album: "Album", fileName: "my-song.mp3",
            originalFileName: "my-song.mp3", duration: 55, isFavorite: true)
        var list = MusicPlaylist(name: "Portable playlist")
        list.trackIDs = [song.id]
        list.sourceURL = "https://open.spotify.com/playlist/0123456789ABCDEFGHIJKL"
        list.sourceOrder = [
            PlaylistWish(title: "Test song", artist: "Local artist", album: "Album")
        ]
        let appleNamespace = UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!
        var appleList = MusicPlaylist(name: "Apple Music list")
        appleList.appleMusicLibraryID = AppleMusicLibraryIdentity.key(namespace: appleNamespace, persistentID: 42)
        appleList.sourceOrder = [PlaylistWish(title: "Test song", artist: "Local artist", album: "Album",
            durationSeconds: 55, artistNames: ["Local artist"],
            appleMusicItemID: AppleMusicLibraryIdentity.key(namespace: appleNamespace, persistentID: 10))]
        // Two different portable playlists can legitimately use an archive
        // UUID that is already a local UUID for another playlist. The explicit
        // portable ID must win, and the second restore must get a distinct
        // local ID without changing either archive's identity.
        let occupiedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var existingPortable = MusicPlaylist(id: occupiedID, name: "Existing imported list")
        existingPortable.portableBackupID = "original-browser-list"
        assert(existingPortable.matchesPortableBackupID("original-browser-list"))
        assert(!existingPortable.matchesPortableBackupID(occupiedID.uuidString))
        let collisionID = MusicPlaylist.restoredLocalID(
            for: occupiedID.uuidString, existing: [existingPortable])
        assert(collisionID != occupiedID)
        var secondPortable = MusicPlaylist(id: collisionID, name: "Different imported list")
        secondPortable.portableBackupID = occupiedID.uuidString
        assert(secondPortable.matchesPortableBackupID(occupiedID.uuidString))
        assert(!existingPortable.matchesPortableBackupID(occupiedID.uuidString))
        assert(MusicPlaylist.restoredLocalID(
            for: "another-web-list", existing: [existingPortable, secondPortable])
            != occupiedID)
        let availableID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        assert(MusicPlaylist.restoredLocalID(
            for: availableID.uuidString, existing: [existingPortable, secondPortable])
            == availableID)
        let legacyLocal = MusicPlaylist(id: occupiedID, name: "Legacy native list")
        assert(legacyLocal.matchesPortableBackupID(occupiedID.uuidString))
        assert(!legacyLocal.matchesPortableBackupID("unrelated-browser-list"))
        print("PASS: portable playlist ID collision preserves both independent identities")

        let database = folder.appendingPathComponent("library.json")
        let snapshot = PersistedLibrary(tracks: [song], playlists: [list, appleList])
        try snapshot.write(to: database)
        // A new install may create its first library, but an unreadable or
        // corrupt existing catalog must never be mistaken for a new install.
        let neverCreated = folder.appendingPathComponent("library-not-created.json")
        let firstLaunch = try PersistedLibrary.readIfPresent(from: neverCreated)
        assert(firstLaunch == nil)
        let fromDisk = try PersistedLibrary.readIfPresent(from: database)
        assert(fromDisk?.tracks == snapshot.tracks)
        let damaged = folder.appendingPathComponent("library-corrupt.json")
        let damagedBytes = Data("{incomplete-library".utf8)
        try damagedBytes.write(to: damaged)
        do {
            _ = try PersistedLibrary.readIfPresent(from: damaged)
            fatalError("An existing corrupt catalog must throw, not start empty")
        } catch DecodingError.dataCorrupted {
            // Expected: preserve the saved bytes and disable persistence.
        }
        let unchangedDamagedBytes = try Data(contentsOf: damaged)
        assert(unchangedDamagedBytes == damagedBytes)
        // Existing catalog paths are never replaced as a side effect of read.
        let savedDatabase = try Data(contentsOf: database)
        let reopened = try JSONDecoder().decode(PersistedLibrary.self, from: Data(contentsOf: database))
        assert(reopened.tracks == snapshot.tracks && reopened.playlists == snapshot.playlists)
        assert(reopened.tracks[0].fileName == "my-song.mp3")
        let blockedDatabase = folder.appendingPathComponent("database-is-a-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedDatabase, withIntermediateDirectories: true)
        do {
            try snapshot.write(to: blockedDatabase)
            fatalError("A failed library write must throw instead of reporting import success")
        } catch {
            assert((error as NSError).domain == PersistedLibrary.writeFailureDomain)
            assert((error as NSError).userInfo[NSUnderlyingErrorKey] != nil)
        }
        var invalidSong = song
        invalidSong.duration = .nan
        do {
            try PersistedLibrary(tracks: [invalidSong], playlists: []).write(to: database)
            fatalError("Encoding failure must not replace the saved library")
        } catch {
            assert((error as NSError).domain == PersistedLibrary.writeFailureDomain)
        }
        let databaseAfterFailure = try Data(contentsOf: database)
        assert(databaseAfterFailure == savedDatabase)
        print("PASS: library snapshots reopen intact; write/encoding errors throw and preserve saved data")
        let archiveURL = folder.appendingPathComponent("test.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: song, audioURL: audio,
                  artwork: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                  lyrics: "[00:05.00]Original lyrics")
        ], playlists: [list, appleList], to: archiveURL)
        let archive = try PortableShelfArchive.open(archiveURL)
        assert(archive.manifest.schema == "mp3-shelf-backup")
        assert(archive.manifest.version == 1)
        assert(archive.manifest.tracks.count == 1)
        assert(archive.manifest.tracks[0].isFavorite == true)
        assert(archive.manifest.tracks[0].lyrics == "[00:05.00]Original lyrics")
        assert(archive.manifest.playlists[0].trackIds == [song.id.uuidString])
        assert(archive.manifest.playlists[0].wishes?.first?.title == "Test song")
        assert(archive.manifest.playlists[1].appleMusicLibraryID == appleList.appleMusicLibraryID)
        let appleWish = archive.manifest.playlists[1].wishes!.first!
        assert(appleWish.appleMusicItemID == appleList.sourceOrder[0].appleMusicItemID)
        assert(appleWish.durationSeconds == 55 && appleWish.artistNames == ["Local artist"])
        let extracted = try PortableShelfArchive.extract(
            archive.manifest.tracks[0].audio, from: archive, extensionName: "mp3")
        defer { try? FileManager.default.removeItem(at: extracted) }
        let extractedBytes = try Data(contentsOf: extracted)
        assert(extractedBytes == originalBytes)
        // Two files with the same name and size are not necessarily the same
        // recording. Check matching data, a same-size collision and a mismatch
        // beyond the 64-KiB streaming comparison boundary.
        let identicalAudio = folder.appendingPathComponent("identical.mp3")
        try originalBytes.write(to: identicalAudio)
        assert(PortableShelfArchive.audioFilesIdentical(audio, identicalAudio))
        let collision = folder.appendingPathComponent("collision.mp3")
        var alteredBytes = originalBytes
        alteredBytes[alteredBytes.count - 1] ^= 1
        try alteredBytes.write(to: collision)
        assert(!PortableShelfArchive.audioFilesIdentical(audio, collision))
        assert(!PortableShelfArchive.audioFilesIdentical(audio, folder.appendingPathComponent("missing.mp3")))
        let largeData = Data(repeating: 0xAB, count: 128 * 1024 + 31)
        let largeA = folder.appendingPathComponent("large-a.mp3")
        let largeB = folder.appendingPathComponent("large-b.mp3")
        try largeData.write(to: largeA)
        try largeData.write(to: largeB)
        assert(PortableShelfArchive.audioFilesIdentical(largeA, largeB))
        var differentEnd = largeData
        differentEnd[differentEnd.count - 1] = 0xAC
        try differentEnd.write(to: largeB)
        assert(!PortableShelfArchive.audioFilesIdentical(largeA, largeB))
        let restoredArt = try PortableShelfArchive.readBytes(
            archive.manifest.tracks[0].artwork!, from: archive)
        assert(restoredArt == Data([0xFF, 0xD8, 0xFF, 0xD9]))

        // Independently assembled web archive: this deliberately bypasses
        // native export to catch incompatible JSON field names or byte framing.
        let webJSON = """
        {"schema":"mp3-shelf-backup","version":1,"createdAt":"2026-10-16T00:00:00Z",
         "tracks":[{"id":"web-song-1","name":"Web recording","originalName":"web.mp3",
          "artist":"Browser artist","album":"Browser album","importedAt":1792108800000,
          "isFavorite":true,"lyrics":"[00:02.00] From the browser",
          "audio":{"offset":0,"length":11,"type":"audio/mpeg"}}],
         "playlists":[{"id":"web-list-1","name":"Browser list",
          "trackIds":["web-song-1"],
          "wishes":[{"title":"Web recording","artist":"Browser artist",
                     "album":"Browser album"}]}]}
        """
        let webManifest = Data(webJSON.utf8)
        let manifestSize = UInt32(webManifest.count)
        var webBytes = PortableShelfArchive.magic
        webBytes.append(contentsOf: [
            UInt8(manifestSize & 0xFF),
            UInt8((manifestSize >> 8) & 0xFF),
            UInt8((manifestSize >> 16) & 0xFF),
            UInt8((manifestSize >> 24) & 0xFF)
        ])
        webBytes.append(webManifest)
        webBytes.append(originalBytes)
        let browserURL = folder.appendingPathComponent("browser-made.mp3shelf")
        try webBytes.write(to: browserURL)
        let browserArchive = try PortableShelfArchive.open(browserURL)
        assert(browserArchive.manifest.tracks.first?.id == "web-song-1")
        assert(browserArchive.manifest.tracks.first?.isFavorite == true)
        assert(browserArchive.manifest.playlists.first?.trackIds == ["web-song-1"])
        let browserExtract = try PortableShelfArchive.extract(
            browserArchive.manifest.tracks[0].audio,
            from: browserArchive, extensionName: "mp3")
        defer { try? FileManager.default.removeItem(at: browserExtract) }
        let browserAudio = try Data(contentsOf: browserExtract)
        assert(browserAudio == originalBytes)

        // Reject duplicate/blank archive identifiers before touching the
        // on-device music library. Otherwise playlist references are ambiguous.
        let webObject = try JSONSerialization.jsonObject(with: webManifest)
            as! [String: Any]
        var repeatedTrack = webObject
        let webTracks = webObject["tracks"] as! [[String: Any]]
        repeatedTrack["tracks"] = [webTracks[0], webTracks[0]]
        var repeatedPlaylist = webObject
        let webPlaylists = webObject["playlists"] as! [[String: Any]]
        repeatedPlaylist["playlists"] = [webPlaylists[0], webPlaylists[0]]
        var emptyPlaylistID = webObject
        var blankPlaylists = webPlaylists
        blankPlaylists[0]["id"] = ""
        emptyPlaylistID["playlists"] = blankPlaylists

        for (name, malformed) in [
            ("duplicate-track-ids", repeatedTrack),
            ("duplicate-playlist-ids", repeatedPlaylist),
            ("blank-playlist-id", emptyPlaylistID)
        ] {
            let json = try JSONSerialization.data(withJSONObject: malformed)
            let length = UInt32(json.count)
            var bytes = PortableShelfArchive.magic
            bytes.append(contentsOf: [
                UInt8(length & 0xFF),
                UInt8((length >> 8) & 0xFF),
                UInt8((length >> 16) & 0xFF),
                UInt8((length >> 24) & 0xFF)
            ])
            bytes.append(json)
            bytes.append(originalBytes)
            let malformedURL = folder.appendingPathComponent(name + ".mp3shelf")
            try bytes.write(to: malformedURL)
            do {
                _ = try PortableShelfArchive.open(malformedURL)
                fatalError("Accepted malformed archive: \(name)")
            } catch PortableShelfArchive.ArchiveError.invalidManifest {
                // Expected: validation stops corrupt IDs before restore.
            }
        }

        // In-range slices may still overlap: the browser and native readers
        // must reject them before restoring any user-owned audio.
        var aliasingTracks = webObject
        var secondTrack = webTracks[0]
        secondTrack["id"] = "web-song-2"
        aliasingTracks["tracks"] = [webTracks[0], secondTrack]
        var aliasingArtwork = webObject
        var artworkTrack = webTracks[0]
        artworkTrack["artwork"] = ["offset": 3, "length": 4, "type": "image/jpeg"] as [String: Any]
        aliasingArtwork["tracks"] = [artworkTrack]
        var adjacentArtwork = webObject
        var adjacentTrack = webTracks[0]
        adjacentTrack["artwork"] = ["offset": 11, "length": 4, "type": "image/jpeg"] as [String: Any]
        adjacentArtwork["tracks"] = [adjacentTrack]
        for (name, malformed, expectedRejection) in [
            ("overlapping-tracks", aliasingTracks, true),
            ("overlapping-artwork", aliasingArtwork, true),
            ("adjacent-artwork", adjacentArtwork, false)
        ] {
            let json = try JSONSerialization.data(withJSONObject: malformed)
            let length = UInt32(json.count)
            var bytes = PortableShelfArchive.magic
            bytes.append(contentsOf: [
                UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF),
                UInt8((length >> 16) & 0xFF), UInt8((length >> 24) & 0xFF)
            ])
            bytes.append(json)
            bytes.append(originalBytes)
            bytes.append(Data([0xFF, 0xD8, 0xFF, 0xD9]))
            let path = folder.appendingPathComponent(name + ".mp3shelf")
            try bytes.write(to: path)
            if expectedRejection {
                do {
                    _ = try PortableShelfArchive.open(path)
                    fatalError("Accepted overlapping media: \\(name)")
                } catch PortableShelfArchive.ArchiveError.invalidRange {
                    // Expected: both parts individually fit but overlap.
                }
            } else {
                let valid = try PortableShelfArchive.open(path)
                assert(valid.manifest.tracks.count == 1)
            }
        }

        // A damaged playlist reference must be rejected before any songs
        // are imported, rather than silently producing an incomplete list.
        var brokenReference = webObject
        var linkedPlaylists = webPlaylists
        linkedPlaylists[0]["trackIds"] = ["unknown-song"]
        brokenReference["playlists"] = linkedPlaylists
        let brokenJSON = try JSONSerialization.data(withJSONObject: brokenReference)
        let brokenLength = UInt32(brokenJSON.count)
        var brokenData = PortableShelfArchive.magic
        brokenData.append(contentsOf: [
            UInt8(brokenLength & 0xFF), UInt8((brokenLength >> 8) & 0xFF),
            UInt8((brokenLength >> 16) & 0xFF), UInt8((brokenLength >> 24) & 0xFF)
        ])
        brokenData.append(brokenJSON)
        brokenData.append(originalBytes)
        let brokenURL = folder.appendingPathComponent("broken-reference.mp3shelf")
        try brokenData.write(to: brokenURL)
        do {
            _ = try PortableShelfArchive.open(brokenURL)
            fatalError("Accepted unknown song in playlist")
        } catch PortableShelfArchive.ArchiveError.invalidManifest {
            // Expected.
        }

        // Native playback UUIDs must not erase IDs from imported browser
        // libraries: re-exported playlists must refer to their original IDs.
        var portableSong = song
        portableSong.portableBackupID = "web-song-1"
        var portableList = MusicPlaylist(name: "Retained web IDs")
        portableList.portableBackupID = "web-list-1"
        portableList.trackIDs = [song.id]
        let portableURL = folder.appendingPathComponent("portable-identities.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: portableSong, audioURL: audio, artwork: nil, lyrics: nil)
        ], playlists: [portableList], to: portableURL)
        let portableArchive = try PortableShelfArchive.open(portableURL)
        assert(portableArchive.manifest.tracks.first?.id == "web-song-1")
        assert(portableArchive.manifest.playlists.first?.trackIds == ["web-song-1"])
        // When restore reuses byte-identical audio already on disk, the
        // original local UUID remains stable but the web ID must survive
        // persistence and re-export for browser playlist interoperability.
        var reusedSong = song
        assert(PortableShelfArchive.audioFilesIdentical(audio, identicalAudio))
        reusedSong.portableBackupID = "web-song-1"
        let persistedReuse = try JSONEncoder().encode(reusedSong)
        let reopenedReuse = try JSONDecoder().decode(MusicTrack.self, from: persistedReuse)
        assert(reopenedReuse.id == song.id)
        assert(reopenedReuse.portableBackupID == "web-song-1")
        let reusedURL = folder.appendingPathComponent("reused-identities.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: reopenedReuse, audioURL: identicalAudio, artwork: nil, lyrics: nil)
        ], playlists: [portableList], to: reusedURL)
        let reusedArchive = try PortableShelfArchive.open(reusedURL)
        assert(reusedArchive.manifest.tracks.first?.id == "web-song-1")
        assert(reusedArchive.manifest.playlists.first?.trackIds == ["web-song-1"])


        // Conflicting legacy portable identities must not make an otherwise
        // valid offline library impossible to back up. All recordings remain
        // distinct and every playlist link resolves to its own audio.
        var conflictA = song
        conflictA.portableBackupID = "shared-legacy-id"
        var conflictB = song
        conflictB.id = UUID()
        conflictB.portableBackupID = "shared-legacy-id"
        var collisionList = MusicPlaylist(name: "Collision playlist")
        collisionList.trackIDs = [conflictA.id, conflictB.id]
        let collisionURL = folder.appendingPathComponent("collision-recovery.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: conflictA, audioURL: audio, artwork: nil, lyrics: nil),
            .init(track: conflictB, audioURL: identicalAudio, artwork: nil, lyrics: nil)
        ], playlists: [collisionList], to: collisionURL)
        let recovered = try PortableShelfArchive.open(collisionURL)
        let exportedIDs = recovered.manifest.tracks.map(\.id)
        assert(exportedIDs.count == 2 && Set(exportedIDs).count == 2)
        assert(exportedIDs[0] == "shared-legacy-id")
        assert(recovered.manifest.playlists[0].trackIds == exportedIDs)
        for recoveredTrack in recovered.manifest.tracks {
            let extractedURL = try PortableShelfArchive.extract(
                recoveredTrack.audio, from: recovered, extensionName: "mp3")
            defer { try? FileManager.default.removeItem(at: extractedURL) }
            let recoveredBytes = try Data(contentsOf: extractedURL)
            assert(recoveredBytes == originalBytes)
        }
        // An explicit browser ID can collide with another local UUID.
        conflictB.portableBackupID = conflictA.id.uuidString
        conflictA.portableBackupID = "browser-a"
        let uuidCollisionURL = folder.appendingPathComponent("uuid-collision.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: conflictA, audioURL: audio, artwork: nil, lyrics: nil),
            .init(track: conflictB, audioURL: identicalAudio, artwork: nil, lyrics: nil)
        ], playlists: [collisionList], to: uuidCollisionURL)
        let uuidRecovered = try PortableShelfArchive.open(uuidCollisionURL)
        assert(Set(uuidRecovered.manifest.tracks.map(\.id)).count == 2)
        // A later track's explicit archive ID must outrank an earlier local
        // UUID fallback. Previously input-order allocation stole this ID.
        var fallbackSong = song
        fallbackSong.portableBackupID = nil
        var explicitSong = song
        explicitSong.id = UUID()
        explicitSong.portableBackupID = fallbackSong.id.uuidString
        var fallbackPlaylist = MusicPlaylist(name: "Local fallback playlist")
        fallbackPlaylist.trackIDs = [fallbackSong.id, explicitSong.id]
        var explicitPlaylist = MusicPlaylist(name: "Explicit portable playlist")
        explicitPlaylist.portableBackupID = fallbackPlaylist.id.uuidString
        explicitPlaylist.trackIDs = [explicitSong.id]
        let reservedIDURL = folder.appendingPathComponent("reserved-explicit-identities.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: fallbackSong, audioURL: audio, artwork: nil, lyrics: nil),
            .init(track: explicitSong, audioURL: identicalAudio, artwork: nil, lyrics: nil)
        ], playlists: [fallbackPlaylist, explicitPlaylist], to: reservedIDURL)
        let reservedArchive = try PortableShelfArchive.open(reservedIDURL)
        let reservedTracks = reservedArchive.manifest.tracks
        let reservedLists = reservedArchive.manifest.playlists
        assert(reservedTracks.count == 2 && reservedLists.count == 2)
        assert(reservedTracks[0].id != fallbackSong.id.uuidString)
        assert(reservedTracks[1].id == fallbackSong.id.uuidString)
        assert(reservedLists[0].id != fallbackPlaylist.id.uuidString)
        assert(reservedLists[1].id == fallbackPlaylist.id.uuidString)
        assert(reservedLists[0].trackIds == reservedTracks.map(\.id))
        assert(reservedLists[1].trackIds == [reservedTracks[1].id])
        assert(fallbackSong.portableBackupID == nil)
        assert(explicitSong.portableBackupID == fallbackSong.id.uuidString)
        assert(fallbackPlaylist.portableBackupID == nil)
        print("PASS: explicit portable IDs win over earlier native UUID fallbacks")
        // Exporting the same collision-repaired library again must preserve
        // archive identities. Random repair IDs previously created a new
        // playlist on each restore even though its local UUID was unchanged.
        let repeatedReservedURL = folder.appendingPathComponent("reserved-explicit-identities-again.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: fallbackSong, audioURL: audio, artwork: nil, lyrics: nil),
            .init(track: explicitSong, audioURL: identicalAudio, artwork: nil, lyrics: nil)
        ], playlists: [fallbackPlaylist, explicitPlaylist], to: repeatedReservedURL)
        let repeatedReserved = try PortableShelfArchive.open(repeatedReservedURL)
        assert(repeatedReserved.manifest.tracks.map(\.id) == reservedTracks.map(\.id))
        assert(repeatedReserved.manifest.playlists.map(\.id) == reservedLists.map(\.id))
        assert(repeatedReserved.manifest.playlists.map(\.trackIds) == reservedLists.map(\.trackIds))
        assert(reservedTracks[0].id.hasPrefix("mp3shelf-track-"))
        assert(reservedLists[0].id.hasPrefix("mp3shelf-playlist-"))
        print("PASS: repeated collision-repaired exports retain stable IDs and playlist links")

        // Duplicate playlist portable IDs are also repaired in the exported
        // manifest without changing local playlist UUIDs or their contents.
        var collisionListB = MusicPlaylist(name: "Second collision playlist")
        collisionList.portableBackupID = "duplicate-playlist-id"
        collisionListB.portableBackupID = "duplicate-playlist-id"
        collisionListB.trackIDs = [conflictB.id]
        let playlistCollisionURL = folder.appendingPathComponent("playlist-collision.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: conflictA, audioURL: audio, artwork: nil, lyrics: nil),
            .init(track: conflictB, audioURL: identicalAudio, artwork: nil, lyrics: nil)
        ], playlists: [collisionList, collisionListB], to: playlistCollisionURL)
        let recoveredPlaylists = try PortableShelfArchive.open(playlistCollisionURL)
        assert(Set(recoveredPlaylists.manifest.playlists.map(\.id)).count == 2)
        assert(recoveredPlaylists.manifest.playlists[0].id == "duplicate-playlist-id")
        assert(recoveredPlaylists.manifest.playlists[1].trackIds ==
            [recoveredPlaylists.manifest.tracks[1].id])
        // Two local entries with the same UUID cannot be disambiguated.
        var repeatedLocal = conflictB
        repeatedLocal.id = conflictA.id
        let invalidDuplicateURL = folder.appendingPathComponent("duplicate-local-uuid.mp3shelf")
        do {
            try PortableShelfArchive.export([
                .init(track: conflictA, audioURL: audio, artwork: nil, lyrics: nil),
                .init(track: repeatedLocal, audioURL: identicalAudio, artwork: nil, lyrics: nil)
            ], playlists: [], to: invalidDuplicateURL)
            fatalError("Duplicate local UUID must fail before publishing backup")
        } catch PortableShelfArchive.ArchiveError.invalidManifest {
            assert(!FileManager.default.fileExists(atPath: invalidDuplicateURL.path))
        }
        print("PASS: conflicting legacy export IDs preserve recordings and playlist links")

        // Legacy on-device song data without the new ID decodes normally.
        let persistedTrack = try JSONEncoder().encode(portableSong)
        var legacyTrack = try JSONSerialization.jsonObject(with: persistedTrack)
            as! [String: Any]
        legacyTrack.removeValue(forKey: "portableBackupID")
        let legacyTrackBytes = try JSONSerialization.data(withJSONObject: legacyTrack)
        let migratedTrack = try JSONDecoder().decode(MusicTrack.self, from: legacyTrackBytes)
        assert(migratedTrack.portableBackupID == nil)

        let invalidURL = folder.appendingPathComponent("invalid.mp3shelf")
        try Data("invalid archive".utf8).write(to: invalidURL)
        do {
            _ = try PortableShelfArchive.open(invalidURL)
            fatalError("Accepted invalid archive")
        } catch PortableShelfArchive.ArchiveError.invalidFile {
            // Expected.
        }
        // Browser playlists use arbitrary string IDs. Repeat restores must
        // match the same persisted playlist rather than generate a new UUID.
        var browserPlaylist = MusicPlaylist(name: "Imported browser playlist")
        browserPlaylist.portableBackupID = "web-list-1"
        assert(browserPlaylist.matchesPortableBackupID("web-list-1"))
        assert(!browserPlaylist.matchesPortableBackupID("different-web-list"))
        let nativePlaylist = MusicPlaylist(name: "Native playlist")
        assert(nativePlaylist.matchesPortableBackupID(nativePlaylist.id.uuidString))

        // New identity field must survive app relaunch while legacy native
        // libraries (which lack this field) still decode successfully.
        let savedPlaylist = try JSONEncoder().encode(browserPlaylist)
        let restoredPlaylist = try JSONDecoder().decode(MusicPlaylist.self, from: savedPlaylist)
        assert(restoredPlaylist.matchesPortableBackupID("web-list-1"))
        var legacyObject = try JSONSerialization.jsonObject(with: savedPlaylist)
            as! [String: Any]
        legacyObject.removeValue(forKey: "portableBackupID")
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyPlaylist = try JSONDecoder().decode(MusicPlaylist.self, from: legacyBytes)
        assert(legacyPlaylist.portableBackupID == nil)
        assert(legacyPlaylist.matchesPortableBackupID(legacyPlaylist.id.uuidString))

        let reexportURL = folder.appendingPathComponent("reexported-web-playlist.mp3shelf")
        try PortableShelfArchive.export([], playlists: [browserPlaylist], to: reexportURL)
        let reexport = try PortableShelfArchive.open(reexportURL)
        assert(reexport.manifest.playlists.first?.id == "web-list-1")

        print("Portable MP3 Shelf v1 archive round-trip and validation passed.")
    }
}
