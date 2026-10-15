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
        let openverse = AudioSourceFinder.openverseCandidate(
            title: "The Song", creator: "The Artist",
            download: "https://upload.wikimedia.org/wikipedia/commons/1/12/the-song.mp3",
            landing: "https://commons.wikimedia.org/wiki/File:The_Song.mp3",
            license: "https://creativecommons.org/licenses/by/4.0/",
            filetype: "mp3", duration: 212000,
            source: "wikimedia", filesize: 5_000_000, wish: wish)
        verify(openverse != nil, "Openverse Wikimedia MP3 exact match accepted")
        verify(AudioSourceFinder.openverseCandidate(
            title: "The Song", creator: "The Artist",
            download: "https://mp3d.jamendo.com/song.mp3",
            landing: "https://jamendo.com/song",
            license: "https://creativecommons.org/licenses/by/4.0/",
            filetype: "mp3", duration: 212000,
            source: "jamendo", filesize: nil, wish: wish) == nil,
            "restrictive offline license provider excluded")
        verify(AudioSourceFinder.openverseCandidate(
            title: "The Song", creator: "The Artist",
            download: "https://upload.wikimedia.org/file.mp3",
            landing: "https://commons.wikimedia.org/wiki/File:test",
            license: "https://creativecommons.org/licenses/by/4.0/",
            filetype: "mp3", duration: 245000,
            source: "wikimedia", filesize: nil, wish: wish) == nil,
            "alternate duration rejected")
        verify(AudioSourceFinder.openverseCandidate(
            title: "The Song", creator: "The Artist",
            download: "https://upload.wikimedia.org/file.mp3",
            landing: "https://commons.wikimedia.org/wiki/File:test",
            license: nil, filetype: "mp3", duration: 212000,
            source: "wikimedia", filesize: nil, wish: wish) == nil,
            "missing license rejected")
        print("Audio source discovery validation tests passed")
    }
}
