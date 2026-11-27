import Foundation

/// A pure playback-order state machine. It keeps the original playlist intact,
/// uses every song in a shuffled cycle before repeating, and makes Back/Next
/// reversible without changing the user's library or playlist order.
enum PlaybackLoopMode {
    case off
    case all
    case one
}

struct PlaybackOrder {
    private(set) var queueIDs: [UUID] = []
    private(set) var currentID: UUID?
    private(set) var isShuffled = false
    private var remainingShuffle: [UUID] = []
    private var playHistory: [UUID] = []
    // A deleted current recording may remain as a positional anchor until advancement.
    // It must never be selected again by repeat, shuffle, or Back.
    private var unavailableAnchor: UUID?

    private var playableIDs: [UUID] {
        queueIDs.filter { $0 != unavailableAnchor }
    }

    mutating func reset(queue ids: [UUID], current: UUID, shuffled: Bool) {
        var seen = Set<UUID>()
        queueIDs = ids.filter { seen.insert($0).inserted }
        if !seen.contains(current) { queueIDs.append(current) }
        currentID = current
        unavailableAnchor = nil
        isShuffled = shuffled
        playHistory.removeAll(keepingCapacity: true)
        remainingShuffle = shuffled ? queueIDs.filter { $0 != current }.shuffled() : []
    }

    // Once playback moves away from a deleted recording, discard its positional
    // anchor permanently. Otherwise clearing unavailableAnchor alone makes the
    // deleted UUID playable again on a later repeat or shuffle rebuild.
    private mutating func finishSelection(_ id: UUID) {
        if let removed = unavailableAnchor, removed != id {
            queueIDs.removeAll { $0 == removed }
            remainingShuffle.removeAll { $0 == removed }
            playHistory.removeAll { $0 == removed }
        }
        currentID = id
        unavailableAnchor = nil
    }

    mutating func select(_ id: UUID) {
        // A stale Now Playing/queue action must not revive a recording that
        // disappeared from the catalog. Its UUID is only a position anchor
        // until playback moves to a surviving recording.
        guard id != unavailableAnchor else { return }
        if !queueIDs.contains(id) { queueIDs.append(id) }
        if let currentID, currentID != id && unavailableAnchor != currentID { playHistory.append(currentID) }
        finishSelection(id)
        if isShuffled { remainingShuffle.removeAll { $0 == id } }
    }

    mutating func setShuffle(_ enabled: Bool) {
        guard enabled != isShuffled else { return }
        isShuffled = enabled
        playHistory.removeAll(keepingCapacity: true)
        remainingShuffle = enabled ? playableIDs.filter { $0 != currentID }.shuffled() : []
    }

    mutating func retainAvailable(_ available: Set<UUID>) {
        // A recording can disappear from the catalog while its already-open
        // player is finishing. Keep that selection as a temporary queue anchor
        // so Next and natural completion can still reach surviving recordings.
        // Do not keep a removed selection if there is nothing left to play.
        let hasSuccessor = queueIDs.contains { available.contains($0) }
        let anchor = hasSuccessor ? currentID : nil
        unavailableAnchor = anchor.flatMap { available.contains($0) ? nil : $0 }
        queueIDs.removeAll { !available.contains($0) && $0 != anchor }
        remainingShuffle.removeAll { !available.contains($0) }
        playHistory.removeAll { !available.contains($0) }
        // The removed current song may have been the final item in a shuffle
        // cycle. An empty pending cycle must not strand surviving recordings:
        // rebuild from the available library, excluding the deleted anchor.
        // This is a recovery continuation, not an ordinary repeat of a
        // completed shuffle cycle (which still obeys loop == .off).
        if isShuffled, unavailableAnchor != nil, remainingShuffle.isEmpty {
            remainingShuffle = playableIDs.shuffled()
        }
        if let selected = currentID, anchor == nil && !available.contains(selected) {
            currentID = nil
        }
    }

