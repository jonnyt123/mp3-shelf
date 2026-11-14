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

    mutating func reset(queue ids: [UUID], current: UUID, shuffled: Bool) {
        var seen = Set<UUID>()
        queueIDs = ids.filter { seen.insert($0).inserted }
        if !seen.contains(current) { queueIDs.append(current) }
        currentID = current
        isShuffled = shuffled
        playHistory.removeAll(keepingCapacity: true)
        remainingShuffle = shuffled ? queueIDs.filter { $0 != current }.shuffled() : []
    }

    mutating func select(_ id: UUID) {
        if !queueIDs.contains(id) { queueIDs.append(id) }
        if let currentID, currentID != id { playHistory.append(currentID) }
        currentID = id
        if isShuffled { remainingShuffle.removeAll { $0 == id } }
    }

    mutating func setShuffle(_ enabled: Bool) {
        guard enabled != isShuffled else { return }
        isShuffled = enabled
        playHistory.removeAll(keepingCapacity: true)
        remainingShuffle = enabled ? queueIDs.filter { $0 != currentID }.shuffled() : []
    }

    mutating func retainAvailable(_ available: Set<UUID>) {
        queueIDs.removeAll { !available.contains($0) }
        remainingShuffle.removeAll { !available.contains($0) }
        playHistory.removeAll { !available.contains($0) }
        if let currentID, !available.contains(currentID) { self.currentID = nil }
    }

    mutating func next(automatic: Bool, loop: PlaybackLoopMode) -> UUID? {
        guard let currentID, !queueIDs.isEmpty else { return nil }
        if automatic && loop == .one { return currentID }
        if isShuffled {
            if remainingShuffle.isEmpty {
                if automatic && loop == .off { return nil }
                remainingShuffle = queueIDs.filter { $0 != currentID }.shuffled()
            }
            guard !remainingShuffle.isEmpty else {
                return automatic && loop == .off ? nil : currentID
            }
            let nextID = remainingShuffle.removeFirst()
            playHistory.append(currentID)
            self.currentID = nextID
            return nextID
        }
        guard let index = queueIDs.firstIndex(of: currentID) else { return nil }
        let nextID: UUID
        if index + 1 < queueIDs.count {
            nextID = queueIDs[index + 1]
        } else if automatic && loop == .off {
            return nil
        } else {
            nextID = queueIDs[0]
        }
        self.currentID = nextID
        return nextID
    }

    mutating func previous(loop: PlaybackLoopMode) -> UUID? {
        guard let currentID, !queueIDs.isEmpty else { return nil }
        if isShuffled {
            guard let previousID = playHistory.popLast() else { return currentID }
            remainingShuffle.removeAll { $0 == previousID }
            if !remainingShuffle.contains(currentID) {
                remainingShuffle.insert(currentID, at: 0)
            }
            self.currentID = previousID
            return previousID
        }
        guard let index = queueIDs.firstIndex(of: currentID) else { return nil }
        let previousID = index > 0 ? queueIDs[index - 1]
            : (loop == .all ? queueIDs[queueIDs.count - 1] : queueIDs[0])
        self.currentID = previousID
        return previousID
    }

    /// Expose only the current cycle's distinct pending songs for editing.
    /// Editing the queue never modifies MusicPlaylist.trackIDs.
    func editableUpcomingIDs(limit: Int = 200) -> [UUID] {
        guard limit > 0, let currentID else { return [] }
        if isShuffled { return Array(remainingShuffle.prefix(limit)) }
        guard let position = queueIDs.firstIndex(of: currentID) else { return [] }
        return Array(queueIDs.dropFirst(position + 1).prefix(limit))
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
              let index = queueIDs.firstIndex(of: id), index > currentIndex else { return false }
        let destination = earlier ? index - 1 : index + 1
        guard destination > currentIndex, queueIDs.indices.contains(destination) else { return false }
        queueIDs.swapAt(index, destination)
        return true
    }

    /// Removing an item from the listening queue leaves its library file,
    /// favorite flag and all persisted playlists completely unchanged.
    @discardableResult
    mutating func removeUpcoming(_ id: UUID) -> Bool {
        guard id != currentID, let index = queueIDs.firstIndex(of: id) else { return false }
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
        queueIDs.remove(at: index)
        let target = queueIDs.firstIndex(of: currentID) ?? currentIndex
        queueIDs.insert(id, at: min(target + 1, queueIDs.count))
        return true
    }

    func canAdvanceAutomatically(loop: PlaybackLoopMode) -> Bool {
        guard let currentID, !queueIDs.isEmpty, loop != .one else { return false }
        if isShuffled {
            return !remainingShuffle.isEmpty || loop == .all
        }
        guard let index = queueIDs.firstIndex(of: currentID) else { return false }
        return index + 1 < queueIDs.count || loop == .all
    }

    func upcomingIDs(limit: Int, loop: PlaybackLoopMode) -> [UUID] {
        guard limit > 0, let currentID, !queueIDs.isEmpty, loop != .one else { return [] }
        if isShuffled { return Array(remainingShuffle.prefix(limit)) }
        guard let index = queueIDs.firstIndex(of: currentID) else { return [] }
        var result = Array(queueIDs.dropFirst(index + 1).prefix(limit))
        if result.count < limit && loop == .all {
            result += Array(queueIDs.prefix(limit - result.count))
        }
        return result
    }
}
