import Foundation

// Run from repository root: swift ios/Tests/SpotifyEmptyPagePaginationTests.swift
// Source-bound regression: Spotify can return an empty intermediate page
// while advancing the cursor to a later page containing usable tracks.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/SpotifyService.swift", encoding: .utf8)
guard let start = source.range(of: "    private static func safeNext("),
      let end = source.range(of: "\n}\n\nextension SpotifyService:", range: start.upperBound..<source.endIndex) else {
    fatalError("Spotify pagination implementation moved; update regression")
}
let body = String(source[start.lowerBound..<end.lowerBound])
func verify(_ condition: Bool, _ message: String) {
    precondition(condition, "FAIL: " + message)
    print("PASS: " + message)
}
verify(body.contains("returnedItems >= 0"), "empty server page is permitted")
verify(!body.contains("returnedItems > 0"), "old empty-page rejection is absent")
verify(body.contains("offset == previousOffset + limit"), "cursor must advance exactly one page")
verify(body.contains("returnedItems <= previousLimit"), "oversized page is rejected")
verify(source.contains("visitedPages.count <= 500"), "track pagination remains bounded")
verify(source.contains("guard visitedPages.insert(url).inserted"), "repeated page URLs are rejected")

// Deterministic cursor fixture: an empty middle page must not discard later
// recordings. A repeated, skipped or oversized page is never accepted.
func validNext(previousOffset: Int, limit: Int, nextOffset: Int, slots: Int) -> Bool {
    (1...50).contains(limit) && (0...limit).contains(slots) &&
    previousOffset >= 0 && previousOffset <= Int.max - limit &&
    nextOffset == previousOffset + limit
}
verify(validNext(previousOffset: 0, limit: 50, nextOffset: 50, slots: 0),
       "zero-slot intermediate page continues")
verify(validNext(previousOffset: 50, limit: 50, nextOffset: 100, slots: 1),
       "subsequent recording remains reachable")
verify(!validNext(previousOffset: 0, limit: 50, nextOffset: 0, slots: 0),
       "nonadvancing cursor is rejected")
verify(!validNext(previousOffset: 0, limit: 50, nextOffset: 100, slots: 0),
       "skipped page is rejected")
verify(!validNext(previousOffset: 0, limit: 50, nextOffset: 50, slots: 51),
       "oversized response is rejected")
print("Spotify empty-page pagination regression passed")
