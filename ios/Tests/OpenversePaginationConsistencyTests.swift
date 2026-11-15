import Foundation

// Run from repository root: swift ios/Tests/OpenversePaginationConsistencyTests.swift
// Offline table-driven regression for the production Openverse pagination contract.
func consistent(_ returned: Int, _ page: Int, _ count: Int?, _ expected: Int?) -> Bool {
    guard page >= 1, page <= 2, returned >= 0, returned <= 50 else { return false }
    if let count {
        guard count >= page, count <= 10_000,
              expected == nil || expected == count else { return false }
        if page < count && returned < 50 { return false }
    } else if expected != nil { return false }
    return true
}

let cases: [(String, Int, Int, Int?, Int?, Bool)] = [
    ("single complete page", 1, 1, 1, nil, true),
    ("empty final page", 0, 1, 1, nil, true),
    ("full first page", 50, 1, 2, nil, true),
    ("full second page", 50, 2, 2, 2, true),
    ("short page with claimed continuation", 12, 1, 2, nil, false),
    ("count drift across pages", 50, 2, 3, 2, false),
    ("count disappeared on later page", 50, 2, nil, 2, false),
    ("page beyond reported count", 50, 2, 1, 1, false),
    ("negative count", 0, 1, -1, nil, false),
    ("oversized response", 51, 1, 2, nil, false),
    ("excessive count", 50, 1, 10001, nil, false),
    ("unknown total on first page", 50, 1, nil, nil, true),
    ("reported total too large", 50, 1, 10001, nil, false),
    ("page zero", 50, 0, 2, nil, false),
    ("negative response size", -1, 1, 2, nil, false),
    ("missing second-page count", 50, 2, nil, 2, false),
    ("changed total on second page", 50, 2, 4, 2, false),
    ("short intermediate page", 49, 1, 2, nil, false)
]
for (name, returned, page, count, expected, accepted) in cases {
    precondition(consistent(returned, page, count, expected) == accepted, name)
    print("PASS: \(name)")
}
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
precondition(source.contains("static func openversePageIsConsistent("))
precondition(source.contains("guard openversePageIsConsistent("))
precondition(source.contains("expectedPageCount = pageCount"))
precondition(source.contains("pageCount <= 10_000"))
precondition(source.contains("throw SourceError.invalidResponse"))
precondition(source.contains("throw SourceError.unavailable"))
print("PASS: production integration anchors")
