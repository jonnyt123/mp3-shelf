import Foundation

func verifyDiscovery(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
}

private struct ClassifiedLookupFailure: SourceLookupRetryableError {
    let shouldRetrySourceLookup: Bool
}

private actor RecordingProbeLog {
    private(set) var requests: [URL] = []
    func record(_ url: URL) { requests.append(url) }
}

@main
enum SourceDiscoveryJobTests {
    @MainActor private static func verifyRecordingStreamFallbacks() async throws {
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        func source(_ id: Int, bitrate: Int, expiresIn: Int = 3600, bytes: Int = 1000) -> RecordingStreamProbe.Candidate {
            let expiry = Int(clock.timeIntervalSince1970) + expiresIn
            return .init(url: URL(string: "https://r1.googlevideo.com/videoplayback?mime=audio%2Fmp4&sig=fixture&expire=\(expiry)&clen=\(bytes)&itag=\(id)")!, bitrate: bitrate)
        }
        let high = source(141, bitrate: 256000)
        let low = source(140, bitrate: 128000)
        let third = source(139, bitrate: 64000)
        let fourth = source(138, bitrate: 32000)
        let oversized = source(150, bitrate: 999000, bytes: 200 * 1024 * 1024)
        let expiring = source(151, bitrate: 888000, expiresIn: 30)
        let candidates = [third, oversized, expiring, low, high, high, fourth]
        verifyDiscovery(RecordingStreamProbe.orderedSources(candidates, at: clock) == [high.url, low.url, third.url],
                        "AAC formats are ranked, deduplicated and capped after invalid/expiring links are removed")
        let unknownRates = [low, high].map { RecordingStreamProbe.Candidate(url: $0.url, bitrate: nil) }
        verifyDiscovery(RecordingStreamProbe.orderedSources(unknownRates, at: clock) == [low.url, high.url],
                        "missing bitrate preserves the extractor's stable source priority")

        let fallbackLog = RecordingProbeLog()
        let fallback = try await RecordingStreamProbe.resolve([high, low], at: clock) { url in
            await fallbackLog.record(url)
            if url == high.url { throw NSError(domain: "Fixture.HTTP", code: 403) }
        }
        let fallbackCalls = await fallbackLog.requests
        verifyDiscovery(fallback == low.url && fallbackCalls == [high.url, low.url],
                        "a refused high-bitrate AAC URL falls back to a working format from the same recording")

        let successLog = RecordingProbeLog()
        let success = try await RecordingStreamProbe.resolve([low, high], at: clock) { url in
            await successLog.record(url)
        }
        let successCalls = await successLog.requests
        verifyDiscovery(success == high.url && successCalls == [high.url],
                        "a working highest-bitrate AAC source stops additional probes")

        let failedLog = RecordingProbeLog()
        do {
            _ = try await RecordingStreamProbe.resolve([fourth, low, third, high], at: clock) { url in
                await failedLog.record(url)
                if url == high.url { throw URLError(.timedOut) }
                throw NSError(domain: "Fixture.HTTP", code: 403)
            }
            fatalError("Failed probes cannot return a ready source")
        } catch {
            let failure = error as NSError
            verifyDiscovery(failure.domain == NSURLErrorDomain && failure.code == URLError.Code.timedOut.rawValue,
                            "a later permanent format refusal cannot hide an earlier temporary outage")
        }
        let failedCalls = await failedLog.requests
        verifyDiscovery(failedCalls == [high.url, low.url, third.url],
                        "at most three distinct AAC formats are probed per recording")

        let cancelledLog = RecordingProbeLog()
        do {
            _ = try await RecordingStreamProbe.resolve([high, low], at: clock) { url in
                await cancelledLog.record(url)
                throw URLError(.cancelled)
            }
            fatalError("A cancelled probe must stop resolution")
        } catch {
            verifyDiscovery((error as NSError).code == URLError.Code.cancelled.rawValue,
                            "request cancellation propagates instead of switching formats")
        }
        let cancelledCalls = await cancelledLog.requests
        verifyDiscovery(cancelledCalls == [high.url], "cancellation never probes the next AAC format")

        let stoppedLog = RecordingProbeLog()
        let stopped = Task { @MainActor in
            try await RecordingStreamProbe.resolve([high, low], at: clock) { url in await stoppedLog.record(url) }
        }
        stopped.cancel()
        do { _ = try await stopped.value; fatalError("A stopped resolver must not return a source") }
        catch is CancellationError { }
        let stoppedCalls = await stoppedLog.requests
        verifyDiscovery(stoppedCalls.isEmpty, "a cancelled task sends no format probes")

        let invalidLog = RecordingProbeLog()
        let invalid = try await RecordingStreamProbe.resolve([oversized, expiring], at: clock) { url in
            await invalidLog.record(url)
        }
        let invalidCalls = await invalidLog.requests
        verifyDiscovery(invalid == nil && invalidCalls.isEmpty, "no admitted AAC format means no network probe")
    }

