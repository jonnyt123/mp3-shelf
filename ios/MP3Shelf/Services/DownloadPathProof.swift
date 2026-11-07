#if DEBUG
import Foundation
import AVFoundation
import CryptoKit

/// Applies only to the isolated proof's second launch. Background transfers
/// are not attached on that launch; ordinary foreground HTTP(S) is refused.
final class DownloadProofOfflineNetwork: URLProtocol, @unchecked Sendable {
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
    }
    private static let counter = Counter()
    private static let installation = URLProtocol.registerClass(DownloadProofOfflineNetwork.self)
    static func install() -> Bool { installation }
    static var isRequested: Bool {
        Bundle.main.bundleIdentifier == "com.jonnyt.mp3shelf.downloadproof" &&
            (ProcessInfo.processInfo.arguments.contains("--mp3shelf-prove-offline-restart") ||
             ProcessInfo.processInfo.arguments.contains("--mp3shelf-prove-local-restart"))
    }
    static var blockedRequestCount: Int {
        counter.lock.lock()
        defer { counter.lock.unlock() }
        return counter.count
    }
    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
    }
    override class func canInit(with task: URLSessionTask) -> Bool {
        guard let request = task.currentRequest else { return false }
        return canInit(with: request)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.counter.lock.lock()
        Self.counter.count += 1
        Self.counter.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() { }
}

