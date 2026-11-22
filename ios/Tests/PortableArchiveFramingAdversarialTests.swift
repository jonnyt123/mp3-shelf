import Foundation

// Standalone archive-framing rejection fixture. Run with:
// swift ios/Tests/PortableArchiveFramingAdversarialTests.swift
// This is a model of the portable v1 framing contract, NOT a production invocation.
enum FramingError: Error { case invalid }
let signature = Data("MP3SHELF1\n".utf8)
let maximumManifest = 4 * 1024 * 1024

func framed(_ manifest: Data, _ payload: Data = Data([0x49, 0x44, 0x33, 0x04])) -> Data {
    precondition(manifest.count <= maximumManifest)
    var bytes = signature
    let count = UInt32(manifest.count)
    for shift in stride(from: 0, through: 24, by: 8) {
        bytes.append(UInt8(truncatingIfNeeded: count >> shift))
    }
    bytes.append(manifest)
    bytes.append(payload)
    return bytes
}

func decodeFrame(_ bytes: Data) throws -> (manifest: Data, payload: Data) {
    let prefixSize = signature.count + 4
    guard bytes.count >= prefixSize, bytes.prefix(signature.count) == signature else {
        throw FramingError.invalid
    }
    var length: UInt32 = 0
    for i in 0..<4 {
        length |= UInt32(bytes[signature.count + i]) << (i * 8)
    }
    guard length > 0, length <= UInt32(maximumManifest),
          Int(length) <= bytes.count - prefixSize else {
        throw FramingError.invalid
    }
    let end = prefixSize + Int(length)
    let manifest = bytes.subdata(in: prefixSize..<end)
    guard let value = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
          value["schema"] as? String == "mp3-shelf-backup",
          value["version"] as? Int == 1,
          value["tracks"] is [Any],
          value["playlists"] is [Any] else {
        throw FramingError.invalid
    }
    return (manifest, bytes.subdata(in: end..<bytes.count))
}

func mustReject(_ name: String, _ data: Data) {
    do { _ = try decodeFrame(data); fatalError("accepted \(name)") }
    catch FramingError.invalid { }
    catch { fatalError("unexpected error for \(name): \(error)") }
}

