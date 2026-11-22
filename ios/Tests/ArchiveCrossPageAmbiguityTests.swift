import Foundation

// Run from repository root: swift ios/Tests/ArchiveCrossPageAmbiguityTests.swift
// Source-bound regression plus deterministic candidate inventory fixtures.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
guard let start = source.range(of: "    static func find(for wish: PlaylistWish,"),
      let end = source.range(of: "    static func archiveCandidate", range: start.upperBound..<source.endIndex) else {
    fatalError("Archive discovery boundaries changed")
}
let implementation = String(source[start.lowerBound..<end.lowerBound])
func check(_ condition: Bool, _ description: String) {
    precondition(condition, "FAIL: " + description)
    print("PASS: " + description)
}
check(implementation.contains("for page in 1...maxArchiveSearchPages"),
      "Archive discovery retains bounded pagination")
check(implementation.contains("uniqueCandidates[match.downloadURL] = match"),
      "candidate inventory persists across pages")
check(implementation.contains("if uniqueCandidates.count > 1 { return nil }"),
      "distinct matching files block automatic selection")
check(implementation.contains("if detailLookupFailed || searchIncomplete { throw SourceError.unavailable }"),
      "incomplete metadata lookup prevents unsafe auto-selection")
check(implementation.contains("return uniqueCandidates.count == 1 ? uniqueCandidates.values.first : nil"),
      "selection happens only after the bounded search")
check(implementation.contains("try Task.checkCancellation()"),
      "Archive discovery remains cancellable")
check(!implementation.contains("if let match = archiveCandidate(item, identifier: result.identifier, for: wish) {\n                    return match"),
      "first metadata match no longer bypasses later candidates")

func selection(_ pages: [[String]], failedDetails: Bool = false) throws -> String? {
    var candidates = Set<String>()
    for page in pages {
        for url in page {
            candidates.insert(url)
            if candidates.count > 1 { return nil }
        }
    }
    if failedDetails { throw NSError(domain: "incomplete-metadata", code: 1) }
    return candidates.count == 1 ? candidates.first : nil
}
check(try selection([["a.mp3"], ["a.mp3"]]) == "a.mp3",
      "same file repeated on two pages remains eligible")
check(try selection([["a.mp3"], ["b.mp3"]]) == nil,
      "different file on second page is ambiguous")
check(try selection([[], ["a.mp3"]]) == "a.mp3",
      "second-page-only match remains eligible")
check(try selection([[], []]) == nil,
      "empty catalog remains unavailable")
do {
    _ = try selection([["a.mp3"]], failedDetails: true)
    preconditionFailure("FAIL: incomplete metadata accepted")
} catch {
    print("PASS: incomplete metadata does not authorize selection")
}

check(implementation.contains("var searchIncomplete = false"),
      "Archive scan tracks incomplete coverage")
check(implementation.contains("if page == maxArchiveSearchPages"),
      "full final search page cannot certify uniqueness")
check(implementation.contains("searchIncomplete = true"),
      "request budget exhaustion invalidates automatic selection")
check(implementation.contains("if detailLookupFailed || searchIncomplete"),
      "incomplete scan retries instead of importing a lone match")

func boundedSelection(_ pages: [[String]], totalPages: Int,
                      detailBudget: Int, elapsedBudgetExhausted: Bool = false) throws -> String? {
    var seen = Set<String>()
    var examined = 0
    for page in pages {
        for url in page {
            if examined >= detailBudget { throw NSError(domain: "budget", code: 1) }
            examined += 1
            seen.insert(url)
            if seen.count > 1 { return nil }
        }
    }
    if elapsedBudgetExhausted || totalPages > pages.count {
        throw NSError(domain: "incomplete", code: 2)
    }
    return seen.first
}
check(try boundedSelection([["a.mp3"], ["a.mp3"]], totalPages: 2, detailBudget: 8) == "a.mp3",
      "complete duplicate inventory permits one recording")
check(try boundedSelection([["a.mp3"], ["b.mp3"]], totalPages: 2, detailBudget: 8) == nil,
      "complete conflicting inventory blocks automatic import")
for fixture in [
    (pages: [["a.mp3"]], total: 2, budget: 8, elapsed: false),
    (pages: [["a.mp3", "b.mp3"]], total: 1, budget: 1, elapsed: false),
    (pages: [["a.mp3"]], total: 1, budget: 8, elapsed: true)
] {
    do {
        _ = try boundedSelection(fixture.pages, totalPages: fixture.total,
                                 detailBudget: fixture.budget,
                                 elapsedBudgetExhausted: fixture.elapsed)
        preconditionFailure("FAIL: truncated scan authorized a recording")
    } catch {
        print("PASS: truncated scan remains retryable")
    }
}
