import Foundation

func verifyDiscovery(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
}

@main
enum SourceDiscoveryJobTests {
    @MainActor static func main() async throws {
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
        let encoded = try JSONEncoder().encode([job])
        let restored = try JSONDecoder().decode([SourceDiscoveryJob].self, from: encoded)
        verifyDiscovery(restored[0].isPaused && restored[0].nextIndex == 1,
                        "pause and incomplete position survive restart")
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
        // Older discovery checkpoints had no outcomes field. They must still
        // decode and resume at the exact same cursor without repeating songs.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job))
            as! [String: Any]
        legacy.removeValue(forKey: "outcomes")
        var migrated = try JSONDecoder().decode(SourceDiscoveryJob.self,
                         from: JSONSerialization.data(withJSONObject: legacy))
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
            isSceneActive: true, hasForegroundTask: false, hasBackgroundBatch: false),
            "idle foreground discovery can start automatically")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canStartForegroundScan(
            isSceneActive: true, hasForegroundTask: true, hasBackgroundBatch: false),
            "Wi-Fi change does not start duplicate foreground discovery")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canStartForegroundScan(
            isSceneActive: true, hasForegroundTask: false, hasBackgroundBatch: true),
            "Wi-Fi callback cannot bypass the five-song background batch limit")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canStartForegroundScan(
            isSceneActive: true, hasForegroundTask: true, hasBackgroundBatch: true),
            "neither active scan permits a concurrent source lookup")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canStartForegroundScan(
            isSceneActive: false, hasForegroundTask: false, hasBackgroundBatch: false),
            "headless URLSession wake cannot initiate unbounded catalog discovery")
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
                onWiFi: false, onCellular: true, explicitlyAllowCellular: false),
            "foreground resume keeps the existing Wi-Fi-only default and never bypasses cellular gating")
        verifyDiscovery(BackgroundDiscoveryPolicy.canProcess(
            onWiFi: true, job: backgroundJob, at: backgroundClock),
            "background source discovery can run on Wi-Fi")
        verifyDiscovery(!BackgroundDiscoveryPolicy.canProcess(
            onWiFi: false, job: backgroundJob, at: backgroundClock),
            "system-granted background window does not authorize cellular")
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
        print("Persistent discovery checkpoint tests passed")
    }
}
