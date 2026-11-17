import Foundation

// Run from repository root: swift ios/Tests/WebAudioISODurationFieldTests.swift
// Static source contract plus deterministic negative recording-duration fixtures.
// The full production matcher requires the native app dependency graph.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
guard let start = source.range(of: "    private static func durationMatches("),
      let end = source.range(of: "    static func recordingDurationEvidenceMatches(", range: start.upperBound..<source.endIndex) else {
    fatalError("Web duration matcher boundaries changed")
}
let implementation = String(source[start.lowerBound..<end.lowerBound])
func check(_ value: Bool, _ message: String) {
    precondition(value, "FAIL: " + message)
    print("PASS: " + message)
}
check(implementation.contains("minutes < 60, secondsField < 60"),
      "production ISO parser rejects overflowing minute and second fields")
check(implementation.contains("hours.isFinite, minutes.isFinite, secondsField.isFinite"),
      "production ISO parser checks finite components")
check(implementation.contains("seconds = hours * 3600 + minutes * 60 + secondsField"),
      "production ISO parser computes duration from validated components")
check(implementation.contains("abs($0 - seconds) <= 4"),
      "production matching retains Spotify duration tolerance")

func isoDuration(_ text: String) -> Double? {
    let regex = try! NSRegularExpression(pattern:
        #"^PT(?:(\\d+(?:\\.\\d+)?)H)?(?:(\\d+(?:\\.\\d+)?)M)?(?:(\\d+(?:\\.\\d+)?)S)?$"#)
    let upper = text.uppercased()
    let ns = upper as NSString
    guard let match = regex.firstMatch(in: upper, range: NSRange(location: 0, length: ns.length)) else { return nil }
    func component(_ i: Int) -> Double {
        let range = match.range(at: i)
        return range.location == NSNotFound ? 0 : Double(ns.substring(with: range)) ?? 0
    }
    let h = component(1), m = component(2), s = component(3)
    guard h.isFinite, m.isFinite, s.isFinite, h >= 0, m >= 0, s >= 0,
          m < 60, s < 60 else { return nil }
    let total = h * 3600 + m * 60 + s
    return total.isFinite && total > 0 ? total : nil
}
for (value, expected) in [("PT3M30S", 210.0), ("PT1H2M3.5S", 3723.5),
                          ("PT0.5H", 1800.0), ("PT59.99S", 59.99)] {
    check(abs((isoDuration(value) ?? -1) - expected) < 0.001, "valid duration " + value)
}
for value in ["PT1M90S", "PT2H75M", "PT60M", "PT60S", "PT1M60S",
              "PT999999999999999999999H", "PT", "PT-3M", "PT1MNaNS"] {
    check(isoDuration(value) == nil, "invalid duration rejected: " + value)
}
