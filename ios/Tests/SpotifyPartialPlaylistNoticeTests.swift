import Foundation

// Compile with SpotifyService.swift and its normal iOS dependencies.
// This fixture never contacts Spotify or imports audio.
@main
enum SpotifyPartialPlaylistNoticeTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }

        check(SpotifyService.playlistImportNotice(imported: 50, unavailable: 0) == nil,
              "complete playlist has no warning")
        check(SpotifyService.playlistImportNotice(imported: 48, unavailable: 2) ==
              "Imported metadata for 48 songs; 2 playlist entries were unavailable and were not downloaded.",
              "partial import discloses omitted entries")
        check(SpotifyService.playlistImportNotice(imported: 1, unavailable: 100) != nil,
              "large redacted page remains visible")
        print("Spotify partial-playlist notice fixtures complete")
    }
}
