import Foundation

/// Native target regression: compile with MP3Shelf's downloader and service
/// dependencies. No network requests are made.
@main
enum BackgroundAudioURLPolicyTests {
    static func main() {
        let rejected = [
            "http://audio.example/recording.mp3",
            "https://localhost/recording.mp3",
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
                let expected = queued && staged
                guard BackgroundAudioDownloader.shouldRecoverStagedAudio(
                    isQueued: queued, hasStagedFile: staged) == expected else {
                    fatalError("Incorrect callback precedence: queued=\(queued), staged=\(staged)")
                }
            }
        }
        print("PASS: background callback staged-file precedence fixtures")
        print("PASS: background download URL policy fixtures")
    }
}
