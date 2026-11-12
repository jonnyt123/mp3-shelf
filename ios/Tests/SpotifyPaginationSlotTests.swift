import Foundation

// Run with: swift ios/Tests/SpotifyPaginationSlotTests.swift
// Compiles the actual SpotifyPage decoder extracted from the production source.
// No Spotify credentials, network access, Xcode project edits or mock decoder.
enum SpotifyPaginationSlotTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent("ios/MP3Shelf/Services/SpotifyService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        guard let start = source.range(of: "private struct SpotifyPage<T: Decodable>: Decodable {"),
              let end = source.range(of: "private struct SpotifyPlaylistItem: Decodable {"),
              start.lowerBound < end.lowerBound else {
            fatalError("Production SpotifyPage decoder not found")
        }
        guard let typesEnd = source.range(of: "private struct SpotifyTokenResponse: Decodable {"),
              end.lowerBound < typesEnd.lowerBound else {
            fatalError("Production Spotify track decoders not found")
        }
        guard let urlType = source.range(of: "struct SpotifyURLContainer: Decodable { let spotify: String? }") else {
            fatalError("Production Spotify URL container decoder not found")
        }
        let decoder = String(source[urlType]) + "\n" +
            String(source[start.lowerBound..<typesEnd.lowerBound])
            .replacingOccurrences(of: "private struct SpotifyPage", with: "struct SpotifyPage")
            .replacingOccurrences(of: "private struct SpotifyPlaylistItem", with: "struct SpotifyPlaylistItem")
            .replacingOccurrences(of: "private struct SpotifyTrack", with: "struct SpotifyTrack")
            .replacingOccurrences(of: "private struct SpotifyArtist", with: "struct SpotifyArtist")
            .replacingOccurrences(of: "private struct SpotifyAlbum", with: "struct SpotifyAlbum")
        let fixture = #"""
        import Foundation
        struct FixtureTrack: Decodable { let name: String }
        func check(_ condition: Bool, _ description: String) {
            guard condition else { fatalError("FAIL: \(description)") }
            print("PASS: \(description)")
        }
        let data = #"{"items":[{"name":"first"},null,{"name":17},{"name":"last"}],"next":"?limit=4&offset=4"}"#.data(using: .utf8)!
        let page = try JSONDecoder().decode(SpotifyPage<FixtureTrack>.self, from: data)
        check(page.items.map(\.name) == ["first", "last"], "valid neighbors survive invalid slots")
        check(page.rawItemCount == 4, "pagination counts raw slots, not filtered entries")
        check(page.next == "?limit=4&offset=4", "next cursor preserved")
        let empty = try JSONDecoder().decode(SpotifyPage<FixtureTrack>.self,
            from: #"{"items":[null,{},7],"next":null}"#.data(using: .utf8)!)
        check(empty.items.isEmpty && empty.rawItemCount == 3, "all-invalid page still advances by raw slots")
        // A short decoded page must not be mistaken for an exhausted page.
        // All positions, including malformed ones, contribute to the cursor.
        let full = try JSONDecoder().decode(SpotifyPage<FixtureTrack>.self,
            from: #"{"items":[null,{"name":"second"},false,{},null],"next":"?limit=5&offset=5"}"#.data(using: .utf8)!)
        check(full.items.map(\.name) == ["second"] && full.rawItemCount == 5,
              "raw cursor retains all five slots when only one track is usable")
        let lastPage = try JSONDecoder().decode(SpotifyPage<FixtureTrack>.self,
            from: #"{"items":[{"name":"final"}],"next":null}"#.data(using: .utf8)!)
        check(lastPage.rawItemCount == 1 && lastPage.next == nil,
              "short final page terminates without inventing another cursor")
        let emptyPage = try JSONDecoder().decode(SpotifyPage<FixtureTrack>.self,
            from: #"{"items":[],"next":null}"#.data(using: .utf8)!)
        check(emptyPage.rawItemCount == 0 && emptyPage.items.isEmpty,
              "genuinely empty page retains zero raw slots")
        // Deeply malformed neighbors must not shift the pagination cursor.
        let nested = try JSONDecoder().decode(SpotifyPage<FixtureTrack>.self,
            from: #"{"items":[{"name":"before"},{"name":["wrong"]},{"unexpected":{"deep":[1,2,3]}},{"name":"after"}],"next":"?offset=4"}"#.data(using: .utf8)!)
        check(nested.items.map(\.name) == ["before", "after"] && nested.rawItemCount == 4,
              "nested malformed entries preserve neighbors and all raw slots")
        // An unavailable-only page must still advance by the raw slot count.
        let unavailable = try JSONDecoder().decode(SpotifyPage<FixtureTrack>.self,
            from: #"{"items":[null,null,null,null],"next":"?offset=4"}"#.data(using: .utf8)!)
        check(unavailable.items.isEmpty && unavailable.rawItemCount == 4 && unavailable.next != nil,
              "unavailable-only page retains the server cursor")
        // Decode nested envelopes using the actual production model types.
        let mixed = try JSONDecoder().decode(SpotifyPage<SpotifyPlaylistItem>.self,
            from: #"{"items":[{"item":{"name":"Episode","type":"episode","artists":[{"name":"Host"}]},"track":{"name":"Studio Song","type":"track","artists":[{"name":"Artist"}],"duration_ms":201000}},{"item":{"name":123,"artists":[]},"track":{"name":"Fallback","type":"track","artists":[{"name":"Second Artist"}]}},{"track":{"name":"Credits","type":"track","artists":[null,{"name":9},{"name":"Valid Artist"}],"album":{"name":42},"duration_ms":"unknown","external_urls":[]}},{"item":{"name":"Missing Artist","type":"track","artists":[null]}},null],"next":"?limit=5&offset=5"}"#.data(using: .utf8)!)
        check(mixed.rawItemCount == 5 && mixed.items.count == 4,
              "nested decoder retains raw positions and skips null entries")
        let selected = mixed.items.compactMap { entry -> SpotifyTrack? in
            [entry.item, entry.track].compactMap { $0 }.first {
                $0.type == "track" &&
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                ($0.artists ?? []).contains {
                    !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
        }
        check(selected.map(\.name) == ["Studio Song", "Fallback", "Credits"],
              "episode and malformed primary envelopes fall back to usable recordings")
        check(selected[2].artists?.map(\.name) == ["Valid Artist"] &&
              selected[2].album == nil && selected[2].duration_ms == nil &&
              selected[2].external_urls == nil,
              "malformed optional evidence does not erase valid credited artists")
        // Duration is evidence for exact-recording matching, never a reason
        // to auto-select a different version when the provider is malformed.
        let durationCases = try JSONDecoder().decode(SpotifyPage<SpotifyPlaylistItem>.self,
            from: #"{"items":[{"track":{"name":"Negative","type":"track","artists":[{"name":"A"}],"duration_ms":-1000}},{"track":{"name":"Zero","type":"track","artists":[{"name":"A"}],"duration_ms":0}},{"track":{"name":"Overflow","type":"track","artists":[{"name":"A"}],"duration_ms":90000000}},{"track":{"name":"Normal","type":"track","artists":[{"name":"A"}],"duration_ms":212345}}],"next":null}"#.data(using: .utf8)!)
        check(durationCases.rawItemCount == 4 && durationCases.items.count == 4,
              "invalid durations do not discard otherwise usable recordings")
        check(durationCases.items.compactMap(\.track).map(\.duration_ms) == [nil, nil, nil, 212345],
              "negative, zero and implausible durations are excluded from matching evidence")
        check(mixed.next == "?limit=5&offset=5",
              "nested metadata failures do not corrupt continuation cursor")
        do {
            _ = try JSONDecoder().decode(SpotifyPage<FixtureTrack>.self,
                from: #"{"next":null}"#.data(using: .utf8)!)
            fatalError("FAIL: missing items array accepted")
        } catch DecodingError.keyNotFound {
            print("PASS: missing items array rejected")
        }
        do {
            _ = try JSONDecoder().decode(SpotifyPage<FixtureTrack>.self,
                from: #"{"items":[],"next":17}"#.data(using: .utf8)!)
            fatalError("FAIL: non-string pagination cursor accepted")
        } catch DecodingError.typeMismatch {
            print("PASS: non-string pagination cursor rejected")
        }
        do {
            _ = try JSONDecoder().decode(SpotifyPage<FixtureTrack>.self,
                from: #"{"items":{},"next":null}"#.data(using: .utf8)!)
            fatalError("FAIL: malformed items envelope accepted")
        } catch DecodingError.typeMismatch {
            print("PASS: malformed items envelope rejected")
        }
        """#
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotify-page-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: temp) }
        try (decoder + "\n" + fixture).write(to: temp, atomically: true, encoding: .utf8)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["swift", temp.path]
        task.standardOutput = FileHandle.standardOutput
        task.standardError = FileHandle.standardError
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw NSError(domain: "SpotifyPaginationSlotTests", code: Int(task.terminationStatus)) }
    }
}

try SpotifyPaginationSlotTests.main()
