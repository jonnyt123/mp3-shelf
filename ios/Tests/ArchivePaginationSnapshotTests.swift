import Foundation

// Offline policy fixture. Run: swift ios/Tests/ArchivePaginationSnapshotTests.swift
// The same checks guard AudioSourceFinder.find before any candidate is returned.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
func check(_ ok: Bool, _ message: String) {
    precondition(ok, "FAIL: " + message)
    print("PASS: " + message)
}
check(source.contains("var expectedArchiveTotal: Int?"), "snapshot total tracked")
check(source.contains("expectedArchiveTotal != total"), "cross-page total drift rejected")
check(source.contains("seenArchiveIdentifiers.insert(entry.identifier).inserted"), "duplicate identifier rejected")
check(source.contains("throw SourceError.unavailable"), "unstable snapshot is retryable")

struct Snapshot {
    var total: Int?
    var seen = Set<String>()
    mutating func accept(total newTotal: Int?, identifiers: [String], page: Int) -> Bool {
        if let newTotal {
            if let total, total != newTotal { return false }
            total = newTotal
        } else if page > 1 && total != nil {
            return false
        }
        for identifier in identifiers {
            if !seen.insert(identifier).inserted { return false }
        }
        return true
    }
}
func pages(_ first: (Int?, [String]), _ second: (Int?, [String])) -> Bool {
    var snapshot = Snapshot()
    return snapshot.accept(total: first.0, identifiers: first.1, page: 1)
        && snapshot.accept(total: second.0, identifiers: second.1, page: 2)
}
check(pages((21, ["a", "b"]), (21, ["c"])), "stable total and unique identifiers")
check(!pages((40, ["a"]), (21, ["b"])), "shrinking total fails")
check(!pages((21, ["a"]), (40, ["b"])), "growing total fails")
check(!pages((21, ["a"]), (21, ["a"])), "cross-page duplicate fails")
check(!pages((21, ["a"]), (nil, ["b"])), "missing later total fails")
check(pages((nil, ["a"]), (nil, ["b"])), "legacy absent totals stay bounded")
check(pages((0, []), (0, [])), "empty snapshot remains valid")