    mutating func next(automatic: Bool, loop: PlaybackLoopMode) -> UUID? {
        guard let currentID, !queueIDs.isEmpty else { return nil }
        if automatic && loop == .one && unavailableAnchor != currentID { return currentID }
        if isShuffled {
            if remainingShuffle.isEmpty {
                // A deleted current recording is not a completed shuffle cycle.
                // Recover from the surviving library even with Repeat Off, for
                // example after the last pending song was removed from the queue.
                if automatic && loop == .off && unavailableAnchor != currentID { return nil }
                remainingShuffle = playableIDs.filter { $0 != currentID }.shuffled()
            }
            guard !remainingShuffle.isEmpty else {
                return unavailableAnchor == currentID ? nil : (automatic && loop == .off ? nil : currentID)
            }
            let nextID = remainingShuffle.removeFirst()
            if unavailableAnchor != currentID { playHistory.append(currentID) }
            finishSelection(nextID)
            return nextID
        }
        guard let index = queueIDs.firstIndex(of: currentID) else { return nil }
        let candidates = queueIDs.dropFirst(index + 1).filter { $0 != unavailableAnchor }
        let nextID: UUID
        if let first = candidates.first {
            nextID = first
        } else if automatic && loop == .off && unavailableAnchor != currentID {
            return nil
        } else if let first = playableIDs.first {
            nextID = first
        } else {
            return nil
        }
        finishSelection(nextID)
        return nextID
    }

    mutating func previous(loop: PlaybackLoopMode) -> UUID? {
        guard let currentID, !queueIDs.isEmpty else { return nil }
        if isShuffled {
            guard let previousID = playHistory.popLast() else {
                guard unavailableAnchor == currentID, let survivor = playableIDs.first else { return currentID }
                finishSelection(survivor)
                remainingShuffle.removeAll { $0 == survivor }
                return survivor
            }
            remainingShuffle.removeAll { $0 == previousID }
            if !remainingShuffle.contains(currentID) {
                if unavailableAnchor != currentID { remainingShuffle.insert(currentID, at: 0) }
            }
            finishSelection(previousID)
            return previousID
        }
        guard let index = queueIDs.firstIndex(of: currentID) else { return nil }
        let preceding = queueIDs.prefix(index).filter { $0 != unavailableAnchor }
        let previousID = preceding.last ?? (loop == .all ? playableIDs.last : playableIDs.first)
        guard let previousID else { return nil }
        finishSelection(previousID)
        return previousID
    }

    /// Expose only the current cycle's distinct pending songs for editing.
    /// Editing the queue never modifies MusicPlaylist.trackIDs.
    func editableUpcomingIDs(limit: Int = 200) -> [UUID] {
        guard limit > 0, let currentID else { return [] }
        if isShuffled { return Array(remainingShuffle.prefix(limit)) }
        guard let position = queueIDs.firstIndex(of: currentID) else { return [] }
        let pending = queueIDs.dropFirst(position + 1).filter { $0 != unavailableAnchor }
        if !pending.isEmpty { return Array(pending.prefix(limit)) }
        // If the last selected song was deleted, Next wraps to surviving
        // recordings even with Repeat Off. Expose that recovery queue to the
        // editor rather than showing an empty queue while Next can advance.
        return unavailableAnchor == currentID ? Array(playableIDs.prefix(limit)) : []
    }

    /// Reorder the currently pending queue without resetting listening history.
    @discardableResult
    mutating func moveUpcoming(_ id: UUID, earlier: Bool) -> Bool {
        if isShuffled {
            guard let index = remainingShuffle.firstIndex(of: id) else { return false }
            let destination = earlier ? index - 1 : index + 1
            guard remainingShuffle.indices.contains(destination) else { return false }
            remainingShuffle.swapAt(index, destination)
            return true
        }
        guard let currentID, let currentIndex = queueIDs.firstIndex(of: currentID),
              let index = queueIDs.firstIndex(of: id), id != unavailableAnchor else { return false }
        // A deleted final selection remains as a positional anchor. The
        // editable recovery queue exposes survivors before that anchor;
        // permit adjacent reordering within that wrapped segment.
        if unavailableAnchor == currentID && currentIndex == queueIDs.count - 1 && index < currentIndex {
            let destination = earlier ? index - 1 : index + 1
            guard destination >= 0, destination < currentIndex else { return false }
            queueIDs.swapAt(index, destination)
            return true
        }
        guard index > currentIndex else { return false }
        let destination = earlier ? index - 1 : index + 1
        guard destination > currentIndex, queueIDs.indices.contains(destination) else { return false }
        queueIDs.swapAt(index, destination)
        return true
    }

