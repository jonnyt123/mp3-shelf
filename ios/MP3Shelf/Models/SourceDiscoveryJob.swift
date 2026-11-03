import Foundation

/// Checkpoint for foreground catalog lookups. Written atomically after each
/// processed song, allowing discovery to resume after app suspension or exit.
/// Pure policy used by the foreground discovery queue and regression tests.
enum DownloadNetworkPolicy {
    static func canDiscover(onWiFi: Bool, onCellular: Bool,
                            explicitlyAllowCellular: Bool) -> Bool {
        onWiFi || (onCellular && explicitlyAllowCellular)
    }
}


/// Small, bounded recovery budget for actual background file transfers.
/// The source catalog has its own independent lookup retry policy. Do not
/// retry invalid media, rejected permissions, or conflicting song metadata.
enum BackgroundTransferRetryPolicy {
    static let maxRetries = 3

    static func delay(afterFailure attempt: Int) -> TimeInterval? {
        switch attempt {
        case 1: return 45
        case 2: return 150
        case 3: return 450
        default: return nil
        }
    }

    static func isTemporaryHTTP(_ statusCode: Int) -> Bool {
        [408, 429, 500, 502, 503, 504].contains(statusCode)
    }

    static func isTemporaryURLFailure(_ code: Int) -> Bool {
        let temporary: Set<Int> = [
            URLError.Code.timedOut.rawValue,
            URLError.Code.networkConnectionLost.rawValue,
            URLError.Code.notConnectedToInternet.rawValue,
            URLError.Code.cannotConnectToHost.rawValue,
            URLError.Code.cannotFindHost.rawValue,
            URLError.Code.dnsLookupFailed.rawValue
        ]
        return temporary.contains(code)
    }
}

/// The local transfer manifest and iOS' background URLSession can drift
/// apart after a crash or the system discards a task. Be conservative: do not
/// duplicate a live task or reissue one whose staging file awaits import.
enum BackgroundTransferRecoveryPolicy {
    static let minimumAge: TimeInterval = 15 * 60

    static func shouldRecover(startedAt: Date?, checkedAt: Date,
                              firstScanHasTask: Bool, secondScanHasTask: Bool,
                              hasUnidentifiedTasks: Bool,
                              hasStagedFile: Bool, isImporting: Bool) -> Bool {
        guard let startedAt,
              checkedAt.timeIntervalSince(startedAt) >= minimumAge else { return false }
        return !firstScanHasTask && !secondScanHasTask &&
            !hasUnidentifiedTasks && !hasStagedFile && !isImporting
    }
}

/// Pure, testable eligibility for bounded system-scheduled catalog work.
/// The foreground queue continues to use the normal user-approved policy.
enum BackgroundDiscoveryPolicy {
    static let maxSongsPerPass = 5

    static func hasPending(_ jobs: [SourceDiscoveryJob]) -> Bool {
        jobs.contains { !$0.isPaused && !$0.isComplete }
    }

    static func canProcess(onWiFi: Bool, job: SourceDiscoveryJob, at date: Date) -> Bool {
        onWiFi && !job.isPaused && !job.isComplete &&
            job.canAttemptLookup(at: date)
    }
}

struct SourceDiscoveryJob: Codable, Equatable, Identifiable {
    enum Result { case queued, unavailable, failed, alreadyPresent, removed }

    /// Per-song outcome for the Spotify → independent-source MP3 matching
    /// dashboard. Optional so existing checkpoint JSON remains decodable.
    enum Outcome: String, Codable, Equatable {
        case queued, unavailable, failed, alreadyPresent, removed, previous
    }

    var playlistID: UUID
    var wishes: [PlaylistWish]
    var nextIndex: Int = 0
    var queued: Int = 0
    var unavailable: Int = 0
    var failed: Int = 0
    var isPaused = false
    var lastError: String? = nil
    var outcomes: [Outcome]? = nil
    // Optional fields preserve decoding of checkpoints created by older builds.
    var transientFailureCount: Int? = nil
    var nextRetryAt: Date? = nil

