import Foundation

// Run from repository root: swift ios/Tests/ArchiveResultCountTests.swift
// Archive search returns numFound (total matches), which can terminate a
// full page without implying an uninspected third page.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
func check(_ condition: Bool, _ message: String) {
    precondition(condition, "FAIL: " + message)
    print("PASS: " + message)
}
check(source.contains("let numFound: Int?"), "Archive total is decoded")
check(source.contains("search.response.numFound.map { inspectedThrough < $0 }"),
      "total count controls whether more pages remain")
check(source.contains("?? (search.response.docs.count >= 20)"),
      "missing count conservatively treats full pages as incomplete")
check(source.contains("if page == maxArchiveSearchPages {\n                searchIncomplete = true"),
      "exhausted page budget is retryable")

// Deterministic offline pagination fixtures, independent of Archive network.
func hasMore(page: Int, returned: Int, total: Int?) -> Bool {
    let inspectedThrough = page * 20
    return total.map { inspectedThrough < $0 } ?? (returned >= 20)
}
check(!hasMore(page: 1, returned: 20, total: 20),
      "exactly 20 results: full first page is terminal")
check(hasMore(page: 1, returned: 20, total: 21),
      "21 results: second page must be inspected")
check(!hasMore(page: 2, returned: 20, total: 40),
      "exactly 40 results: full second page is terminal")
check(hasMore(page: 2, returned: 20, total: 41),
      "41 results: bounded scan cannot certify uniqueness")
check(hasMore(page: 2, returned: 20, total: nil),
      "unknown total and full second page remain incomplete")
check(!hasMore(page: 2, returned: 7, total: nil),
      "unknown total and short final page are complete")
check(hasMore(page: 1, returned: 19, total: 100),
      "authoritative total overrides unexpectedly short page")
