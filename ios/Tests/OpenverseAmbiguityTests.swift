import Foundation

// Run from repository root: swift ios/Tests/OpenverseAmbiguityTests.swift
// Source-bound regression for a false-positive auto-download: page one can
// contain one exact artist/title match while page two or the broad query
// contains a different recording. Never select the first page prematurely.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
guard let start = source.range(of: "    static func findOpenverse(for wish: PlaylistWish,"),
      let end = source.range(of: "    // Wikimedia Commons", range: start.upperBound..<source.endIndex) else {
    fatalError("Openverse discovery boundaries changed")
}
let implementation = String(source[start.lowerBound..<end.lowerBound])
func check(_ condition: Bool, _ description: String) {
    precondition(condition, "FAIL: " + description)
    print("PASS: " + description)
}
check(implementation.contains("for fieldSearch in [true, false]"),
      "both focused and broad queries are inspected")
check(implementation.contains("for page in 1...maxOpenversePages"),
      "each query has a bounded page budget")
check(implementation.contains("candidates[match.downloadURL.absoluteString] = match"),
      "candidate identities are deduplicated across pages")
check(implementation.contains("if candidates.count > 1 { return nil }"),
      "different recordings are not selected automatically")
check(implementation.contains("if let firstSearchError { throw firstSearchError }"),
      "partial provider failure cannot silently authorize auto-import")
check(implementation.contains("try Task.checkCancellation()"),
      "batch discovery remains cancellable")
check(!implementation.contains("if unique.count == 1 { return unique.values.first?.first }"),
      "first-page match is not accepted prematurely")

// Deterministic multi-page inventory cases exercise the expected uniqueness
// contract independently of network access. Production wiring is checked above.
func selection(_ pages: [[String]]) -> String? {
    var candidates = Set<String>()
    for page in pages {
        for url in page {
            candidates.insert(url)
            if candidates.count > 1 { return nil }
        }
    }
    return candidates.count == 1 ? candidates.first : nil
}
check(selection([["https://audio.example/a.mp3"], ["https://audio.example/a.mp3"]]) != nil,
      "duplicate URL on two pages remains unambiguous")
check(selection([["https://audio.example/a.mp3"], ["https://audio.example/b.mp3"]]) == nil,
      "different URL on later page blocks automatic selection")
check(selection([[], ["https://audio.example/a.mp3"]]) != nil,
      "later-page single candidate remains eligible")
check(selection([[], []]) == nil, "no match remains unavailable")

check(implementation.contains("if page >= maxOpenversePages && hasMorePages"),
      "last inspected page rejects a catalog reporting further unseen results")
check(implementation.contains("throw SourceError.catalogsUnavailable"),
      "page-budget exhaustion remains retryable rather than auto-selecting")
check(implementation.contains("result.page_count.map { page < $0 }"),
      "explicit catalog page count governs completion")
check(implementation.contains("result.results.count >= 50"),
      "full-page fallback cannot silently imply a completed search")

// Offline pagination boundary fixtures. A unique URL is not sufficient when
// unexamined catalog pages might contain a conflicting recording.
func completeScan(page: Int, pageCount: Int?, returned: Int, budget: Int = 2) -> Bool {
    let hasMore = pageCount.map { page < $0 } ?? (returned >= 50)
    return !(page >= budget && hasMore)
}
check(!completeScan(page: 2, pageCount: 3, returned: 1),
      "third advertised page makes a single match unsafe")
check(completeScan(page: 2, pageCount: 2, returned: 1),
      "terminal second page permits unique-match evaluation")
check(!completeScan(page: 2, pageCount: nil, returned: 50),
      "unknown page count and full second page remain incomplete")
check(completeScan(page: 2, pageCount: nil, returned: 12),
      "short final page terminates an uncounted result set")
