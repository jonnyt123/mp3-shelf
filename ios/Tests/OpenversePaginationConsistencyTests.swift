import Foundation

// Run from repository root: swift ios/Tests/OpenversePaginationConsistencyTests.swift
// Source-bound regression: contradictory page metadata cannot authorize an
// unattended download even when only one candidate URL was observed.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
guard let helperStart = source.range(of: "    static func openversePageConsistent("),
      let helperEnd = source.range(of: "    static func findOpenverse(", range: helperStart.upperBound..<source.endIndex),
      let searchStart = source.range(of: "    static func findOpenverse("),
      let searchEnd = source.range(of: "    // Wikimedia Commons", range: searchStart.upperBound..<source.endIndex)
else { fatalError("Production pagination helper/search boundaries changed") }
let helper = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
let search = String(source[searchStart.lowerBound..<searchEnd.lowerBound])
precondition(search.contains("guard openversePageConsistent("))
precondition(search.contains("var expectedPageCount: Int?"))
precondition(search.contains("if let count = result.page_count { expectedPageCount = count }"))
precondition(search.contains("throw SourceError.catalogsUnavailable"))
// Compile the actual production helper body, rather than an independently
// reimplemented pagination algorithm.
let program = """
enum Production {
    static let maxOpenversePages = 2
\(helper)
}
let cases: [(Int, Int?, Int, Int?, Bool)] = [
    (1, 2, 50, nil, true),
    (2, 2, 1, 2, true),
    (2, 3, 1, 2, false),
    (2, 1, 1, 1, false),
    (1, 0, 1, nil, false),
    (1, 1, 51, nil, false),
    (1, 1, 1, nil, true),
    (2, nil, 1, 2, false),
    (1, nil, 50, nil, true),
    (1, 2, 0, nil, false)
]
for (page, count, rows, expected, allowed) in cases {
    precondition(Production.openversePageConsistent(
        page: page, pageCount: count, returned: rows,
        expectedPageCount: expected) == allowed)
}
print("PASS: 10 production-helper Openverse pagination fixtures")
"""
let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift")
try program.write(to: path, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: path) }
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", path.path]
try process.run()
process.waitUntilExit()
precondition(process.terminationStatus == 0, "production pagination fixtures failed")
print("PASS: source-bound Openverse pagination regression")
