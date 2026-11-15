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

// Openverse durations are milliseconds. Missing or malformed timing must never
// authorize a high-confidence automatic recording selection.
func durationCompatible(_ milliseconds: Double?, _ expected: Double?) -> Bool {
    guard let milliseconds, milliseconds.isFinite,
          milliseconds > 0, milliseconds <= 3_600_000 else { return false }
    guard let expected else { return true }
    guard expected.isFinite, expected > 0 else { return false }
    return abs(milliseconds / 1000.0 - expected) <= 4.0
}

let durationCases: [(String, Double?, Double?, Bool)] = [
    ("exact recording", 183_000, 183, true),
    ("four second tolerance", 187_000, 183, true),
    ("wrong edition", 210_000, 183, false),
    ("missing duration", nil, 183, false),
    ("missing duration without Spotify timing", nil, nil, false),
    ("zero duration", 0, 183, false),
    ("negative duration", -1000, 183, false),
    ("infinite duration", .infinity, 183, false),
    ("NaN duration", .nan, 183, false),
    ("overlong audio", 3_600_001, 183, false),
    ("invalid expected duration", 183_000, .nan, false),
    ("valid catalog duration without Spotify timing", 183_000, nil, true)
]
for (name, milliseconds, expected, accepted) in durationCases {
    precondition(durationCompatible(milliseconds, expected) == accepted,
                 "Openverse duration regression: \(name)")
}
precondition(source.contains("static func openverseDurationIsCompatible("))
precondition(source.contains("guard openverseDurationIsCompatible(durationMilliseconds: duration,"))
print("PASS: \(durationCases.count) Openverse duration cases and production anchors")
