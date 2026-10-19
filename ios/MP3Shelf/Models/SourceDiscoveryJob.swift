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

struct SourceDiscoveryJob: Codable, Equatable, Identifiable {
    enum Result { case queued, unavailable, failed, alreadyPresent }

    /// Per-song outcome for the Spotify → independent-source MP3 matching
    /// dashboard. Optional so existing checkpoint JSON remains decodable.
    enum Outcome: String, Codable, Equatable {
        case queued, unavailable, failed, alreadyPresent, previous
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

    var id: UUID { playlistID }
    var isComplete: Bool { nextIndex >= wishes.count }
    var remaining: Int { max(0, wishes.count - nextIndex) }
    var currentWish: PlaylistWish? { isComplete ? nil : wishes[nextIndex] }

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
        }
        outcomes = updated
        nextIndex += 1
        lastError = nil
    }
}
