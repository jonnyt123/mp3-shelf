import Foundation

// Run from repository root: swift ios/Tests/AudiusPaginationAmbiguityTests.swift
// Deterministic, network-independent pagination and selection regression.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), "FAIL: " + label)
    print("PASS: " + label)
}
check(source.contains("static let maxAudiusPages = 2"), "bounded Audius page budget")
check(source.contains("URLQueryItem(name: \"offset\""), "Audius offset pagination")
check(source.contains("audiusSearchURL(for: wish, page: page)"), "production requests each page")
check(source.contains("if candidates.count > 1 { return nil }"), "different recordings reject auto-selection")
check(source.contains("if audiusHasUninspectedResults(returned: response.data.count, page: page)"), "incomplete final page blocks auto-selection")
check(source.contains("try Task.checkCancellation()"), "cancellation retained")

struct Page { let urls: [String]; let returned: Int }
enum Outcome: Equatable { case selected(String), ambiguous, incomplete, unavailable }
func resolve(_ pages: [Page], pageSize: Int = 25, limit: Int = 2) -> Outcome {
    var seen = Set<String>()
    for (index, page) in pages.prefix(limit).enumerated() {
        for url in page.urls {
            seen.insert(url)
            if seen.count > 1 { return .ambiguous }
        }
        if page.returned >= pageSize && index + 1 >= limit { return .incomplete }
        if page.returned < pageSize { break }
    }
    return seen.first.map(Outcome.selected) ?? .unavailable
}
check(resolve([Page(urls: ["a"], returned: 1)]) == .selected("a"),
      "one short page can select a unique recording")
check(resolve([Page(urls: ["a"], returned: 25), Page(urls: ["b"], returned: 1)]) == .ambiguous,
      "second-page conflicting recording blocks selection")
check(resolve([Page(urls: ["a"], returned: 25), Page(urls: ["a"], returned: 1)]) == .selected("a"),
      "duplicate URL across pages remains one recording")
check(resolve([Page(urls: ["a"], returned: 25), Page(urls: [], returned: 25)]) == .incomplete,
      "full final page cannot certify uniqueness")
check(resolve([Page(urls: [], returned: 25), Page(urls: [], returned: 0)]) == .unavailable,
      "empty terminal page yields unavailable")
check(resolve([Page(urls: ["a"], returned: 25), Page(urls: ["b"], returned: 25)]) == .ambiguous,
      "conflicting candidate takes precedence over incomplete page")