let json = Data(#"{"schema":"mp3-shelf-backup","version":1,"tracks":[],"playlists":[]}"#.utf8)
let valid = framed(json)
let result = try decodeFrame(valid)
precondition(result.manifest == json && result.payload == Data([0x49, 0x44, 0x33, 0x04]))
var rejected = 0

// Every truncated framing prefix must fail, even when the suffix could be JSON.
for size in 0..<(signature.count + 4) {
    mustReject("truncated header \(size)", Data(valid.prefix(size)))
    rejected += 1
}
for position in signature.indices {
    var changed = valid
    changed[position] ^= 0x20
    mustReject("signature byte \(position)", changed)
    rejected += 1
}
// The 32-bit manifest length is little-endian. Reject oversized, zero,
// truncated and forged values rather than consuming media as JSON.
for length in [UInt32(0), 1, 2, UInt32(maximumManifest + 1), UInt32.max] {
    var changed = valid
    for index in 0..<4 {
        changed[signature.count + index] = UInt8(truncatingIfNeeded: length >> (index * 8))
    }
    mustReject("forged length \(length)", changed)
    rejected += 1
}
// Truncate each JSON byte while keeping its original declared size. The
// media tail is removed to prevent a truncated JSON from borrowing audio.
for size in 0..<json.count {
    mustReject("truncated manifest \(size)", Data(valid.prefix(signature.count + 4 + size)))
    rejected += 1
}
let invalidManifests = [
    Data(), Data("null".utf8), Data("[]".utf8),
    Data(#"{"schema":"mp3-shelf-backup","version":2,"tracks":[],"playlists":[]}"#.utf8),
    Data(#"{"schema":"wrong","version":1,"tracks":[],"playlists":[]}"#.utf8),
    Data(#"{"schema":"mp3-shelf-backup","version":1,"tracks":{},"playlists":[]}"#.utf8),
    Data(#"{"schema":"mp3-shelf-backup","version":1,"tracks":[],"playlists":{}}"#.utf8),
    Data([0xff, 0xfe, 0xfd])
]
for (index, manifest) in invalidManifests.enumerated() {
    mustReject("invalid manifest \(index)", framed(manifest))
    rejected += 1
}
// A byte-swapped length is not a valid alternate interpretation.
var swapped = valid
let size = UInt32(json.count)
for index in 0..<4 {
    swapped[signature.count + index] = UInt8(truncatingIfNeeded: size >> ((3 - index) * 8))
}
mustReject("big endian length", swapped)
rejected += 1

// Preserve opaque media bytes exactly, including an embedded archive signature,
// binary zeros and a payload large enough to cross common buffer boundaries.
for payload in [
    Data(),
    Data(repeating: 0, count: 65_537),
    signature + json,
    Data([0x00, 0xff, 0x7f, 0x80, 0x0a, 0x00])
] {
    let decoded = try decodeFrame(framed(json, payload))
    precondition(decoded.manifest == json)
    precondition(decoded.payload == payload, "opaque payload was reinterpreted")
}
// The declared JSON region must be complete, not a valid prefix followed by
// garbage. Audio bytes after that region cannot rescue malformed JSON.
let malformedPrefix = Data(#"{"schema":"mp3-shelf-backup","version":1,"tracks":[],"#.utf8)
mustReject("partial manifest before audio", framed(malformedPrefix, Data([0x49, 0x44, 0x33])))
rejected += 1
mustReject("JSON object with trailing garbage", framed(json + Data("garbage".utf8)))
rejected += 1


// Independently model the byte-range contract before any restore writes.
// The production reader must reject overlapping, out-of-bounds, negative and
// zero-length media slices even when the framing and JSON are otherwise valid.
struct CheckedPart {
    let offset: Int64
    let length: Int64
}
func validateParts(_ parts: [CheckedPart], payloadLength: Int64) throws {
    guard payloadLength >= 0 else { throw FramingError.invalid }
    var intervals: [(Int64, Int64)] = []
    for part in parts {
        guard part.offset >= 0, part.length > 0,
              part.offset <= payloadLength,
              part.length <= payloadLength - part.offset else {
            throw FramingError.invalid
        }
        intervals.append((part.offset, part.offset + part.length))
    }
    intervals.sort { $0.0 < $1.0 }
    for i in 1..<intervals.count where intervals[i].0 < intervals[i - 1].1 {
        throw FramingError.invalid
    }
}
func mustRejectParts(_ name: String, _ parts: [CheckedPart], _ payloadLength: Int64) {
    do { try validateParts(parts, payloadLength: payloadLength); fatalError("accepted \\(name)") }
    catch FramingError.invalid { }
    catch { fatalError("unexpected range error for \\(name): \\(error)") }
}
let adjacent = [CheckedPart(offset: 0, length: 4), CheckedPart(offset: 4, length: 6)]
try validateParts(adjacent, payloadLength: 10)
try validateParts([CheckedPart(offset: 1, length: 2)], payloadLength: 10)
try validateParts([], payloadLength: 0)
for (name, parts, size) in [
    ("negative offset", [CheckedPart(offset: -1, length: 2)], Int64(10)),
    ("negative length", [CheckedPart(offset: 0, length: -1)], Int64(10)),
    ("empty audio", [CheckedPart(offset: 0, length: 0)], Int64(10)),
    ("past end", [CheckedPart(offset: 9, length: 2)], Int64(10)),
    ("overflow", [CheckedPart(offset: Int64.max, length: Int64.max)], Int64.max),
    ("duplicate", [CheckedPart(offset: 0, length: 4), CheckedPart(offset: 0, length: 4)], Int64(10)),
    ("partial overlap", [CheckedPart(offset: 0, length: 5), CheckedPart(offset: 4, length: 2)], Int64(10)),
    ("nested overlap", [CheckedPart(offset: 0, length: 9), CheckedPart(offset: 2, length: 2)], Int64(10)),
    ("negative payload", [CheckedPart(offset: 0, length: 1)], Int64(-1))
] {
    mustRejectParts(name, parts, size)
    rejected += 1
}

precondition(try decodeFrame(valid).payload == result.payload, "mutations changed valid baseline")
print("PASS: \(rejected) malformed archive framing cases rejected")
print("LIMITATION: standalone framing model; production restore and iPhone execution UNVERIFIED")
