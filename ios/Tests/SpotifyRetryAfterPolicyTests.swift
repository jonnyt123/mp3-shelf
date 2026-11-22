import Foundation

// Run from repository root: swift ios/Tests/SpotifyRetryAfterPolicyTests.swift
// Offline source-bound regression: compile and exercise the actual policy body
// without importing UIKit, AuthenticationServices, or making network requests.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/SpotifyService.swift", encoding: .utf8)
let marker = "    nonisolated static func boundedRetryAfter("
guard let start = source.range(of: marker),
      let end = source.range(of: "\n    private func request<T: Decodable>", range: start.upperBound..<source.endIndex),
      source.contains("Self.boundedRetryAfter(header, now: Date())"),
      source.contains("Self.boundedRetryAfter(value, now: Date())") else {
    fatalError("Spotify Retry-After policy is missing or disconnected from API or OAuth HTTP 429 handlers")
}
let implementation = String(source[start.lowerBound..<end.lowerBound])
let fixture = """
import Foundation
struct SpotifyRetryAfterFixture {
\(implementation)
}
let now = Date(timeIntervalSince1970: 1_700_000_000)
func expect(_ value: String, _ expected: Int?) {
    let actual = SpotifyRetryAfterFixture.boundedRetryAfter(value, now: now)
    precondition(actual == expected, "Retry-After \\(value): got \\(String(describing: actual)), expected \\(String(describing: expected))")
}
expect("0", 1)
expect("10", 10)
expect("11", nil)
expect("-1", nil)
expect("nonsense", nil)
let formatter = DateFormatter()
formatter.locale = Locale(identifier: "en_US_POSIX")
formatter.timeZone = TimeZone(secondsFromGMT: 0)
formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
expect(formatter.string(from: now.addingTimeInterval(4)), 4)
expect(formatter.string(from: now.addingTimeInterval(11)), nil)
expect(formatter.string(from: now.addingTimeInterval(-5)), nil)
print("PASS: Spotify Retry-After delta/date bounds and HTTP 429 wiring")
"""
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift")
try fixture.write(to: temporary, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: temporary) }
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", temporary.path]
try process.run()
process.waitUntilExit()
precondition(process.terminationStatus == 0, "Spotify Retry-After executable regression failed")
