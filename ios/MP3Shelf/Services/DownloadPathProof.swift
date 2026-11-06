#if DEBUG
import Foundation
import AVFoundation
import CryptoKit

/// Runs only in the isolated Simulator app installed by prove-download-path.sh.
/// Uses the production search, matcher, review queue, downloader and importer.
@MainActor
enum DownloadPathProof {
    static func run(library: MusicLibrary) async {
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MP3ShelfDownloadProof.json")
        var steps: [[String: String]] = []
        var report: [String: Any] = ["schema": "mp3-shelf-download-proof-v1", "status": "RUNNING",
            "scope": "iOS Simulator foreground pipeline; physical-device/background acceptance is separate"]
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
            try record("start", "Live test: Carefree — Kevin MacLeod, expected 206 seconds")
            guard Bundle.main.bundleIdentifier == "com.jonnyt.mp3shelf.downloadproof",
                  library.tracks.isEmpty, library.playlists.isEmpty else {
                throw fail("Proof requires a fresh, isolated test app; the normal music library is never cleared.")
            }
            let wish = PlaylistWish(title: "Carefree", artist: "Kevin MacLeod", album: "",
                                    durationSeconds: 206, artistNames: ["Kevin MacLeod"])
            let imported = library.importPlaylist(wishes: [wish], name: "Download path proof")
            playlistID = imported.playlistID
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
            var finished = false
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
            guard decoded.0 > 0, decoded.1, abs(decoded.2 - 206) <= 4 else {
                throw fail("Full MP3 decode was empty, silent or had the wrong duration")
            }
            report["decodedFrames"] = decoded.0
            report["durationSeconds"] = decoded.2
            try record("full-decode", "Decoded the entire saved MP3; non-silent PCM and expected duration confirmed")
            let player = try AVAudioPlayer(contentsOf: file)
            player.volume = 0
            guard player.prepareToPlay(), player.play() else { throw fail("Local-file playback could not start") }
            defer { player.stop() }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            guard player.currentTime > 0.25 else { throw fail("Local-file playback did not advance") }
            report["status"] = "PASS"
            try record("local-playback", "Local file player advanced without a streaming URL; output muted during the test")
        } catch {
            if let playlistID { library.stopBackgroundTransfers(for: playlistID) }
            report["status"] = "FAIL"
            report["error"] = error.localizedDescription
            try? record("failed", error.localizedDescription)
        }
    }
}
#endif
