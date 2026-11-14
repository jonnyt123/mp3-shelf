import Foundation

// Run from repository root: swift ios/Tests/PCMEOFBoundaryTests.swift
// Portable source-contract and boundary-model regression; not an AVFoundation test.
let path = "ios/MP3Shelf/Services/MusicLibrary.swift"
let source = try String(contentsOfFile: path, encoding: .utf8)
guard let converterStart = source.range(of: "private final class ShelfPCMConversion {") else {
    fatalError("Production PCM converter not found")
}
let converter = source[converterStart.lowerBound...]
let required = [
    "let remaining = state.file.length - state.file.framePosition",
    "guard remaining > 0 else { return 0 }",
    "AVAudioFrameCount(min(Int64(capacity), remaining))",
    "if buffer.frameLength == 0 { return 0 }"
]
for token in required {
    precondition(converter.contains(token), "Missing production EOF safeguard: \(token)")
}
precondition(!converter.contains("read(into: buffer, frameCount: AVAudioFrameCount(capacity))"),
             "Converter must not request unbounded frames")

// Model the production bounds against zero, partial, and full-buffer reads.
func requestedFrames(length: Int64, position: Int64, capacity: Int64) -> Int64 {
    precondition(capacity > 0 && position >= 0 && length >= 0)
    let remaining = length - position
    guard remaining > 0 else { return 0 }
    return min(capacity, remaining)
}
let cases: [(Int64, Int64, Int64, Int64)] = [
    (0, 0, 4096, 0),
    (1000, 1000, 4096, 0),
    (1000, 1001, 4096, 0),
    (1000, 999, 4096, 1),
    (4097, 4096, 4096, 1),
    (8192, 0, 4096, 4096),
    (8192, 4096, 4096, 4096),
    (8192, 8192, 4096, 0),
    (2000, 1000, 256, 256)
]
for (length, position, capacity, expected) in cases {
    precondition(requestedFrames(length: length, position: position, capacity: capacity) == expected,
                 "Wrong EOF bound at \(position)/\(length)")
}
print("PASS: production converter EOF contract and \(cases.count) boundary cases")
