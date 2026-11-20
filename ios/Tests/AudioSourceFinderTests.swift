import Foundation

func verify(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fatalError("FAIL: \(description)") }
    print("PASS: \(description)")
}

@main
enum AudioSourceFinderTests {
    static func main() throws {
        // Catalog arrays sometimes contain duplicate or contradictory
        // recording identities. Empty leading values may be skipped, but
        // disagreeing titles/artists must never authorize auto-selection.
        func decodeCatalogText(_ json: String) throws -> String {
            try JSONDecoder().decode(AudioSourceFinder.FlexibleText.self,
                                     from: Data(json.utf8)).value
        }
        verify(try decodeCatalogText(#"["", "Exact Song", " Exact Song "]"#) == "Exact Song",
               "blank first catalog title retains an unambiguous identity")
        verify(try decodeCatalogText(#"["Exact Song", "Different Song"]"#).isEmpty,
               "conflicting catalog titles cannot select the first match")
        verify(try decodeCatalogText(#"["Artist", "Other Artist"]"#).isEmpty,
               "conflicting catalog artist credits cannot auto-match")
        verify(try decodeCatalogText(#"["Exact Song", "exact song"]"#) == "Exact Song",
               "case-only duplicate catalog identities remain usable")
        verify(try decodeCatalogText(#"["", "  "]"#).isEmpty,
               "blank-only catalog metadata stays unavailable")

        // RSS and JSON catalogs share one bounded response validator. A
        // redirect is rejected by their common URLSession delegate before
        // either response can be parsed; status and size fail closed here.
        let catalogURL = URL(string: "https://ccmixter.org/api/query")!
        let ok = HTTPURLResponse(url: catalogURL, statusCode: 200,
                                 httpVersion: nil, headerFields: nil)!
        let redirect = HTTPURLResponse(url: catalogURL, statusCode: 302,
                                       httpVersion: nil, headerFields: nil)!
        let throttled = HTTPURLResponse(url: catalogURL, statusCode: 429,
                                        httpVersion: nil, headerFields: nil)!
        let rss = Data("<rss/>".utf8)
        verify((try? AudioSourceFinder.validatedCatalogBody(
            rss, response: ok, maximumBytes: rss.count)) == rss,
            "RSS response at exact size limit is accepted")
        verify((try? AudioSourceFinder.validatedCatalogBody(
            rss, response: redirect, maximumBytes: 100)) == nil,
            "redirect responses cannot be mistaken for catalog data")
        verify((try? AudioSourceFinder.validatedCatalogBody(
            rss, response: throttled, maximumBytes: 100)) == nil,
            "rate-limited RSS is not parsed as successful data")
        verify((try? AudioSourceFinder.validatedCatalogBody(
            Data(), response: ok, maximumBytes: 100)) == nil,
            "empty RSS catalog response is rejected")
        verify((try? AudioSourceFinder.validatedCatalogBody(
            rss, response: ok, maximumBytes: rss.count - 1)) == nil,
            "oversized RSS catalog response is rejected")
        let commonsComplete = Data(#"{"query":{"pages":{}}}"#.utf8)
        let commonsContinued = Data(#"{"continue":{"gsroffset":20,"continue":"-||"},"query":{"pages":{}}}"#.utf8)
        let commonsMalformed = Data(#"{"continue":{"gsroffset":20}}"#.utf8)
        verify(AudioSourceFinder.commonsSearchComplete(commonsComplete),
               "complete Commons page can be evaluated for recording uniqueness")
        verify(!AudioSourceFinder.commonsSearchComplete(commonsContinued),
               "Commons continuation prevents first-page automatic selection")
        verify(!AudioSourceFinder.commonsSearchComplete(commonsMalformed),
               "malformed Commons page cannot authorize a recording")
        let wish = PlaylistWish(title: "The Song", artist: "The Artist",
                                album: "The Album", spotifyURL: nil, durationSeconds: 212)
        // Single-file Archive items often hide a different recording edition
        // in the physical filename despite exact item-level title/artist.
        for alternate in ["The Song (Karaoke).mp3", "The Song - Live.mp3",
                          "The Song (Slowed).mp3", "The Song - Radio Edit.mp3",
                          "The Song (Acoustic).mp3", "The Song (Remix).mp3"] {
            verify(!AudioSourceFinder.archiveFileCandidate(
                name: alternate, source: "original", sizeBytes: "6000000",
                itemTitle: "The Song", itemCreator: "The Artist",
                audioFileCount: 1, wish: wish),
                "single-file alternate edition cannot auto-match: \(alternate)")
        }
        verify(AudioSourceFinder.archiveFileCandidate(
            name: "The Song.mp3", source: "original", sizeBytes: "6000000",
            itemTitle: "The Song", itemCreator: "The Artist",
            audioFileCount: 1, wish: wish),
            "single-file original edition remains eligible")
        // Additional independent-file edition labels are not interchangeable
        // with the studio recording even if title/artist/duration agree.
        for edition in ["A Cappella", "Acapella", "Rehearsal", "Bootleg",
                        "Bass Boosted", "Club Mix", "Dub Version", "Vocal Mix"] {
            verify(!AudioSourceFinder.recordingEditionAgrees(
                filename: "The Song - \(edition).mp3", requestedTitle: "The Song"),
                "alternate recording cannot be silently selected: \(edition)")
            verify(AudioSourceFinder.recordingEditionAgrees(
                filename: "The Song - \(edition).mp3",
                requestedTitle: "The Song (\(edition))"),
                "same explicitly requested edition remains eligible: \(edition)")
        }
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "The Song - A Capella.mp3",
            requestedTitle: "The Song (A Cappella)"),
            "a cappella spelling variants describe the same edition")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "The Song - Bassboosted.mp3",
            requestedTitle: "The Song (Bass Boosted)"),
            "bass boosted spelling variants describe the same edition")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "The Club.mp3", requestedTitle: "The Club"),
            "ordinary title containing club is not an alternate mix")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Deliver.mp3", requestedTitle: "Deliver"),
            "embedded live letters are not a live-edition marker")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "The Song - Live.mp3", requestedTitle: "The Song (Live)"),
            "explicit matching live edition remains eligible")
        // Archive may contain one broken file entry among usable recordings.
        // Preserve the valid original instead of discarding the whole item.
        // One invalid search row must not abort a whole playlist lookup.
        // Keep the raw count so an incomplete full page cannot look final.
        let mixedSearch = #"""
        {"response":{"numFound":20,"docs":[
          {"identifier":"valid-one","title":"The Song","creator":"The Artist"},
          null, {"identifier":42,"title":"Broken"},
          {"identifier":"valid-two","title":["The Song"],"creator":["The Artist"]}
        ]}}
        """#.data(using: .utf8)!
        let decodedSearch = try JSONDecoder().decode(
            AudioSourceFinder.SearchResponse.self, from: mixedSearch)
        verify(decodedSearch.response.docs.map(\.identifier) == ["valid-one", "valid-two"] &&
               decodedSearch.response.rawItemCount == 4 &&
               decodedSearch.response.numFound == 20,
               "malformed Archive index rows preserve valid siblings and raw pagination count")
        verify(!AudioSourceFinder.archiveSearchRowsComplete(decodedSearch.response),
               "malformed Archive index row blocks unattended unique-match selection")
        // Regex anchors may accept a trailing newline. Only literal ASCII
        // path segments are safe to construct as Archive download URLs.
        for unsafe in ["valid\n", "valid\r", "valid\u{0000}",
                       "valid/other", "valid..other", "valid%2Fother",
                       String(repeating: "a", count: 129)] {
            let encoded = try JSONEncoder().encode(unsafe)
            let identifier = String(data: encoded, encoding: .utf8)!
            let index = #"{"response":{"numFound":1,"docs":[{"identifier":__ID__,"title":"The Song","creator":"The Artist"}]}}"#
                .replacingOccurrences(of: "__ID__", with: identifier)
            let decoded = try JSONDecoder().decode(AudioSourceFinder.SearchResponse.self,
                                                   from: Data(index.utf8))
            verify(!AudioSourceFinder.archiveSearchRowsComplete(decoded.response),
                   "unsafe Archive identifier cannot authorize download: \(unsafe.debugDescription)")
        }
        let safeIndex = #"{"response":{"numFound":1,"docs":[{"identifier":"safe_01-archive.mp3","title":"The Song","creator":"The Artist"}]}}"#
        let safeRows = try JSONDecoder().decode(AudioSourceFinder.SearchResponse.self,
                                               from: Data(safeIndex.utf8))
        verify(AudioSourceFinder.archiveSearchRowsComplete(safeRows.response),
               "valid ASCII Archive identifier remains eligible")
        let duplicateIndex = #"""
        {"response":{"numFound":3,"docs":[
          {"identifier":"same-recording","title":"The Song","creator":"The Artist"},
          {"identifier":"same-recording","title":"The Song (Live)","creator":"The Artist"},
          {"identifier":"other-recording","title":"The Song","creator":"The Artist"}]}}
        """#.data(using: .utf8)!
        let conflictingIndex = try JSONDecoder().decode(
            AudioSourceFinder.SearchResponse.self, from: duplicateIndex)
        verify(!AudioSourceFinder.archiveSearchRowsComplete(conflictingIndex.response),
               "contradictory duplicate Archive identifiers cannot prove a unique recording")
        let consistentIndex = duplicateIndex.replacingOccurrences(
            of: "The Song (Live)", with: "The Song")
        let consistentRows = try JSONDecoder().decode(
            AudioSourceFinder.SearchResponse.self, from: consistentIndex)
        verify(AudioSourceFinder.archiveSearchRowsComplete(consistentRows.response),
               "identical duplicate Archive identifiers remain eligible for bounded inspection")
        let differentArtist = duplicateIndex.replacingOccurrences(
            of: "The Song (Live)", with: "The Song").replacingOccurrences(
            of: #""title":"The Song","creator":"The Artist"},
          {"identifier":"other-recording""#,
            with: #""title":"The Song","creator":"Other Artist"},
          {"identifier":"other-recording""#)
        let conflictingCreator = try JSONDecoder().decode(
            AudioSourceFinder.SearchResponse.self, from: differentArtist)
        verify(!AudioSourceFinder.archiveSearchRowsComplete(conflictingCreator.response),
               "duplicate Archive identifiers with conflicting creators fail closed")
        let cleanSearch = #"""
        {"response":{"numFound":1,"docs":[
          {"identifier":"valid-one","title":"The Song","creator":"The Artist"}]}}
        """#.data(using: .utf8)!
        let decodedClean = try JSONDecoder().decode(
            AudioSourceFinder.SearchResponse.self, from: cleanSearch)
        verify(AudioSourceFinder.archiveSearchRowsComplete(decodedClean.response),
               "fully decoded Archive index preserves automatic selection eligibility")
        let contradictorySearch = #"""
        {"response":{"numFound":0,"docs":[
          {"identifier":"valid-one","title":"The Song","creator":"The Artist"}]}}
        """#.data(using: .utf8)!
        let decodedContradictory = try JSONDecoder().decode(
            AudioSourceFinder.SearchResponse.self, from: contradictorySearch)
        verify(!AudioSourceFinder.archiveSearchRowsComplete(decodedContradictory.response),
               "contradictory Archive total cannot authorize an automatic match")
        let missingTotal = #"""
        {"response":{"docs":[
          {"identifier":"valid-one","title":"The Song","creator":"The Artist"}]}}
        """#.data(using: .utf8)!
        let decodedMissingTotal = try JSONDecoder().decode(
            AudioSourceFinder.SearchResponse.self, from: missingTotal)
        verify(!AudioSourceFinder.archiveSearchRowsComplete(decodedMissingTotal.response),
               "Archive index without total cannot prove a unique recording")
        verify(AudioSourceFinder.archiveSearchRowsComplete(decodedClean.response),
               "known complete Archive total still permits exact matching")
        let negativeTotal = #"""
        {"response":{"numFound":-1,"docs":[]}}
        """#.data(using: .utf8)!
        let decodedNegative = try JSONDecoder().decode(
            AudioSourceFinder.SearchResponse.self, from: negativeTotal)
        verify(!AudioSourceFinder.archiveSearchRowsComplete(decodedNegative.response),
               "negative Archive total cannot represent a completed search")
        let emptySearch = #"""
        {"response":{"numFound":0,"docs":[]}}
        """#.data(using: .utf8)!
        let decodedEmpty = try JSONDecoder().decode(
            AudioSourceFinder.SearchResponse.self, from: emptySearch)
        verify(AudioSourceFinder.archiveSearchRowsComplete(decodedEmpty.response),
               "genuinely empty Archive search remains a completed no-match")

        let fullPage = #"""
        {"response":{"docs":[{"identifier":"valid-one"},
          null,null,null,null,null,null,null,null,null,
          null,null,null,null,null,null,null,null,null,null]}}
        """#.data(using: .utf8)!
        let decodedFullPage = try JSONDecoder().decode(
            AudioSourceFinder.SearchResponse.self, from: fullPage)
        verify(!AudioSourceFinder.archiveSearchRowsComplete(decodedFullPage.response),
               "lossy full Archive page cannot authorize a unique match")
        verify(decodedFullPage.response.docs.count == 1 &&
               decodedFullPage.response.rawItemCount == 20 &&
               decodedFullPage.response.numFound == nil,
               "a malformed full Archive page still requires continuation")
        let mixedArchive = #"""
        {"metadata":{"title":"The Song","creator":"The Artist"},"files":[
          {"name":17,"source":"original","length":"212"},
          {"name":"The Song.mp3","source":"original","size":"3500000","length":"3:32"},
          null,
          {"source":"original","length":"212"}
        ]}
        """#.data(using: .utf8)!
        let decodedMixed = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                                                    from: mixedArchive)
        verify(decodedMixed.files?.count == 1 &&
               decodedMixed.files?.first?.name == "The Song.mp3",
               "malformed Archive file entries do not discard valid siblings")
        verify(AudioSourceFinder.archiveCandidate(decodedMixed, identifier: "mixed_archive",
                                                 for: wish) != nil,
               "valid exact-duration original remains discoverable beside corrupt entries")
        let onlyBroken = #"""
        {"metadata":{"title":"The Song","creator":"The Artist"},"files":[
          {"name":17,"source":"original"},null,{"source":"original"}
        ]}
        """#.data(using: .utf8)!
        let decodedBroken = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                                                     from: onlyBroken)
        verify(decodedBroken.files?.isEmpty == true &&
               AudioSourceFinder.archiveCandidate(decodedBroken, identifier: "broken_archive",
                                                  for: wish) == nil,
               "corrupt-only Archive items never become automatic downloads")
        let fallbackRequest = WebAudioSearch.searchRequest(
            query: "The Artist The Song", apiKey: "test-token", allowsCellular: false)
        verify(!fallbackRequest.allowsCellularAccess &&
               !fallbackRequest.allowsExpensiveNetworkAccess &&
               !fallbackRequest.allowsConstrainedNetworkAccess,
               "automatic web requests cannot switch from Wi-Fi to cellular")
        verify(fallbackRequest.url?.host == "api.search.brave.com" &&
               fallbackRequest.value(forHTTPHeaderField: "X-Subscription-Token") == "test-token" &&
               !(fallbackRequest.url?.absoluteString.contains("test-token") ?? true),
               "Brave credential is sent as a header only to the search endpoint")
        let exactWebFile = URL(string: "https://artist.example/The_Artist-The_Song.mp3")!
        verify(AutomaticWebAudioFinder.fileMatches(exactWebFile, wish: wish),
               "automatic fallback accepts an exact artist-title audio filename")
        verify(!AutomaticWebAudioFinder.fileMatches(
            URL(string: "https://artist.example/The_Song.mp3")!, wish: wish) &&
               !AutomaticWebAudioFinder.fileMatches(
            URL(string: "https://artist.example/The_Artist-The_Song_Live.mp3")!, wish: wish),
               "title-only links and alternate performances cannot enter automatic fallback")
        let structuredPage = #"<script type="application/ld+json">{"@type":"MusicRecording","name":"The Song","byArtist":{"@type":"MusicGroup","name":"The Artist"},"duration":"PT3M32S","audio":{"@type":"AudioObject","contentUrl":"/download?id=7"}}</script>"#
        let pageURL = URL(string: "https://artist.example/song")!
        let structuredMatches = AutomaticWebAudioFinder.matches(in: structuredPage,
            pageURL: pageURL, wish: wish)
        verify(structuredMatches.first?.downloadURL.absoluteString == "https://artist.example/download?id=7",
               "exact structured recording metadata can identify an extensionless audio download")
        verify(AutomaticWebAudioFinder.matches(in: structuredPage.replacingOccurrences(
            of: "The Artist", with: "Other Artist"), pageURL: pageURL, wish: wish).isEmpty,
               "page audio from another artist is not substituted")
        verify(AutomaticWebAudioFinder.matches(in: structuredPage.replacingOccurrences(
            of: "PT3M32S", with: "PT30S"), pageURL: pageURL, wish: wish).isEmpty,
               "structured preview duration cannot replace a full song")
        verify(AutomaticWebAudioFinder.matches(in: structuredPage.replacingOccurrences(
            of: "/download?id=7", with: "https://localhost/song.mp3"),
            pageURL: pageURL, wish: wish).isEmpty,
               "structured audio links still reject local network targets")
        verify(AutomaticWebAudioFinder.matches(in: structuredPage.replacingOccurrences(
            of: #""@type":"AudioObject","contentUrl""#,
            with: #""@type":"AudioObject","name":"Another Song","contentUrl""#),
            pageURL: pageURL, wish: wish).isEmpty,
               "contradictory child audio metadata cannot borrow the parent song identity")
        let graphPage = ##"<script type="application/ld+json">{"@graph":[{"@type":"MusicRecording","name":"The Song","byArtist":{"@id":"#artist"},"audio":{"@id":"#file"}},{"@id":"#artist","@type":"MusicGroup","name":"The Artist"},{"@id":"#file","@type":"AudioObject","contentUrl":"/song.mp3"}]}</script>"##
        verify(AutomaticWebAudioFinder.matches(in: graphPage, pageURL: pageURL, wish: wish)
            .first?.downloadURL.absoluteString == "https://artist.example/song.mp3",
               "structured artist and audio references resolve within the same page graph")
        let testURL = URL(string: "https://api.audius.co/v1/tracks/search")!
        let wifiCatalogRequest = AudioSourceFinder.catalogRequest(for: testURL)
        verify(wifiCatalogRequest.allowsCellularAccess == false,
               "catalog lookups cannot silently switch to cellular")
        verify(wifiCatalogRequest.allowsExpensiveNetworkAccess == false,
               "Wi-Fi-only source lookup avoids metered hotspots")
        verify(wifiCatalogRequest.allowsConstrainedNetworkAccess == false,
               "automatic lookups respect constrained network connections")
        verify(wifiCatalogRequest.timeoutInterval == 18,
               "Wi-Fi-only catalog lookup keeps bounded request timeout")
        let manuallyApprovedRequest = AudioSourceFinder.catalogRequest(
            for: testURL, allowsCellular: true)
        verify(manuallyApprovedRequest.allowsCellularAccess == true &&
               manuallyApprovedRequest.allowsExpensiveNetworkAccess == true &&
               manuallyApprovedRequest.allowsConstrainedNetworkAccess == true,
               "manual cellular opt-in enables catalog requests for that playlist")
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
               "audio links are not misrepresented as Creative Commons licenses")
        // A single numeric or malformed optional field must not abort a
        // whole Archive metadata response and hide unrelated valid tracks.
        let archiveMixedJSON = """
        {"metadata":{"title":"The Song","creator":"The Artist"},
         "files":[
           {"name":"The Song.mp3","source":"original","size":5120000,"length":212.0},
           {"name":"bad.mp3","source":"original","size":{"unexpected":1},"length":"unknown"}
         ]}
        """
        let archiveMixed = try JSONDecoder().decode(
            AudioSourceFinder.ArchiveItem.self, from: Data(archiveMixedJSON.utf8))
        verify(archiveMixed.files?.count == 2 &&
               archiveMixed.files?.first?.size == "5120000" &&
               Double(archiveMixed.files?.first?.length ?? "") == 212,
               "numeric Archive size and duration decode without dropping catalog files")
        verify(archiveMixed.files?.last?.size == nil &&
               archiveMixed.files?.last?.length == "unknown",
               "malformed optional size does not invalidate other catalog files")
        // A present malformed size must never be treated as missing size.
        // This previously allowed a catalog row with contradictory size
        // evidence to become an unattended exact-recording download.
        let malformedSizeJSON = #"{\"metadata\":{\"title\":\"The Song\",\"creator\":\"The Artist\"},\"files\":[{\"name\":\"The Song.mp3\",\"source\":\"original\",\"size\":{\"unexpected\":1},\"length\":\"212\"}]}"#
        let malformedSize = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
            from: Data(malformedSizeJSON.utf8))
        verify(malformedSize.files?.first?.hasInvalidSize == true &&
               AudioSourceFinder.archiveCandidate(malformedSize,
                   identifier: "invalid-size", for: wish) == nil,
               "malformed declared Archive size cannot authorize an automatic download")
        // An explicitly malformed Archive source is not the same as an absent
        // classification on a legacy upload. A malformed value must never
        // become an unattended original even when title/duration match.
        for malformed in ["42", "null", #"{\"kind\":\"original\"}"#, "true"] {
            let json = """
            {"metadata":{"title":"The Song","creator":"The Artist"},
             "files":[{"name":"The Song.mp3","source":\(malformed),
                       "size":"5120000","length":"212"}]}
            """
            let item = try JSONDecoder().decode(
                AudioSourceFinder.ArchiveItem.self, from: Data(json.utf8))
            verify(item.files?.first?.hasInvalidSource == true &&
                   AudioSourceFinder.archiveCandidate(
                       item, identifier: "malformed-source", for: wish) == nil,
                   "malformed explicit Archive source never becomes a legacy original")
        }
        let legacySource = """
        {"metadata":{"title":"The Song","creator":"The Artist"},
         "files":[{"name":"The Song.mp3","size":"5120000","length":"212"}]}
        """
        let legacyItem = try JSONDecoder().decode(
            AudioSourceFinder.ArchiveItem.self, from: Data(legacySource.utf8))
        verify(legacyItem.files?.first?.hasInvalidSource == false &&
               AudioSourceFinder.archiveCandidate(
                   legacyItem, identifier: "legacy-source", for: wish) != nil,
               "truly absent source classification retains legacy exact-match behavior")
        // A duplicate filename with one valid row and one malformed declared
        // size must not become eligible merely because the valid row is first.
        // Both permutations must reject the entire unattended candidate.
        let validDuplicate = #"{"name":"The Song.mp3","source":"original","size":5120000,"length":"212"}"#
        let invalidDuplicate = #"{"name":"The Song.mp3","source":"original","size":{"broken":true},"length":"212"}"#
        for rows in [[validDuplicate, invalidDuplicate],
                     [invalidDuplicate, validDuplicate]] {
            let json = """
            {"metadata":{"title":"The Song","creator":"The Artist"},
             "files":[\(rows.joined(separator: ","))]}
            """
            let item = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                                                from: Data(json.utf8))
            verify(AudioSourceFinder.archiveCandidate(item,
                identifier: "duplicate-malformed-size", for: wish) == nil,
                "duplicate Archive filename with malformed size rejects either row ordering")
        }
        // Archive can publish case or canonically equivalent names as
        // separate objects. A local case-insensitive filesystem may collapse
        // them, so even a matching duration cannot justify automatic choice.
        for alias in ["the song.mp3", "The Song.MP3"] {
            let aliasRow = """
            {"name":"\(alias)","source":"original","size":5120000,"length":"212"}
            """
            for rows in [[validDuplicate, aliasRow], [aliasRow, validDuplicate]] {
                let json = """
                {"metadata":{"title":"The Song","creator":"The Artist"},
                 "files":[\(rows.joined(separator: ","))]}
                """
                let item = try JSONDecoder().decode(
                    AudioSourceFinder.ArchiveItem.self, from: Data(json.utf8))
                verify(AudioSourceFinder.archiveCandidate(
                    item, identifier: "alias-collision", for: wish) == nil,
                    "case-aliased Archive filenames must not auto-select by row order")
            }
        }
        // An unclassified sibling can be a second uploaded recording, even
        // when the catalog also contains a confidently classified original.
        // Ignoring it would falsely authorize an unattended exact match.
        // A duplicate physical filename with contradictory derivative metadata
        // must not be treated as one confidently identified original.
        // Same-path contradictory source classifications cannot be resolved
        // by catalog order or by dropping the derivative row.
        let originalRow = #"{"name":"The Song.mp3","source":"original","size":5120000,"length":"212"}"#
        let derivativeRow = #"{"name":"The Song.mp3","source":"derivative","size":5120000,"length":"212"}"#
        for rows in [[originalRow, derivativeRow], [derivativeRow, originalRow]] {
            let json = "{\"metadata\":{\"title\":\"The Song\",\"creator\":\"The Artist\"},\"files\":["
                + rows.joined(separator: ",") + "]}"
            let item = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                                                from: Data(json.utf8))
            verify(AudioSourceFinder.archiveCandidate(item,
                identifier: "conflicting-source", for: wish) == nil,
                "same-path original/derivative conflict rejects both row orders")
        }
        let originalAndUnknown = """
        {"metadata":{"title":"The Song","creator":"The Artist"},
         "files":[{"name":"The Song.mp3","source":"original","size":5120000,"length":"212"},
                  {"name":"Other Take.mp3","size":5120000,"length":"212"}]}
        """
        let ambiguousUnknown = try JSONDecoder().decode(
            AudioSourceFinder.ArchiveItem.self, from: Data(originalAndUnknown.utf8))
        verify(AudioSourceFinder.archiveCandidate(ambiguousUnknown,
            identifier: "original-and-unknown", for: wish) == nil,
            "unclassified competing audio prevents false unique automatic selection")
        let originalAndDerivative = originalAndUnknown.replacingOccurrences(
            of: "\"name\":\"Other Take.mp3\",",
            with: "\"name\":\"Other Take.mp3\",\"source\":\"derivative\",")
        let safeDerivative = try JSONDecoder().decode(
            AudioSourceFinder.ArchiveItem.self, from: Data(originalAndDerivative.utf8))
        verify(AudioSourceFinder.archiveCandidate(safeDerivative,
            identifier: "original-and-derivative", for: wish) != nil,
            "explicit derivative alongside original does not block a valid match")
        // Alternative edition labels must not collapse into a studio original.
        // Test both directions: requested alternate vs plain file and vice versa.
        let alternateEditions = [
            "The Song (Radio Version).mp3",
            "The Song (Single Edit).mp3",
            "The Song (Extended Version).mp3",
            "The Song (Extended Edit).mp3",
            "The Song (Pitch Shifted).mp3",
            "The Song (Chopped and Screwed).mp3"
        ]
        for alternate in alternateEditions {
            verify(!AudioSourceFinder.recordingEditionAgrees(
                filename: alternate, requestedTitle: "The Song"),
                "alternate edition must not silently match studio: \(alternate)")
            verify(!AudioSourceFinder.recordingEditionAgrees(
                filename: "The Song.mp3",
                requestedTitle: (alternate as NSString).deletingPathExtension),
                "studio file must not match requested alternate: \(alternate)")
            verify(AudioSourceFinder.recordingEditionAgrees(
                filename: alternate,
                requestedTitle: (alternate as NSString).deletingPathExtension),
                "identical alternate edition remains eligible: \(alternate)")
        }
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "The Radio Song.mp3", requestedTitle: "The Radio Song"),
            "ordinary title containing radio is not an edition marker")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Extended Family.mp3", requestedTitle: "Extended Family"),
            "ordinary title containing extended is not an edition marker")
        // One Archive item can include both studio and live/remix editions
        // with matching artist/title metadata. Never auto-select the studio
        // file just because the alternate edition fails its individual gate.
        for alternate in ["The Song Live.mp3", "The Song Remix.mp3",
                          "The Song Remastered.mp3"] {
            let json = """
            {"metadata":{"title":"The Song","creator":"The Artist"},
             "files":[{"name":"The Song.mp3","source":"original",
                       "size":"5120000","length":"212"},
                      {"name":"\(alternate)","source":"original",
                       "size":"5120000","length":"212"}]}
            """
            let item = try JSONDecoder().decode(
                AudioSourceFinder.ArchiveItem.self, from: Data(json.utf8))
            verify(AudioSourceFinder.archiveCandidate(
                item, identifier: "competing-edition", for: wish) == nil,
                "competing edition in same Archive item requires review")
        }
        let unrelatedAlbum = """
        {"metadata":{"title":"The Song","creator":"The Artist"},
         "files":[{"name":"The Song.mp3","source":"original",
                   "size":"5120000","length":"212"},
                  {"name":"Another Track.mp3","source":"original",
                   "size":"5120000","length":"180"}]}
        """
        let albumItem = try JSONDecoder().decode(
            AudioSourceFinder.ArchiveItem.self, from: Data(unrelatedAlbum.utf8))
        verify(AudioSourceFinder.archiveCandidate(
            albumItem, identifier: "unrelated-album", for: wish) != nil,
            "unrelated album tracks do not block exact original selection")
        let identicalDuplicateJSON = """
        {"metadata":{"title":"The Song","creator":"The Artist"},
         "files":[\(validDuplicate),\(validDuplicate)]}
        """
        let identicalDuplicate = try JSONDecoder().decode(
            AudioSourceFinder.ArchiveItem.self, from: Data(identicalDuplicateJSON.utf8))
        verify(AudioSourceFinder.archiveCandidate(identicalDuplicate,
            identifier: "duplicate-valid-size", for: wish) != nil,
            "identical valid duplicate Archive rows still represent one recording")
        // A malformed duration must not disappear as optional evidence, even
        // when a duplicate row provides a valid duration for the same file.
        let validDurationRow = #"{"name":"The Song.mp3","source":"original","size":5120000,"length":"212"}"#
        let malformedDurationRow = #"{"name":"The Song.mp3","source":"original","size":5120000,"length":{"broken":true}}"#
        for rows in [[validDurationRow, malformedDurationRow],
                     [malformedDurationRow, validDurationRow]] {
            let json = """
            {"metadata":{"title":"The Song","creator":"The Artist"},
             "files":[\(rows.joined(separator: ","))]}
            """
            let item = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                                                from: Data(json.utf8))
            verify(item.files?.contains(where: { $0.hasInvalidLength }) == true &&
                   AudioSourceFinder.archiveCandidate(item,
                       identifier: "duplicate-invalid-duration", for: wish) == nil,
                   "malformed duration cannot be masked by duplicate row order")
        }
        let invalidDurationOnly = """
        {"metadata":{"title":"The Song","creator":"The Artist"},
         "files":[\(malformedDurationRow)]}
        """
        let invalidDurationItem = try JSONDecoder().decode(
            AudioSourceFinder.ArchiveItem.self, from: Data(invalidDurationOnly.utf8))
        verify(AudioSourceFinder.archiveCandidate(invalidDurationItem,
            identifier: "invalid-duration-only", for: wish) == nil,
            "unreadable declared duration is never treated as missing evidence")
        let missingSizeJSON = malformedSizeJSON.replacingOccurrences(
            of: #"\"size\":{\"unexpected\":1},"#, with: "")
        let missingSize = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
            from: Data(missingSizeJSON.utf8))
        verify(missingSize.files?.first?.hasInvalidSize == false &&
               AudioSourceFinder.archiveCandidate(missingSize,
                   identifier: "missing-size", for: wish) != nil,
               "legacy Archive records with absent size remain eligible")
        for invalid in ["0", "-1", "104857601", "not-a-number"] {
            let invalidJSON = malformedSizeJSON.replacingOccurrences(
                of: #"{\"unexpected\":1}"#, with: "\"\(invalid)\"")
            let item = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                from: Data(invalidJSON.utf8))
            verify(AudioSourceFinder.archiveCandidate(item,
                identifier: "invalid-range", for: wish) == nil,
                "invalid Archive file-size range is rejected: \(invalid)")
        }
        let archiveValidOnlyJSON = """
        {"metadata":{"title":"The Song","creator":"The Artist"},
         "files":[{"name":"The Song.mp3","source":"original",
                   "size":5120000,"length":212.0}]}
        """
        let archiveValidOnly = try JSONDecoder().decode(
            AudioSourceFinder.ArchiveItem.self, from: Data(archiveValidOnlyJSON.utf8))
        verify(AudioSourceFinder.archiveCandidate(
            archiveValidOnly, identifier: "fixture-recording", for: wish) != nil,
               "numeric duration permits an otherwise exact original recording")
        let archivePreviewJSON = archiveValidOnlyJSON.replacingOccurrences(
            of: "\"length\":212.0", with: "\"length\":30.0")
        let archivePreview = try JSONDecoder().decode(
            AudioSourceFinder.ArchiveItem.self, from: Data(archivePreviewJSON.utf8))
        verify(AudioSourceFinder.archiveCandidate(
            archivePreview, identifier: "fixture-preview", for: wish) == nil,
               "numeric short previews still fail exact-duration selection")
        // Archive can encode the same recording length as seconds, MM:SS,
        // or HH:MM:SS. These must agree without accepting malformed clocks.
        for value in ["212", "212.0", "3:32", "03:32.0", "0:03:32", "00:03:32.000"] {
            verify(AudioSourceFinder.archiveDurationSeconds(value) == 212,
                   "Archive duration parses valid clock or seconds: \(value)")
            let item = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                from: Data(archiveValidOnlyJSON.replacingOccurrences(
                    of: "212.0", with: "\"\(value)\"").utf8))
            verify(AudioSourceFinder.archiveCandidate(item,
                identifier: "duration-clock-fixture", for: wish) != nil,
                "matching Archive clock evidence permits exact recording: \(value)")
        }
        for value in ["", "0", "-1", "3:60", "1:60:00", "3:", ":32",
                      "1:2:3:4", "3:32garbage", "1.5:32", "NaN", "Infinity",
                      "999999999999999999999999:00"] {
            verify(AudioSourceFinder.archiveDurationSeconds(value) == nil,
                   "malformed Archive duration rejected: \(value)")
        }
        for value in ["0:30", "3:45", "00:03:45"] {
            let item = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                from: Data(archiveValidOnlyJSON.replacingOccurrences(
                    of: "212.0", with: "\"\(value)\"").utf8))
            verify(AudioSourceFinder.archiveCandidate(item,
                identifier: "wrong-edition-fixture", for: wish) == nil,
                "preview or wrong edition rejected despite exact artist/title: \(value)")
        }
        let archiveSearch = URLComponents(
            url: AudioSourceFinder.archiveSearchURL(for: wish, page: 2),
            resolvingAgainstBaseURL: false)!
        verify(archiveSearch.url?.host == "archive.org" &&
               archiveSearch.queryItems?.first(where: { $0.name == "page" })?.value == "2" &&
               archiveSearch.queryItems?.first(where: { $0.name == "rows" })?.value == "20",
               "Internet Archive searches a bounded second batch of public recordings")
        verify(URLComponents(url: AudioSourceFinder.archiveSearchURL(
            for: wish, page: 99), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })?.value == "2",
               "Internet Archive pagination clamps to the documented 2-page budget")
        // Spotify metadata is untrusted query text. Lucene punctuation must
        // never escape quoted title/creator terms or add new search clauses.
        let hostileWish = PlaylistWish(
            title: #"Song") OR mediatype:movies OR title:("*"#,
            artist: #"Artist" AND identifier:private*"#,
            album: "", spotifyURL: nil, durationSeconds: 212)
        let hostileSearch = URLComponents(url: AudioSourceFinder.archiveSearchURL(
            for: hostileWish, page: 1), resolvingAgainstBaseURL: false)!
        let hostileQuery = hostileSearch.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
        verify(hostileQuery.contains(#"title:("Song OR mediatype movies OR title")"#) &&
               !hostileQuery.contains("mediatype:movies") &&
               !hostileQuery.contains("identifier:private") &&
               !hostileQuery.contains("*") &&
               hostileSearch.url?.host == "archive.org",
               "Archive search removes injected field operators and wildcards")
        let unicodeWish = PlaylistWish(title: "Beyoncé – Déjà Vu",
            artist: "Beyoncé", album: "", spotifyURL: nil, durationSeconds: nil)
        let unicodeQuery = URLComponents(url: AudioSourceFinder.archiveSearchURL(
            for: unicodeWish, page: 1), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value ?? ""
        verify(unicodeQuery.contains("Beyoncé") && unicodeQuery.contains("Déjà Vu"),
               "Archive query sanitization retains Unicode recording metadata")
        let archiveFields = archiveSearch.queryItems?.filter { $0.name == "fl[]" }
            .compactMap(\.value) ?? []
        verify(archiveFields.contains("title") && archiveFields.contains("creator"),
               "Archive search retrieves title and creator before expensive detail lookups")
        let budget = AudioSourceFinder.ArchiveLookupBudget.self
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        verify(budget.maxDetailRequestsPerPage == 8 &&
               budget.maxElapsedSeconds == 45,
               "per-song Archive requests and wall-clock time are bounded")
        verify(budget.canRequestDetails(
            completed: 0, startedAt: started, now: started) &&
               budget.canRequestDetails(
            completed: 7, startedAt: started, now: started.addingTimeInterval(44)),
               "Archive details can still be queried while within both limits")
        verify(!budget.canRequestDetails(
            completed: 8, startedAt: started, now: started) &&
               !budget.canRequestDetails(
            completed: 1, startedAt: started, now: started.addingTimeInterval(45)),
               "Archive stops at eight detail lookups or a 45-second window")
        verify(!budget.stillWithinWindow(
            startedAt: started, now: started.addingTimeInterval(46)),
               "Archive page two cannot start after per-song deadline")
        verify(AudioSourceFinder.archiveIndexRelevance(
            title: "The Song", creator: "The Artist", for: wish) >
               AudioSourceFinder.archiveIndexRelevance(
            title: "Another Song", creator: "The Artist", for: wish),
               "exact Archive title and creator are inspected before album/index noise")
        verify(AudioSourceFinder.archiveIndexRelevance(
            title: "Another Song", creator: "The Artist", for: wish) >
               AudioSourceFinder.archiveIndexRelevance(
            title: "Another Song", creator: "Another Artist", for: wish),
               "artist attribution remains a ranking signal")
        let archiveMatch = AudioCatalogMatch(
            downloadURL: URL(string: "https://archive.org/download/a/song.mp3")!,
            itemURL: URL(string: "https://archive.org/details/a")!,
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
            sourceName: "Internet Archive")
        let commonsMatch = AudioCatalogMatch(
            downloadURL: URL(string: "https://upload.wikimedia.org/audio/song.mp3")!,
            itemURL: URL(string: "https://commons.wikimedia.org/wiki/File:song.mp3")!,
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
            sourceName: "Wikimedia Commons")
        let discovered = [archiveMatch, commonsMatch]
        let partial = try AudioSourceFinder.catalogReport(from: [
            .init(rank: 0, provider: "Audius", candidate: nil, failure: "HTTP 429"),
            .init(rank: 1, provider: "Internet Archive", candidate: nil, failure: nil)
        ])
        verify(partial.candidates.isEmpty && partial.warnings == ["Audius: HTTP 429"],
               "one provider outage preserves a healthy no-match result and its diagnostic")
        let surviving = try AudioSourceFinder.catalogReport(from: [
            .init(rank: 0, provider: "Audius", candidate: nil, failure: "HTTP 403"),
            .init(rank: 1, provider: "Internet Archive", candidate: archiveMatch, failure: nil)
        ])
        verify(surviving.candidates.first?.downloadURL == archiveMatch.downloadURL,
               "a failed provider never discards another catalog's downloadable recording")
        do {
            _ = try AudioSourceFinder.catalogReport(from: [
                .init(rank: 0, provider: "Audius", candidate: nil, failure: "HTTP 429"),
                .init(rank: 1, provider: "Internet Archive", candidate: nil, failure: "HTTP 503")
            ])
            fatalError("FAIL: total catalog outage must remain retryable")
        } catch {
            verify(error.localizedDescription.contains("Audius") &&
                   error.localizedDescription.contains("503"),
                   "total outage reports the providers and specific failures")
        }
        let archiveJSON = #"{"metadata":{"title":"The Song","creator":"The Artist"},"files":[{"name":"song.mp3","source":"original","length":"212.43","size":"8419768"}]}"#
        let archiveItem = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                                                   from: Data(archiveJSON.utf8))
        // An Archive single-song upload may repeat the identical MP3 row.
        // It must still use exact item metadata even if its filename is opaque.
        let repeatedSingleJSON = #"{\"metadata\":{\"title\":\"The Song\",\"creator\":\"The Artist\"},\"files\":[{\"name\":\"opaque.mp3\",\"source\":\"original\",\"length\":\"212\",\"size\":\"5000000\"},{\"name\":\"opaque.mp3\",\"source\":\"original\",\"length\":\"212\",\"size\":\"5000000\"}]}"#
        let repeatedSingle = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
            from: Data(repeatedSingleJSON.utf8))
        verify(AudioSourceFinder.archiveCandidate(repeatedSingle,
            identifier: "single-repeated", for: wish) != nil,
            "identical duplicate rows retain single-track exact metadata matching")
        let conflictingSingleJSON = repeatedSingleJSON.replacingOccurrences(
            of: #"\"length\":\"212\",\"size\":\"5000000\"}]}"#,
            with: #"\"length\":\"190\",\"size\":\"5000000\"}]}"#)
        let conflictingSingle = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
            from: Data(conflictingSingleJSON.utf8))
        verify(AudioSourceFinder.archiveCandidate(conflictingSingle,
            identifier: "single-conflict", for: wish) == nil,
            "conflicting duplicate rows cannot choose an arbitrary recording")
        // MusicMatching may strip edition suffixes. A studio and live take
        // sharing the same normalized title must not auto-select either.
        let studioAndLiveJSON = #"{\"metadata\":{\"title\":\"The Song\",\"creator\":\"The Artist\"},\"files\":[{\"name\":\"The Song.mp3\",\"source\":\"original\",\"length\":\"212\",\"size\":\"5000000\"},{\"name\":\"The Song (Live).mp3\",\"source\":\"original\",\"length\":\"212\",\"size\":\"5000000\"}]}"#
        let studioAndLive = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
            from: Data(studioAndLiveJSON.utf8))
        verify(AudioSourceFinder.archiveCandidate(studioAndLive,
            identifier: "studio-live-ambiguous", for: wish) == nil,
            "studio/live alternatives sharing normalized title require review")
        let liveAndStudioJSON = studioAndLiveJSON.replacingOccurrences(
            of: #"{\"name\":\"The Song.mp3\",\"source\":\"original\",\"length\":\"212\",\"size\":\"5000000\"},{\"name\":\"The Song (Live).mp3\",\"source\":\"original\",\"length\":\"212\",\"size\":\"5000000\"}"#,
            with: #"{\"name\":\"The Song (Live).mp3\",\"source\":\"original\",\"length\":\"212\",\"size\":\"5000000\"},{\"name\":\"The Song.mp3\",\"source\":\"original\",\"length\":\"212\",\"size\":\"5000000\"}"#)
        let liveAndStudio = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
            from: Data(liveAndStudioJSON.utf8))
        verify(AudioSourceFinder.archiveCandidate(liveAndStudio,
            identifier: "live-studio-ambiguous", for: wish) == nil,
            "edition ambiguity is independent of Archive file ordering")
        let publicMatch = AudioSourceFinder.archiveCandidate(archiveItem,
            identifier: "public-recording", for: wish)
        verify(publicMatch?.downloadURL.lastPathComponent == "song.mp3" &&
               publicMatch?.licenseURL == nil,
               "real Archive decimal duration and absent license do not reject matching MP3")
        // Archive duration belongs to the selected audio file, not to the
        // item title or a similarly named album. Only the original recording
        // within four seconds of Spotify may enter automatic download.
        for (length, accepted) in [
            ("212", true), ("208", true), ("216", true),
            ("207.99", false), ("216.01", false), ("30", false),
            ("0", false), ("-1", false), ("nan", false),
            ("inf", false), ("not-a-duration", false)
        ] {
            let fixture = archiveJSON.replacingOccurrences(of: "212.43", with: length)
            let item = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                                                from: Data(fixture.utf8))
            verify((AudioSourceFinder.archiveCandidate(item,
                identifier: "public-recording", for: wish) != nil) == accepted,
                "Archive per-file duration \(length) matches Spotify runtime policy")
        }
        let missingLength = archiveJSON.replacingOccurrences(of: #","length":"212.43""#, with: "")
        let missingItem = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                                                  from: Data(missingLength.utf8))
        verify(AudioSourceFinder.archiveCandidate(missingItem,
            identifier: "public-recording", for: wish) == nil,
            "Archive cannot auto-select a recording without per-file runtime evidence")
        let noSpotifyDuration = PlaylistWish(title: "The Song", artist: "The Artist",
            album: "The Album", spotifyURL: nil, durationSeconds: nil)
        verify(AudioSourceFinder.archiveCandidate(missingItem,
            identifier: "public-recording", for: noSpotifyDuration) != nil,
            "Archive keeps metadata-only songs discoverable when Spotify omits duration")
        let oversizedJSON = archiveJSON.replacingOccurrences(of: "8419768", with: "104857601")
        let oversizedItem = try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                                                     from: Data(oversizedJSON.utf8))
        verify(AudioSourceFinder.archiveCandidate(oversizedItem,
                   identifier: "public-recording", for: wish) == nil,
               "Archive file.size still rejects media larger than 100 MiB")
        let legacyMatch = try JSONDecoder().decode(AudioCatalogMatch.self,
            from: JSONEncoder().encode(archiveMatch))
        verify(legacyMatch.licenseURL == archiveMatch.licenseURL,
               "saved sources with license metadata remain decodable")
        if let publicMatch {
            let restored = try JSONDecoder().decode(AudioCatalogMatch.self,
                from: JSONEncoder().encode(publicMatch))
            verify(restored.licenseURL == nil && restored.downloadURL == publicMatch.downloadURL,
                   "public sources without license metadata survive persisted alternate-source roundtrip")
        }
        verify(AudioSourceFinder.prioritize(
            discovered, successfulProviders: [], failedProviders: [])
                .first?.sourceName == "Internet Archive",
               "new sources have equal neutral reliability and preserve discovery order")
        verify(AudioSourceFinder.prioritize(
            discovered, successfulProviders: ["Wikimedia Commons"], failedProviders: [])
                .first?.sourceName == "Wikimedia Commons",
               "verified offline imports improve source priority")
        verify(AudioSourceFinder.prioritize(
            discovered, successfulProviders: [], failedProviders: ["Internet Archive"])
                .first?.sourceName == "Wikimedia Commons",
               "terminal failures lower provider priority")
        verify(AudioSourceFinder.prioritize(
            [archiveMatch, archiveMatch, commonsMatch],
            successfulProviders: [], failedProviders: []).count == 2,
               "source scoring still removes duplicate download URLs")
        let ccMixterURL = URLComponents(
            url: AudioSourceFinder.ccMixterSearchURL(for: wish),
            resolvingAgainstBaseURL: false)!
        verify(ccMixterURL.url?.host == "ccmixter.org" &&
               ccMixterURL.queryItems?.first(where: { $0.name == "f" })?.value == "rss" &&
               ccMixterURL.queryItems?.first(where: { $0.name == "search" })?.value == wish.title &&
               ccMixterURL.queryItems?.first(where: { $0.name == "limit" })?.value == "20",
               "official ccMixter search uses bounded public RSS API")
        let ccMixterFeed = """
            <?xml version="1.0"?>
            <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"
                               xmlns:cc="http://creativecommons.org/ns#">
              <channel><title>ccMixter matches</title>
                <item>
                  <title>The Song</title>
                  <dc:creator>The Artist</dc:creator>
                  <link>https://ccmixter.org/files/the_artist/1234</link>
                  <enclosure url="https://ccmixter.org/content/the_artist/the_song.mp3"
                             type="audio/mpeg" />
                  <cc:license>https://creativecommons.org/licenses/by/4.0/</cc:license>
                </item>
              </channel>
            </rss>
            """
        let ccMixterMatches = AudioSourceFinder.ccMixterCandidates(
            in: Data(ccMixterFeed.utf8), matching: wish)
        verify(ccMixterMatches?.count == 1 &&
               ccMixterMatches?.first?.sourceName == "ccMixter" &&
               ccMixterMatches?.first?.downloadURL.pathExtension == "mp3",
               "ccMixter RSS exact recording with declared CC license is eligible")
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data("not xml".utf8), matching: wish) == nil,
               "malformed publisher RSS cannot create any MP3 candidates")
        let ccMixterWrongLicense = ccMixterFeed.replacingOccurrences(
            of: "https://creativecommons.org/licenses/by/4.0/",
            with: "https://example.com/terms")
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data(ccMixterWrongLicense.utf8), matching: wish)?.count == 1,
               "matching ccMixter file does not require a Creative Commons label")
        let ccMixterWrongVersion = ccMixterFeed.replacingOccurrences(
            of: "<title>The Song</title>", with: "<title>The Song (Live)</title>")
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data(ccMixterWrongVersion.utf8), matching: wish)?.isEmpty == true,
               "ccMixter live/remix recording does not silently replace Spotify version")
        let ccMixterWrongHost = ccMixterFeed.replacingOccurrences(
            of: "https://ccmixter.org/content/", with: "https://evil.example/content/")
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data(ccMixterWrongHost.utf8), matching: wish)?.isEmpty == true,
               "untrusted MP3 host is rejected even when RSS claims a valid license")
        verify(AudioSourceFinder.catalogFileTitle("File:The Song.MP3") == "The Song",
               "catalog file extension matching ignores capitalization")
        verify(AudioSourceFinder.catalogFileTitle("The.mp3 Song") == "The.mp3 Song",
               "catalog title cleanup preserves internal extension-like text")
        for title in ["File:The Song.MP3", "The Song.Mp3"] {
            verify(AudioSourceFinder.openverseCandidate(
                title: title, creator: "The Artist",
                download: "https://upload.wikimedia.org/file.mp3",
                landing: "https://commons.wikimedia.org/wiki/File:test",
                license: "https://creativecommons.org/licenses/by/4.0/",
                filetype: "mp3", duration: 212000,
                source: "wikimedia", filesize: nil, wish: wish) != nil,
                "Openverse accepts exact recording with mixed-case extension")
        }
        let openverse = AudioSourceFinder.openverseCandidate(
            title: "The Song", creator: "The Artist",
            download: "https://upload.wikimedia.org/wikipedia/commons/1/12/the-song.mp3",
            landing: "https://commons.wikimedia.org/wiki/File:The_Song.mp3",
            license: "https://creativecommons.org/licenses/by/4.0/",
            filetype: "mp3", duration: 212000,
            source: "wikimedia", filesize: 5_000_000, wish: wish)
        verify(openverse != nil, "Openverse Wikimedia MP3 exact match accepted")
        let focusedOpenverse = URLComponents(
            url: AudioSourceFinder.openverseSearchURL(
                for: wish, fieldSearch: true, page: 2),
            resolvingAgainstBaseURL: false)?.queryItems ?? []
        func parameter(_ name: String, in items: [URLQueryItem]) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        verify(parameter("title", in: focusedOpenverse) == wish.title &&
               parameter("creator", in: focusedOpenverse) == wish.artist &&
               parameter("extension", in: focusedOpenverse) == "mp3" &&
               parameter("page", in: focusedOpenverse) == "2",
               "focused Openverse lookup searches second page with exact title/artist filters")
        let broadOpenverse = URLComponents(
            url: AudioSourceFinder.openverseSearchURL(
                for: wish, fieldSearch: false, page: 1),
            resolvingAgainstBaseURL: false)?.queryItems ?? []
        verify(parameter("q", in: broadOpenverse) == "\"The Song\" \"The Artist\"" &&
               parameter("creator", in: broadOpenverse) == nil &&
               parameter("page_size", in: broadOpenverse) == "50",
               "Openverse fallback retains quoted title and artist search")
        verify(AudioSourceFinder.shouldSearchNextOpenversePage(
            page: 1, pageCount: 3, returned: 50, eligible: 0) &&
               AudioSourceFinder.shouldSearchNextOpenversePage(
                   page: 1, pageCount: nil, returned: 50, eligible: 0),
               "a full unmatched catalog page searches for more matching MP3s")
        verify(!AudioSourceFinder.shouldSearchNextOpenversePage(
            page: 1, pageCount: 1, returned: 50, eligible: 0) &&
               !AudioSourceFinder.shouldSearchNextOpenversePage(
                   page: 1, pageCount: nil, returned: 20, eligible: 0),
               "catalog exhaustion stops unnecessary pagination")
        verify(!AudioSourceFinder.shouldSearchNextOpenversePage(
            page: 2, pageCount: 100, returned: 50, eligible: 0) &&
               !AudioSourceFinder.shouldSearchNextOpenversePage(
                   page: 1, pageCount: 100, returned: 50, eligible: 1),
               "Openverse requests stay bounded and stop after a verified candidate")
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
            source: "wikimedia", filesize: nil, wish: wish) != nil,
            "matching public MP3 remains eligible without license metadata")
        for name in ["01 - The Song.mp3", "02. The Song.mp3", "003_The_Song.mp3"] {
            verify(AudioSourceFinder.archiveFileCandidate(
                name: name, source: "original", sizeBytes: "5421879",
                itemTitle: "The Album", itemCreator: wish.artist,
                audioFileCount: 3, wish: wish),
                "numbered album track matches: \(name)")
        }
        for name in ["01 - The Song (Live).mp3", "99 The Song.mp3", "01 - Other Song.mp3"] {
            verify(!AudioSourceFinder.archiveFileCandidate(
                name: name, source: "original", sizeBytes: "5421879",
                itemTitle: "The Album", itemCreator: wish.artist,
                audioFileCount: 3, wish: wish),
                "number stripping preserves recording identity: \(name)")
        }
        verify(AudioSourceFinder.archiveFileCandidate(
            name: "The Song.mp3", source: "original", sizeBytes: "5421879",
            itemTitle: "The Album", itemCreator: "The Artist",
            audioFileCount: 8, wish: wish),
            "exact individual MP3 is eligible inside an album")
        verify(!AudioSourceFinder.archiveFileCandidate(
            name: "The Song (Live).mp3", source: "original", sizeBytes: "5421879",
            itemTitle: "The Album", itemCreator: "The Artist",
            audioFileCount: 8, wish: wish),
            "do not substitute album live takes")
        verify(!AudioSourceFinder.archiveFileCandidate(
            name: "The Song.mp3", source: "derivative", sizeBytes: "5421879",
            itemTitle: "The Album", itemCreator: "The Artist",
            audioFileCount: 8, wish: wish),
            "generated derivatives never qualify in multiple-audio archives")
        verify(AudioSourceFinder.archiveFileCandidate(
            name: "unrelated-file.mp3", source: "original", sizeBytes: "5421879",
            itemTitle: "The Song", itemCreator: "The Artist",
            audioFileCount: 1, wish: wish),
            "single-song item uses its exact title and creator metadata")
        verify(!AudioSourceFinder.archiveFileCandidate(
            name: "The Song.mp3", source: "original", sizeBytes: "105000000",
            itemTitle: "The Song", itemCreator: "The Artist",
            audioFileCount: 1, wish: wish),
            "archive size interpreted as bytes and oversized media rejected")
        verify(!AudioSourceFinder.archiveFileCandidate(
            name: "The Song.mp3", source: "original", sizeBytes: "5400000",
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
        let commonsWithoutLicense = AudioSourceFinder.commonsCandidate(
            fileTitle: "File:The Song.mp3", artistCredit: "The Artist",
            download: "https://upload.wikimedia.org/file.mp3",
            landing: "https://commons.wikimedia.org/wiki/File:test",
            license: nil, bytes: 8_000_000, wish: wish)
        verify(commonsWithoutLicense != nil && commonsWithoutLicense?.licenseURL == nil,
               "Commons identity and direct-file checks do not require license metadata")
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
        let ccMixterBrowseURL = WebAudioSearch.browserURL(
            for: wish, provider: .ccMixter)
        verify(ccMixterBrowseURL.host == "ccmixter.org" &&
               ccMixterBrowseURL.path == "/search" &&
               URLComponents(url: ccMixterBrowseURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "search_text" })?.value ==
                    "\(wish.artist) \(wish.title)",
               "publisher fallback opens ccMixter search directly")
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

        verify(AudioSourceFinder.audiusPermalink("/the-artist/the-song")?.absoluteString ==
               "https://audius.co/the-artist/the-song",
               "relative Audius track permalink resolves to trusted origin")
        verify(AudioSourceFinder.audiusPermalink("https://audius.co/the-artist/the-song") != nil,
               "absolute Audius track permalink remains supported")
        for raw in ["//evil.example/song", "https://audius.co.evil.example/a/b",
                    "https://user@audius.co/a/b", "/artist", "/artist/../song",
                    "/artist/song?next=evil", "http://audius.co/a/b"] {
            verify(AudioSourceFinder.audiusPermalink(raw) == nil,
                   "untrusted or malformed Audius permalink rejected: \(raw)")
        }
        // Relevant fields captured from the public /v1/tracks/D7KyD response.
        // This real recording is NOT downloadable; never turn it into a candidate.
        let liveAudiusJSON = #"""
        {"id": "D7KyD", "title": "Paauer | Baauer B2B Party Favor | B&L Block Party LA (Live Set)", "permalink": "/TeamBandL/paauer-|-baauer-b2b-party-favor-|-bl-block-party-la-live-set-725", "duration": 5265, "is_downloadable": false, "download_conditions": null, "is_download_gated": false, "is_stream_gated": false, "is_unlisted": false, "user": {"name": "Brownies & Lemonade", "handle": "TeamBandL"}}
        """#
        let liveAudius = try? JSONDecoder().decode(
            AudioSourceFinder.AudiusTrack.self, from: Data(liveAudiusJSON.utf8))
        verify(liveAudius != nil, "real Audius response fields decode")
        verify(liveAudius.flatMap { AudioSourceFinder.audiusPermalink($0.permalink) }?.host == "audius.co",
               "real relative Audius permalink resolves to trusted host")
        if let liveAudius {
            let liveWish = PlaylistWish(title: liveAudius.title,
                artist: liveAudius.user?.name ?? "", album: "", spotifyURL: nil,
                durationSeconds: liveAudius.duration)
            verify(AudioSourceFinder.audiusCandidate(liveAudius, for: liveWish) == nil,
                   "real non-downloadable recording remains excluded")
        }
        // Relevant fields from a real ungated, download-enabled search result.
        let eligibleAudiusJSON = #"""
        {"id": "dloY13J", "title": "ohnoitsdoug x diskade - Sound System Check [FREE DOWNLOAD]", "permalink": "/diskadebass/ohnoitsdoug-x-diskade-sound-system-check-free-download", "duration": 192, "is_downloadable": true, "download_conditions": null, "is_download_gated": false, "is_stream_gated": false, "is_unlisted": false, "user": {"name": "DISKADE", "handle": "diskadebass"}}
        """#
        let eligibleAudius = try? JSONDecoder().decode(
            AudioSourceFinder.AudiusTrack.self, from: Data(eligibleAudiusJSON.utf8))
        verify(eligibleAudius != nil, "real downloadable Audius result decodes")
        if let track = eligibleAudius {
            let requested = PlaylistWish(title: track.title, artist: track.user?.name ?? "",
                album: "", spotifyURL: nil, durationSeconds: track.duration)
            let candidate = AudioSourceFinder.audiusCandidate(track, for: requested)
            verify(candidate?.downloadURL.absoluteString ==
                   "https://api.audius.co/v1/tracks/dloY13J/download",
                   "real downloadable relative permalink creates expected MP3 candidate")
            verify(candidate?.itemURL.host == "audius.co",
                   "real download candidate retains trusted attribution")
        }
        let audiusArtist = AudioSourceFinder.AudiusTrack.User(
            name: "The Artist", handle: "the-artist")
        let audiusOK = AudioSourceFinder.AudiusTrack(
            id: "D7KyD", title: "The Song", user: audiusArtist,
            duration: 212, is_downloadable: true, is_download_gated: false,
            is_stream_gated: false, is_unlisted: false,
            download_conditions: nil, permalink: "https://audius.co/the-artist/the-song",
            license: nil)
        var conflictingAudius = audiusOK
        conflictingAudius.downloadable = false
        verify(AudioSourceFinder.audiusCandidate(conflictingAudius, for: wish) == nil,
               "explicit false alternate Audius flag prevents automatic download")
        let fallbackAudius = AudioSourceFinder.AudiusTrack(
            id: "D7KyD", title: "The Song", user: audiusArtist,
            duration: 212, is_downloadable: nil, is_download_gated: false,
            is_stream_gated: false, is_unlisted: false,
            download_conditions: nil, permalink: "https://audius.co/the-artist/the-song",
            license: nil, downloadable: true)
        verify(AudioSourceFinder.audiusCandidate(fallbackAudius, for: wish) != nil,
               "alternate Audius download flag works when primary flag is absent")
        let audiusMatch = AudioSourceFinder.audiusCandidate(audiusOK, for: wish)
        verify(audiusMatch?.downloadURL.host == "api.audius.co",
               "Audius artist-enabled direct-download endpoint is recognized")
        verify(audiusMatch?.sourceName.contains("Audius") == true,
               "Audius attribution is retained")
        verify(audiusMatch?.downloadURL.absoluteString.contains("/download") == true,
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
        var conflictingPrimary = audiusNonDownload
        conflictingPrimary.downloadable = true
        verify(AudioSourceFinder.audiusCandidate(conflictingPrimary, for: wish) == nil,
               "alternate true cannot override explicit primary false")
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
        // Audius' published TrackResponse can use "downloadable" instead
        // of the legacy "is_downloadable" key.
        let documentedTrackJSON = """
        {"id":"D7KyD","title":"The Song",
         "user":{"name":"The Artist","handle":"the-artist"},
         "duration":212,"downloadable":true,
         "permalink":"https://audius.co/the-artist/the-song",
         "is_unlisted":false,"is_stream_gated":false}
        """
        let documentedTrack = try? JSONDecoder().decode(
            AudioSourceFinder.AudiusTrack.self,
            from: Data(documentedTrackJSON.utf8))
        verify(documentedTrack != nil, "decode documented Audius API response")
        verify(documentedTrack.flatMap {
            AudioSourceFinder.audiusCandidate($0, for: wish)
        } != nil, "documented Audius downloadable=true yields a valid candidate")

        let deniedTrackJSON = documentedTrackJSON.replacingOccurrences(
            of: #""downloadable":true"#, with: #""downloadable":false"#)
        let deniedTrack = try? JSONDecoder().decode(
            AudioSourceFinder.AudiusTrack.self,
            from: Data(deniedTrackJSON.utf8))
        verify(deniedTrack.flatMap {
            AudioSourceFinder.audiusCandidate($0, for: wish)
        } == nil, "documented Audius downloadable=false cannot enter automatic queue")
        let gatedTrackJSON = documentedTrackJSON.replacingOccurrences(
            of: #""downloadable":true"#,
            with: #""downloadable":true,"download_conditions":{"follow_user_id":1}"#)
        let gatedTrack = try? JSONDecoder().decode(
            AudioSourceFinder.AudiusTrack.self, from: Data(gatedTrackJSON.utf8))
        verify(gatedTrack.flatMap {
            AudioSourceFinder.audiusCandidate($0, for: wish)
        } == nil, "an Audius gated download cannot enter the automatic queue")

        // Multiple enclosures in one RSS item may be different edits or
        // recordings. XML ordering must never decide which file to import.
        let multiEnclosureRSS = """
        <rss version="2.0"><channel><item>
          <title>The Song</title><dc:creator xmlns:dc="http://purl.org/dc/elements/1.1/">The Artist</dc:creator>
          <link>https://ccmixter.org/files/artist/123</link>
          <enclosure url="https://ccmixter.org/content/artist/one.mp3" type="audio/mpeg"/>
          <enclosure url="https://ccmixter.org/content/artist/two.mp3" type="audio/mpeg"/>
        </item></channel></rss>
        """
        let duplicateEnclosureRSS = multiEnclosureRSS.replacingOccurrences(
            of: "two.mp3", with: "one.mp3")
        let rssWish = PlaylistWish(title: "The Song", artist: "The Artist",
            album: "", spotifyURL: nil, durationSeconds: nil)
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data(multiEnclosureRSS.utf8), matching: rssWish)?.isEmpty == true,
            "distinct RSS enclosures cannot select a recording by feed order")
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data(duplicateEnclosureRSS.utf8), matching: rssWish)?.count == 1,
            "identical duplicate RSS enclosures preserve a unique source")
        let reversedRSS = multiEnclosureRSS
            .replacingOccurrences(of: "one.mp3", with: "temp.mp3")
            .replacingOccurrences(of: "two.mp3", with: "one.mp3")
            .replacingOccurrences(of: "temp.mp3", with: "two.mp3")
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data(reversedRSS.utf8), matching: rssWish)?.isEmpty == true,
            "reversing ambiguous enclosure order never changes rejection")

        // Commons has no reliable per-file decoded duration. A same-named
        // radio edit must not be selected for a timed Spotify recording.
        let commonsTimedWish = PlaylistWish(title: "The Song", artist: "The Artist",
            album: "", spotifyURL: nil, durationSeconds: 212)
        let commonsUntimedWish = PlaylistWish(title: "The Song", artist: "The Artist",
            album: "", spotifyURL: nil, durationSeconds: nil)
        func commonsMatch(_ wish: PlaylistWish) -> AudioCatalogMatch? {
            AudioSourceFinder.commonsCandidate(
                fileTitle: "File:The Song.mp3", artistCredit: "The Artist",
                download: "https://upload.wikimedia.org/wikipedia/commons/a/a1/The_Song.mp3",
                landing: "https://commons.wikimedia.org/wiki/File:The_Song.mp3",
                license: nil, bytes: 3_000_000, wish: wish)
        }
        verify(commonsMatch(commonsTimedWish) == nil,
               "Commons without duration cannot auto-match a timed Spotify recording")
        verify(commonsMatch(commonsUntimedWish) != nil,
               "Commons still permits metadata-only wishes without duration evidence")
        let invalidCommonsWish = PlaylistWish(title: "The Song", artist: "The Artist",
            album: "", spotifyURL: nil, durationSeconds: .infinity)
        verify(commonsMatch(invalidCommonsWish) == nil,
               "invalid Spotify runtime cannot authorize an unattended Commons match")

        let firstSource = AudioCatalogMatch(
            downloadURL: URL(string: "https://first.example/song.mp3")!,
            itemURL: URL(string: "https://first.example/song")!,
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
            sourceName: "First verified provider")
        let secondSource = AudioCatalogMatch(
            downloadURL: URL(string: "https://second.example/song.mp3")!,
            itemURL: URL(string: "https://second.example/song")!,
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
            sourceName: "Second verified provider")
        let duplicateFirst = AudioCatalogMatch(
            downloadURL: firstSource.downloadURL,
            itemURL: URL(string: "https://mirror.example/song")!,
            licenseURL: firstSource.licenseURL,
            sourceName: "Duplicate index")
        let deduped = AudioSourceFinder.uniqueDownloadSources(
            [firstSource, duplicateFirst, secondSource])
        verify(deduped.count == 2 &&
               deduped.map(\.sourceName) == ["First verified provider", "Second verified provider"],
               "download-source deduplication preserves provider precedence")
        let fallback = AudioSourceFinder.nextAlternative(
            to: firstSource.downloadURL, from: [duplicateFirst, secondSource])
        verify(fallback?.source.downloadURL == secondSource.downloadURL &&
               fallback?.remaining.isEmpty == true,
               "failed first source rotates to a distinct verified second source")
        verify(AudioSourceFinder.nextAlternative(
            to: secondSource.downloadURL, from: fallback?.remaining ?? []) == nil,
               "exhausted source alternatives cannot cause repeated download loops")
        let expiredAAC = AudioCatalogMatch(
            downloadURL: URL(string: "https://r1.googlevideo.com/videoplayback?mime=audio%2Fmp4&sig=fixture&expire=100")!,
            itemURL: firstSource.itemURL, licenseURL: nil, sourceName: "Expired AAC")
        let freshFallback = AudioSourceFinder.nextAlternative(
            to: firstSource.downloadURL, from: [expiredAAC, secondSource], at: Date(timeIntervalSince1970: 100))
        verify(freshFallback?.source == secondSource && freshFallback?.remaining.isEmpty == true,
               "a signed backup that expires by the scheduled start is skipped")
        // A restored queue can contain older, untrusted fallback URLs. Never
        // issue a retry to local services or URLs carrying credentials, ports
        // or fragments; keep scanning for the next valid public HTTPS file.
        func fallback(_ raw: String) -> AudioCatalogMatch {
            AudioCatalogMatch(downloadURL: URL(string: raw)!,
                itemURL: firstSource.itemURL, licenseURL: nil,
                sourceName: "Persisted fallback fixture")
        }
        let unsafeFallbacks = [
            "https://localhost/song.mp3",
            "https://printer.local/song.mp3",
            "https://127.0.0.1/song.mp3",
            "https://192.168.1.5/song.mp3",
            "https://[::1]/song.mp3",
            "https://user:pass@audio.example/song.mp3",
            "https://audio.example:8443/song.mp3",
            "https://audio.example/song.mp3#fragment",
            "https://open.spotify.com/track/fixture",
            "https://audio.spotifycdn.com/song.mp3",
            "https://r1.googlevideo.com/videoplayback?mime=audio%2Fmp4",
            "https://0x7f.0x0.0x0.0x1/song.mp3",
            "https://0177.0.0.1/song.mp3",
            "http://audio.example/song.mp3"
        ].map(fallback)
        verify(AudioSourceFinder.nextAlternative(to: firstSource.downloadURL,
            from: unsafeFallbacks) == nil,
            "persisted private/credentialed/redirect-prone fallback URLs are rejected")
        let recoveredFallback = AudioSourceFinder.nextAlternative(
            to: firstSource.downloadURL, from: unsafeFallbacks + [secondSource])
        verify(recoveredFallback?.source.downloadURL == secondSource.downloadURL &&
               recoveredFallback?.remaining.isEmpty == true,
               "unsafe persisted URLs are skipped without blocking a valid fallback")
        verify(AudioSourceFinder.nextAlternative(to: firstSource.downloadURL,
            from: [firstSource, secondSource])?.source.downloadURL == secondSource.downloadURL,
            "duplicate current-ticket URLs cannot be retried")
        // A resumed queue must discard every invalid/expired/duplicate source,
        // including those AFTER the first usable candidate. Otherwise the
        // next retry persists and re-examines unsafe old queue entries.
        let thirdSource = fallback("https://third.example/recording.mp3")
        let prunedFallback = AudioSourceFinder.nextAlternative(
            to: firstSource.downloadURL,
            from: unsafeFallbacks + [secondSource, secondSource,
                fallback("https://jamendo.com/track/fixture.mp3"),
                fallback("https://open.spotify.com/track/fixture"),
                thirdSource, firstSource])
        verify(prunedFallback?.source.downloadURL == secondSource.downloadURL &&
               prunedFallback?.remaining.map(\.downloadURL) == [thirdSource.downloadURL],
               "recovered queue prunes all unsafe and duplicate later alternatives")
        let secondRecovery = AudioSourceFinder.nextAlternative(
            to: secondSource.downloadURL, from: prunedFallback?.remaining ?? [])
        verify(secondRecovery?.source.downloadURL == thirdSource.downloadURL &&
               secondRecovery?.remaining.isEmpty == true,
               "subsequent recovery deterministically advances to the last valid file")


        let serializedSources = try? JSONEncoder().encode(deduped)
        let restoredSources = serializedSources.flatMap {
            try? JSONDecoder().decode([AudioCatalogMatch].self, from: $0)
        }
        verify(restoredSources?.map(\.downloadURL) == deduped.map(\.downloadURL) &&
               restoredSources?.map(\.sourceName) == deduped.map(\.sourceName),
               "verified fallback source URLs and attribution survive app restart")
        // Archive search rows can decode successfully but carry identifiers
        // that cannot be safely requested. They must count as uninspected
        // competing recordings rather than authorize a false unique match.
        func archiveSearchBody(_ rows: String) -> AudioSourceFinder.SearchBody? {
            let json = #"{"docs":["# + rows + #"],"numFound":1}"#
            return try? JSONDecoder().decode(AudioSourceFinder.SearchBody.self,
                                             from: Data(json.utf8))
        }
        verify(AudioSourceFinder.archivePageComplete(page: 1, rows: 20, reportedTotal: 35),
               "full first page is consistent with 35 indexed recordings")
        verify(AudioSourceFinder.archivePageComplete(page: 2, rows: 15, reportedTotal: 35),
               "15-row final page exhausts the reported index")
        verify(AudioSourceFinder.archivePageComplete(page: 2, rows: 0, reportedTotal: 20),
               "empty final page is valid when previous page exhausted total")
        verify(!AudioSourceFinder.archivePageComplete(page: 1, rows: 1, reportedTotal: 35),
               "truncated first page cannot authorize a unique match")
        verify(!AudioSourceFinder.archivePageComplete(page: 2, rows: 10, reportedTotal: 35),
               "truncated second page cannot authorize a unique match")
        verify(!AudioSourceFinder.archivePageComplete(page: 2, rows: 20, reportedTotal: 35),
               "second page cannot exceed the index total")
        verify(!AudioSourceFinder.archivePageComplete(page: 0, rows: 1, reportedTotal: 1),
               "invalid index page numbers are rejected")
        verify(!AudioSourceFinder.archivePageComplete(page: 1, rows: 21, reportedTotal: 40),
               "oversized page response cannot pass bounded search policy")
        let validIndex = archiveSearchBody(#"{"identifier":"safe-recording","title":"Exact Song","creator":"Exact Artist"}"#)
        verify(validIndex.map(AudioSourceFinder.archiveSearchRowsComplete) == true,
               "valid Archive identifiers retain complete-index eligibility")
        for identifier in ["../other", "bad/id", "bad\\\\id", "", "a?b"] {
            let escaped = identifier.replacingOccurrences(of: "\\\\", with: "\\\\\\\\")
            let index = archiveSearchBody(#"{"identifier":""# + escaped + #""}"#)
            verify(index.map(AudioSourceFinder.archiveSearchRowsComplete) == false,
                   "unsafe decoded Archive identifier cannot authorize automatic selection")
        }
        let mixedIndex = archiveSearchBody(
            #"{"identifier":"safe-recording"},{"identifier":"../hidden"}"#)
        verify(mixedIndex.map(AudioSourceFinder.archiveSearchRowsComplete) == false,
               "a valid recording cannot hide an unsafe competing index row")
        // Replayed Archive metadata rows must not suppress an otherwise exact
        // original recording, while contradictory evidence must fail closed.
        let archiveWish = PlaylistWish(title: "Exact Song", artist: "Exact Artist",
            album: "", spotifyURL: nil, durationSeconds: 180)
        func archiveFixture(_ rows: String) -> AudioSourceFinder.ArchiveItem? {
            let json = """
            {"metadata":{"title":"Exact Song","creator":"Exact Artist"},
             "files":[\(rows)]}
            """
            return try? JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self,
                                              from: Data(json.utf8))
        }
        let originalRow = #"{"name":"Exact Song.mp3","source":"original","size":"3000000","length":"180"}"#
        let duplicateArchive = archiveFixture(originalRow + "," + originalRow)
        verify(duplicateArchive.flatMap {
            AudioSourceFinder.archiveCandidate($0, identifier: "exact-song", for: archiveWish)
        } != nil, "identical Archive file rows identify one recording")
        let corruptedArchive = archiveFixture(originalRow + ",null")
        verify(corruptedArchive?.hasMalformedFileRows == true && corruptedArchive.flatMap {
            AudioSourceFinder.archiveCandidate($0, identifier: "exact-song", for: archiveWish)
        } == nil, "malformed sibling cannot make an original falsely unique")
        let missingNameArchive = archiveFixture(originalRow + #",{"source":"original","length":"180"}"#)
        verify(missingNameArchive?.hasMalformedFileRows == true && missingNameArchive.flatMap {
            AudioSourceFinder.archiveCandidate($0, identifier: "exact-song", for: archiveWish)
        } == nil, "missing filename cannot authorize unattended import")
        let conflictingRow = #"{"name":"Exact Song.mp3","source":"original","size":"3000000","length":"120"}"#
        let contradictoryArchive = archiveFixture(originalRow + "," + conflictingRow)
        verify(contradictoryArchive.flatMap {
            AudioSourceFinder.archiveCandidate($0, identifier: "exact-song", for: archiveWish)
        } == nil, "conflicting duplicate duration evidence cannot auto-select")
        let differentFile = #"{"name":"Exact Artist - Exact Song.mp3","source":"original","size":"3000000","length":"180"}"#
        let ambiguousArchive = archiveFixture(originalRow + "," + differentFile)
        verify(ambiguousArchive.flatMap {
            AudioSourceFinder.archiveCandidate($0, identifier: "exact-song", for: archiveWish)
        } == nil, "distinct exact-looking files remain ambiguous")
        // JSON-LD publishers may encode duration as numeric seconds rather than
        // ISO-8601. Accept only complete, finite numeric values matching Spotify.
        let numericWish = PlaylistWish(title: "Exact Song", artist: "Exact Artist",
            album: "", spotifyURL: nil, durationSeconds: 180)
        verify(AutomaticWebAudioFinder.recordingDurationEvidenceMatches(
            recording: "180", audio: nil, wish: numericWish),
            "numeric JSON-LD duration in seconds identifies the expected recording")
        verify(AutomaticWebAudioFinder.recordingDurationEvidenceMatches(
            recording: "180.5", audio: "PT3M", wish: numericWish),
            "numeric and ISO duration evidence can agree")
        for invalid in ["180seconds", "180 ", "-180", "NaN", "Infinity", "1e2",
                        "PT3Mgarbage", "PT", "300"] {
            verify(!AutomaticWebAudioFinder.recordingDurationEvidenceMatches(
                recording: invalid, audio: nil, wish: numericWish),
                "invalid or conflicting JSON-LD duration must not auto-match: \\(invalid)")
        }
        verify(!AutomaticWebAudioFinder.recordingDurationEvidenceMatches(
            recording: "180", audio: "PT2M", wish: numericWish),
            "conflicting recording and audio duration claims fail closed")
        // A duplicate URL with changed attribution is not independent
        // corroboration of the same recording. Do not silently overwrite it.
        let openverseFile = URL(string: "https://upload.wikimedia.org/audio/exact.mp3")!
        let originalOpenverse = AudioCatalogMatch(
            downloadURL: openverseFile,
            itemURL: URL(string: "https://commons.wikimedia.org/wiki/File:Exact.mp3")!,
            licenseURL: nil, sourceName: "Openverse: wikimedia")
        let repeatedOpenverse = AudioCatalogMatch(
            downloadURL: openverseFile,
            itemURL: originalOpenverse.itemURL,
            licenseURL: nil, sourceName: "Openverse: wikimedia")
        let conflictingLanding = AudioCatalogMatch(
            downloadURL: openverseFile,
            itemURL: URL(string: "https://commons.wikimedia.org/wiki/File:Other.mp3")!,
            licenseURL: nil, sourceName: "Openverse: wikimedia")
        let conflictingPublisher = AudioCatalogMatch(
            downloadURL: openverseFile,
            itemURL: originalOpenverse.itemURL,
            licenseURL: nil, sourceName: "Openverse: fma")
        verify(AudioSourceFinder.consistentOpenverseDuplicate(
            originalOpenverse, repeatedOpenverse),
            "identical Openverse duplicate URL and provenance are safe to collapse")
        verify(!AudioSourceFinder.consistentOpenverseDuplicate(
            originalOpenverse, conflictingLanding),
            "same URL with conflicting landing evidence is not safe to auto-select")
        verify(!AudioSourceFinder.consistentOpenverseDuplicate(
            originalOpenverse, conflictingPublisher),
            "same URL with conflicting publisher is not safe to auto-select")
        verify(!AudioSourceFinder.consistentOpenverseDuplicate(
            originalOpenverse, AudioCatalogMatch(
                downloadURL: URL(string: "https://upload.wikimedia.org/audio/other.mp3")!,
                itemURL: originalOpenverse.itemURL,
                licenseURL: nil, sourceName: "Openverse: wikimedia")),
            "different recording URLs are not duplicate evidence")
        // Conflicting repeated RSS identity fields must never turn an unrelated
        // enclosure into an automatic match just because the last value wins.
        let conflictingRSS = """
        <rss><channel><item>
          <title>Unrelated Song</title><title>Exact Song</title>
          <creator>Exact Artist</creator>
          <link>https://ccmixter.org/files/artist/123</link>
          <enclosure url="https://ccmixter.org/content/artist/exact.mp3" type="audio/mpeg"/>
        </item></channel></rss>
        """
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data(conflictingRSS.utf8), matching: archiveWish)?.isEmpty == true,
            "conflicting RSS titles cannot authorize a last-value automatic match")
        let repeatedRSS = """
        <rss><channel><item>
          <title>Exact Song</title><title>Exact Song</title>
          <creator>Exact Artist</creator>
          <link>https://ccmixter.org/files/artist/123</link>
          <enclosure url="https://ccmixter.org/content/artist/exact.mp3" type="audio/mpeg"/>
        </item></channel></rss>
        """
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data(repeatedRSS.utf8), matching: archiveWish)?.count == 1,
            "identical repeated RSS titles remain a single eligible recording")
        let conflictingLandingRSS = repeatedRSS.replacingOccurrences(
            of: "<link>https://ccmixter.org/files/artist/123</link>",
            with: "<link>https://ccmixter.org/files/other/999</link><link>https://ccmixter.org/files/artist/123</link>")
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data(conflictingLandingRSS.utf8), matching: archiveWish)?.isEmpty == true,
            "conflicting RSS landing identities cannot authorize unattended selection")
        let conflictingAuthorRSS = repeatedRSS.replacingOccurrences(
            of: "<creator>Exact Artist</creator>",
            with: "<creator>Exact Artist</creator><author>Different Performer</author>")
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data(conflictingAuthorRSS.utf8), matching: archiveWish)?.isEmpty == true,
            "conflicting RSS author and creator cannot authorize automatic selection")
        let authorFirstRSS = repeatedRSS.replacingOccurrences(
            of: "<creator>Exact Artist</creator>",
            with: "<author>Different Performer</author><creator>Exact Artist</creator>")
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data(authorFirstRSS.utf8), matching: archiveWish)?.isEmpty == true,
            "conflicting RSS creator after author must also fail closed")
        let matchingAuthorRSS = repeatedRSS.replacingOccurrences(
            of: "<creator>Exact Artist</creator>",
            with: "<creator>Exact Artist</creator><author>Exact Artist</author>")
        verify(AudioSourceFinder.ccMixterCandidates(
            in: Data(matchingAuthorRSS.utf8), matching: archiveWish)?.count == 1,
            "consistent RSS author and creator preserve valid recording")
        // Archive pages can repeat an identifier with changed credits even
        // when each individual page is internally consistent.
        func archiveIndexPage(_ title: String, _ creator: String) throws
            -> [AudioSourceFinder.SearchItem] {
            let json = """
            {"response":{"docs":[{"identifier":"same-upload",
                                   "title":"\(title)","creator":"\(creator)"}],
                         "numFound":2}}
            """
            return try JSONDecoder().decode(AudioSourceFinder.SearchResponse.self,
                                            from: Data(json.utf8)).response.docs
        }
        var crossPageEvidence: [String: String] = [:]
        let firstIndexPage = try archiveIndexPage("Exact Song", "Exact Artist")
        let sameIndexPage = try archiveIndexPage("Exact Song", "Exact Artist")
        let changedArtistPage = try archiveIndexPage("Exact Song", "Other Artist")
        verify(AudioSourceFinder.archiveCrossPageIdentitiesAgree(
            firstIndexPage, seen: &crossPageEvidence),
            "first Archive page establishes stable recording identity")
        verify(AudioSourceFinder.archiveCrossPageIdentitiesAgree(
            sameIndexPage, seen: &crossPageEvidence),
            "identical identifier repeated on next page remains eligible")
        verify(!AudioSourceFinder.archiveCrossPageIdentitiesAgree(
            changedArtistPage, seen: &crossPageEvidence),
            "contradictory artist across Archive pages invalidates uniqueness")
        verify(AudioSourceFinder.archiveCrossPageIdentitiesAgree(
            sameIndexPage, seen: &crossPageEvidence),
            "conflicting later page cannot overwrite original identity")
        var reversedEvidence: [String: String] = [:]
        verify(AudioSourceFinder.archiveCrossPageIdentitiesAgree(
            changedArtistPage, seen: &reversedEvidence) &&
            !AudioSourceFinder.archiveCrossPageIdentitiesAgree(
                firstIndexPage, seen: &reversedEvidence),
            "cross-page contradictions reject regardless of page order")
        // Duration evidence must not confuse a short preview with the full
        // recording even when the absolute difference is under four seconds.
        verify(AudioSourceFinder.recordingDurationTolerance(15) == 0.5,
            "short recordings use a subsecond evidence window")
        verify(AudioSourceFinder.recordingDurationTolerance(100) == 3.0,
            "midlength songs use proportional duration evidence")
        verify(AudioSourceFinder.recordingDurationTolerance(240) == 4.0,
            "full-length recordings retain the existing four-second allowance")
        verify(AudioSourceFinder.recordingDurationTolerance(.nan) == 0 &&
               AudioSourceFinder.recordingDurationTolerance(-1) == 0,
            "invalid expected runtimes cannot authorize a match")
        verify(abs(12.0 - 15.0) > AudioSourceFinder.recordingDurationTolerance(15),
            "a twelve-second preview cannot auto-match a fifteen-second song")
        verify(abs(239.0 - 240.0) <= AudioSourceFinder.recordingDurationTolerance(240),
            "a full-length recording with one-second metadata drift stays eligible")
        // Multi-file Archive items must not bypass the recording-edition
        // policy already applied to single-file uploads.
        func multiFileEdition(_ filename: String, requestedTitle: String) -> Bool {
            AudioSourceFinder.archiveFileCandidate(
                name: filename, source: "original", sizeBytes: "5000000",
                itemTitle: requestedTitle, itemCreator: "Exact Artist",
                audioFileCount: 2,
                wish: PlaylistWish(title: requestedTitle, artist: "Exact Artist",
                                   album: "", spotifyURL: nil, durationSeconds: 180))
        }
        verify(!multiFileEdition("Exact Song (Live).mp3", requestedTitle: "Exact Song"),
            "multi-file live recording cannot auto-match studio request")
        verify(!multiFileEdition("Exact Song.mp3", requestedTitle: "Exact Song (Live)"),
            "multi-file studio recording cannot auto-match live request")
        verify(!multiFileEdition("Exact Song (Karaoke).mp3", requestedTitle: "Exact Song"),
            "multi-file karaoke recording cannot auto-match studio request")
        verify(multiFileEdition("Exact Song.mp3", requestedTitle: "Exact Song"),
            "multi-file studio original remains eligible")
        // The Spotify request can specify a particular edition even when an
        // independently hosted file has the same base title and artist.
        // Missing edition evidence must require review, not unattended import.
        verify(!AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song.mp3", requestedTitle: "Exact Song (Live)"),
            "generic studio filename cannot satisfy requested live recording")
        verify(!AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song.mp3", requestedTitle: "Exact Song (Remastered)"),
            "generic filename cannot satisfy a requested remaster")
        verify(!AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Live).mp3", requestedTitle: "Exact Song"),
            "live filename cannot satisfy a requested studio recording")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Live).mp3", requestedTitle: "Exact Song (Live)"),
            "matching live edition remains eligible")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song.mp3", requestedTitle: "Exact Song"),
            "ordinary unqualified recordings remain eligible")
        // Canonical edition labels avoid rejecting a correct recording simply
        // because the independent host uses a different standard spelling.
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Remaster).mp3",
            requestedTitle: "Exact Song (Remastered)"),
            "remaster and remastered describe the same recording edition")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Unplugged).mp3",
            requestedTitle: "Exact Song (Acoustic)"),
            "unplugged and acoustic edition aliases agree")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Speed Up).mp3",
            requestedTitle: "Exact Song (Sped Up)"),
            "sped-up spelling variants agree without matching studio audio")
        verify(!AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (2011 Remaster).mp3",
            requestedTitle: "Exact Song (2024 Remaster)"),
            "different remaster years must not auto-match")
        verify(!AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Remastered).mp3",
            requestedTitle: "Exact Song (2024 Remaster)"),
            "missing requested remaster year requires review")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (2024 Remastered).mp3",
            requestedTitle: "Exact Song (2024 Remaster)"),
            "equivalent remaster labels with identical years match")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Remastered).mp3",
            requestedTitle: "Exact Song (Remaster)"),
            "yearless remaster aliases remain eligible")
        verify(!AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Remastered Live).mp3",
            requestedTitle: "Exact Song (Remaster)"),
            "a live remaster cannot match a studio remaster")
        verify(!AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Mono).mp3",
            requestedTitle: "Exact Song (Stereo)"),
            "mono and stereo editions remain distinct")
        verify(!AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Re-recorded).mp3",
            requestedTitle: "Exact Song"),
            "re-recordings cannot silently replace original recordings")
        verify(!AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Nightcore).mp3",
            requestedTitle: "Exact Song (Sped Up)"),
            "nightcore and sped-up editions are not interchangeable")
        // Recording variants can share the same base title and duration.
        for (file, requested) in [
            ("Exact Song (Clean).mp3", "Exact Song"),
            ("Exact Song (Explicit).mp3", "Exact Song"),
            ("Exact Song (Censored).mp3", "Exact Song"),
            ("Exact Song (Deluxe Edition).mp3", "Exact Song"),
            ("Exact Song (Anniversary Edition).mp3", "Exact Song"),
            ("Exact Song (Session Version).mp3", "Exact Song"),
            ("Exact Song (Alternate Mix).mp3", "Exact Song"),
            ("Exact Song.mp3", "Exact Song (Clean)"),
            ("Exact Song.mp3", "Exact Song (Deluxe)")
        ] {
            verify(!AudioSourceFinder.recordingEditionAgrees(
                filename: file, requestedTitle: requested),
                "different recording variants require review: \\(file)")
        }
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Uncensored).mp3",
            requestedTitle: "Exact Song (Explicit)"),
            "explicit and uncensored labels are equivalent")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Deluxe).mp3",
            requestedTitle: "Exact Song (Deluxe Edition)"),
            "equivalent deluxe labels remain eligible")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Exact Song (Clean Edit).mp3",
            requestedTitle: "Exact Song (Clean)"),
            "equivalent clean edit labels remain eligible")
        verify(AudioSourceFinder.recordingEditionAgrees(
            filename: "Deliver.mp3", requestedTitle: "Deliver"),
            "edition words must be matched as whole tokens")
        // An Openverse page without authoritative page_count may be a
        // truncated result set, hiding another version of the same recording.
        verify(!AudioSourceFinder.openversePageConsistent(
            page: 1, pageCount: nil, returned: 1, expectedPageCount: nil),
            "short Openverse page without total cannot authorize unique selection")
        verify(!AudioSourceFinder.openversePageConsistent(
            page: 2, pageCount: nil, returned: 0, expectedPageCount: 2),
            "later Openverse page cannot drop authoritative pagination")
        verify(AudioSourceFinder.openversePageConsistent(
            page: 1, pageCount: 1, returned: 1, expectedPageCount: nil),
            "complete one-page Openverse search remains eligible")
        verify(AudioSourceFinder.openversePageConsistent(
            page: 2, pageCount: 2, returned: 1, expectedPageCount: 2),
            "stable final Openverse page remains eligible")
        verify(!AudioSourceFinder.openversePageConsistent(
            page: 2, pageCount: 3, returned: 1, expectedPageCount: 2),
            "changing Openverse totals invalidate uniqueness")
        print("Audio source discovery validation tests passed")
    }
}