    @MainActor static func main() async throws {
        try await verifyRecordingStreamFallbacks()
        verifyDiscovery(AudioDownloadDiagnostics.maySearchForAnotherSource(
            reason: AudioDownloadDiagnostics.http(403), recordedAdvice: nil),
                        "legacy source refusals can trigger a different source during playlist retry")
        verifyDiscovery(!AudioDownloadDiagnostics.maySearchForAnotherSource(
            reason: "Not enough space on this iPhone. Free storage and retry.", recordedAdvice: nil) &&
                        !AudioDownloadDiagnostics.maySearchForAnotherSource(
            reason: AudioDownloadDiagnostics.http(403), recordedAdvice: false),
                        "local storage failures do not cause paid web fallback")
        verifyDiscovery(AudioDownloadDiagnostics.http(403).contains("source refused"),
                        "access refusal explains source permissions instead of generic failure")
        verifyDiscovery(AudioDownloadDiagnostics.http(404).contains("no longer available") &&
                        AudioDownloadDiagnostics.http(410).contains("new audio link"),
                        "expired source links offer a recovery action")
        verifyDiscovery(AudioDownloadDiagnostics.contentType("text/html").contains("webpage"),
                        "HTML source response is distinguished from actual audio")
        let fullDisk = NSError(domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileWriteOutOfSpace.rawValue)
        let wrappedFullDisk = NSError(domain: "Conversion", code: 1,
            userInfo: [NSUnderlyingErrorKey: fullDisk])
        verifyDiscovery(AudioDownloadDiagnostics.message(for: wrappedFullDisk).contains("Free storage") &&
                        !AudioDownloadDiagnostics.shouldTryAlternateSource(for: wrappedFullDisk),
                        "local disk-full errors do not start more provider downloads")
        let deniedStorage = NSError(domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileWriteNoPermission.rawValue)
        verifyDiscovery(!AudioDownloadDiagnostics.shouldTryAlternateSource(for: deniedStorage),
                        "local write-access failure does not switch network source")
        let libraryWriteFailure = NSError(domain: PersistedLibrary.writeFailureDomain, code: 1,
            userInfo: [NSUnderlyingErrorKey: CocoaError(.fileWriteFileExists)])
        verifyDiscovery(!AudioDownloadDiagnostics.shouldTryAlternateSource(for: libraryWriteFailure) &&
                        AudioDownloadDiagnostics.message(for: libraryWriteFailure).contains("library could not be saved"),
                        "failed library persistence cannot trigger another source download")
        let libraryDiskFull = NSError(domain: PersistedLibrary.writeFailureDomain, code: 1,
            userInfo: [NSUnderlyingErrorKey: fullDisk])
        verifyDiscovery(AudioDownloadDiagnostics.message(for: libraryDiskFull).contains("Free storage"),
                        "library persistence retains the underlying disk-full diagnosis")
        let timedOut = URLError(.timedOut)
        verifyDiscovery(AudioDownloadDiagnostics.shouldTryAlternateSource(for: timedOut) &&
                        AudioDownloadDiagnostics.message(for: timedOut).contains("did not respond"),
                        "network timeout retains source-fallback eligibility")

        let temporaryLookupCodes: [URLError.Code] = [.timedOut, .networkConnectionLost, .notConnectedToInternet,
            .dataNotAllowed, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
        for code in temporaryLookupCodes {
            verifyDiscovery(SourceLookupRetryPolicy.failureToRetry(
                URLError(code), hasCandidates: false) != nil,
                "empty optional catalogs preserve interrupted recording lookup: \(code.rawValue)")
        }
        verifyDiscovery(SourceLookupRetryPolicy.failureToRetry(timedOut, hasCandidates: true) == nil,
                        "a usable fallback proceeds despite a primary lookup timeout")
        verifyDiscovery(SourceLookupRetryPolicy.failureToRetry(nil, hasCandidates: false) == nil,
                        "a healthy search with no matches remains a genuine unavailable result")
        verifyDiscovery(SourceLookupRetryPolicy.failureToRetry(
            ClassifiedLookupFailure(shouldRetrySourceLookup: true), hasCandidates: false) != nil &&
                        SourceLookupRetryPolicy.failureToRetry(
            ClassifiedLookupFailure(shouldRetrySourceLookup: false), hasCandidates: false) == nil,
                        "typed resolver failures preserve temporary versus permanent classification")
        let permanentLookupFailures: [Error] = [CancellationError(), URLError(.cancelled),
            URLError(.unsupportedURL), URLError(.serverCertificateUntrusted)]
        for error in permanentLookupFailures {
            verifyDiscovery(SourceLookupRetryPolicy.failureToRetry(error, hasCandidates: false) == nil,
                            "cancellation and permanent failures do not consume lookup retries")
        }
        let interruptedWish = PlaylistWish(title: "Interrupted search", artist: "Artist", album: "")
        var interrupted = SourceDiscoveryJob(playlistID: UUID(), wishes: [interruptedWish])
        _ = interrupted.reserveWebSearch(for: interruptedWish.id)
        for attempt in 1...SourceDiscoveryJob.automaticRetryLimit {
            guard let failure = SourceLookupRetryPolicy.failureToRetry(timedOut, hasCandidates: false) else {
                fatalError("An interrupted primary search cannot be treated as no match")
            }
            interrupted.recordTransientFailure(failure.localizedDescription,
                at: Date(timeIntervalSince1970: TimeInterval(attempt * 3600)))
            let exhausted = interrupted.finishExhaustedRetriesIfNeeded()
            verifyDiscovery(exhausted == (attempt == SourceDiscoveryJob.automaticRetryLimit),
                            "interrupted recording lookup obeys the existing retry limit")
            if !exhausted {
                verifyDiscovery(interrupted.nextIndex == 0 && interrupted.unavailable == 0 && interrupted.nextRetryAt != nil,
                                "a transient source failure keeps the song pending with backoff")
                interrupted = try JSONDecoder().decode(SourceDiscoveryJob.self,
                    from: JSONEncoder().encode(interrupted))
            }
        }
        verifyDiscovery(interrupted.isComplete && interrupted.failed == 1 && interrupted.unavailable == 0 &&
                        interrupted.outcome(for: interruptedWish) == .failed &&
                        interrupted.webSearchWishIDs == [interruptedWish.id],
                        "exhaustion records a failure and preserves the web-search credit ledger")

        for mime in ["audio/mpeg", "audio/mp4", "audio/aac", "audio/wav", "audio/x-aiff", "audio/flac", "Audio/X-FLAC; charset=binary"] {
            verifyDiscovery(DownloadedAudioContentType.allows(mime), "supported audio response reaches decoding: \(mime)")
        }
        for mime in ["text/html", "application/json", "audio/ogg", "", "audio/mpeg-unsafe"] {
            verifyDiscovery(!DownloadedAudioContentType.allows(mime), "non-supported response is rejected: \(mime)")
        }
        verifyDiscovery(!DownloadedAudioContentType.allows(nil), "missing response type is rejected")
        verifyDiscovery(BackgroundDownloadBackpressure.maximumOutstandingTransfers == 4,
                        "large playlist discovery limits outstanding background transfers")
        for count in 0..<4 {
            verifyDiscovery(BackgroundDownloadBackpressure.mayEnqueue(
                outstandingTransfers: count),
                "transfer slot available with \(count) active downloads")
        }
        verifyDiscovery(!BackgroundDownloadBackpressure.mayEnqueue(outstandingTransfers: 4) &&
                        !BackgroundDownloadBackpressure.mayEnqueue(outstandingTransfers: 10) &&
                        !BackgroundDownloadBackpressure.mayEnqueue(outstandingTransfers: -1),
                        "discovery does not advance when queue is full or corrupt")
        verifyDiscovery(DownloadNetworkPolicy.canDiscover(
            onWiFi: true, onCellular: false, explicitlyAllowCellular: false),
            "Wi-Fi downloads run without per-track confirmation")
        verifyDiscovery(!DownloadNetworkPolicy.canDiscover(
            onWiFi: false, onCellular: true, explicitlyAllowCellular: false),
            "cellular automatic downloads are disabled by default")
        verifyDiscovery(DownloadNetworkPolicy.canDiscover(
            onWiFi: false, onCellular: true, explicitlyAllowCellular: true),
            "explicit user approval permits cellular source discovery")
        verifyDiscovery(!DownloadNetworkPolicy.canDiscover(
            onWiFi: false, onCellular: false, explicitlyAllowCellular: true),
            "downloads do not start without network connectivity")
        let id = UUID()
        let named = LocalAudioFileNaming.storageName(
            originalName: "The Artist - The Song.mp3", id: id, fileExtension: "MP3")
        verifyDiscovery(named.hasPrefix("The Artist - The Song [") && named.hasSuffix("].mp3"),
                        "Spotify-matched MP3s have readable names")
        let unsafe = LocalAudioFileNaming.storageName(
            originalName: "bad:name?.mp3", id: id, fileExtension: "mp3")
        verifyDiscovery(!unsafe.contains(":") && !unsafe.contains("?"),
                        "download filenames remove unsafe characters")
        let otherID = UUID()
        verifyDiscovery(named != LocalAudioFileNaming.storageName(
            originalName: "The Artist - The Song.mp3", id: otherID, fileExtension: "mp3"),
                        "distinct recordings do not overwrite each other")
        let validPlaylist = "37i9dQZF1DXcBWIGoYBM5M"
        verifyDiscovery(SpotifyPlaylistLinks.playlistID(
            from: "https://open.spotify.com/playlist/\(validPlaylist)?si=share") == validPlaylist,
            "Spotify share link identifies the selected playlist")
        for invalid in [
            "http://open.spotify.com/playlist/\(validPlaylist)",
            "https://open.spotify.com.evil.invalid/playlist/\(validPlaylist)",
            "https://open.spotify.com/track/\(validPlaylist)",
            "https://open.spotify.com/playlist/not-a-valid-spotify-id",
            "https://user:secret@open.spotify.com/playlist/\(validPlaylist)"
        ] {
            verifyDiscovery(SpotifyPlaylistLinks.playlistID(from: invalid) == nil,
                            "reject unrelated or malformed playlist URLs")
        }
        let wishes = [
            PlaylistWish(title: "First", artist: "Artist", album: "", spotifyURL: nil),
            PlaylistWish(title: "Second", artist: "Artist", album: "", spotifyURL: nil),
            PlaylistWish(title: "Third", artist: "Artist", album: "", spotifyURL: nil)
        ]
        var job = SourceDiscoveryJob(playlistID: id, wishes: wishes)
        verifyDiscovery(job.remaining == 3 && job.currentWish?.title == "First", "initial cursor")
        job.record(.queued)
        verifyDiscovery(job.nextIndex == 1 && job.queued == 1, "enqueue updates cursor")
        verifyDiscovery(job.outcome(for: wishes[0]) == .queued,
                        "per-song queued state is available")
        verifyDiscovery(job.outcome(for: wishes[1]) == nil,
                        "unprocessed songs do not claim a result")
        job.isPaused = true
        verifyDiscovery(job.reserveWebSearch(for: wishes[0].id),
                        "first automatic web request reserves its budget before network access")
        verifyDiscovery(!job.reserveWebSearch(for: wishes[0].id),
                        "resuming the same song cannot spend another automatic search credit")
        job.catalogWarnings = ["Openverse: HTTP 429"]
        let encoded = try JSONEncoder().encode([job])
        let restored = try JSONDecoder().decode([SourceDiscoveryJob].self, from: encoded)
        verifyDiscovery(restored[0].isPaused && restored[0].nextIndex == 1,
                        "pause and incomplete position survive restart")
        verifyDiscovery(restored[0].catalogWarnings == ["Openverse: HTTP 429"],
                        "partial provider failures survive checkpoint persistence")
        verifyDiscovery(restored[0].webSearchWishIDs == [wishes[0].id],
                        "web request reservations survive process restart")
        var budgetJob = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        for _ in 0..<SourceDiscoveryJob.maxAutomaticWebSearches {
            verifyDiscovery(budgetJob.reserveWebSearch(for: UUID()), "reserve bounded web search")
        }
        verifyDiscovery(!budgetJob.reserveWebSearch(for: UUID()),
                        "a playlist cannot exceed its persisted automatic web request limit")
        var stoppedJob = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        stoppedJob.webSearchStoppedReason = "Search credit limit reached"
        verifyDiscovery(!stoppedJob.reserveWebSearch(for: wishes[0].id),
                        "a search credit or authentication failure stops further paid calls")
        let cachedSource = AudioCatalogMatch(
            downloadURL: URL(string: "https://artist.example/Artist-Song.mp3")!,
            itemURL: URL(string: "https://artist.example/song")!, licenseURL: nil, sourceName: "Web: artist.example")
        stoppedJob.webSources = [wishes[0].id.uuidString: [cachedSource]]
        stoppedJob.saveLookupDetails(["Web file: audio confirmed"], for: wishes[0].id)
        let restoredWeb = try JSONDecoder().decode(SourceDiscoveryJob.self,
            from: JSONEncoder().encode(stoppedJob))
        verifyDiscovery(restoredWeb.webSources?[wishes[0].id.uuidString] == [cachedSource] &&
                        restoredWeb.lookupDetails?[wishes[0].id.uuidString] == ["Web file: audio confirmed"],
                        "verified web sources and song diagnostics survive a capacity pause or restart")
        job = restored[0]
        job.isPaused = false
        job.record(.unavailable)
        job.record(.alreadyPresent)
        verifyDiscovery(job.isComplete && job.remaining == 0, "resume finishes remaining songs")
        verifyDiscovery(job.queued == 1 && job.unavailable == 1 && job.failed == 0,
                        "outcome counts preserved")
        verifyDiscovery(job.outcome(for: wishes[1]) == .unavailable &&
                        job.outcome(for: wishes[2]) == .alreadyPresent,
                        "each Spotify song retains its independent source result")
        let finished = try JSONDecoder().decode(SourceDiscoveryJob.self,
                                                from: JSONEncoder().encode(job))
        verifyDiscovery(finished.outcome(for: wishes[0]) == .queued &&
                        finished.outcome(for: wishes[1]) == .unavailable,
                        "individual MP3 search outcomes survive restart")
        var recovery = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        recovery.record(.queued)
        recovery.record(.unavailable)
        _ = recovery.reserveWebSearch(for: wishes[0].id)
        let retryClock = Date(timeIntervalSince1970: 1_700_000_000)
        recovery.recordTransientFailure("Current song is waiting", at: retryClock)
        let choice = RecordingCandidate(id: "abcdefghijk", title: "First", uploader: "Artist", durationSeconds: 210)
        recovery.recordingCandidates = [wishes[0].id.uuidString: [choice]]
        let beforeRecovery = recovery
        verifyDiscovery(recovery.requeueFailedSource(for: wishes[0].id) &&
                        recovery.nextIndex == 1 && recovery.currentWish?.id == wishes[2].id &&
                        recovery.wishes.last?.id == wishes[0].id && recovery.queued == 0 &&
                        recovery.unavailable == 1 && recovery.outcome(for: wishes[1]) == .unavailable,
                        "failed recording returns to pending without skipping another song or rewriting its history")
        verifyDiscovery(recovery.webSearchWishIDs == beforeRecovery.webSearchWishIDs &&
                        recovery.nextRetryAt == beforeRecovery.nextRetryAt &&
                        recovery.transientFailureCount == beforeRecovery.transientFailureCount &&
                        !beforeRecovery.isCurrent(in: [recovery], at: 0),
                        "source recovery preserves paid-search reservations and current-song backoff, invalidating stale lookups")
        let restoredRecovery = try JSONDecoder().decode(SourceDiscoveryJob.self,
            from: JSONEncoder().encode(recovery))
        verifyDiscovery(restoredRecovery.recordingCandidates?[wishes[0].id.uuidString] == [choice] &&
                        restoredRecovery.sourceRecoveryAttempts?[wishes[0].id.uuidString] == 1,
                        "recording candidates and recovery budget survive relaunch")
        verifyDiscovery(!recovery.requeueFailedSource(for: wishes[2].id) &&
                        !recovery.requeueFailedSource(for: UUID()),
                        "pending and removed songs cannot trigger processed-source recovery")
        recovery.record(.alreadyPresent)
        recovery.record(.queued)
        recovery.isPaused = true
        verifyDiscovery(!recovery.requeueFailedSource(for: wishes[0].id),
                        "paused playlists do not silently restart a failed recording")
        recovery.isPaused = false
        for expected in 2...3 {
            verifyDiscovery(recovery.requeueFailedSource(for: wishes[0].id) &&
                            recovery.currentWish?.id == wishes[0].id &&
                            recovery.sourceRecoveryAttempts?[wishes[0].id.uuidString] == expected,
                            "automatic recovery consumes one persisted attempt")
            recovery.record(.queued)
        }
        verifyDiscovery(!recovery.requeueFailedSource(for: wishes[0].id),
                        "source recovery stops after three attempts")
        var unknownHistory = beforeRecovery
        unknownHistory.outcomes = nil
        verifyDiscovery(!unknownHistory.requeueFailedSource(for: wishes[0].id),
                        "legacy checkpoints with unknown outcomes cannot invent a queued result")
        // Older discovery checkpoints had no outcomes field. They must still
        // decode and resume at the exact same cursor without repeating songs.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job))
            as! [String: Any]
        legacy.removeValue(forKey: "outcomes")
        legacy.removeValue(forKey: "catalogWarnings")
        legacy.removeValue(forKey: "webSearchWishIDs")
        var migrated = try JSONDecoder().decode(SourceDiscoveryJob.self,
                         from: JSONSerialization.data(withJSONObject: legacy))
        verifyDiscovery(migrated.catalogWarnings == nil,
                        "legacy checkpoints without provider warnings still load")
        verifyDiscovery(migrated.nextIndex == 3 &&
                        migrated.outcome(for: wishes[1]) == .previous,
                        "pre-upgrade checkpoints retain their processed cursor")
        migrated.nextIndex = 2
        migrated.record(.failed)
        verifyDiscovery(migrated.outcome(for: wishes[2]) == .failed &&
                        migrated.outcomes?.count == 3,
                        "older checkpoint resumes with a new per-song outcome")
        let cursor = job.nextIndex
        job.record(.failed)
        verifyDiscovery(job.nextIndex == cursor, "complete job cannot advance beyond its list")
        // A truncated or malformed persisted discovery cursor must never
        // subscript wishes[-1], allocate a negative-sized outcome array,
        // or skip a still-unprocessed song after relaunch.
        var healthyCheckpoint = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        healthyCheckpoint.record(.queued)
        verifyDiscovery(!healthyCheckpoint.repairPersistedCheckpoint() &&
                        healthyCheckpoint.nextIndex == 1 &&
                        healthyCheckpoint.outcome(for: wishes[0]) == .queued,
                        "healthy persisted checkpoints are preserved byte-for-byte in memory")
        var invalidNegative = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        invalidNegative.nextIndex = -3
        invalidNegative.queued = -100
        invalidNegative.outcomes = [.queued, .failed]
        invalidNegative.transientFailureCount = -1
        invalidNegative.nextRetryAt = Date(timeIntervalSince1970: 1_700_000_000)
        verifyDiscovery(invalidNegative.currentWish == nil && invalidNegative.remaining == 3,
                        "negative persisted cursor cannot subscript an invalid song index")
        let decodedNegative = try JSONDecoder().decode(SourceDiscoveryJob.self,
            from: JSONEncoder().encode(invalidNegative))
        var repairedNegative = decodedNegative
        verifyDiscovery(repairedNegative.repairPersistedCheckpoint() &&
                        repairedNegative.nextIndex == 0 &&
                        repairedNegative.currentWish?.id == wishes[0].id &&
                        repairedNegative.queued == 0 &&
                        repairedNegative.outcomes?.isEmpty == true &&
                        repairedNegative.nextRetryAt == nil &&
                        repairedNegative.transientFailureCount == nil,
                        "saved negative cursor, counts, and obsolete retry state are repaired")
        repairedNegative.record(.queued)
        verifyDiscovery(repairedNegative.nextIndex == 1 && repairedNegative.queued == 1,
                        "restored first song can be processed without losing playlist progress")
        var invalidOversized = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        invalidOversized.nextIndex = Int.max
        invalidOversized.failed = Int.max
        invalidOversized.outcomes = Array(repeating: .failed, count: 6)
        invalidOversized.transientFailureCount = Int.max
        invalidOversized.nextRetryAt = Date(timeIntervalSince1970: 1_700_000_000)
        verifyDiscovery(invalidOversized.repairPersistedCheckpoint() &&
                        invalidOversized.nextIndex == wishes.count &&
                        invalidOversized.isComplete &&
                        invalidOversized.remaining == 0 &&
                        invalidOversized.failed == wishes.count &&
                        invalidOversized.outcomes?.count == wishes.count &&
                        invalidOversized.transientFailureCount == nil &&
                        invalidOversized.nextRetryAt == nil,
                        "oversized saved cursor and history are bounded by actual song count")
        var truncatedHistory = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        truncatedHistory.nextIndex = 2
        truncatedHistory.outcomes = [.previous]
        verifyDiscovery(!truncatedHistory.repairPersistedCheckpoint() &&
                        truncatedHistory.outcomes?.count == 1,
                        "legacy short history is preserved for record() migration")
        truncatedHistory.record(.failed)
        verifyDiscovery(truncatedHistory.nextIndex == 3 &&
                        truncatedHistory.outcomes?.count == 3 &&
                        truncatedHistory.outcome(for: wishes[2]) == .failed,
                        "truncated outcome history safely fills only its missing entries")
        // A transient provider outage must never skip the current song.
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        var delayed = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        delayed.recordTransientFailure("API temporarily unavailable", at: clock)
        verifyDiscovery(delayed.nextIndex == 0 && delayed.remaining == 3,
                        "transient error keeps current song in queue")
        verifyDiscovery(!delayed.canAttemptLookup(at: clock.addingTimeInterval(14)) &&
                        delayed.canAttemptLookup(at: clock.addingTimeInterval(15)),
                        "first automatic retry occurs after 15 seconds")
        delayed.recordTransientFailure("API temporarily unavailable", at: clock)
        verifyDiscovery(delayed.nextRetryAt == clock.addingTimeInterval(30),
                        "repeated failures increase retry delay")
        for _ in 0..<12 {
            delayed.recordTransientFailure("API temporarily unavailable", at: clock)
        }
        verifyDiscovery(delayed.nextRetryAt == clock.addingTimeInterval(240),
                        "retry delay is capped at 4 minutes per attempt")
        verifyDiscovery(delayed.hasExhaustedAutomaticRetries,
                        "repeated catalog outages exhaust a bounded budget")
        let resumed = try JSONDecoder().decode(SourceDiscoveryJob.self,
            from: JSONEncoder().encode(delayed))
        verifyDiscovery(resumed.nextRetryAt == delayed.nextRetryAt &&
                        resumed.transientFailureCount == delayed.transientFailureCount,
                        "retry schedule survives app restart")
        verifyDiscovery(delayed.finishExhaustedRetriesIfNeeded(),
                        "exhausted remote lookup advances to the next song")
        verifyDiscovery(delayed.failed == 1 && delayed.nextIndex == 1 &&
                        delayed.outcome(for: wishes[0]) == .failed &&
                        delayed.currentWish?.title == "Second",
                        "failed lookup does not block the rest of the playlist")
        verifyDiscovery(delayed.nextRetryAt == nil &&
                        delayed.transientFailureCount == nil,
                        "failed lookup clears retry delay before continuing")
        verifyDiscovery(!delayed.finishExhaustedRetriesIfNeeded(),
                        "exhausted lookup is never double-counted")
        delayed.recordTransientFailure("Next track temporarily unavailable", at: clock)
        delayed.record(.queued)
        verifyDiscovery(delayed.outcome(for: wishes[1]) == .queued &&
                        delayed.nextRetryAt == nil &&
                        delayed.transientFailureCount == nil,
                        "successful second song resets retry history")
        var backwardCompatible = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(delayed)) as! [String: Any]
        backwardCompatible.removeValue(forKey: "nextRetryAt")
        backwardCompatible.removeValue(forKey: "transientFailureCount")
        let oldCheckpoint = try JSONDecoder().decode(SourceDiscoveryJob.self,
            from: JSONSerialization.data(withJSONObject: backwardCompatible))
        verifyDiscovery(oldCheckpoint.canAttemptLookup(at: clock),
                        "pre-retry persisted queues remain decodable")
        let byteLimit = BackgroundTransferProgressPolicy.maxBytes
        verifyDiscovery(!BackgroundTransferProgressPolicy.exceedsLimit(
            received: byteLimit, expected: -1) &&
            !BackgroundTransferProgressPolicy.exceedsLimit(
                received: 1024, expected: byteLimit),
            "100 MB files remain eligible, including unknown transfer size")
        verifyDiscovery(BackgroundTransferProgressPolicy.exceedsLimit(
            received: byteLimit + 1, expected: -1) &&
            BackgroundTransferProgressPolicy.exceedsLimit(
                received: 0, expected: byteLimit + 1),
            "oversized downloads stop as soon as received or announced size exceeds limit")
        verifyDiscovery(BackgroundTransferProgressPolicy.shouldPublish(
            received: 0, total: -1, previousReceived: nil) &&
            !BackgroundTransferProgressPolicy.shouldPublish(
                received: 1024, total: 1_000_000, previousReceived: 0) &&
            BackgroundTransferProgressPolicy.shouldPublish(
                received: 300_000, total: 1_000_000, previousReceived: 0),
            "progress UI coalesces small increments without losing meaningful movement")
        verifyDiscovery(BackgroundTransferProgressPolicy.shouldPublish(
            received: 999_999, total: 999_999, previousReceived: 999_000) &&
            BackgroundTransferProgressPolicy.shouldPublish(
                received: 250, total: -1, previousReceived: 50_000),
            "finished downloads and restarted transfers always refresh progress")
        verifyDiscovery(BackgroundTransferRetryPolicy.delay(afterFailure: 1) == 45,
                        "first interrupted background transfer is delayed")
        verifyDiscovery(BackgroundTransferRetryPolicy.delay(afterFailure: 2) == 150 &&
                        BackgroundTransferRetryPolicy.delay(afterFailure: 3) == 450,
                        "successive transfer failures increase delay")
        verifyDiscovery(BackgroundTransferRetryPolicy.delay(afterFailure: 4) == nil &&
                        BackgroundTransferRetryPolicy.delay(afterFailure: 100) == nil,
                        "non-connectivity transfer failures cannot retry indefinitely")
        verifyDiscovery(BackgroundTransferRetryPolicy.isConnectivityInterruption(
            URLError.Code.notConnectedToInternet.rawValue) &&
            BackgroundTransferRetryPolicy.isConnectivityInterruption(
                URLError.Code.networkConnectionLost.rawValue) &&
            BackgroundTransferRetryPolicy.isConnectivityInterruption(
                URLError.Code.dataNotAllowed.rawValue),
            "offline, interrupted and restricted-network errors keep pending Wi-Fi work")
        verifyDiscovery(!BackgroundTransferRetryPolicy.isConnectivityInterruption(
            URLError.Code.timedOut.rawValue) &&
            !BackgroundTransferRetryPolicy.isConnectivityInterruption(
                URLError.Code.badURL.rawValue),
            "server timeout and invalid URLs do not qualify for unlimited connectivity wait")
        verifyDiscovery(BackgroundTransferRetryPolicy.connectivityDelay(afterFailure: 1) == 60 &&
            BackgroundTransferRetryPolicy.connectivityDelay(afterFailure: 2) == 180 &&
            BackgroundTransferRetryPolicy.connectivityDelay(afterFailure: 3) == 600 &&
            BackgroundTransferRetryPolicy.connectivityDelay(afterFailure: 4) == 1_800 &&
            BackgroundTransferRetryPolicy.connectivityDelay(afterFailure: 15) == 3_600,
            "Wi-Fi-reconnect attempts use bounded one-hour maximum delay")
        verifyDiscovery(BackgroundTransferRetryPolicy.isTemporaryURLFailure(
            URLError.Code.dataNotAllowed.rawValue),
            "network permission interruption is retryable without changing permissions")
        for status in [408, 429, 500, 502, 503, 504] {
            verifyDiscovery(BackgroundTransferRetryPolicy.isTemporaryHTTP(status),
                            "temporary HTTP \(status) is retried")
        }
        for status in [400, 401, 403, 404, 410, 451] {
            verifyDiscovery(!BackgroundTransferRetryPolicy.isTemporaryHTTP(status),
                            "permanent HTTP \(status) is not retried")
        }
        for error in [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet] {
            verifyDiscovery(BackgroundTransferRetryPolicy.isTemporaryURLFailure(error.rawValue),
                            "recoverable network disconnection is retried")
        }
        for error in [URLError.Code.badURL, .userAuthenticationRequired, .secureConnectionFailed] {
            verifyDiscovery(!BackgroundTransferRetryPolicy.isTemporaryURLFailure(error.rawValue),
                            "invalid links and security failures are not retried")
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = now.addingTimeInterval(-BackgroundTransferRecoveryPolicy.minimumAge - 1)
        let fresh = now.addingTimeInterval(-20)
        func canRestore(startedAt: Date? = stale,
                        first: Bool = false, second: Bool = false,
                        unknown: Bool = false, staged: Bool = false,
                        importing: Bool = false) -> Bool {
            BackgroundTransferRecoveryPolicy.shouldRecover(
                startedAt: startedAt, checkedAt: now,
                firstScanHasTask: first, secondScanHasTask: second,
                hasUnidentifiedTasks: unknown, hasStagedFile: staged,
                isImporting: importing)
        }
        verifyDiscovery(canRestore(),
                        "two clean URLSession scans recover an abandoned old download")
        verifyDiscovery(!canRestore(startedAt: fresh) &&
                        !canRestore(startedAt: nil),
                        "new or pre-upgrade tickets are never prematurely duplicated")
        verifyDiscovery(!canRestore(first: true) && !canRestore(second: true),
                        "an active task in either scan prevents duplicate transfers")
        verifyDiscovery(!canRestore(unknown: true),
                        "unidentifiable background tasks block unsafe resurrection")
        verifyDiscovery(!canRestore(staged: true) && !canRestore(importing: true),
                        "staged media or in-progress import is never downloaded twice")
        var refreshedJob = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        refreshedJob.record(.queued)
        let added = PlaylistWish(title: "Recently Added", artist: "Band",
                                 album: "", spotifyURL: nil, durationSeconds: 180)
        verifyDiscovery(refreshedJob.appendNewMissingWishes([wishes[1], added, added]) == 1,
                        "playlist refresh appends only new Spotify occurrences")
        verifyDiscovery(refreshedJob.nextIndex == 1 && refreshedJob.queued == 1 &&
                        refreshedJob.wishes.last?.id == added.id,
                        "refresh preserves download cursor and completed outcome")
        let editedPending = PlaylistWish(id: wishes[1].id,
            title: "Second (renamed)", artist: wishes[1].artist,
            album: "New Album", spotifyURL: wishes[1].spotifyURL,
            durationSeconds: 213)
        verifyDiscovery(refreshedJob.appendNewMissingWishes([editedPending]) == 0 &&
                        refreshedJob.wishes[1].title == "Second (renamed)" &&
                        refreshedJob.wishes[1].durationSeconds == 213 &&
                        refreshedJob.nextIndex == 1,
                        "refresh updates unprocessed song metadata without resetting cursor")
        let persistedMetadataEdit = try JSONDecoder().decode(SourceDiscoveryJob.self,
            from: JSONEncoder().encode(refreshedJob))
        verifyDiscovery(persistedMetadataEdit.wishes[1].title == "Second (renamed)" &&
                        persistedMetadataEdit.wishes[1].durationSeconds == 213 &&
                        persistedMetadataEdit.nextIndex == 1 && persistedMetadataEdit.queued == 1,
                        "metadata-only pending refresh survives serialization without resetting history")
        refreshedJob.record(.removed)
        verifyDiscovery(refreshedJob.outcome(for: wishes[1]) == .removed &&
                        refreshedJob.nextIndex == 2,
                        "removed Spotify entries advance without scanning catalogs")
        let synchronized = try JSONDecoder().decode(SourceDiscoveryJob.self,
            from: JSONEncoder().encode(refreshedJob))
        verifyDiscovery(synchronized.wishes.last?.id == added.id &&
                        synchronized.outcome(for: wishes[1]) == .removed,
                        "refreshed playlist checkpoint survives app relaunch")
        var backgroundJob = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        let backgroundClock = Date(timeIntervalSince1970: 1_700_100_000)
        verifyDiscovery(BackgroundDiscoveryPolicy.maxSongsPerPass == 5,
                        "background source discovery is bounded to five songs")
        verifyDiscovery(BackgroundDiscoveryPolicy.canStartForegroundScan(
            isSceneActive: true, hasForegroundTask: false, hasBackgroundBatch: false, hasPendingWork: true),
            "idle foreground discovery can start automatically")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canStartForegroundScan(
            isSceneActive: true, hasForegroundTask: true, hasBackgroundBatch: false, hasPendingWork: true),
            "Wi-Fi change does not start duplicate foreground discovery")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canStartForegroundScan(
            isSceneActive: true, hasForegroundTask: false, hasBackgroundBatch: true, hasPendingWork: true),
            "Wi-Fi callback cannot bypass the five-song background batch limit")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canStartForegroundScan(
            isSceneActive: true, hasForegroundTask: true, hasBackgroundBatch: true, hasPendingWork: true),
            "neither active scan permits a concurrent source lookup")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canStartForegroundScan(
            isSceneActive: false, hasForegroundTask: false, hasBackgroundBatch: false, hasPendingWork: true),
            "headless URLSession wake cannot initiate unbounded catalog discovery")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canStartForegroundScan(
            isSceneActive: true, hasForegroundTask: false, hasBackgroundBatch: false,
            hasPendingWork: false),
            "an empty discovery queue cannot schedule a foreground scan")
        verifyDiscovery(BackgroundDiscoveryPolicy.shouldResumeForegroundDiscovery(
            isSceneActive: true, foregroundRequestPending: true,
            hasBackgroundBatch: false),
            "a foreground request deferred by a completed batch resumes after ownership is released")
        verifyDiscovery(!BackgroundDiscoveryPolicy.shouldResumeForegroundDiscovery(
            isSceneActive: true, foregroundRequestPending: true,
            hasBackgroundBatch: true) &&
            !BackgroundDiscoveryPolicy.shouldResumeForegroundDiscovery(
                isSceneActive: false, foregroundRequestPending: true,
                hasBackgroundBatch: false) &&
            !BackgroundDiscoveryPolicy.shouldResumeForegroundDiscovery(
                isSceneActive: true, foregroundRequestPending: false,
                hasBackgroundBatch: false),
            "deferred completion cannot overlap a batch or create a headless or empty scan")
        verifyDiscovery(DownloadNetworkPolicy.canDiscover(
            onWiFi: true, onCellular: false, explicitlyAllowCellular: false) &&
            !DownloadNetworkPolicy.canDiscover(
                onWiFi: false, onCellular: true, explicitlyAllowCellular: false) &&
            DownloadNetworkPolicy.canDiscover(
                onWiFi: false, onCellular: true, explicitlyAllowCellular: true) &&
            !DownloadNetworkPolicy.canDiscover(
                onWiFi: false, onCellular: false, explicitlyAllowCellular: true),
            "foreground resume requires a known permitted path and honors explicit cellular approval")
        verifyDiscovery(BackgroundDiscoveryPolicy.canProcess(
            onWiFi: true, job: backgroundJob, at: backgroundClock),
            "background source discovery can run on Wi-Fi")
        var completedBackgroundJob = backgroundJob
        for _ in completedBackgroundJob.wishes.indices {
            completedBackgroundJob.record(.queued)
        }
        verifyDiscovery(!BackgroundDiscoveryPolicy.canProcess(
            onWiFi: true, job: completedBackgroundJob, at: backgroundClock),
            "completed playlists are not rescanned in a later background window")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canProcess(
            onWiFi: false, job: backgroundJob, at: backgroundClock),
            "system-granted background window does not authorize cellular")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canRecordLookupFailure(
            isCancelled: false, isPaused: false, networkAllowed: true,
            backgroundWiFiOnly: true, onWiFi: false),
            "Wi-Fi loss during a background lookup does not spend catalog retry budget")
        verifyDiscovery(BackgroundDiscoveryPolicy.canRecordLookupFailure(
            isCancelled: false, isPaused: false, networkAllowed: true,
            backgroundWiFiOnly: true, onWiFi: true) &&
            BackgroundDiscoveryPolicy.canRecordLookupFailure(
                isCancelled: false, isPaused: false, networkAllowed: true,
                backgroundWiFiOnly: false, onWiFi: false),
            "real provider errors remain retryable on permitted foreground or background paths")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canRecordLookupFailure(
            isCancelled: true, isPaused: false, networkAllowed: true,
            backgroundWiFiOnly: false, onWiFi: true) &&
            !BackgroundDiscoveryPolicy.canRecordLookupFailure(
                isCancelled: false, isPaused: true, networkAllowed: true,
                backgroundWiFiOnly: false, onWiFi: true) &&
            !BackgroundDiscoveryPolicy.canRecordLookupFailure(
                isCancelled: false, isPaused: false, networkAllowed: false,
                backgroundWiFiOnly: false, onWiFi: true),
            "cancelled, paused or network-blocked requests do not spend retry budget")
        verifyDiscovery(!DownloadNetworkPolicy.canDiscover(
            onWiFi: false, onCellular: false, explicitlyAllowCellular: true),
            "unknown network path remains blocked despite cellular approval")
        verifyDiscovery(DownloadNetworkPolicy.canDiscover(
            onWiFi: false, onCellular: true, explicitlyAllowCellular: true) &&
            !BackgroundDiscoveryPolicy.canProcess(
                onWiFi: false, job: backgroundJob, at: backgroundClock),
            "foreground cellular approval cannot authorize background discovery")
        backgroundJob.recordTransientFailure("Temporary catalog error",
                                             at: backgroundClock)
        verifyDiscovery(!BackgroundDiscoveryPolicy.canProcess(
            onWiFi: true, job: backgroundJob, at: backgroundClock),
            "background discovery honors persisted API retry backoff")
        backgroundJob.nextRetryAt = nil
        backgroundJob.isPaused = true
        verifyDiscovery(!BackgroundDiscoveryPolicy.hasPending([backgroundJob]) &&
                        !BackgroundDiscoveryPolicy.canProcess(
                            onWiFi: true, job: backgroundJob, at: backgroundClock),
                        "user-paused playlists never schedule background work")
        backgroundJob.isPaused = false
        verifyDiscovery(BackgroundDiscoveryPolicy.hasPending([backgroundJob]),
                        "unfinished unpaused playlist can request a background window")
        // Long playlists should not starve later playlists when iOS grants
        // only a handful of short background processing windows.
        let firstWindow = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        let secondWindow = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        let thirdWindow = SourceDiscoveryJob(playlistID: UUID(), wishes: wishes)
        let fairJobs = [firstWindow, secondWindow, thirdWindow]
        verifyDiscovery(BackgroundDiscoveryPolicy.nextJob(
            in: fairJobs, lastPlaylistID: nil, onWiFi: true,
            at: backgroundClock)?.playlistID == firstWindow.playlistID,
            "first background window begins with first available playlist")
        verifyDiscovery(BackgroundDiscoveryPolicy.nextJob(
            in: fairJobs, lastPlaylistID: firstWindow.playlistID,
            onWiFi: true, at: backgroundClock)?.playlistID == secondWindow.playlistID &&
            BackgroundDiscoveryPolicy.nextJob(
                in: fairJobs, lastPlaylistID: thirdWindow.playlistID,
                onWiFi: true, at: backgroundClock)?.playlistID == firstWindow.playlistID,
            "successive windows rotate and wrap across playlists")
        verifyDiscovery(BackgroundDiscoveryPolicy.nextJob(
            in: fairJobs, lastPlaylistID: firstWindow.playlistID,
            onWiFi: false, at: backgroundClock) == nil,
            "rotating background queue never authorizes cellular discovery")
        var blockedPlaylist = secondWindow
        blockedPlaylist.isPaused = true
        var deferredPlaylist = thirdWindow
        deferredPlaylist.nextRetryAt = backgroundClock.addingTimeInterval(45 * 60)
        verifyDiscovery(BackgroundDiscoveryPolicy.nextJob(
            in: [firstWindow, blockedPlaylist, deferredPlaylist],
            lastPlaylistID: firstWindow.playlistID, onWiFi: true,
            at: backgroundClock)?.playlistID == firstWindow.playlistID,
            "skip paused and backing-off playlists rather than wasting a window")
        verifyDiscovery(BackgroundDiscoveryPolicy.earliestUsefulDate(
            for: [blockedPlaylist, deferredPlaylist], at: backgroundClock) ==
                deferredPlaylist.nextRetryAt,
            "system wake is deferred until the provider retry becomes due")
        verifyDiscovery(BackgroundDiscoveryPolicy.earliestUsefulDate(
            for: [firstWindow, deferredPlaylist], at: backgroundClock) == backgroundClock &&
            BackgroundDiscoveryPolicy.earliestUsefulDate(
                for: [blockedPlaylist], at: backgroundClock) == nil,
            "ready playlists trigger work while paused-only queues do not")
        // URLSession may deliver two completed MP3s while a third callback
        // reports that iOS has no more background events. Every caller must
        // await the import pass and any additional pass requested during it.
        let staging = StagedAudioRecoveryCoordinator()
        var importPasses = 0
        var unblockImport: CheckedContinuation<Void, Never>?
        let firstImport = Task { @MainActor in
            await staging.run {
                importPasses += 1
                if importPasses == 1 {
                    await withCheckedContinuation { continuation in
                        unblockImport = continuation
                    }
                }
            }
        }
        while unblockImport == nil { await Task.yield() }
        let secondImport = Task { @MainActor in
            await staging.run { importPasses += 1 }
        }
        let finishingEvents = Task { @MainActor in
            await staging.run { importPasses += 1 }
        }
        for _ in 0..<8 { await Task.yield() }
        verifyDiscovery(importPasses == 1,
                        "staged downloads are never imported concurrently")
        unblockImport?.resume()
        await firstImport.value
        await secondImport.value
        await finishingEvents.value
        verifyDiscovery(importPasses == 2,
                        "overlapping imports coalesce while completion awaits final staging pass")
        let completedRetry = BackgroundProviderHistoryPolicy.Outcome(
            provider: "Internet Archive", imported: true, failed: false,
            failureReason: nil)
        let staleRetry = BackgroundProviderHistoryPolicy.Outcome(
            provider: "Internet Archive", imported: true, failed: false,
            failureReason: "Previous Wi-Fi failure")
        let alreadyStored = BackgroundProviderHistoryPolicy.Outcome(
            provider: "Openverse", imported: true, failed: false,
            failureReason: "This recording is already saved offline")
        let failedSource = BackgroundProviderHistoryPolicy.Outcome(
            provider: "Wikimedia Commons", imported: false, failed: true,
            failureReason: "Invalid audio")
        let pendingTransfer = BackgroundProviderHistoryPolicy.Outcome(
            provider: "ccMixter", imported: false, failed: false,
            failureReason: "Waiting for Wi-Fi")
        verifyDiscovery(BackgroundProviderHistoryPolicy.counts(completedRetry) &&
                        BackgroundProviderHistoryPolicy.counts(failedSource) &&
                        !BackgroundProviderHistoryPolicy.counts(staleRetry) &&
                        !BackgroundProviderHistoryPolicy.counts(alreadyStored) &&
                        !BackgroundProviderHistoryPolicy.counts(pendingTransfer),
                        "only verified imported recordings and terminal source failures affect provider priority")
        let history = BackgroundProviderHistoryPolicy.sources(
            in: [completedRetry, staleRetry, alreadyStored, failedSource, pendingTransfer])
        verifyDiscovery(history.successful == ["Internet Archive"] &&
                        history.failed == ["Wikimedia Commons"],
                        "a recovered MP3 download improves source ranking without rewarding duplicates or incomplete transfers")
        let repeated = Array(repeating: completedRetry, count: 250)
        verifyDiscovery(BackgroundProviderHistoryPolicy.sources(
            in: repeated).successful.count == BackgroundProviderHistoryPolicy.maxOutcomes,
            "source ranking only processes the most recent 200 eligible outcomes")

        struct ManifestFixture {
            let id: UUID
            let startedAt: Date?
            let title: String
        }
        let collisionID = UUID()
        let firstAttempt = ManifestFixture(
            id: collisionID, startedAt: Date(timeIntervalSince1970: 1000),
            title: "stale manifest entry")
        let newerAttempt = ManifestFixture(
            id: collisionID, startedAt: Date(timeIntervalSince1970: 2000),
            title: "latest valid download")
        let earlierAttempt = ManifestFixture(
            id: collisionID, startedAt: Date(timeIntervalSince1970: 500),
            title: "even older")
        let unrelatedAttempt = ManifestFixture(
            id: UUID(), startedAt: nil, title: "other playlist")
        let restoredManifest = BackgroundTicketManifestPolicy.distinctByIdentifier(
            [firstAttempt, newerAttempt, earlierAttempt, unrelatedAttempt],
            id: { $0.id }, startedAt: { $0.startedAt })
        verifyDiscovery(restoredManifest.count == 2 &&
                        restoredManifest[collisionID]?.title == "latest valid download" &&
                        restoredManifest[unrelatedAttempt.id]?.title == "other playlist",
                        "duplicate ticket IDs no longer crash manifest restoration or lose unrelated queued downloads")
        let legacyCollision = BackgroundTicketManifestPolicy.distinctByIdentifier(
            [ManifestFixture(id: collisionID, startedAt: nil, title: "legacy first"),
             ManifestFixture(id: collisionID, startedAt: nil, title: "legacy second")],
            id: { $0.id }, startedAt: { $0.startedAt })
        verifyDiscovery(legacyCollision[collisionID]?.title == "legacy first",
                        "legacy manifest duplicates without timestamps are stable and deterministic")
        let snapshot = SourceDiscoveryJob(playlistID: UUID(), wishes: [])
        verifyDiscovery(snapshot.isCurrent(in: [snapshot], at: 0),
                        "unchanged lookup snapshot can be applied")
        verifyDiscovery(!snapshot.isCurrent(in: [], at: 0),
                        "deleted lookup job cannot access its old index")
        let unrelatedJob = SourceDiscoveryJob(playlistID: UUID(), wishes: [])
        verifyDiscovery(!snapshot.isCurrent(in: [unrelatedJob], at: 0),
                        "shifted playlist cannot be overwritten by another lookup")
        var pausedSnapshot = snapshot
        pausedSnapshot.isPaused = true
        verifyDiscovery(!snapshot.isCurrent(in: [pausedSnapshot], at: 0),
                        "in-flight result cannot overwrite a user pause")
        var retriedSnapshot = snapshot
        retriedSnapshot.lastError = "Newer lookup state"
        verifyDiscovery(!snapshot.isCurrent(in: [retriedSnapshot], at: 0),
                        "in-flight result cannot overwrite newer checkpoint state")
        var exhausted = SourceDiscoveryJob(playlistID: UUID(), wishes: [
            PlaylistWish(title: "Song", artist: "Artist", album: "Album", spotifyURL: nil)
        ])
        for _ in 0..<SourceDiscoveryJob.automaticRetryLimit {
            exhausted.recordTransientFailure("Catalog request failed")
        }
        verifyDiscovery(exhausted.finishExhaustedRetriesIfNeeded(),
                        "exhausted search advances beyond the failing song")
        verifyDiscovery(exhausted.lastError == "Catalog request failed" &&
                        exhausted.nextRetryAt == nil && exhausted.failed == 1,
                        "exhausted search retains the error without scheduling another retry")
        print("Persistent discovery checkpoint tests passed")
    }
}