    /// Removing an item from the listening queue leaves its library file,
    /// favorite flag and all persisted playlists completely unchanged.
    @discardableResult
    mutating func removeUpcoming(_ id: UUID) -> Bool {
        guard let currentID, id != currentID,
              let currentIndex = queueIDs.firstIndex(of: currentID),
              let index = queueIDs.firstIndex(of: id) else { return false }
        // Delayed queue actions may refer to songs that have already played.
        // Never remove listening history when an Up Next row has gone stale.
        if isShuffled {
            guard remainingShuffle.contains(id) else { return false }
        } else {
            let recovering = unavailableAnchor == currentID && currentIndex == queueIDs.count - 1
            guard index > currentIndex || (recovering && index < currentIndex) else { return false }
        }
        queueIDs.remove(at: index)
        remainingShuffle.removeAll { $0 == id }
        playHistory.removeAll { $0 == id }
        return true
    }

    /// Place an already queued recording immediately after the current song.
    @discardableResult
    mutating func playNext(_ id: UUID) -> Bool {
        guard let currentID, id != currentID,
              let currentIndex = queueIDs.firstIndex(of: currentID),
              let index = queueIDs.firstIndex(of: id) else { return false }
        if isShuffled {
            guard let pending = remainingShuffle.firstIndex(of: id) else { return false }
            remainingShuffle.remove(at: pending)
            remainingShuffle.insert(id, at: 0)
            return true
        }
        // Only visible upcoming rows may be promoted. A delayed action for
        // a previously played row must not rewrite listening history.
        let recovering = unavailableAnchor == currentID && currentIndex == queueIDs.count - 1
        guard index > currentIndex || (recovering && index < currentIndex) else { return false }
        queueIDs.remove(at: index)
        if recovering {
            // Keep the deleted anchor last. Recovery wraps to the first
            // survivor, then advances normally through the remaining queue.
            queueIDs.insert(id, at: 0)
            return true
        }
        let target = queueIDs.firstIndex(of: currentID) ?? currentIndex
        queueIDs.insert(id, at: min(target + 1, queueIDs.count))
        return true
    }

    func canAdvanceAutomatically(loop: PlaybackLoopMode) -> Bool {
        guard let currentID, !queueIDs.isEmpty else { return false }
        // A removed current recording cannot repeat; advance to survivors.
        if loop == .one && unavailableAnchor != currentID { return false }
        if isShuffled {
            return !remainingShuffle.isEmpty
                || (unavailableAnchor == currentID && playableIDs.contains { $0 != currentID })
                || (loop == .all && playableIDs.contains { $0 != currentID })
        }
        guard let index = queueIDs.firstIndex(of: currentID) else { return false }
        return queueIDs.dropFirst(index + 1).contains { $0 != unavailableAnchor }
            || (unavailableAnchor == currentID && !playableIDs.isEmpty)
            || (loop == .all && !playableIDs.isEmpty)
    }

    func upcomingIDs(limit: Int, loop: PlaybackLoopMode) -> [UUID] {
        guard limit > 0, let currentID, !queueIDs.isEmpty else { return [] }
        if loop == .one && unavailableAnchor != currentID { return [] }
        if isShuffled {
            if remainingShuffle.isEmpty && unavailableAnchor == currentID {
                // The exact order is selected when advancement occurs; expose
                // surviving candidates instead of an incorrectly empty queue.
                return Array(playableIDs.filter { $0 != currentID }.prefix(limit))
            }
            return Array(remainingShuffle.prefix(limit))
        }
        guard let index = queueIDs.firstIndex(of: currentID) else { return [] }
        var result = Array(queueIDs.dropFirst(index + 1).filter { $0 != unavailableAnchor }.prefix(limit))
        // Recovery after deleting the last selected recording wraps to the
        // surviving queue even with Repeat Off. Keep the preview consistent
        // with next(automatic:loop:) and canAdvanceAutomatically(loop:).
        if result.isEmpty && unavailableAnchor == currentID {
            return Array(playableIDs.prefix(limit))
        }
        if result.count < limit && loop == .all {
            result += Array(playableIDs.prefix(limit - result.count))
        }
        return result
    }
}
