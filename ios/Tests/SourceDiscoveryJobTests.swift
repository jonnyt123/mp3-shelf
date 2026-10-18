import Foundation

func verifyDiscovery(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
}

@main
enum SourceDiscoveryJobTests {
    static func main() throws {
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
        print("Persistent discovery checkpoint tests passed")
    }
}
