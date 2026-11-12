import Foundation

@main
struct PortableShelfArchiveTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp3shelf-archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A pre-cancelled export must not publish a misleading empty backup.
        // Gate the worker so cancellation always precedes its first check.
        let cancelledExport = folder.appendingPathComponent("cancelled.mp3shelf")
        let gate = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let cancelledWorker = Task.detached {
            gate.wait()
            do {
                try PortableShelfArchive.export([], playlists: [], to: cancelledExport)
                fatalError("Cancelled export unexpectedly published an archive")
            } catch is CancellationError {
                // Expected.
            } catch {
                fatalError("Unexpected cancellation failure: \(error)")
            }
            completed.signal()
        }
        cancelledWorker.cancel()
        gate.signal()
        guard completed.wait(timeout: .now() + 10) == .success else {
            fatalError("Cancelled export did not terminate promptly")
        }
        assert(!FileManager.default.fileExists(atPath: cancelledExport.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        assert(!leftovers.contains { $0.contains("cancelled.mp3shelf") && $0.hasSuffix(".partial") })
        print("PASS: cancelled archive export publishes no output or partial files")

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

        // Backup export must never follow an audio symlink or read a directory
        // if the saved catalog is damaged. Source bytes remain untouched.
        let outsideAudio = folder.appendingPathComponent("private-source.mp3")
        let privateBytes = Data("not-library-audio".utf8)
        try privateBytes.write(to: outsideAudio)
        let linkedAudio = folder.appendingPathComponent("linked-recording.mp3")
        try FileManager.default.createSymbolicLink(at: linkedAudio, withDestinationURL: outsideAudio)
        let linkedBackup = folder.appendingPathComponent("linked-audio.mp3shelf")
        do {
            try PortableShelfArchive.export([
                .init(track: song, audioURL: linkedAudio, artwork: nil, lyrics: nil)
            ], playlists: [list], to: linkedBackup)
            fatalError("Audio symlink must not be followed by backup export")
        } catch PortableShelfArchive.ArchiveError.invalidManifest {
            // Expected.
        }
        assert(!FileManager.default.fileExists(atPath: linkedBackup.path))
        let directoryAudio = folder.appendingPathComponent("directory-recording.mp3", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryAudio, withIntermediateDirectories: true)
        do {
            try PortableShelfArchive.export([
                .init(track: song, audioURL: directoryAudio, artwork: nil, lyrics: nil)
            ], playlists: [list], to: folder.appendingPathComponent("directory-audio.mp3shelf"))
            fatalError("Directory must not be accepted as an audio recording")
        } catch PortableShelfArchive.ArchiveError.invalidManifest {
            // Expected.
        }
        let privateBytesAfter = try Data(contentsOf: outsideAudio)
        assert(privateBytesAfter == privateBytes)
        // Same-inode, same-length changes must be detected by identity
        // checks, not accepted merely because file size is unchanged.
        let mutableAudio = folder.appendingPathComponent("mutable-audio.mp3")
        try originalBytes.write(to: mutableAudio)
        let mutableBackup = folder.appendingPathComponent("mutable-audio.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: song, audioURL: mutableAudio, artwork: nil, lyrics: nil)
        ], playlists: [list], to: mutableBackup)
        let beforeEdit = try Data(contentsOf: mutableAudio)
        let editor = try FileHandle(forUpdating: mutableAudio)
        try editor.seek(toOffset: 3)
        try editor.write(contentsOf: Data([0x7F]))
        try editor.synchronize()
        try editor.close()
        let afterEdit = try Data(contentsOf: mutableAudio)
        assert(beforeEdit.count == afterEdit.count)
        assert(beforeEdit != afterEdit)
        let originalAfterEdit = try Data(contentsOf: audio)
        assert(originalAfterEdit == originalBytes)
        print("PASS: same-size source mutation fixture leaves original recording intact")

        let validAudioBackup = folder.appendingPathComponent("valid-regular-audio.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: song, audioURL: audio, artwork: nil, lyrics: nil)
        ], playlists: [list], to: validAudioBackup)
        // Archive inspection also runs on a cancellable task. A cancelled
        // reader must stop before consuming the header/manifest and must not
        // mutate or delete the existing backup.
        let inspectionGate = DispatchSemaphore(value: 0)
        let inspectionFinished = DispatchSemaphore(value: 0)
        let cancelledInspection = Task.detached {
            inspectionGate.wait()
            do {
                _ = try PortableShelfArchive.open(validAudioBackup)
                fatalError("Cancelled archive inspection unexpectedly succeeded")
            } catch is CancellationError {
                // Expected: readExactly checks cancellation before each read.
            } catch {
                fatalError("Unexpected cancelled archive inspection error: \(error)")
            }
            inspectionFinished.signal()
        }
        cancelledInspection.cancel()
        inspectionGate.signal()
        guard inspectionFinished.wait(timeout: .now() + 10) == .success else {
            fatalError("Cancelled archive inspection did not terminate")
        }
        assert(FileManager.default.fileExists(atPath: validAudioBackup.path))
        print("PASS: cancelled archive inspection preserves the existing backup")

        let validAudioArchive = try PortableShelfArchive.open(validAudioBackup)
        let validAudioExtract = try PortableShelfArchive.extract(
            validAudioArchive.manifest.tracks[0].audio,
            from: validAudioArchive, extensionName: "mp3")
        let validAudioBytes = try Data(contentsOf: validAudioExtract)
        assert(validAudioBytes == originalBytes)
        try FileManager.default.removeItem(at: validAudioExtract)
        // A previously inspected archive may be replaced by Files or edited
        // before a track/cover is extracted. Its manifest cannot authorize
        // bytes from another inode or a mutated version of the same inode.
        let identityBackup = folder.appendingPathComponent("identity-check.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: song, audioURL: audio, artwork: Data([1, 2, 3]), lyrics: nil)
        ], playlists: [list], to: identityBackup)
        let inspected = try PortableShelfArchive.open(identityBackup)
        let identityAudio = inspected.manifest.tracks[0].audio
        let identityArt = inspected.manifest.tracks[0].artwork!
        let cover = try PortableShelfArchive.readBytes(identityArt, from: inspected)
        assert(cover == Data([1, 2, 3]))
        let beforeReplacement = try Data(contentsOf: identityBackup)
        let replacement = folder.appendingPathComponent("replacement.mp3shelf")
        try beforeReplacement.write(to: replacement)
        try FileManager.default.removeItem(at: identityBackup)
        try FileManager.default.moveItem(at: replacement, to: identityBackup)
        do {
            let extracted = try PortableShelfArchive.extract(identityAudio, from: inspected, extensionName: "mp3")
            try? FileManager.default.removeItem(at: extracted)
            fatalError("A replaced backup must not be extracted using stale manifest")
        } catch PortableShelfArchive.ArchiveError.invalidFile {
            // Expected.
        }
        do {
            _ = try PortableShelfArchive.readBytes(identityArt, from: inspected)
            fatalError("A replaced backup must not supply artwork under stale manifest")
        } catch PortableShelfArchive.ArchiveError.invalidFile {
            // Expected.
        }
        let reopened = try PortableShelfArchive.open(identityBackup)
        let mutation = try FileHandle(forUpdating: identityBackup)
        try mutation.seek(toOffset: UInt64(beforeReplacement.count - 1))
        try mutation.write(contentsOf: Data([beforeReplacement.last! ^ 0xFF]))
        try mutation.synchronize()
        try mutation.close()
        do {
            _ = try PortableShelfArchive.readBytes(reopened.manifest.tracks[0].artwork!, from: reopened)
            fatalError("Same-inode archive mutation must invalidate prior inspection")
        } catch PortableShelfArchive.ArchiveError.invalidFile {
            // Expected.
        }
        let preservedSource = try Data(contentsOf: audio)
        assert(preservedSource == originalBytes)
        print("PASS: stale archive inspection rejects replacement and same-inode mutation")
        print("PASS: audio export rejects symlinks and directories; regular audio round-trips")

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
        // A catalog-referenced sidecar must never vanish silently from a
        // backup when protected storage, corruption or disk loss prevents read.
        let sidecarDirectory = folder.appendingPathComponent("sidecars", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
        let savedLyrics = sidecarDirectory.appendingPathComponent("song.lrc")
        let expectedLyrics = Data("[00:01.00] Preserved lyric".utf8)
        try expectedLyrics.write(to: savedLyrics)
        let loadedLyrics = try PortableShelfArchive.readSidecar(
            named: "song.lrc", from: sidecarDirectory, maximumBytes: 500 * 1024)
        assert(loadedLyrics == expectedLyrics)
        // Reading a sidecar is a fresh, validated operation each time.
        // A same-size atomic replacement must return the new file's bytes,
        // never cached content from a prior descriptor or pathname.
        let replacementLyrics = Data("[00:01.00] Recovered lyric".utf8)
        let sidecarReplacement = sidecarDirectory.appendingPathComponent("replacement.lrc")
        try replacementLyrics.write(to: sidecarReplacement)
        try FileManager.default.removeItem(at: savedLyrics)
        try FileManager.default.moveItem(at: sidecarReplacement, to: savedLyrics)
        assert(try PortableShelfArchive.readSidecar(
            named: "song.lrc", from: sidecarDirectory,
            maximumBytes: 500 * 1024) == replacementLyrics)
        // Restore the original fixture before the remaining archive tests.
        try expectedLyrics.write(to: savedLyrics, options: .atomic)
        assert(try PortableShelfArchive.readSidecar(
            named: "song.lrc", from: sidecarDirectory,
            maximumBytes: 500 * 1024) == expectedLyrics)
        print("PASS: sidecar reads validate the current file after pathname replacement")
        let absentSidecar = try PortableShelfArchive.readSidecar(
            named: nil, from: sidecarDirectory, maximumBytes: 500 * 1024)
        assert(absentSidecar == nil)
        let artworkSidecar = sidecarDirectory.appendingPathComponent("saved.img")
        let artworkBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try artworkBytes.write(to: artworkSidecar)
        let loadedArtwork = try PortableShelfArchive.readSidecar(
            named: "saved.img", from: sidecarDirectory,
            maximumBytes: 20 * 1024 * 1024)
        assert(loadedArtwork == artworkBytes)
        do {
            _ = try PortableShelfArchive.readSidecar(
                named: "lost.lrc", from: sidecarDirectory, maximumBytes: 500 * 1024)
            fatalError("Missing referenced lyrics must not become nil in backup")
        } catch {
            // Expected: a saved reference is different from no saved lyrics.
        }
        do {
            _ = try PortableShelfArchive.readSidecar(
                named: "song.lrc", from: sidecarDirectory, maximumBytes: 2)
            fatalError("Oversized sidecar should prevent incomplete backup")
        } catch PortableShelfArchive.ArchiveError.oversized {
            // Expected.
        }
        do {
            _ = try PortableShelfArchive.readSidecar(
                named: "../song.lrc", from: sidecarDirectory, maximumBytes: 500 * 1024)
            fatalError("Sidecar must not escape the app's storage directory")
        } catch PortableShelfArchive.ArchiveError.invalidManifest {
            // Expected.
        }
        // An archive must never follow a catalog sidecar symlink.
        let externalLyrics = folder.appendingPathComponent("external-private.lrc")
        let externalBytes = Data("Do not export this external file".utf8)
        try externalBytes.write(to: externalLyrics)
        let linkedLyrics = sidecarDirectory.appendingPathComponent("linked.lrc")
        try FileManager.default.createSymbolicLink(at: linkedLyrics, withDestinationURL: externalLyrics)
        do {
            _ = try PortableShelfArchive.readSidecar(
                named: "linked.lrc", from: sidecarDirectory, maximumBytes: 500 * 1024)
            fatalError("Referenced sidecars must not follow external symlinks")
        } catch PortableShelfArchive.ArchiveError.invalidManifest {
            // Expected.
        }
        let internalLink = sidecarDirectory.appendingPathComponent("internal-link.lrc")
        try FileManager.default.createSymbolicLink(at: internalLink, withDestinationURL: savedLyrics)
        do {
            _ = try PortableShelfArchive.readSidecar(
                named: "internal-link.lrc", from: sidecarDirectory, maximumBytes: 500 * 1024)
            fatalError("Catalog sidecar aliases must not be followed")
        } catch PortableShelfArchive.ArchiveError.invalidManifest {
            // Expected.
        }
        let directoryAlias = sidecarDirectory.appendingPathComponent("not-a-file.lrc", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryAlias, withIntermediateDirectories: true)
        do {
            _ = try PortableShelfArchive.readSidecar(
                named: "not-a-file.lrc", from: sidecarDirectory, maximumBytes: 500 * 1024)
            fatalError("A sidecar reference must not open a directory")
        } catch PortableShelfArchive.ArchiveError.invalidManifest {
            // Expected.
        }
        let externalAfter = try Data(contentsOf: externalLyrics)
        assert(externalAfter == externalBytes)
        print("PASS: sidecar export rejects external/internal symlinks and directories")

        let corruptLyrics = sidecarDirectory.appendingPathComponent("corrupt.lrc")
        try Data([0xFF, 0xFE]).write(to: corruptLyrics)
        let invalidUTF8 = try PortableShelfArchive.readSidecar(
            named: "corrupt.lrc", from: sidecarDirectory, maximumBytes: 500 * 1024)!
        assert(String(data: invalidUTF8, encoding: .utf8) == nil)
        let originalSidecarBytes = try Data(contentsOf: savedLyrics)
        assert(originalSidecarBytes == expectedLyrics)
        // A partial restore must also heal stale non-nil references, not just
        // completely absent references. Never mutate the old file while
        // determining whether archive bytes should be restored.
        assert(!PortableShelfArchive.sidecarNeedsRecovery(
            named: "song.lrc", from: sidecarDirectory,
            maximumBytes: 500 * 1024,
            isValid: { String(data: $0, encoding: .utf8) != nil }))
        assert(PortableShelfArchive.sidecarNeedsRecovery(
            named: nil, from: sidecarDirectory,
            maximumBytes: 500 * 1024, isValid: { _ in true }))
        assert(PortableShelfArchive.sidecarNeedsRecovery(
            named: "lost.lrc", from: sidecarDirectory,
            maximumBytes: 500 * 1024, isValid: { _ in true }))
        assert(PortableShelfArchive.sidecarNeedsRecovery(
            named: "corrupt.lrc", from: sidecarDirectory,
            maximumBytes: 500 * 1024,
            isValid: { String(data: $0, encoding: .utf8) != nil }))
        assert(PortableShelfArchive.sidecarNeedsRecovery(
            named: "song.lrc", from: sidecarDirectory,
            maximumBytes: 2, isValid: { _ in true }))
        assert(PortableShelfArchive.sidecarNeedsRecovery(
            named: "../song.lrc", from: sidecarDirectory,
            maximumBytes: 500 * 1024, isValid: { _ in true }))
        let originalLyricsAfterRecoveryCheck = try Data(contentsOf: savedLyrics)
        assert(originalLyricsAfterRecoveryCheck == expectedLyrics)
        print("PASS: restore eligibility detects missing/corrupt/stale sidecars without modifying originals")
        print("PASS: referenced sidecars fail closed; intact bytes and valid sidecars remain safe")

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
        // Reject damaged catalog snapshots rather than dropping playlist
        // membership from a superficially successful portable backup.
        var danglingList = list
        danglingList.trackIDs = [song.id, UUID()]
        let danglingBackup = folder.appendingPathComponent("dangling-links.mp3shelf")
        do {
            try PortableShelfArchive.export([
                .init(track: song, audioURL: audio, artwork: nil, lyrics: nil)
            ], playlists: [danglingList], to: danglingBackup)
            fatalError("Export silently discarded a missing playlist track")
        } catch PortableShelfArchive.ArchiveError.invalidManifest {
            // Expected: no incomplete backup was published.
        }
        assert(!FileManager.default.fileExists(atPath: danglingBackup.path))
        let intactSource = try Data(contentsOf: audio)
        assert(intactSource == originalBytes)
        var emptyList = list
        emptyList.trackIDs = []
        let emptyBackup = folder.appendingPathComponent("empty-playlist.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: song, audioURL: audio, artwork: nil, lyrics: nil)
        ], playlists: [emptyList], to: emptyBackup)
        let reopenedEmpty = try PortableShelfArchive.open(emptyBackup)
        assert(reopenedEmpty.manifest.playlists[0].trackIds.isEmpty)
        print("PASS: dangling playlist links fail closed; empty playlists round-trip")

        // A source pathname resolving through a symlink must not be backed up,
        // even when the target is valid audio with identical content.
        let linkedSource = folder.appendingPathComponent("linked-source.mp3")
        let externalSource = folder.appendingPathComponent("external-source.mp3")
        try originalBytes.write(to: externalSource)
        try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: externalSource)
        let linkedBackup = folder.appendingPathComponent("linked-source.mp3shelf")
        do {
            try PortableShelfArchive.export([
                .init(track: song, audioURL: linkedSource, artwork: nil, lyrics: nil)
            ], playlists: [list], to: linkedBackup)
            fatalError("Symlink source should never be exported")
        } catch {
            assert(!FileManager.default.fileExists(atPath: linkedBackup.path))
            let targetAfter = try Data(contentsOf: externalSource)
            assert(targetAfter == originalBytes)
        }
        print("PASS: symlink audio source rejected without modifying target")

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

        // Duplicate detection must never treat a symlink or an unstable
        // source as proof that an incoming recording can be discarded.
        let comparisonA = folder.appendingPathComponent("comparison-a.mp3")
        let comparisonB = folder.appendingPathComponent("comparison-b.mp3")
        let comparisonLink = folder.appendingPathComponent("comparison-link.mp3")
        let comparisonBytes = Data(repeating: 0x53, count: 256 * 1024)
        try comparisonBytes.write(to: comparisonA)
        try comparisonBytes.write(to: comparisonB)
        assert(PortableShelfArchive.audioFilesIdentical(comparisonA, comparisonB))
        try FileManager.default.createSymbolicLink(
            at: comparisonLink, withDestinationURL: comparisonA)
        assert(!PortableShelfArchive.audioFilesIdentical(
            comparisonA, comparisonLink))
        assert(!PortableShelfArchive.audioFilesIdentical(
            comparisonA, folder))
        try Data(repeating: 0x54, count: comparisonBytes.count)
            .write(to: comparisonB, options: .atomic)
        assert(!PortableShelfArchive.audioFilesIdentical(comparisonA, comparisonB))
        assert(try Data(contentsOf: comparisonA) == comparisonBytes)
        print("PASS: duplicate audio comparison rejects nonfiles and changed bytes")

        // A valid archive range is not authority to restore arbitrary bytes.
        // Only exact manifest-declared audio/artwork slices may be accessed.
        let guardedArchive = try PortableShelfArchive.open(portableURL)
        let guardedAudio = guardedArchive.manifest.tracks[0].audio
        let shiftedAudio = PortableShelfArchive.Part(
            offset: guardedAudio.offset + 1,
            length: guardedAudio.length - 1,
            type: guardedAudio.type)
        do {
            let unexpected = try PortableShelfArchive.extract(
                shiftedAudio, from: guardedArchive, extensionName: "mp3")
            try? FileManager.default.removeItem(at: unexpected)
            fatalError("Accepted undeclared audio subrange")
        } catch PortableShelfArchive.ArchiveError.invalidRange {
            // Expected: even a bounded range must be declared.
        }
        do {
            _ = try PortableShelfArchive.readBytes(guardedAudio, from: guardedArchive)
            fatalError("Read audio bytes through artwork API")
        } catch PortableShelfArchive.ArchiveError.invalidRange {
            // Expected: artwork reads cannot expose audio.
        }
        let legitimate = try PortableShelfArchive.extract(
            guardedAudio, from: guardedArchive, extensionName: "mp3")
        assert(try Data(contentsOf: legitimate) == originalBytes)
        try FileManager.default.removeItem(at: legitimate)
        print("PASS: archive extraction permits only declared media slices")

        print("Portable MP3 Shelf v1 archive round-trip and validation passed.")
    }
}
