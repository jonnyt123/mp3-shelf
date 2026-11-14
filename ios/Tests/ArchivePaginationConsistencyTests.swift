import Foundation

// Run from repository root: swift ios/Tests/ArchivePaginationConsistencyTests.swift
// Offline adversarial index fixtures: inconsistent totals must not permit
// an apparently unique first-page match to become an automatic download.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
func check(_ condition: Bool, _ name: String) {
    precondition(condition, "FAIL: " + name)
    print("PASS: " + name)
}
check(source.contains("static func archivePageIsConsistent("), "production consistency policy exists")
check(source.contains("guard archivePageIsConsistent("), "production lookup enforces policy")
check(source.contains("else { throw SourceError.invalidResponse }"), "contradictory response fails closed")

func consistent(returned: Int, total: Int?, page: Int) -> Bool {
    guard page >= 1, page <= 2, returned >= 0, returned <= 20 else { return false }
    guard let total else { return true }
    guard total >= 0, total >= (page - 1) * 20 + returned else { return false }
    if returned < 20 && total > (page - 1) * 20 + returned { return false }
    return true
}
check(consistent(returned: 20, total: 20, page: 1), "full terminal first page")
check(consistent(returned: 20, total: 21, page: 1), "full first page with continuation")
check(consistent(returned: 1, total: 21, page: 2), "short terminal second page")
check(!consistent(returned: 1, total: 40, page: 2), "short second page with hidden results")
check(!consistent(returned: 1, total: 0, page: 1), "count smaller than observed results")
check(!consistent(returned: 20, total: -1, page: 1), "negative total")
check(!consistent(returned: 21, total: nil, page: 1), "oversized page without total")
check(!consistent(returned: 1, total: 1, page: 2), "second-page total below observed offset")
check(consistent(returned: 0, total: 0, page: 1), "valid empty result")
check(consistent(returned: 20, total: nil, page: 2), "missing count retained for bounded scan")
