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
        let archiveURL = folder.appendingPathComponent("test.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: song, audioURL: audio,
                  artwork: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                  lyrics: "[00:05.00]Original lyrics")
        ], playlists: [list], to: archiveURL)
        let archive = try PortableShelfArchive.open(archiveURL)
        assert(archive.manifest.schema == "mp3-shelf-backup")
        assert(archive.manifest.version == 1)
        assert(archive.manifest.tracks.count == 1)
        assert(archive.manifest.tracks[0].isFavorite == true)
        assert(archive.manifest.tracks[0].lyrics == "[00:05.00]Original lyrics")
        assert(archive.manifest.playlists[0].trackIds == [song.id.uuidString])
        assert(archive.manifest.playlists[0].wishes?.first?.title == "Test song")
        let extracted = try PortableShelfArchive.extract(
            archive.manifest.tracks[0].audio, from: archive, extensionName: "mp3")
        defer { try? FileManager.default.removeItem(at: extracted) }
        let extractedBytes = try Data(contentsOf: extracted)
        assert(extractedBytes == originalBytes)
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
                fatalError("Accepted malformed archive: \\(name)")
            } catch PortableShelfArchive.ArchiveError.invalidManifest {
                // Expected: validation stops corrupt IDs before restore.
            }
        }

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
