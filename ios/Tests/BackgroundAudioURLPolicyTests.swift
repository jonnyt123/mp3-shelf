import Foundation

/// Native target regression: compile with MP3Shelf's downloader and service
/// dependencies. No network requests are made.
@main
enum BackgroundAudioURLPolicyTests {
    static func main() {
        let rejected = [
            "http://audio.example/recording.mp3",
            "https://localhost/recording.mp3",
            "https://audio.example./recording.mp3",
            "https://open.spotify.com./track/fixture",
            "https://r1.googlevideo.com./videoplayback",
            "https://speaker.local/recording.mp3",
            "https://gateway.internal/recording.mp3",
            "https://127.0.0.1/recording.mp3",
            "https://192.168.1.2/recording.mp3",
            "https://[::1]/recording.mp3",
            "https://0x7f.0.0.1/recording.mp3",
            "https://0177.0.0.1/recording.mp3",
            "https://user:password@audio.example/recording.mp3",
            "https://audio.example:8443/recording.mp3",
            "https://audio.example/recording.mp3#fragment",
            "https://open.spotify.com/track/fixture",
            "https://r1.googlevideo.com/videoplayback"
        ]
        for raw in rejected {
            guard let url = URL(string: raw),
                  !BackgroundAudioDownloader.allowedDownloadURL(url) else {
                fatalError("Rejected background URL was accepted: \(raw)")
            }
        }
        let accepted = [
            "https://cdn.audio.example/recording.mp3",
            "https://media.example.org/files/recording.m4a?token=fixture"
        ]
        for raw in accepted {
            guard let url = URL(string: raw),
                  BackgroundAudioDownloader.allowedDownloadURL(url) else {
                fatalError("Safe public HTTPS URL was rejected: \(raw)")
            }
        }
        // A complete staged recording wins against late HTTP failures,
        // cancellation errors and progress-limit callbacks. A cancelled or
        // already imported ticket must not revive a stale staged file.
        for queued in [false, true] {
            for staged in [false, true] {
                for importing in [false, true] {
                    let expected = queued && (staged || importing)
                    guard BackgroundAudioDownloader.shouldDeferCallbackFailure(
                        isQueued: queued, hasStagedFile: staged,
                        isImporting: importing) == expected else {
                        fatalError("Incorrect callback precedence: queued=\(queued), staged=\(staged), importing=\(importing)")
                    }
                }
            }
        }
        // A relaunched downloader can recover a bounded approval, but no
        // session-level setting may override a request without consent.
        let fixtureURL = URL(string: "https://audio.example.org/song.mp3")!
        for approved in [false, true] {
            let request = BackgroundAudioDownloader.requestForAudio(
                fixtureURL, cellularApproved: approved)
            guard request.allowsCellularAccess == approved,
                  request.allowsExpensiveNetworkAccess == approved,
                  request.allowsConstrainedNetworkAccess == approved else {
                fatalError("Incorrect cellular request permissions for approval=\(approved)")
            }
        }
        // Opt-in must not cancel an active decoder or restart a recording
        // whose staged bytes are already ready for library import.
        for queued in [false, true] {
            for staged in [false, true] {
                for importing in [false, true] {
                    for cellular in [false, true] {
                        let expected = queued && !staged && !importing && !cellular
                        guard BackgroundAudioDownloader.mayUpgradeToCellular(
                            isQueued: queued, hasStagedFile: staged,
                            isImporting: importing,
                            taskAlreadyAllowsCellular: cellular) == expected else {
                            fatalError("Incorrect cellular upgrade eligibility")
                        }
                    }
                }
            }
        }
        // A shared task is safe only for the exact recording and URL,
        // while its leader remains queued in a different playlist.
        var validSharedCases = 0
        for sameRecording in [false, true] {
            for sameURL in [false, true] {
                for leaderQueued in [false, true] {
                    for samePlaylist in [false, true] {
                        let expected = sameRecording && sameURL && leaderQueued && !samePlaylist
                        guard BackgroundAudioDownloader.mayShareTransfer(
                            sameRecording: sameRecording, sameURL: sameURL,
                            leaderQueued: leaderQueued, samePlaylist: samePlaylist) == expected else {
                            fatalError("Shared download eligibility regression")
                        }
                        validSharedCases += 1
                    }
                }
            }
        }
        guard validSharedCases == 16 else { fatalError("Incomplete sharing matrix") }
        print("PASS: 16 cross-playlist transfer eligibility combinations")
        print("PASS: 16 cellular upgrade and in-progress import combinations")
        print("PASS: cellular, expensive and constrained network opt-in fixtures")
        print("PASS: background callback staged-file precedence fixtures")
        print("PASS: background download URL policy fixtures")
    }
}
