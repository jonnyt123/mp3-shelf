import Foundation

func verifyDiscovery(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
}

@main
enum SourceDiscoveryJobTests {
    static func main() throws {
        let id = UUID()
        let wishes = [
            PlaylistWish(title: "First", artist: "Artist", album: "", spotifyURL: nil),
            PlaylistWish(title: "Second", artist: "Artist", album: "", spotifyURL: nil),
            PlaylistWish(title: "Third", artist: "Artist", album: "", spotifyURL: nil)
        ]
        var job = SourceDiscoveryJob(playlistID: id, wishes: wishes)
        verifyDiscovery(job.remaining == 3 && job.currentWish?.title == "First", "initial cursor")
        job.record(.queued)
        verifyDiscovery(job.nextIndex == 1 && job.queued == 1, "enqueue updates cursor")
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
        let cursor = job.nextIndex
        job.record(.failed)
        verifyDiscovery(job.nextIndex == cursor, "complete job cannot advance beyond its list")
        print("Persistent discovery checkpoint tests passed")
    }
}
