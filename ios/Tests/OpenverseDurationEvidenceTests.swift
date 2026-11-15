import Foundation

// Run from repository root: swift ios/Tests/OpenverseDurationEvidenceTests.swift
// Deterministic offline regression for Openverse exact-recording auto-selection.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
guard let start = source.range(of: "    static func openverseCandidate("),
      let end = source.range(of: "    static let maxOpenversePages", range: start.upperBound..<source.endIndex) else {
    fatalError("Openverse candidate boundaries changed")
}
let production = String(source[start.lowerBound..<end.lowerBound])
func check(_ ok: Bool, _ message: String) {
    precondition(ok, "FAIL: " + message)
    print("PASS: " + message)
}
check(production.contains("if let expected = wish.durationSeconds {"),
      "Spotify duration is a mandatory Openverse match constraint")
check(production.contains("let duration, duration.isFinite, duration > 0 else { return nil }"),
      "missing, nonfinite and nonpositive catalog duration cannot auto-match")
check(production.contains("expected.isFinite, expected > 0"),
      "invalid Spotify duration cannot authorize automatic selection")
check(production.contains("let measured = duration / 1000.0"),
      "Openverse milliseconds are converted explicitly")
check(production.contains("abs(measured - expected) <= 4.0"),
      "duration mismatch is bounded")
check(!production.contains("if let expected = wish.durationSeconds, let duration"),
      "missing catalog duration cannot bypass the duration check")

// Mirror the predicate with independent edge-case inputs. This tests expected
// matching behavior; the source-bound assertions above verify production wiring.
func accepts(expected: Double?, catalogMilliseconds: Double?) -> Bool {
    guard let expected else { return true }
    guard expected.isFinite, expected > 0,
          let duration = catalogMilliseconds, duration.isFinite, duration > 0 else { return false }
    let measured = duration / 1000.0
    return measured.isFinite && measured > 0 && abs(measured - expected) <= 4.0
}
check(accepts(expected: 180, catalogMilliseconds: 180000), "exact duration accepted")
check(accepts(expected: 180, catalogMilliseconds: 183999), "within tolerance accepted")
check(!accepts(expected: 180, catalogMilliseconds: 184001), "outside tolerance rejected")
check(!accepts(expected: 180, catalogMilliseconds: nil), "missing duration rejected")
check(!accepts(expected: 180, catalogMilliseconds: 0), "zero duration rejected")
check(!accepts(expected: 180, catalogMilliseconds: -1000), "negative duration rejected")
check(!accepts(expected: 180, catalogMilliseconds: .nan), "NaN duration rejected")
check(!accepts(expected: 180, catalogMilliseconds: .infinity), "infinite duration rejected")
check(!accepts(expected: .nan, catalogMilliseconds: 180000), "invalid Spotify duration rejected")
check(!accepts(expected: 180, catalogMilliseconds: 180), "seconds mistaken for milliseconds rejected")
check(accepts(expected: nil, catalogMilliseconds: nil),
      "legacy wish without Spotify duration retains manual/other evidence eligibility")