    /// Exhaust a bounded retry budget instead of blocking this playlist
    /// indefinitely when a remote catalog cannot answer. An exhausted song
    /// is classified as failed, not falsely recorded as unavailable.
    static let automaticRetryLimit = 5
    var hasExhaustedAutomaticRetries: Bool {
        (transientFailureCount ?? 0) >= Self.automaticRetryLimit
    }

    var id: UUID { playlistID }
    var isComplete: Bool { nextIndex >= wishes.count }
    var remaining: Int { max(0, wishes.count - nextIndex) }
    var currentWish: PlaylistWish? { isComplete ? nil : wishes[nextIndex] }

    func canAttemptLookup(at date: Date) -> Bool {
        nextRetryAt.map { $0 <= date } ?? true
    }

    /// The current song is not discarded when a catalog is temporarily down.
    /// Increasing delays avoid hammering APIs during an outage. The next
    /// retry date is persisted alongside the existing discovery cursor.
    mutating func recordTransientFailure(_ message: String, at date: Date = .now) {
        guard !isComplete else { return }
        let count = min(Self.automaticRetryLimit, (transientFailureCount ?? 0) + 1)
        let delays: [TimeInterval] = [15, 30, 60, 120, 240]
        transientFailureCount = count
        nextRetryAt = date.addingTimeInterval(delays[count - 1])
        lastError = message
    }

    /// A source still failing after repeated automatic attempts should not
    /// hold the rest of the playlist hostage. Manual playlist Retry remains
    /// available once its missing-song search finishes.
    @discardableResult
    mutating func finishExhaustedRetriesIfNeeded() -> Bool {
        guard hasExhaustedAutomaticRetries && !isComplete else { return false }
        record(.failed)
        return true
    }

    /// Append only genuinely new missing tracks while keeping completed
    /// entries and their persisted cursor, outcomes, retries and errors intact.
    /// Safe even when a duplicate song occurs more than once in the playlist.
    @discardableResult
    mutating func appendNewMissingWishes(_ missing: [PlaylistWish]) -> Int {
        // Some external playlist feeds can repeat an internal wish ID.
        // Accept the newest metadata without crashing on duplicate keys.
        let updated = Dictionary(missing.map { ($0.id, $0) },
                                 uniquingKeysWith: { _, newest in newest })
        // Refresh metadata for unfinished lookups using the same Spotify
        // occurrence IDs; retain all historical outcomes and retry cursors.
        for index in nextIndex..<wishes.count {
            if let latest = updated[wishes[index].id] {
                wishes[index] = latest
            }
        }
        var ids = Set(wishes.map(\.id))
        let appended = missing.filter { ids.insert($0.id).inserted }
        wishes.append(contentsOf: appended)
        return appended.count
    }

    func outcome(for wish: PlaylistWish) -> Outcome? {
        guard let index = wishes.firstIndex(where: { $0.id == wish.id }),
              index < nextIndex else { return nil }
        return outcomes.flatMap { index < $0.count ? $0[index] : nil } ?? .previous
    }

    mutating func record(_ result: Result) {
        guard !isComplete else { return }
        var updated = outcomes ?? Array(repeating: Outcome.previous, count: nextIndex)
        // Repair truncated/corrupted optional history without changing the
        // authoritative persisted cursor or aggregate counts.
        if updated.count > nextIndex { updated = Array(updated.prefix(nextIndex)) }
        if updated.count < nextIndex {
            updated.append(contentsOf: repeatElement(.previous, count: nextIndex - updated.count))
        }
        switch result {
        case .queued:
            queued += 1
            updated.append(.queued)
        case .unavailable:
            unavailable += 1
            updated.append(.unavailable)
        case .failed:
            failed += 1
            updated.append(.failed)
        case .alreadyPresent:
            updated.append(.alreadyPresent)
        case .removed:
            updated.append(.removed)
        }
        outcomes = updated
        nextIndex += 1
        lastError = nil
        transientFailureCount = nil
        nextRetryAt = nil
    }
}