/// Runs only in the isolated Simulator app installed by prove-download-path.sh.
/// Uses the production search, matcher, review queue, downloader and importer.
@MainActor
enum DownloadPathProof {
    private static let processToken = UUID().uuidString
    private static var runToken: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--mp3shelf-proof-run"),
              index + 1 < arguments.count, UUID(uuidString: arguments[index + 1]) != nil else { return nil }
        return arguments[index + 1]
    }

    static func run(library: MusicLibrary, localFixture: Bool = false) async {
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MP3ShelfDownloadProof.json")
        var steps: [[String: String]] = []
        var report: [String: Any] = ["schema": "mp3-shelf-download-proof-v2", "status": "RUNNING",
            "scope": "iOS Simulator foreground pipeline; physical-device/background acceptance is separate"]
        report["runID"] = runToken
        report["initialProcessToken"] = processToken
        report["mode"] = localFixture ? "local-import-restart" : "live-download"
        var playlistID: UUID?
        func record(_ stage: String, _ detail: String) throws {
            steps.append(["stage": stage, "detail": detail])
            report["steps"] = steps
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output, options: .atomic)
        }
        func fail(_ message: String) -> NSError {
            NSError(domain: "MP3Shelf.DownloadProof", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])
        }
        do {
            try record("start", localFixture ? "Local MP3 import/restart test; no live-source result is claimed" :
                "Live test: Carefree — Kevin MacLeod, expected 206 seconds")
            guard Bundle.main.bundleIdentifier == "com.jonnyt.mp3shelf.downloadproof", runToken != nil,
                  library.tracks.isEmpty, library.playlists.isEmpty else {
                throw fail("Proof requires a fresh, isolated test app; the normal music library is never cleared.")
            }
            let fixture = output.deletingLastPathComponent().appendingPathComponent("MP3ShelfRestartFixture.mp3")
            var expectedDuration = 206.0
            if localFixture {
                let audio = try AVAudioFile(forReading: fixture)
                expectedDuration = Double(audio.length) / audio.processingFormat.sampleRate
                guard expectedDuration.isFinite, expectedDuration > 0 else { throw fail("The local fixture is empty") }
            }
            let wish = PlaylistWish(title: localFixture ? "Offline restart fixture" : "Carefree",
                                    artist: localFixture ? "MP3 Shelf" : "Kevin MacLeod", album: "",
                                    durationSeconds: expectedDuration)
            report["expectedDurationSeconds"] = expectedDuration
            report["expectedTitle"] = wish.title
            report["expectedArtist"] = wish.artist
            let imported = library.importPlaylist(wishes: [wish], name: "Download path proof")
            playlistID = imported.playlistID
            var finished = false
            if localFixture {
                finished = try await library.importStagedAudio(from: fixture, matching: wish,
                    attribution: AudioSourceAttribution(pageURL: "", licenseURL: "", providerName: "Local test fixture"))
                report["selection"] = "local-fixture"
                try record("local-fixture-import", "Imported the repository's real MP3 fixture through the production importer; no network transfer")
            } else {
                try await verifyRejectedQueueSave(for: wish, playlistID: imported.playlistID)
                try record("queue-write-failure-rejected", "An unwritable queue file prevented a ticket and background task from being created")
                for _ in 0..<30 {
                    if library.canResolveRecordingSources(for: imported.playlistID) { break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                guard library.canResolveRecordingSources(for: imported.playlistID) else {
                    throw fail("The test app is waiting for its normal foreground/Wi-Fi policy. Connect the Mac to Wi-Fi and retry.")
                }
                let candidates = try await NativeAudioEngine.shared.search(for: wish, allowsCellular: false)
                try record("search", "Received \(candidates.count) recording candidates")
                let ranked = RecordingMatcher.rank(candidates, for: wish)
                let candidate: RecordingCandidate
                if let automatic = RecordingMatcher.automaticChoice(ranked) {
                    candidate = automatic
                    report["selection"] = "automatic"
                    // The actual Find & Save workflow runs below, including fallback.
                } else if let reference = ranked.first(where: {
                    $0.candidate.id == "sMcWOaJFuw0" && $0.decision != .rejected
                }) {
                    // This explicit reference exercises the same path as choosing
                    // a recording in Review matches. It does not prove auto selection.
                    candidate = reference.candidate
                    report["selection"] = "reference-review"
                } else { throw fail("No matching reference recording was found; no substituted source is accepted.") }
                let usesAutomaticWorkflow = report["selection"] as? String == "automatic"
                try record("match", "Selected \(candidate.id); selection=\(report["selection"] as? String ?? "unknown")")
                if usesAutomaticWorkflow {
                    library.startAutomaticDownloads(for: imported.playlistID)
                    try record("automatic-search-started", "Started the production Find & Save workflow")
                } else {
                    try await library.queueRecording(candidate, matching: wish, playlistID: imported.playlistID)
                }
                let transfers = BackgroundAudioDownloader.shared
                let deadline = Date().addingTimeInterval(240)
                var recordedQueue = false
                while Date() < deadline {
                    try Task.checkCancellation()
                    let tickets = transfers.ticketsForPlaylist(imported.playlistID)
                    if !recordedQueue, let ticket = tickets.first {
                        report["sourceProvider"] = ticket.provider
                        report["sourcePage"] = ticket.sourcePage.absoluteString
                        try record("resolved-and-queued", "The production workflow created a background transfer")
                        recordedQueue = true
                    }
                    if let completed = tickets.first(where: { $0.status == .imported }) {
                        report["sourceProvider"] = completed.provider
                        report["sourcePage"] = completed.sourcePage.absoluteString
                        finished = true
                        break
                    }
                    let job = library.discoveryJob(for: imported.playlistID)
                    let recoveryPending = usesAutomaticWorkflow && (job.map { !$0.isComplete && !$0.isPaused } ?? false)
                    if !tickets.contains(where: { $0.status == .queued }), !recoveryPending,
                       let failure = tickets.first(where: { $0.status == .failed || $0.status == .cancelled }) {
                        throw fail(failure.failureReason ?? "Transfer was cancelled or failed")
                    }
                    if usesAutomaticWorkflow, tickets.isEmpty,
                       let job = library.discoveryJob(for: imported.playlistID), job.isComplete {
                        let details = job.lookupDetails?[wish.id.uuidString]?.suffix(6).joined(separator: " • ") ?? "No source was queued"
                        throw fail("Automatic source search ended without a transfer: " + details)
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            guard finished, let track = MusicMatching.reusableOfflineTrack(for: wish, in: library.tracks) else {
                throw fail("Transfer/import did not finish before its deadline")
            }
            let file = library.fileURL(for: track)
            guard file.isFileURL, try DownloadedAudioFormat.isMP3(file) else {
                throw fail("Saved file is not an actual MP3")
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard !data.isEmpty else { throw fail("Saved MP3 is empty") }
            report["filePath"] = file.path
            report["trackID"] = track.id.uuidString
            report["playlistID"] = imported.playlistID.uuidString
            report["fileBytes"] = data.count
            report["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try record("saved-mp3", "Imported \(data.count) bytes, MP3 codec confirmed")
            let decoded = try await Task.detached(priority: .utility) {
                let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else {
                    throw NSError(domain: "MP3Shelf.DownloadProof", code: 2)
                }
                var frames: Int64 = 0
                var audible = false
                while true {
                    try Task.checkCancellation()
                    try audio.read(into: buffer, frameCount: 4096)
                    if buffer.frameLength == 0 { break }
                    frames += Int64(buffer.frameLength)
                    if let samples = buffer.floatChannelData?[0] {
                        for index in 0..<Int(buffer.frameLength) where abs(samples[index]) > 0.0001 { audible = true; break }
                    }
                }
                return (frames, audible, Double(frames) / audio.processingFormat.sampleRate)
            }.value
            guard decoded.0 > 0, decoded.1, abs(decoded.2 - expectedDuration) <= (localFixture ? 0.1 : 4) else {
                throw fail("Full MP3 decode was empty, silent or had the wrong duration")
            }
            report["decodedFrames"] = decoded.0
            report["durationSeconds"] = decoded.2
            try record("full-decode", "Decoded the entire saved MP3; non-silent PCM and expected duration confirmed")
            let player = try AVAudioPlayer(contentsOf: file)
            player.volume = 0
            if localFixture { player.numberOfLoops = -1 }
            guard player.prepareToPlay(), player.play() else { throw fail("Local-file playback could not start") }
            defer { player.stop() }
            let minimumAdvance = min(0.25, player.duration / 4)
            let playbackDeadline = Date().addingTimeInterval(5)
            while player.currentTime <= minimumAdvance && Date() < playbackDeadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard player.currentTime > minimumAdvance else { throw fail("Local-file playback did not advance") }
            try record("local-playback", "Local file player advanced without a streaming URL; output muted during the test")
            guard BackgroundAudioDownloader.shared.pendingCount() == 0 else {
                throw fail("A transfer is still active; the isolated library is not ready for the restart test")
            }
            try await verifyRejectedSave(using: file, library: library)
            try record("storage-failure-rejected", "A real library write failure was rejected; saved records and audio remained unchanged")
            report["status"] = "READY_FOR_RESTART"
            try record("ready-for-restart", "The runner must terminate this process and reopen the saved library")
        } catch {
            if let playlistID { library.stopBackgroundTransfers(for: playlistID) }
            report["status"] = "FAIL"
            report["error"] = error.localizedDescription
            try? record("failed", error.localizedDescription)
        }
    }

    private static func verifyRejectedQueueSave(for wish: PlaylistWish, playlistID: UUID) async throws {
        let fm = FileManager.default
        let transfers = BackgroundAudioDownloader.shared
        let manifest = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MP3Shelf/background-audio-tickets.json")
        func fail(_ message: String) -> NSError {
            NSError(domain: "MP3Shelf.DownloadProof", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard transfers.ticketsForPlaylist().isEmpty, !(await transfers.hasBackgroundTasksForProof()),
              !fm.fileExists(atPath: manifest.path) else {
            throw fail("Queue failure proof requires an empty, isolated download queue")
        }

        // A directory at the manifest destination blocks a real atomic save.
        try fm.createDirectory(at: manifest, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: manifest) }
        let url = URL(string: "https://example.invalid/queue-proof.mp3")!
        let source = AudioCatalogMatch(downloadURL: url, itemURL: url, licenseURL: nil, sourceName: "Queue proof fixture")
        do {
            try transfers.enqueue(source: source, requested: wish, playlistID: playlistID)
            throw fail("Queueing did not report the manifest write failure")
        } catch let error as NSError where error.domain == BackgroundTicketManifestPolicy.writeFailureDomain {
            guard transfers.ticketsForPlaylist().isEmpty, transfers.pendingCount() == 0,
                  !(await transfers.hasBackgroundTasksForProof()) else {
                throw fail("The queue added a ticket or started a transfer despite the write failure")
            }
        }
    }

    private static func verifyRejectedSave(using file: URL, library: MusicLibrary) async throws {
        let fm = FileManager.default
        let database = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MP3Shelf/library.json")
        let music = file.deletingLastPathComponent()
        let original = try Data(contentsOf: database)
        let originalTracks = library.tracks
        let originalPlaylists = library.playlists
        let originalFiles = Set(try fm.contentsOfDirectory(atPath: music.path))
        let backup = database.deletingLastPathComponent().appendingPathComponent("proof-save-\(UUID().uuidString).json")
        let probe = fm.temporaryDirectory.appendingPathComponent("proof-save-\(UUID().uuidString).mp3")
        try fm.copyItem(at: file, to: probe)
        defer { try? fm.removeItem(at: probe) }
        try fm.moveItem(at: database, to: backup)
        var restored = false
        defer {
            if !restored {
                try? fm.removeItem(at: database)
                try? fm.moveItem(at: backup, to: database)
            }
        }
        // A directory at the file destination produces a real atomic-write
        // failure without changing permissions or filling the user's disk.
        try fm.createDirectory(at: database, withIntermediateDirectories: false)
        let rejected = await library.importAudio(urls: [probe])
        try fm.removeItem(at: database)
        try fm.moveItem(at: backup, to: database)
        restored = true
        let currentFiles = Set(try fm.contentsOfDirectory(atPath: music.path))
        let currentDatabase = try Data(contentsOf: database)
        guard rejected.imported == 0, !rejected.errors.isEmpty,
              library.tracks == originalTracks, library.playlists == originalPlaylists,
              currentFiles == originalFiles, currentDatabase == original else {
            throw NSError(domain: "MP3Shelf.DownloadProof", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "A failed save reported import success or changed the existing library"])
        }
    }

    static func verifyAfterRestart(library: MusicLibrary, playback: PlaybackController,
                                   networkGuardInstalled: Bool) async {
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MP3ShelfDownloadProof.json")
        var report: [String: Any] = ["schema": "mp3-shelf-download-proof-v2", "status": "RUNNING"]
        var steps: [[String: String]] = []
        func record(_ stage: String, _ detail: String) throws {
            steps.append(["stage": stage, "detail": detail])
            report["steps"] = steps
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output, options: .atomic)
        }
        func fail(_ message: String) -> NSError {
            NSError(domain: "MP3Shelf.DownloadProof", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { playback.stop() }
        do {
            guard DownloadProofOfflineNetwork.isRequested, networkGuardInstalled, let runToken else {
                throw fail("The isolated restart launch and foreground network guard are required")
            }
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
            guard let saved, saved["schema"] as? String == "mp3-shelf-download-proof-v2",
                  saved["status"] as? String == "READY_FOR_RESTART",
                  saved["runID"] as? String == runToken,
                  let initialProcess = saved["initialProcessToken"] as? String,
                  UUID(uuidString: initialProcess) != nil, initialProcess != processToken else {
                throw fail("A matching first-phase receipt from a different process is required")
            }
            report = saved
            steps = saved["steps"] as? [[String: String]] ?? []
            report["status"] = "RUNNING"
            report["restartProcessToken"] = processToken
            report["networkMode"] = "foreground-http-denied; discovery-disabled; transfers-not-attached"
            report["deviceAirplaneMode"] = "NOT TESTED"
            try record("restart", "Fresh app process; MusicLibrary loaded from its saved records")
            guard DownloadProofOfflineNetwork.blockedRequestCount == 0 else {
                throw fail("The restarted app attempted HTTP before local playback verification")
            }
            var guardProbe = URLRequest(url: URL(string: "https://mp3shelf-offline-proof.invalid/guard-check")!)
            guardProbe.timeoutInterval = 2
            do {
                _ = try await URLSession.shared.data(for: guardProbe)
                throw fail("The foreground HTTP guard allowed its control request")
            } catch {
                let failure = error as NSError
                guard failure.domain == NSURLErrorDomain,
                      failure.code == URLError.Code.notConnectedToInternet.rawValue,
                      DownloadProofOfflineNetwork.blockedRequestCount == 1 else {
                    throw fail("The foreground HTTP guard did not intercept its control request")
                }
            }
            let networkBaseline = DownloadProofOfflineNetwork.blockedRequestCount
            report["networkGuardVerified"] = true
            try record("offline-guard-verified", "A control HTTP request was intercepted locally; playback must make no additional requests")
            guard let rawTrack = report["trackID"] as? String, let trackID = UUID(uuidString: rawTrack),
                  let rawPlaylist = report["playlistID"] as? String, let playlistID = UUID(uuidString: rawPlaylist),
                  let expectedTitle = report["expectedTitle"] as? String,
                  let expectedArtist = report["expectedArtist"] as? String,
                  let track = library.song(with: trackID),
                  track.title == expectedTitle, track.artist == expectedArtist,
                  library.playlists.contains(where: { $0.id == playlistID && $0.trackIDs.contains(trackID) && $0.missingTracks.isEmpty }) else {
                throw fail("The saved song metadata or playlist link did not survive the app restart")
            }
            let file = library.fileURL(for: track)
            guard file.isFileURL, try DownloadedAudioFormat.isMP3(file) else {
                throw fail("The restored track does not resolve to a local MP3")
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard let expectedBytes = report["fileBytes"] as? Int, let expectedDigest = report["sha256"] as? String,
                  data.count == expectedBytes, digest == expectedDigest else {
                throw fail("The local MP3 changed or disappeared across restart")
            }
            report["filePath"] = file.path
            try record("restored-library", "Track ID, playlist link, metadata, local MP3 codec and checksum survived restart")
            playback.play(track, queue: [track])
            guard let decodedDuration = report["durationSeconds"] as? Double,
                  decodedDuration.isFinite, decodedDuration > 0 else { throw fail("The saved full-decode duration is missing") }
            let minimumAdvance = min(0.25, decodedDuration / 4)
            let deadline = Date().addingTimeInterval(5)
            var observation = playback.localFilePlaybackProof()
            while observation.currentTime <= minimumAdvance && Date() < deadline {
                try Task.checkCancellation()
                if let error = playback.playbackError { throw fail(error) }
                try await Task.sleep(nanoseconds: 20_000_000)
                observation = playback.localFilePlaybackProof()
            }
            guard observation.isPlaying, observation.url?.isFileURL == true,
                  observation.url?.standardizedFileURL == file.standardizedFileURL,
                  playback.currentTrackID == trackID, observation.currentTime > minimumAdvance,
                  playback.playbackError == nil, DownloadProofOfflineNetwork.blockedRequestCount == networkBaseline else {
                throw fail("Production local playback did not advance cleanly without HTTP requests after restart")
            }
            report["blockedNetworkRequests"] = DownloadProofOfflineNetwork.blockedRequestCount - networkBaseline
            report["restartPlaybackSeconds"] = observation.currentTime
            report["status"] = "PASS"
            try record("restart-local-playback", "Production PlaybackController advanced the restored local MP3 with foreground HTTP refused")
        } catch {
            report["runID"] = runToken
            report["status"] = "FAIL"
            report["error"] = error.localizedDescription
            try? record("failed", error.localizedDescription)
        }
    }
}
#endif
