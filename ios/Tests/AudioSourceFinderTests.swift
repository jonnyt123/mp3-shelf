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
        let sourcePage = URL(string: "https://artist.example/releases/album")!
        let pageHTML = #"""
            <html><head>
              <meta property="og:audio:secure_url" content="/media/lead-track.mp3">
              <meta property="og:audio" content="https://artist.example/media/lead-track.mp3">
            </head>
            <body>
              <audio controls><source type="audio/mpeg" src="../audio/second-track.mp3"></audio>
              <a href="https://files.example/authorized%20track.mp3?download=1&amp;v=2" download>Download</a>
              <a href="http://unsecured.example/song.mp3">HTTP is rejected</a>
              <a href="https://localhost/internal.mp3">Local network is rejected</a>
              <a href="https://artist.example/stream.m3u8">Streaming manifests are rejected</a>
              <script type="application/ld+json">
                {"@context":"https://schema.org","@type":"AudioObject",
                 "contentUrl":"https://cdn.example.org/files/third-track.m4a"}
              </script>
              <script type="application/ld+json">
                {"@type":"VideoObject","contentUrl":"https://cdn.example.org/video.mp3"}
              </script>
            </body></html>
            """#
        let pageLinks = AudioLandingPageInspector.candidates(in: pageHTML, pageURL: sourcePage)
        verify(pageLinks.count == 4,
               "inspects audio/meta/anchor/JSON-LD links without unsafe duplicates")
        verify(pageLinks.contains { $0.absoluteString == "https://artist.example/media/lead-track.mp3" },
               "relative Open Graph audio metadata is resolved")
        verify(pageLinks.contains { $0.absoluteString == "https://artist.example/audio/second-track.mp3" },
               "relative HTML5 audio source is resolved")
        verify(pageLinks.contains { $0.absoluteString ==
               "https://files.example/authorized%20track.mp3?download=1&v=2" },
               "escaped ampersands retain direct file URL parameters")
        verify(pageLinks.contains { $0.absoluteString == "https://cdn.example.org/files/third-track.m4a" },
               "structured AudioObject metadata exposes direct M4A audio")
        verify(!pageLinks.contains { $0.absoluteString.hasSuffix("video.mp3") },
               "unrelated JSON-LD video files are not treated as audio")
        verify(AudioLandingPageInspector.candidateURL("javascript:alert(1)", relativeTo: sourcePage) == nil,
               "script URLs are never audio candidates")
        verify(AudioLandingPageInspector.candidateURL("https://localhost/song.mp3",
                relativeTo: sourcePage) == nil, "local-network audio URLs rejected")
        verify(AudioLandingPageInspector.candidateURL("https://127.0.0.2/song.mp3",
                relativeTo: sourcePage) == nil, "all literal loopback IPs rejected")
        verify(AudioLandingPageInspector.candidateURL("https://192.168.50.2/song.mp3",
                relativeTo: sourcePage) == nil, "private IP audio links rejected")
        verify(AudioLandingPageInspector.candidateURL("https://artist.example:8443/song.mp3",
                relativeTo: sourcePage) == nil, "nonstandard source ports rejected")
        verify(AudioLandingPageInspector.candidateURL("track.m3u8",
                relativeTo: sourcePage) == nil, "streaming playlists are not direct audio")
        verify(AudioLandingPageInspector.candidates(in: String(repeating: "a", count: 1_000_001),
                pageURL: sourcePage).isEmpty, "oversized HTML is never parsed")
        let aligned = WebAudioSearchResult(
            title: "The Artist — The Song MP3", description: "Official music download",
            url: URL(string: "https://publisher.example/the-song.mp3")!)
        let unrelated = WebAudioSearchResult(
            title: "Random artist audio", description: "A different song",
            url: URL(string: "https://publisher.example/random-page")!)
        let textOnly = WebAudioSearchResult(
            title: "The Artist - The Song", description: "Music store listing",
            url: URL(string: "https://publisher.example/album/song")!)
        verify(WebAudioSearch.resultScore(aligned, for: wish) >
               WebAudioSearch.resultScore(textOnly, for: wish),
               "matching downloadable audio files rank above matching pages")
        verify(WebAudioSearch.resultScore(textOnly, for: wish) >
               WebAudioSearch.resultScore(unrelated, for: wish),
               "artist/title evidence ranks ahead of unrelated web pages")
        verify(WebAudioSearch.resultScore(unrelated, for: wish) == 0,
               "unrelated links are not described as confirmed song matches")
        let downloadButtonHTML = #"""
            <a href="/download?track=123" download>Artist download</a>
            <a href="/download?track=321">Ordinary page link</a>
            <source src="/audio?file=554" type="audio/mpeg">
            <a href="/index.html" download>Not an audio file</a>
            <a href="/stream.m3u8" download>Never use streaming manifests</a>
            <a href="/actual-song.mp3">Normal MP3 file</a>
            """#
        let buttons = AudioLandingPageInspector.candidates(
            in: downloadButtonHTML, pageURL: sourcePage)
        verify(buttons.contains { $0.absoluteString == "https://artist.example/download?track=123" },
               "explicit download attribute discovers extensionless endpoint")
        verify(buttons.contains { $0.absoluteString == "https://artist.example/audio?file=554" },
               "audio MIME source tag discovers extensionless endpoint")
        verify(!buttons.contains { $0.absoluteString == "https://artist.example/download?track=321" },
               "an ordinary webpage link is not treated as audio")
        verify(!buttons.contains { $0.pathExtension == "html" },
               "HTML pages cannot masquerade as download buttons")
        verify(!buttons.contains { $0.pathExtension == "m3u8" },
               "streaming manifests cannot masquerade as audio downloads")
        verify(buttons.contains { $0.lastPathComponent == "actual-song.mp3" },
               "traditional direct MP3 links still supported")
        verify(AudioLandingPageInspector.candidateURL(
            "/download?id=1", relativeTo: sourcePage) == nil,
            "extensionless URL requires explicit page audio evidence")
        verify(AudioLandingPageInspector.candidateURL(
            "/download?id=1", relativeTo: sourcePage, explicitlyDownloadable: true) != nil,
            "explicit download button permits later HTTP HEAD validation")
        let validHead = HTTPURLResponse(url: sourcePage, statusCode: 200,
            httpVersion: nil, headerFields: [
                "Content-Type": "audio/mpeg",
                "Content-Length": "1000000"
            ])!
        let htmlHead = HTTPURLResponse(url: sourcePage, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        let redirectHead = HTTPURLResponse(url: sourcePage, statusCode: 302,
            httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!
        let giantHead = HTTPURLResponse(url: sourcePage, statusCode: 200,
            httpVersion: nil, headerFields: [
                "Content-Type": "audio/mpeg",
                "Content-Length": "200000000"
            ])!
        verify(AudioLandingPageInspector.isVerifiedAudioResponse(validHead),
               "audio HEAD response passes MIME and size checks")
        verify(!AudioLandingPageInspector.isVerifiedAudioResponse(htmlHead),
               "HTML returned by an extensionless link is rejected")
        verify(!AudioLandingPageInspector.isVerifiedAudioResponse(redirectHead),
               "redirect response cannot be accepted as downloadable audio")
        verify(!AudioLandingPageInspector.isVerifiedAudioResponse(giantHead),
               "oversized audio content length is rejected")
        let publisherHTML = #"""
            <meta property="og:audio" content="/media?id=531">
            <audio src="/download/audio?file=23"></audio>
            <script type="application/ld+json">
            {"@type":"AudioObject","contentUrl":"/api/audio/recording?id=11"}
            </script>
            """#
        let declaredDownloads = AudioLandingPageInspector.candidates(
            in: publisherHTML, pageURL: sourcePage)
        verify(declaredDownloads.count == 3,
                    "Open Graph, HTML audio and AudioObject all support extensionless audio URLs")
        verify(declaredDownloads.contains {
            $0.absoluteString == "https://artist.example/media?id=531"
        }, "extensionless og:audio link is offered for HEAD verification")
        verify(declaredDownloads.contains {
            $0.absoluteString == "https://artist.example/download/audio?file=23"
        }, "extensionless <audio> source is offered for HEAD verification")
        verify(declaredDownloads.contains {
            $0.absoluteString == "https://artist.example/api/audio/recording?id=11"
        }, "extensionless Schema.org AudioObject contentUrl is offered for HEAD verification")
        let pageWithManyLinks = (0..<30).map {
            "<a href=\"/misc/loose-\($0).mp3\">Unrelated file</a>"
        }.joined() + #"<meta property="og:audio" content="/verified-track.mp3">"#
        let prioritizedLinks = AudioLandingPageInspector.candidates(
            in: pageWithManyLinks, pageURL: sourcePage)
        verify(prioritizedLinks.count == 25,
                    "source inspection remains bounded to 25 candidates")
        verify(prioritizedLinks.first?.lastPathComponent == "verified-track.mp3",
                    "explicit publisher audio beats first 25 generic anchors")
        let weakPage = WebAudioSearchResult(
            title: "The Song", description: "Unknown artist, unrelated store",
            url: URL(string: "https://elsewhere.example/the-song")!)
        let irrelevantPage = WebAudioSearchResult(
            title: "Shopping website", description: "Buy a hat",
            url: URL(string: "https://store.example/hats")!)
        let chosenPages = WebAudioSearch.pagesWorthInspecting(
            [irrelevantPage, weakPage, aligned, textOnly],
            for: wish, limit: 2)
        verify(chosenPages.map(\.url) == [textOnly.url, weakPage.url],
               "batch inspection prioritizes strong artist/title matches, excludes audio URLs")
        verify(WebAudioSearch.pagesWorthInspecting(
            [irrelevantPage], for: wish, limit: 3).isEmpty,
               "unrelated search pages are not visited automatically")
        verify(WebAudioSearch.pagesWorthInspecting(
            [textOnly], for: wish, limit: 0).isEmpty,
               "zero page-inspection budget makes no network candidates")

        let audiusArtist = AudioSourceFinder.AudiusTrack.User(
            name: "The Artist", handle: "the-artist")
        let audiusOK = AudioSourceFinder.AudiusTrack(
            id: "D7KyD", title: "The Song", user: audiusArtist,
            duration: 212, is_downloadable: true, is_download_gated: false,
            is_stream_gated: false, is_unlisted: false,
            download_conditions: nil, permalink: "https://audius.co/the-artist/the-song",
            license: nil)
        let audiusMatch = AudioSourceFinder.audiusCandidate(audiusOK, for: wish)
        verify(audiusMatch?.downloadURL.host == "api.audius.co",
               "Audius artist-enabled direct-download endpoint is recognized")
        verify(audiusMatch?.sourceName.contains("Audius") == true,
               "Audius attribution is retained")
        verify(audiusMatch?.downloadURL.absoluteString.contains("/download?original=false") == true,
               "Audius requires real download endpoint, not streaming playback")
        verify(AudioSourceFinder.audiusSearchURL(for: wish).absoluteString.contains(
            "only_downloadable=true"), "Audius search filters to downloadable tracks")
        let audiusNonDownload = AudioSourceFinder.AudiusTrack(
            id: "D7KyD", title: "The Song", user: audiusArtist,
            duration: 212, is_downloadable: false, is_download_gated: false,
            is_stream_gated: false, is_unlisted: false,
            download_conditions: nil, permalink: "https://audius.co/the-artist/the-song",
            license: nil)
        verify(AudioSourceFinder.audiusCandidate(audiusNonDownload, for: wish) == nil,
               "Audius stream-only recordings cannot auto-download")
        let audiusGated = AudioSourceFinder.AudiusTrack(
            id: "D7KyD", title: "The Song", user: audiusArtist,
            duration: 212, is_downloadable: true, is_download_gated: true,
            is_stream_gated: false, is_unlisted: false,
            download_conditions: nil, permalink: "https://audius.co/the-artist/the-song",
            license: nil)
        verify(AudioSourceFinder.audiusCandidate(audiusGated, for: wish) == nil,
               "Audius paid or gated downloads are rejected")
        let audiusWrongArtist = AudioSourceFinder.AudiusTrack(
            id: "D7KyD", title: "The Song",
            user: .init(name: "Another Artist", handle: "someone"),
            duration: 212, is_downloadable: true, is_download_gated: false,
            is_stream_gated: false, is_unlisted: false,
            download_conditions: nil, permalink: "https://audius.co/someone/the-song",
            license: nil)
        verify(AudioSourceFinder.audiusCandidate(audiusWrongArtist, for: wish) == nil,
               "a title match cannot replace the original Spotify artist")
        let audiusWrongDuration = AudioSourceFinder.AudiusTrack(
            id: "D7KyD", title: "The Song", user: audiusArtist,
            duration: 30, is_downloadable: true, is_download_gated: false,
            is_stream_gated: false, is_unlisted: false,
            download_conditions: nil, permalink: "https://audius.co/the-artist/the-song",
            license: nil)
        verify(AudioSourceFinder.audiusCandidate(audiusWrongDuration, for: wish) == nil,
               "preview-length recordings are rejected against Spotify duration")
        let audiusSpoof = AudioSourceFinder.AudiusTrack(
            id: "D7KyD", title: "The Song", user: audiusArtist,
            duration: 212, is_downloadable: true, is_download_gated: false,
            is_stream_gated: false, is_unlisted: false, download_conditions: nil,
            permalink: "https://audius.co.evil.example/the-song", license: nil)
        verify(AudioSourceFinder.audiusCandidate(audiusSpoof, for: wish) == nil,
               "Audius result landing URL must be the genuine Audius domain")
        print("Audio source discovery validation tests passed")
    }
}
