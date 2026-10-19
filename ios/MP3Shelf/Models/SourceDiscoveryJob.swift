import Foundation

/// Checkpoint for foreground catalog lookups. Written atomically after each
/// processed song, allowing discovery to resume after app suspension or exit.
struct SourceDiscoveryJob: Codable, Equatable, Identifiable {
    enum Result { case queued, unavailable, failed, alreadyPresent }

    var playlistID: UUID
    var wishes: [PlaylistWish]
    var nextIndex: Int = 0
    var queued: Int = 0
    var unavailable: Int = 0
    var failed: Int = 0
    var isPaused = false
    var lastError: String? = nil

    var id: UUID { playlistID }
    var isComplete: Bool { nextIndex >= wishes.count }
    var remaining: Int { max(0, wishes.count - nextIndex) }
    var currentWish: PlaylistWish? { isComplete ? nil : wishes[nextIndex] }

    mutating func record(_ result: Result) {
        guard !isComplete else { return }
        switch result {
        case .queued: queued += 1
        case .unavailable: unavailable += 1
        case .failed: failed += 1
        case .alreadyPresent: break
        }
        nextIndex += 1
        lastError = nil
    }
}
