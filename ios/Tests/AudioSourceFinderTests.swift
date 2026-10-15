import Foundation

func verify(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fatalError("FAIL: \(description)") }
    print("PASS: \(description)")
}

@main
enum AudioSourceFinderTests {
    static func main() {
        let wish = PlaylistWish(title: "The Song", artist: "The Artist",
                                album: "The Album", spotifyURL: nil, durationSeconds: 212)
        verify(AudioSourceFinder.exactMetadataMatch(title: "The Song", creator: "The Artist",
                                                     wish: wish), "exact title and artist")
        verify(!AudioSourceFinder.exactMetadataMatch(title: "The Song (Live)",
                                                      creator: "The Artist", wish: wish),
               "no alternate live version")
        verify(!AudioSourceFinder.exactMetadataMatch(title: "The Song", creator: "Another Artist",
                                                      wish: wish), "no other artist")
        verify(AudioSourceFinder.licensedURL("https://creativecommons.org/licenses/by/4.0/") != nil,
               "Creative Commons license accepted")
        verify(AudioSourceFinder.licensedURL("https://creativecommons.org/publicdomain/zero/1.0/") != nil,
               "CC0 accepted")
        verify(AudioSourceFinder.licensedURL("https://creativecommons.org.evil.example/licenses/by/4.0/") == nil,
               "spoofed license host rejected")
        verify(AudioSourceFinder.licensedURL("https://example.com/free-download.mp3") == nil,
               "unlicensed file link rejected")
        print("Audio source discovery validation tests passed")
    }
}
