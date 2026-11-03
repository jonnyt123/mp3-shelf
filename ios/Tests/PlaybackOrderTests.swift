import Foundation

@main
struct PlaybackOrderTests {
    static func main() {
        let songs = (0..<6).map { _ in UUID() }
        var order = PlaybackOrder()
        order.reset(queue: songs, current: songs[0], shuffled: true)
        assert(order.queueIDs == songs)
        var visited = Set([songs[0]])
        for _ in 0..<(songs.count - 1) {
            let upcoming = order.upcomingIDs(limit: 3, loop: .off)
            let next = order.next(automatic: true, loop: .off)!
            assert(upcoming.first == next, "Queue preview must match next song")
            assert(visited.insert(next).inserted, "Shuffle replayed before using all songs")
        }
        assert(visited.count == songs.count)
        assert(order.next(automatic: true, loop: .off) == nil)
        assert(!order.canAdvanceAutomatically(loop: .off))
        assert(order.next(automatic: false, loop: .off) != nil, "Manual next can restart")

        order.reset(queue: songs, current: songs[0], shuffled: true)
        let forward = order.next(automatic: true, loop: .off)!
        let subsequent = order.next(automatic: true, loop: .off)!
        assert(order.previous(loop: .off) == forward)
        assert(order.upcomingIDs(limit: 1, loop: .off).first == subsequent)
        assert(order.next(automatic: true, loop: .off) == subsequent)
        assert(order.previous(loop: .off) == forward)
        assert(order.previous(loop: .off) == songs[0])
        assert(order.previous(loop: .off) == songs[0])

        order.reset(queue: songs, current: songs[0], shuffled: false)
        assert(order.upcomingIDs(limit: 3, loop: .off) == Array(songs[1...3]))
        assert(order.next(automatic: true, loop: .one) == songs[0])
        assert(order.next(automatic: true, loop: .off) == songs[1])
        assert(order.previous(loop: .off) == songs[0])
        assert(order.previous(loop: .off) == songs[0])
        order.select(songs[5])
        assert(order.next(automatic: true, loop: .off) == nil)
        assert(order.next(automatic: true, loop: .all) == songs[0])
        assert(order.previous(loop: .all) == songs[5])

        order.reset(queue: [songs[0], songs[0], songs[1]], current: songs[0], shuffled: false)
        assert(order.queueIDs == [songs[0], songs[1]])
        order.select(songs[2])
        assert(order.queueIDs == [songs[0],songs[1],songs[2]])
        order.setShuffle(true)
        assert(order.upcomingIDs(limit: 5, loop: .all).count == 2)
        order.retainAvailable(Set([songs[1],songs[2]]))
        assert(!order.queueIDs.contains(songs[0]))
        assert(order.queueIDs.count == 2)
        assert(order.currentID == songs[2])
        order.retainAvailable(Set([songs[1]]))
        assert(order.currentID == nil)

        order.reset(queue: [songs[0]], current: songs[0], shuffled: true)
        assert(order.next(automatic: true, loop: .off) == nil)
        assert(order.next(automatic: true, loop: .all) == songs[0])
        assert(order.upcomingIDs(limit: 3, loop: .all).isEmpty)
        print("PASS PlaybackOrder: shuffle exhaustion, previews, history, repeat, manual controls, pruning, single-song")
    }
}
