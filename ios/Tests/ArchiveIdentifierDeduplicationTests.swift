import Foundation

// Run from repository root: swift ios/Tests/ArchiveIdentifierDeduplicationTests.swift
// Verify that the production Archive scan deduplicates identifiers before
// applying its metadata-request budget, without treating unseen rows as safe.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
guard let start = source.range(of: "    static func find(for wish: PlaylistWish,"),
      let end = source.range(of: "    static func archiveDurationSeconds", range: start.upperBound..<source.endIndex) else {
    fatalError("Archive scan source boundaries changed")
}
let scan = String(source[start.lowerBound..<end.lowerBound])
func check(_ value: Bool, _ label: String) {
    precondition(value, "FAIL: " + label)
    print("PASS: " + label)
}
check(scan.contains("var inspectedIdentifiers: Set<String> = []"),
      "identifier inventory persists across Archive pages")
check(scan.contains("!inspectedIdentifiers.contains(result.identifier)"),
      "repeated identifiers are skipped before budget accounting")
check(scan.contains("inspectedIdentifiers.insert(result.identifier)"),
      "unique identifiers are recorded before metadata requests")
check(scan.contains("searchIncomplete = true"),
      "uninspected distinct identifiers still invalidate selection")

enum ScanResult: Equatable { case complete(Int), incomplete }
func scanPages(_ pages: [[String]], budgetPerPage: Int) -> ScanResult {
    var seen = Set<String>()
    for page in pages {
        var requests = 0
        for id in page {
            guard !id.isEmpty, !seen.contains(id) else { continue }
            guard requests < budgetPerPage else { return .incomplete }
            seen.insert(id)
            requests += 1
        }
    }
    return .complete(seen.count)
}
check(scanPages([["a", "a", "b"], ["b", "a", "c"]], budgetPerPage: 2) == .complete(3),
      "cross-page duplicate rows do not consume lookup budget")
check(scanPages([["a", "a", "b", "c"]], budgetPerPage: 2) == .incomplete,
      "distinct uninspected recording remains retryable")
check(scanPages([["a", "a", "a"]], budgetPerPage: 1) == .complete(1),
      "repeated single recording does not become false unavailable")
