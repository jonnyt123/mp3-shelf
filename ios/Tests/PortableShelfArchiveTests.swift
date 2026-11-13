import Foundation

private enum ImportTransactionFailure: Error { case invalidAudio, catalogWrite }

// Evaluate throwing fixture reads before entering assert's nonthrowing closure.
private func assertThrowing(_ condition: @autoclosure () throws -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) rethrows {
    let passed = try condition()
    assert(passed, file: file, line: line)
}

// Synchronize results from concurrent exporters without mutable captured vars.
// @unchecked Sendable is justified by the lock guarding every access.
private final class ArchiveExportRaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var winners: [Int] = []
    private var failureCount = 0

    func recordSuccess(_ index: Int) {
        lock.lock()
        defer { lock.unlock() }
        winners.append(index)
    }

    func recordFailure(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        failureCount += 1
    }

    func snapshot() -> (winners: [Int], failureCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (winners, failureCount)
    }
}

@main
struct PortableShelfArchiveTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp3shelf-archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Archive sidecar publication is a pre-catalog operation: a failed
        // post-write check must remove only the new file, while existing
        // user-owned bytes and filenames are never replaced.
        let sidecarURL = folder.appendingPathComponent("archive-sidecar.img")
        let sidecarBytes = Data(repeating: 0xAC, count: 4096)
        do {
            try PortableShelfArchive.writeRestoredSidecar(sidecarBytes, to: sidecarURL) {
                throw ImportTransactionFailure.catalogWrite
            }
            fatalError("Accepted a rejected sidecar publication")
        } catch ImportTransactionFailure.catalogWrite { }
        assert(!FileManager.default.fileExists(atPath: sidecarURL.path))
        let previousSidecar = Data([0x12, 0x34, 0x56])
        try previousSidecar.write(to: sidecarURL)
        do {
            try PortableShelfArchive.writeRestoredSidecar(sidecarBytes, to: sidecarURL)
            fatalError("Overwrote a pre-existing user sidecar")
        } catch { }
        try assertThrowing(try Data(contentsOf: sidecarURL) == previousSidecar)
        try FileManager.default.removeItem(at: sidecarURL)
        try PortableShelfArchive.writeRestoredSidecar(sidecarBytes, to: sidecarURL)
        try assertThrowing(try Data(contentsOf: sidecarURL) == sidecarBytes)
        print("PASS: failed archive sidecar publication cleans new files without replacing existing bytes")

        // A valid recovery journal is durable metadata, not permission to
        // delete or overwrite unknown audio. A process may die after writing
        // the intent, before publishing or committing the catalog.
        let recoveryTrack = MusicTrack(
            id: UUID(), title: "Interrupted import", artist: "Local",
            album: "Recovery", fileName: "Interrupted [123456789ABC].mp3",
            originalFileName: "interrupted.mp3", duration: 13)
        let recoveryStage = ".mp3shelf-import-recovery-fixture.mp3"
        let recoveryBytes = Data(repeating: 0x49, count: 65_536)
        let recoveryStageURL = folder.appendingPathComponent(recoveryStage)
        try recoveryBytes.write(to: recoveryStageURL)
        let recoveryRecord = LocalAudioRecoveryRecord(
            version: 1, track: recoveryTrack,
            stagingName: recoveryStage, audioLength: Int64(recoveryBytes.count))
        let recoveryJournal = LocalAudioRecoveryRecord.journalURL(
            for: recoveryTrack.id, in: folder)
        try JSONEncoder().encode(recoveryRecord).write(to: recoveryJournal, options: .atomic)
        assert(LocalAudioRecoveryRecord.pending(in: folder).contains(recoveryJournal))
        let reopenedRecovery = try LocalAudioRecoveryRecord.read(
            recoveryJournal, in: folder)
        assert(reopenedRecovery.track.id == recoveryTrack.id)
        assert(reopenedRecovery.track.fileName == recoveryTrack.fileName)
        assert(reopenedRecovery.audioLength == Int64(recoveryBytes.count))
        // An unrelated file may coexist with the journal and must be retained.
        let recoveryUnknown = folder.appendingPathComponent("user-owned-audio.mp3")
        let unknownBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try unknownBytes.write(to: recoveryUnknown)
        // A forged journal name cannot reassign the track's intended identity.
        let changedJournal = folder.appendingPathComponent(
            ".mp3shelf-recovery-\(UUID().uuidString).json")
        try JSONEncoder().encode(recoveryRecord).write(to: changedJournal)
        do {
            _ = try LocalAudioRecoveryRecord.read(changedJournal, in: folder)
            fatalError("Accepted recovery intent under the wrong journal identity")
        } catch PortableShelfArchive.ArchiveError.invalidManifest { }
        try FileManager.default.removeItem(at: changedJournal)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent(
                ".mp3shelf-recovery-\(UUID().uuidString).json"),
            withDestinationURL: recoveryJournal)
        // A wrong-name journal never grants authority over source audio.
        let symlinkJournal = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil).first {
                $0.lastPathComponent.hasPrefix(".mp3shelf-recovery-") &&
                $0 != recoveryJournal
            }!
        do {
            _ = try LocalAudioRecoveryRecord.read(symlinkJournal, in: folder)
            fatalError("Accepted a symlink as a recovery journal")
        } catch { }
        try FileManager.default.removeItem(at: symlinkJournal)
        try assertThrowing(try Data(contentsOf: recoveryStageURL) == recoveryBytes)
        try assertThrowing(try Data(contentsOf: recoveryUnknown) == unknownBytes)
        // Exercise the production no-replace publication helper without
        // requiring AVFoundation on Linux. The verifier accepts exact bytes.
        let recoveryPublished = folder.appendingPathComponent(recoveryTrack.fileName)
        let recoveredFile = try reopenedRecovery.restorePublication(in: folder) {
            (try? Data(contentsOf: $0)) == recoveryBytes
        }
        assert(recoveredFile == recoveryPublished)
        try assertThrowing(try Data(contentsOf: recoveryPublished) == recoveryBytes)
        // A second launch reuses the same file without making another copy.
        let recoveredAgain = try reopenedRecovery.restorePublication(in: folder) {
            (try? Data(contentsOf: $0)) == recoveryBytes
        }
        assert(recoveredAgain == recoveryPublished)
        // A malicious or corrupt destination must never be overwritten with
        // the journal's stage even when the staged audio itself is intact.
        try FileManager.default.removeItem(at: recoveryPublished)
        try unknownBytes.write(to: recoveryPublished)
        let refusedCollision = try reopenedRecovery.restorePublication(in: folder) {
            (try? Data(contentsOf: $0)) == recoveryBytes
        }
        assert(refusedCollision == nil)
        try assertThrowing(try Data(contentsOf: recoveryPublished) == unknownBytes)
        try FileManager.default.removeItem(at: recoveryPublished)
        // An interrupted import with no surviving stage is not synthesized
        // as a made-up recording: leave the journal, skip publication.
        try FileManager.default.removeItem(at: recoveryStageURL)
        let missingStage = try reopenedRecovery.restorePublication(in: folder) { _ in true }
        assert(missingStage == nil)
        assert(FileManager.default.fileExists(atPath: recoveryJournal.path))
        // A previously saved library entry does not justify discarding its
        // recovery intent while its audio is missing or file-protected.
        let unrelatedSaved = MusicTrack(
            id: UUID(), title: recoveryTrack.title, artist: recoveryTrack.artist,
            album: recoveryTrack.album, fileName: recoveryTrack.fileName,
            originalFileName: recoveryTrack.originalFileName,
            duration: recoveryTrack.duration)
        let unrelatedResult = try reopenedRecovery.restoreExistingTrack(
            unrelatedSaved, in: folder, verify: { _ in true })
        assert(!unrelatedResult)
        let missingSaved = try reopenedRecovery.restoreExistingTrack(
            recoveryTrack, in: folder, verify: { _ in true })
        assert(!missingSaved)
        assert(FileManager.default.fileExists(atPath: recoveryJournal.path))
        // A later foreground retry can safely reattach staged bytes without
        // replacing the catalog's UUID, title or other user-owned metadata.
        try recoveryBytes.write(to: recoveryStageURL)
        let restoredSaved = try reopenedRecovery.restoreExistingTrack(
            recoveryTrack, in: folder, verify: {
                (try? Data(contentsOf: $0)) == recoveryBytes
            })
        assert(restoredSaved)
        try assertThrowing(try Data(contentsOf: recoveryPublished) == recoveryBytes)
        try FileManager.default.removeItem(at: recoveryPublished)
        try FileManager.default.removeItem(at: recoveryStageURL)
        print("PASS: cataloged recovery retains intent until audio is readable")
        print("PASS: recovery publication is byte-preserving, idempotent and no-replace")
        try FileManager.default.removeItem(at: recoveryJournal)
        print("PASS: recovery journals round-trip, reject aliasing and preserve original files")

        // A colliding generated destination is a pre-existing user recording,
        // not a partial copy belonging to the new import. Never delete it
        // when copy or catalog persistence fails.
        let importSource = folder.appendingPathComponent("incoming-import.mp3")
        let importDestination = folder.appendingPathComponent("imported-recording.mp3")
        let incomingBytes = Data(repeating: 0x4D, count: 64 * 1024)
        let existingBytes = Data(repeating: 0x24, count: 64 * 1024)
        try incomingBytes.write(to: importSource)
        try existingBytes.write(to: importDestination)
        var importPersistCalls = 0
        do {
            try LocalAudioImportTransaction.perform(
                from: importSource, to: importDestination,
                validate: { staged in
                    let copied = try Data(contentsOf: staged)
                    assert(staged.pathExtension == "mp3" && copied == incomingBytes)
                },
                persist: { importPersistCalls += 1 })
            fatalError("Import overwrote a pre-existing recording")
        } catch {
            assert(importPersistCalls == 0)
        }
        try assertThrowing(try Data(contentsOf: importDestination) == existingBytes)
        try FileManager.default.removeItem(at: importDestination)
        do {
            try LocalAudioImportTransaction.perform(
                from: importSource, to: importDestination,
                validate: { _ in throw ImportTransactionFailure.invalidAudio },
                persist: { importPersistCalls += 1 })
            fatalError("Invalid audio was published")
        } catch ImportTransactionFailure.invalidAudio { }
        assert(!FileManager.default.fileExists(atPath: importDestination.path))
        do {
            try LocalAudioImportTransaction.perform(
                from: importSource, to: importDestination,
                validate: { _ in },
                persist: { throw ImportTransactionFailure.catalogWrite })
            fatalError("Failed catalog commit left published audio")
        } catch ImportTransactionFailure.catalogWrite { }
        assert(!FileManager.default.fileExists(atPath: importDestination.path))
        try LocalAudioImportTransaction.perform(
            from: importSource, to: importDestination,
            validate: { _ in },
            persist: { importPersistCalls += 1 })
        assert(importPersistCalls == 1)
        try assertThrowing(try Data(contentsOf: importDestination) == incomingBytes)
        try assertThrowing(try Data(contentsOf: importSource) == incomingBytes)
        let importOrphans = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(".mp3shelf-import-") }
        assert(importOrphans.isEmpty)
        print("PASS: import collisions, validation/storage failures and success preserve audio bytes")

        // The durable journal must already exist when the catalog commit
        // begins. Normal success removes it; a storage failure removes only
        // this attempt's journal and published file, never the input source.
        let journaledTrack = MusicTrack(
            id: UUID(), title: "Journaled recording", artist: "Local",
            album: "Recovery", fileName: "journaled-recording.mp3",
            originalFileName: "journaled-recording.mp3",
            artworkFileName: "journaled-cover.img", duration: 13)
        let journaledDestination = folder.appendingPathComponent(journaledTrack.fileName)
        let journaledIntent = LocalAudioRecoveryRecord.journalURL(
            for: journaledTrack.id, in: folder)
        do {
            try LocalAudioImportTransaction.perform(
                from: importSource, to: journaledDestination,
                validate: { staged in
                    let copied = try Data(contentsOf: staged)
                    assert(copied == incomingBytes)
                },
                recoveryTrack: { journaledTrack },
                persist: {
                    assert(FileManager.default.fileExists(atPath: journaledDestination.path))
                    let saved = try LocalAudioRecoveryRecord.read(
                        journaledIntent, in: folder)
                    assert(saved.track.id == journaledTrack.id)
                    assert(saved.audioLength == Int64(incomingBytes.count))
                    throw ImportTransactionFailure.catalogWrite
                })
            fatalError("Simulated failure committed a journaled import")
        } catch ImportTransactionFailure.catalogWrite { }
        assert(!FileManager.default.fileExists(atPath: journaledDestination.path))
        assert(!FileManager.default.fileExists(atPath: journaledIntent.path))
        assert(!LocalAudioRecoveryRecord.retainsArtwork(
            "journaled-cover.img", for: journaledTrack.id, in: folder))
        // Simulate an OS/filesystem refusal to unlink a published file after
        // catalog persistence fails. Preserve the original source, published
        // audio, staging bytes and durable journal for a subsequent retry.
        var injectedRollbackCalls = 0
        do {
            try LocalAudioImportTransaction.perform(
                from: importSource, to: journaledDestination,
                validate: { _ in },
                recoveryTrack: { journaledTrack },
                rollbackPublished: { published in
                    assert(published == journaledDestination)
                    injectedRollbackCalls += 1
                    throw ImportTransactionFailure.catalogWrite
                },
                persist: { throw ImportTransactionFailure.catalogWrite })
            fatalError("Injected rollback failure unexpectedly committed")
        } catch ImportTransactionFailure.catalogWrite { }
        assert(injectedRollbackCalls == 1)
        let retainedIntent = try LocalAudioRecoveryRecord.read(
            journaledIntent, in: folder)
        let retainedStage = folder.appendingPathComponent(retainedIntent.stagingName)
        let cover = folder.appendingPathComponent("journaled-cover.img")
        let coverBytes = Data(repeating: 0xA3, count: 2048)
        try coverBytes.write(to: cover)
        assert(LocalAudioRecoveryRecord.retainsArtwork(
            cover.lastPathComponent, for: journaledTrack.id, in: folder))
        assert(!LocalAudioRecoveryRecord.retainsArtwork(
            cover.lastPathComponent, for: UUID(), in: folder))
        assert(!LocalAudioRecoveryRecord.retainsArtwork(
            "../journaled-cover.img", for: journaledTrack.id, in: folder))
        assert(!LocalAudioRecoveryRecord.retainsArtwork(
            "other-cover.img", for: journaledTrack.id, in: folder))
        assert(FileManager.default.fileExists(atPath: retainedStage.path))
        try assertThrowing(try Data(contentsOf: retainedStage) == incomingBytes)
        try assertThrowing(try Data(contentsOf: journaledDestination) == incomingBytes)
        try assertThrowing(try Data(contentsOf: importSource) == incomingBytes)
        let retryPublished = try retainedIntent.restorePublication(in: folder) {
            (try? Data(contentsOf: $0)) == incomingBytes
        }
        assert(retryPublished == journaledDestination)
        try FileManager.default.removeItem(at: journaledDestination)
        let repairedAfterLoss = try retainedIntent.restorePublication(in: folder) {
            (try? Data(contentsOf: $0)) == incomingBytes
        }
        assert(repairedAfterLoss == journaledDestination)
        try assertThrowing(try Data(contentsOf: journaledDestination) == incomingBytes)
        try FileManager.default.removeItem(at: journaledDestination)
        try FileManager.default.removeItem(at: retainedStage)
        try FileManager.default.removeItem(at: journaledIntent)
        assert(!LocalAudioRecoveryRecord.retainsArtwork(
            cover.lastPathComponent, for: journaledTrack.id, in: folder))
        try assertThrowing(try Data(contentsOf: cover) == coverBytes)
        try FileManager.default.removeItem(at: cover)
        print("PASS: failed rollback retains staged bytes, artwork and journal for retry")
        try LocalAudioImportTransaction.perform(
            from: importSource, to: journaledDestination,
            validate: { _ in },
            recoveryTrack: { journaledTrack },
            persist: {
                let saved = try LocalAudioRecoveryRecord.read(
                    journaledIntent, in: folder)
                assert(saved.track.fileName == journaledTrack.fileName)
            })
        try assertThrowing(try Data(contentsOf: journaledDestination) == incomingBytes)
        assert(!FileManager.default.fileExists(atPath: journaledIntent.path))
        try assertThrowing(try Data(contentsOf: importSource) == incomingBytes)
        let journalLeftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        assert(!journalLeftovers.contains {
            $0.hasPrefix(".mp3shelf-recovery-") || $0.hasPrefix(".mp3shelf-import-")
        })
        print("PASS: journal intent exists before catalog publication and cleans up safely")
        // A cancellation after publication must roll back its own recording
        // and journal without deleting the original source.
        let cancelledTrack = MusicTrack(
            id: UUID(), title: "Cancelled journal", artist: "Local",
            album: "Recovery", fileName: "cancelled-journal.mp3",
            originalFileName: "cancelled-journal.mp3", duration: 13)
        let cancelledDestination = folder.appendingPathComponent(cancelledTrack.fileName)
        let cancelledJournal = LocalAudioRecoveryRecord.journalURL(
            for: cancelledTrack.id, in: folder)
        do {
            try LocalAudioImportTransaction.perform(
                from: importSource, to: cancelledDestination,
                validate: { _ in },
                recoveryTrack: { cancelledTrack },
                persist: { throw CancellationError() })
            fatalError("Cancelled journaled import unexpectedly committed")
        } catch is CancellationError { }
        assert(!FileManager.default.fileExists(atPath: cancelledDestination.path))
        assert(!FileManager.default.fileExists(atPath: cancelledJournal.path))
        try assertThrowing(try Data(contentsOf: importSource) == incomingBytes)

        // A pre-existing recording with the same destination is never
        // overwritten, even if the import already wrote its recovery intent.
        let collisionTrack = MusicTrack(
            id: UUID(), title: "Collision journal", artist: "Local",
            album: "Recovery", fileName: "collision-journal.mp3",
            originalFileName: "collision-journal.mp3", duration: 13)
        let collisionDestination = folder.appendingPathComponent(collisionTrack.fileName)
        let collisionJournal = LocalAudioRecoveryRecord.journalURL(
            for: collisionTrack.id, in: folder)
        try existingBytes.write(to: collisionDestination)
        var collisionPersisted = false
        do {
            try LocalAudioImportTransaction.perform(
                from: importSource, to: collisionDestination,
                validate: { _ in },
                recoveryTrack: { collisionTrack },
                persist: { collisionPersisted = true })
            fatalError("Colliding journaled import replaced user audio")
        } catch { }
        assert(!collisionPersisted)
        assert(!FileManager.default.fileExists(atPath: collisionJournal.path))
        try assertThrowing(try Data(contentsOf: collisionDestination) == existingBytes)
        try FileManager.default.removeItem(at: collisionDestination)
        print("PASS: journaled cancellation and collisions preserve original audio")




        // Simulate two interruption boundaries: an aborted decoder/probe
        // before publication, and cancellation after publication but before
        // the catalog can durably reference its new recording.
        try FileManager.default.removeItem(at: importDestination)
        do {
            try LocalAudioImportTransaction.perform(
                from: importSource, to: importDestination,
                validate: { _ in throw CancellationError() },
                persist: { importPersistCalls += 1 })
            fatalError("Cancelled validation published an audio file")
        } catch is CancellationError { }
        assert(!FileManager.default.fileExists(atPath: importDestination.path))
        do {
            try LocalAudioImportTransaction.perform(
                from: importSource, to: importDestination,
                validate: { _ in },
                persist: { throw CancellationError() })
            fatalError("Cancelled catalog update retained unpublished audio")
        } catch is CancellationError { }
        assert(!FileManager.default.fileExists(atPath: importDestination.path))
        try assertThrowing(try Data(contentsOf: importSource) == incomingBytes)
        let afterCancellation = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        assert(!afterCancellation.contains { $0.hasPrefix(".mp3shelf-import-") })

        // A process can die between writing the staging copy and publishing.
        // The next import must never delete another session's recoverable
        // partial recording: each transaction cleans only its own unique path.
        let crashedSessionStage = folder.appendingPathComponent(".mp3shelf-import-old-session.mp3")
        let recoverableBytes = Data([0x49, 0x44, 0x33, 0xAB, 0xCD])
        try recoverableBytes.write(to: crashedSessionStage)
        do {
            try LocalAudioImportTransaction.perform(
                from: importSource, to: importDestination,
                validate: { _ in throw ImportTransactionFailure.invalidAudio },
                persist: { importPersistCalls += 1 })
            fatalError("Rejected reentry unexpectedly committed audio")
        } catch ImportTransactionFailure.invalidAudio { }
        assert(!FileManager.default.fileExists(atPath: importDestination.path))
        try assertThrowing(try Data(contentsOf: crashedSessionStage) == recoverableBytes)
        // Keep the recovery fixture from influencing unrelated archive tests.
        try FileManager.default.removeItem(at: crashedSessionStage)
        try assertThrowing(try Data(contentsOf: importSource) == incomingBytes)
        assert(importPersistCalls == 1)
        print("PASS: simulated cancellation leaves no new catalog file; crashed-session bytes survive reentry")


        // Case-insensitive iPhone filesystems may resolve differently cased
        // legacy catalog names to the same audio or sidecar. Deleting one
        // entry must retain files referenced by the surviving entry.
        assert(LocalLibraryFileSafety.isReferenced("Track.MP3", by: ["track.mp3"]))
        assert(LocalLibraryFileSafety.isReferenced("Café.img", by: ["Cafe.img"]))
        assert(LocalLibraryFileSafety.isReferenced("Lyrics.LRC", by: [nil, "lyrics.lrc"]))
        assert(!LocalLibraryFileSafety.isReferenced("track.mp3", by: [nil, "other.mp3"]))
        assert(!LocalLibraryFileSafety.isReferenced("track.mp3", by: []))
        print("PASS: shared audio and sidecars survive case-variant catalog references")

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
        // A malformed persisted fileName must never escape the owned Music
        // folder when a backup exports or a recording is removed. Existing
        // catalog-generated filenames and genuine regular files still work.
        let ownedFolder = folder.appendingPathComponent("OwnedMusic", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedFolder, withIntermediateDirectories: true)
        let ownedAudio = ownedFolder.appendingPathComponent("owned.mp3")
        let outsideAudio = folder.appendingPathComponent("outside.mp3")
        try originalBytes.write(to: ownedAudio)
        try originalBytes.write(to: outsideAudio)
        let ownedLink = ownedFolder.appendingPathComponent("linked.mp3")
        try FileManager.default.createSymbolicLink(
            at: ownedLink, withDestinationURL: outsideAudio)
        let internalLink = ownedFolder.appendingPathComponent("internal.mp3")
        try FileManager.default.createSymbolicLink(
            at: internalLink, withDestinationURL: ownedAudio)
        let disguisedDirectory = ownedFolder.appendingPathComponent("folder.mp3", isDirectory: true)
        try FileManager.default.createDirectory(
            at: disguisedDirectory, withIntermediateDirectories: true)
        assert(LocalLibraryFileSafety.regularFile(named: "owned.mp3", in: ownedFolder) == ownedAudio)
        for badName in ["../outside.mp3", "../../outside.mp3", "/tmp/outside.mp3",
                        "sub/owned.mp3", "sub\\owned.mp3", ".", "..", "",
                        "linked.mp3", "internal.mp3", "folder.mp3", "missing.mp3"] {
            assert(LocalLibraryFileSafety.regularFile(named: badName, in: ownedFolder) == nil,
                   "Accepted unsafe catalog filename: \(badName)")
        }
        assert(LocalLibraryFileSafety.regularFile(named: nil, in: ownedFolder) == nil)
        let unaffectedOutsideBytes = try Data(contentsOf: outsideAudio)
        let unaffectedOwnedBytes = try Data(contentsOf: ownedAudio)
        assert(unaffectedOutsideBytes == originalBytes && unaffectedOwnedBytes == originalBytes)
        print("PASS: malformed and linked catalog paths cannot escape owned music storage")

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

        // A malformed artwork reference on a later track must fail archive
        // preflight before a restore can import any earlier recording.
        // Build a real two-track container, then rewrite only its manifest;
        // keep the payload bytes unchanged to exercise the actual reader.
        let secondSong = MusicTrack(
            id: UUID(), title: "Second song", artist: "Local artist",
            album: "Album", fileName: "second.mp3",
            originalFileName: "second.mp3", duration: 30)
        let secondAudio = folder.appendingPathComponent("second.mp3")
        let secondBytes = Data([0x49, 0x44, 0x33, 9, 8, 7, 6])
        try secondBytes.write(to: secondAudio)
        let twoTrackBackup = folder.appendingPathComponent("two-track-valid.mp3shelf")
        try PortableShelfArchive.export([
            .init(track: song, audioURL: audio, artwork: nil, lyrics: nil),
            .init(track: secondSong, audioURL: secondAudio, artwork: nil, lyrics: nil)
        ], playlists: [], to: twoTrackBackup)
        let twoTrackArchive = try PortableShelfArchive.open(twoTrackBackup)
        assert(twoTrackArchive.manifest.tracks.count == 2)
        // Verify both recordings independently, not just the first payload.
        // This catches shifted offsets or artwork/track boundary regressions
        // that a single-track round trip cannot detect.
        for (index, expected) in [originalBytes, secondBytes].enumerated() {
            let entry = twoTrackArchive.manifest.tracks[index]
            let extractedTrack = try PortableShelfArchive.extract(
                entry.audio, from: twoTrackArchive, extensionName: "mp3")
            defer { try? FileManager.default.removeItem(at: extractedTrack) }
            let restoredBytes = try Data(contentsOf: extractedTrack)
            assert(restoredBytes == expected,
                   "Track \(index) must restore exactly its original audio bytes")
        }
        // Reopening the published backup must preserve every manifest offset
        // and source recording; extraction must never consume source files.
        let reopenedTwoTrack = try PortableShelfArchive.open(twoTrackBackup)
        assert(reopenedTwoTrack.manifest.tracks.map { $0.audio.offset } ==
               twoTrackArchive.manifest.tracks.map { $0.audio.offset })
        let firstSourceAfterRoundTrip = try Data(contentsOf: audio)
        let secondSourceAfterRoundTrip = try Data(contentsOf: secondAudio)
        assert(firstSourceAfterRoundTrip == originalBytes)
        assert(secondSourceAfterRoundTrip == secondBytes)
        print("PASS: two-track archive extraction preserves both audio payloads")
        var brokenManifest = twoTrackArchive.manifest
        brokenManifest.tracks[1].artwork = .init(
            offset: brokenManifest.tracks[1].audio.offset, length: 0, type: "image/jpeg")
        let manifestData = try JSONEncoder().encode(brokenManifest)
        let originalContainer = try Data(contentsOf: twoTrackBackup)
        let originalPayload = originalContainer.subdata(
            in: Int(twoTrackArchive.payloadOffset)..<originalContainer.count)
        var brokenContainer = PortableShelfArchive.magic
        let manifestLength = UInt32(manifestData.count)
        brokenContainer.append(contentsOf: [
            UInt8(truncatingIfNeeded: manifestLength),
            UInt8(truncatingIfNeeded: manifestLength >> 8),
            UInt8(truncatingIfNeeded: manifestLength >> 16),
            UInt8(truncatingIfNeeded: manifestLength >> 24)
        ])
        brokenContainer.append(manifestData)
        brokenContainer.append(originalPayload)
        let malformedArtworkBackup = folder.appendingPathComponent("late-empty-artwork.mp3shelf")
        try brokenContainer.write(to: malformedArtworkBackup)
        do {
            _ = try PortableShelfArchive.open(malformedArtworkBackup)
            fatalError("Late zero-length artwork must fail before restoration")
        } catch PortableShelfArchive.ArchiveError.invalidManifest {
            // Expected: reject the entire archive during preflight.
        }
        let preservedFirstAudio = try Data(contentsOf: audio)
        let preservedSecondAudio = try Data(contentsOf: secondAudio)
        let preservedValidBackup = try Data(contentsOf: twoTrackBackup)
        assert(preservedFirstAudio == originalBytes)
        assert(preservedSecondAudio == secondBytes)
        assert(preservedValidBackup == originalContainer)
        print("PASS: late zero-length artwork rejected without changing audio or valid backup")

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
        let reopenedLibrary = try JSONDecoder().decode(PersistedLibrary.self, from: Data(contentsOf: database))
        assert(reopenedLibrary.tracks == snapshot.tracks && reopenedLibrary.playlists == snapshot.playlists)
        assert(reopenedLibrary.tracks[0].fileName == "my-song.mp3")
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
        try assertThrowing(try PortableShelfArchive.readSidecar(
            named: "song.lrc", from: sidecarDirectory,
            maximumBytes: 500 * 1024) == replacementLyrics)
        // Restore the original fixture before the remaining archive tests.
        try expectedLyrics.write(to: savedLyrics, options: .atomic)
        try assertThrowing(try PortableShelfArchive.readSidecar(
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
        // These are also the runtime artwork/lyrics readers' limits. A damaged
        // catalog must not allocate an unbounded sidecar or escape the shelf.
        let oversizedLyrics = sidecarDirectory.appendingPathComponent("oversized.lrc")
        let oversizedBytes = Data(repeating: 0x61, count: 500 * 1024 + 1)
        try oversizedBytes.write(to: oversizedLyrics)
        do {
            _ = try PortableShelfArchive.readSidecar(
                named: "oversized.lrc", from: sidecarDirectory,
                maximumBytes: 500 * 1024)
            fatalError("Runtime lyrics reader accepted an oversized sidecar")
        } catch PortableShelfArchive.ArchiveError.oversized {
            // Expected: no large allocation or partial lyrics.
        }
        try assertThrowing(try Data(contentsOf: oversizedLyrics) == oversizedBytes)
        do {
            _ = try PortableShelfArchive.readSidecar(
                named: folder.appendingPathComponent("private-artwork.img").path, from: sidecarDirectory,
                maximumBytes: 20 * 1024 * 1024)
            fatalError("Runtime artwork reader accepted an absolute path")
        } catch PortableShelfArchive.ArchiveError.invalidManifest {
            // Expected.
        }
        // Replacing lyrics must not delete a sidecar still referenced by a
        // second legacy recording under a differently cased APFS filename.
        // The same conservative alias rule protects removeTrack().
        assert(LocalLibraryFileSafety.isReferenced(
            "Shared-Lyrics.LRC", by: ["shared-lyrics.lrc", nil]))
        assert(LocalLibraryFileSafety.isReferenced(
            "Café.lrc", by: ["cafe.lrc"]))
        assert(!LocalLibraryFileSafety.isReferenced(
            "Shared-Lyrics.LRC", by: ["unrelated.lrc", nil]))
        // A new unique sidecar must be removable after the final owner drops
        // it, without treating unrelated names as references.
        assert(!LocalLibraryFileSafety.isReferenced(
            "new-unique.lrc", by: ["old-shared.lrc"]))
        print("PASS: lyrics replacement retains case/diacritic aliases")
        print("PASS: runtime sidecar size and path limits preserve source bytes")
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
        let linkedSourceBackup = folder.appendingPathComponent("linked-source.mp3shelf")
        do {
            try PortableShelfArchive.export([
                .init(track: song, audioURL: linkedSource, artwork: nil, lyrics: nil)
            ], playlists: [list], to: linkedSourceBackup)
            fatalError("Symlink source should never be exported")
        } catch {
            assert(!FileManager.default.fileExists(atPath: linkedSourceBackup.path))
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
        // A published backup is immutable: a second export to the same path
        // must fail without changing even one byte of the original archive.
        let protectedBackupBytes = try Data(contentsOf: portableURL)
        var rejectedOverwrite = false
        do {
            try PortableShelfArchive.export([
                .init(track: portableSong, audioURL: audio, artwork: nil, lyrics: nil)
            ], playlists: [portableList], to: portableURL)
        } catch {
            rejectedOverwrite = true
        }
        assert(rejectedOverwrite, "Export must reject an existing backup")
        let preservedBackupBytes = try Data(contentsOf: portableURL)
        let preservedSourceBytes = try Data(contentsOf: audio)
        assert(preservedBackupBytes == protectedBackupBytes)
        assert(preservedSourceBytes == originalBytes)
        let protectedArchive = try PortableShelfArchive.open(portableURL)
        assert(protectedArchive.manifest.tracks.map(\.id) == ["web-song-1"])
        let protectedExtract = try PortableShelfArchive.extract(
            protectedArchive.manifest.tracks[0].audio,
            from: protectedArchive, extensionName: "mp3")
        let preservedExtractedBytes = try Data(contentsOf: protectedExtract)
        assert(preservedExtractedBytes == originalBytes)
        try FileManager.default.removeItem(at: protectedExtract)
        let backupFolderEntries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        assert(!backupFolderEntries.contains {
            $0.contains("portable-identities.mp3shelf") && $0.hasSuffix(".partial")
        })
        print("PASS: rejected backup overwrite preserves archive and recording bytes")
        // Two exporters racing for an absent destination must never replace
        // each other's output. Both candidates contain distinct audio bytes;
        // exactly one must win the atomic publish operation.
        let raceAudioA = folder.appendingPathComponent("race-a.mp3")
        let raceAudioB = folder.appendingPathComponent("race-b.mp3")
        let raceBytesA = Data(repeating: 0x31, count: 256 * 1024)
        let raceBytesB = Data(repeating: 0x72, count: 256 * 1024)
        try raceBytesA.write(to: raceAudioA)
        try raceBytesB.write(to: raceAudioB)
        // Repeat with fresh destinations: a one-off race can pass even when
        // a rare publication interleaving would overwrite the winner.
        // Each iteration has an independent gate, results accumulator and
        // destination, so stale successes cannot mask a later failure.
        for iteration in 0..<12 {
            let raceDestination = folder.appendingPathComponent(
                "racing-export-\(iteration).mp3shelf")
            let raceGate = DispatchSemaphore(value: 0)
            let raceGroup = DispatchGroup()
            let raceResults = ArchiveExportRaceResults()
            for index in 0..<2 {
                raceGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { raceGroup.leave() }
                    raceGate.wait()
                    do {
                        try PortableShelfArchive.export([
                            .init(track: portableSong,
                                  audioURL: index == 0 ? raceAudioA : raceAudioB,
                                  artwork: nil, lyrics: nil)
                        ], playlists: [portableList], to: raceDestination)
                        raceResults.recordSuccess(index)
                    } catch {
                        raceResults.recordFailure(error)
                    }
                }
            }
            raceGate.signal()
            raceGate.signal()
            guard raceGroup.wait(timeout: .now() + 30) == .success else {
                fatalError("Concurrent archive exporters timed out in iteration \(iteration)")
            }
            let raceOutcome = raceResults.snapshot()
            assert(raceOutcome.winners.count == 1 && raceOutcome.failureCount == 1,
                   "Exactly one exporter must succeed in iteration \(iteration)")
            let publishedBefore = try Data(contentsOf: raceDestination)
            let raceArchive = try PortableShelfArchive.open(raceDestination)
            assert(raceArchive.manifest.tracks.count == 1)
            let raceExtract = try PortableShelfArchive.extract(
                raceArchive.manifest.tracks[0].audio,
                from: raceArchive, extensionName: "mp3")
            let raceExtractBytes = try Data(contentsOf: raceExtract)
            assert(raceExtractBytes ==
                   (raceOutcome.winners[0] == 0 ? raceBytesA : raceBytesB),
                   "Winner audio differs in iteration \(iteration)")
            try FileManager.default.removeItem(at: raceExtract)
            // A failed contender must not alter the archive after its
            // successful competitor has returned and the group has joined.
            let publishedAfter = try Data(contentsOf: raceDestination)
            assert(publishedAfter == publishedBefore,
                   "Published archive changed after contention")
            let raceEntries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            assert(!raceEntries.contains {
                $0.contains("racing-export-\(iteration).mp3shelf") &&
                $0.hasSuffix(".partial")
            }, "Export staging leak in iteration \(iteration)")
            try FileManager.default.removeItem(at: raceDestination)
        }
        let sourceAfterRaceA = try Data(contentsOf: raceAudioA)
        let sourceAfterRaceB = try Data(contentsOf: raceAudioB)
        assert(sourceAfterRaceA == raceBytesA)
        assert(sourceAfterRaceB == raceBytesB)
        print("PASS: 12 competing exporter races each publish one byte-intact backup")

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
        try assertThrowing(try Data(contentsOf: comparisonA) == comparisonBytes)
        // A cancelled restore must not continue a potentially multi-gigabyte
        // byte-for-byte duplicate scan. Gate the worker so this is deterministic
        // rather than relying on timing or a large fixture.
        let compareGate = DispatchSemaphore(value: 0)
        let compareFinished = DispatchSemaphore(value: 0)
        let cancelledComparison = Task.detached {
            compareGate.wait()
            assert(!PortableShelfArchive.audioFilesIdentical(comparisonA, comparisonA))
            compareFinished.signal()
        }
        cancelledComparison.cancel()
        compareGate.signal()
        guard compareFinished.wait(timeout: .now() + 10) == .success else {
            fatalError("Cancelled duplicate comparison did not terminate promptly")
        }
        try assertThrowing(try Data(contentsOf: comparisonA) == comparisonBytes)
        print("PASS: cancelled duplicate scan returns false without modifying audio")
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
        try assertThrowing(try Data(contentsOf: legitimate) == originalBytes)
        try FileManager.default.removeItem(at: legitimate)
        print("PASS: archive extraction permits only declared media slices")

        print("Portable MP3 Shelf v1 archive round-trip and validation passed.")
    }
}
