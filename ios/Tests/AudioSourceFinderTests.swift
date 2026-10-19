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
        verify(AudioSourceFinder.archiveFileCandidate(
            name: "The Song.mp3", source: "original", lengthBytes: "5421879",
            itemTitle: "The Album", itemCreator: "The Artist",
            audioFileCount: 8, wish: wish),
            "exact individual MP3 is eligible inside a licensed album")
        verify(!AudioSourceFinder.archiveFileCandidate(
            name: "The Song (Live).mp3", source: "original", lengthBytes: "5421879",
            itemTitle: "The Album", itemCreator: "The Artist",
            audioFileCount: 8, wish: wish),
            "do not substitute album live takes")
        verify(!AudioSourceFinder.archiveFileCandidate(
            name: "The Song.mp3", source: "derivative", lengthBytes: "5421879",
            itemTitle: "The Album", itemCreator: "The Artist",
            audioFileCount: 8, wish: wish),
            "generated derivatives never qualify in multiple-audio archives")
        verify(AudioSourceFinder.archiveFileCandidate(
            name: "unrelated-file.mp3", source: "original", lengthBytes: "5421879",
            itemTitle: "The Song", itemCreator: "The Artist",
            audioFileCount: 1, wish: wish),
            "single-song item uses its exact title and creator metadata")
        verify(!AudioSourceFinder.archiveFileCandidate(
            name: "The Song.mp3", source: "original", lengthBytes: "105000000",
            itemTitle: "The Song", itemCreator: "The Artist",
            audioFileCount: 1, wish: wish),
            "archive length interpreted as bytes and oversized media rejected")
        verify(!AudioSourceFinder.archiveFileCandidate(
            name: "The Song.mp3", source: "original", lengthBytes: "5400000",
            itemTitle: "The Album", itemCreator: "Wrong Artist",
            audioFileCount: 4, wish: wish),
            "album file with wrong credited artist never qualifies")
        verify(AudioSourceFinder.openverseCandidate(
            title: "The Song", creator: "The Artist",
            download: "https://upload.wikimedia.org/file.mp3",
            landing: "https://commons.wikimedia.org/wiki/File:test",
            license: "https://creativecommons.org/licenses/by/4.0/",
            filetype: "mp3", duration: 212000,
            source: "wikimedia", filesize: nil, wish: wish) != nil,
            "Openverse milliseconds decoded correctly for valid recording")
        verify(AudioSourceFinder.openverseCandidate(
            title: "The Song", creator: "The Artist",
            download: "https://upload.wikimedia.org/file.mp3",
            landing: "https://commons.wikimedia.org/wiki/File:test",
            license: "https://creativecommons.org/licenses/by/4.0/",
            filetype: "mp3", duration: 212,
            source: "wikimedia", filesize: nil, wish: wish) == nil,
            "do not mistake Openverse milliseconds for seconds")
        let commons = AudioSourceFinder.commonsCandidate(
            fileTitle: "File:The Song.mp3", artistCredit: "The Artist",
            download: "https://upload.wikimedia.org/wikipedia/commons/1/12/The_Song.mp3",
            landing: "https://commons.wikimedia.org/wiki/File:The_Song.mp3",
            license: "https://creativecommons.org/licenses/by/4.0/",
            bytes: 4_000_000, wish: wish)
        verify(commons?.sourceName == "Wikimedia Commons",
               "direct Commons file with exact credit and license accepted")
        verify(AudioSourceFinder.commonsCandidate(
            fileTitle: "File:The Song.mp3", artistCredit: "Different Performer",
            download: "https://upload.wikimedia.org/wikipedia/commons/1/12/The_Song.mp3",
            landing: "https://commons.wikimedia.org/wiki/File:The_Song.mp3",
            license: "https://creativecommons.org/licenses/by/4.0/",
            bytes: nil, wish: wish) == nil,
            "Wikimedia version with different artist rejected")
        verify(AudioSourceFinder.commonsCandidate(
            fileTitle: "File:The Song.mp3", artistCredit: "The Artist",
            download: "https://malicious.invalid/wikipedia/commons/1/12/The_Song.mp3",
            landing: "https://commons.wikimedia.org/wiki/File:The_Song.mp3",
            license: "https://creativecommons.org/licenses/by/4.0/",
            bytes: nil, wish: wish) == nil,
            "Commons download cannot redirect to untrusted upload hosts")
        verify(AudioSourceFinder.commonsCandidate(
            fileTitle: "File:The Song.mp3", artistCredit: "<a>Unverified Artist</a>",
            download: "https://upload.wikimedia.org/file.mp3",
            landing: "https://commons.wikimedia.org/wiki/File:The_Song.mp3",
            license: "https://creativecommons.org/licenses/by/4.0/",
            bytes: nil, wish: wish) == nil,
            "HTML author credits are not mistaken for verified artists")
        // Web-wide search lists possible source pages; unlike catalog matches
        // these are never automatically treated as licensed MP3 recordings.
        let webQuery = WebAudioSearch.searchQuery(for: wish)
        verify(webQuery.contains("The Song") && webQuery.contains("The Artist"),
               "web query includes the requested title and artist")
        let browser = WebAudioSearch.browserURL(for: wish)
        verify(browser.scheme == "https" && browser.host == "search.brave.com",
               "web search browser fallback is HTTPS")
        verify(WebAudioSearch.sanitizedResultURL(
            "https://artist.bandcamp.com/track/the-song") != nil,
            "artist-hosted download pages are discoverable")
        verify(WebAudioSearch.sanitizedResultURL(
            "https://official.example/music/the-song.mp3") != nil,
            "direct HTTPS MP3 candidate can be surfaced for user review")
        verify(WebAudioSearchResult(title: "File", description: "",
            url: URL(string: "https://official.example/music/the-song.mp3")!).isDirectAudio,
            "direct audio links distinguished from landing pages")
        verify(WebAudioSearch.sanitizedResultURL("http://official.example/song.mp3") == nil,
               "insecure web results rejected")
        verify(WebAudioSearch.sanitizedResultURL(
            "https://user:pass@official.example/song.mp3") == nil,
            "credential-bearing web results rejected")
        verify(WebAudioSearch.sanitizedResultURL("https://localhost/song.mp3") == nil,
               "local-host web results rejected")
        verify(WebAudioSearch.sanitizedResultURL(
            "https://open.spotify.com/track/0123456789") == nil,
            "Spotify links are not presented as downloadable audio")
        let quickQueries = WebAudioSearch.searchQueries(for: wish, depth: .quick)
        let thoroughQueries = WebAudioSearch.searchQueries(for: wish, depth: .thorough)
        let extensiveQueries = WebAudioSearch.searchQueries(for: wish, depth: .extensive)
        verify(quickQueries.count == 1 && thoroughQueries.count == 3 &&
               extensiveQueries.count == 5, "selectable API request budget per song")
        verify(Set(extensiveQueries).count == 5, "search strategies use distinct queries")
        verify(extensiveQueries.contains(where: { $0.contains("filetype:mp3") }),
               "file-oriented search included in extensive mode")
        verify(extensiveQueries.contains(where: { $0.contains("bandcamp.com") }),
               "store and artist-site discovery included")
        verify(WebAudioSearch.BrowserProvider.allCases.count == 10,
               "ten browser search destinations available without an API key")
        for provider in WebAudioSearch.BrowserProvider.allCases {
            let link = WebAudioSearch.browserURL(for: wish, provider: provider)
            verify(link.scheme == "https" && link.host != nil &&
                   !link.absoluteString.contains(" "), "safe encoded search URL for \(provider.rawValue)")
        }
        verify(WebAudioSearch.browserURL(for: wish, provider: .bandcamp).host == "bandcamp.com",
               "artist store search link targets Bandcamp")
        verify(WebAudioSearch.browserURL(for: wish, provider: .archive).host == "archive.org",
               "archive search link targets Internet Archive")
        verify(WebAudioSearch.sanitizedResultURL("https://192.168.1.1/music/song.mp3") == nil,
               "search results pointing to private networks are discarded")
        verify(WebAudioSearch.sanitizedResultURL("https://router.internal/song.mp3") == nil,
               "internal network hostname excluded")
        print("Audio source discovery validation tests passed")
    }
}
