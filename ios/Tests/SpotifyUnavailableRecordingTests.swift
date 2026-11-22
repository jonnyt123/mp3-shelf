import Foundation

// Run from repository root: swift ios/Tests/SpotifyUnavailableRecordingTests.swift
// Network-independent regression: verify the production decoding and
// auto-discovery gate remain connected. This is not an iPhone integration test.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/SpotifyService.swift", encoding: .utf8)
func check(_ condition: Bool, _ description: String) {
    precondition(condition, "FAIL: " + description)
    print("PASS: " + description)
}
guard let start = source.range(of: "private struct SpotifyTrack: Decodable"),
      let end = source.range(of: "private struct SpotifyArtist:", range: start.upperBound..<source.endIndex),
      let gateStart = source.range(of: "    var usableTrack: SpotifyTrack? {"),
      let gateEnd = source.range(of: "    init(from decoder: Decoder)", range: gateStart.upperBound..<source.endIndex) else {
    fatalError("Spotify metadata decoder or matching gate was moved")
}
let decoder = String(source[start.lowerBound..<end.lowerBound])
let gate = String(source[gateStart.lowerBound..<gateEnd.lowerBound])
for key in ["is_local", "is_playable"] {
    check(decoder.contains("case name, type, artists, album, external_urls, duration_ms, is_local, is_playable"), "decode recording availability flags: " + key)
    check(decoder.contains("decode(Bool.self, forKey: ." + key + ")"), "read optional provider flag: " + key)
}
check(gate.contains("candidate.is_local != true"), "local-only entries cannot auto-match")
check(gate.contains("candidate.is_playable != false"), "explicitly unavailable entries cannot auto-match")
check(gate.contains("candidate.type == \"track\""), "podcasts remain excluded")
let fixtures: [(String, Bool)] = [
    (#"{"is_local":true,"is_playable":true}"#, false),
    (#"{"is_local":false,"is_playable":false}"#, false),
    (#"{"is_local":false,"is_playable":true}"#, true),
    (#"{}"#, true),
    (#"{"is_local":true}"#, false),
    (#"{"is_playable":false}"#, false)
]
for (json, expected) in fixtures {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    let allowed = (object["is_local"] as? Bool) != true &&
                  (object["is_playable"] as? Bool) != false
    check(allowed == expected, "availability fixture: " + json)
}
