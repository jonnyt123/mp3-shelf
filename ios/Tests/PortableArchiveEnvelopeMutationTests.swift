import Foundation

// Standalone adversarial fixture for the portable v1 envelope.
// Run: swift ios/Tests/PortableArchiveEnvelopeMutationTests.swift
// This is a format-contract fixture, not an invocation of production restore.
private let magic = Data("MP3SHELF1\n".utf8)
private let manifestLimit = 4 * 1024 * 1024
private enum Invalid: Error { case envelope }
private struct Part: Codable {
    let offset: Int64
    let length: Int64
    let type: String
}
private struct Track: Codable {
    let id: String
    let audio: Part
}
private struct Playlist: Codable {
    let id: String
    let trackIds: [String]
}
private struct Manifest: Codable {
    let schema: String
    let version: Int
    let tracks: [Track]
    let playlists: [Playlist]
}
private func encode(_ manifest: Manifest, payload: Data) throws -> Data {
    let json = try JSONEncoder().encode(manifest)
    precondition(json.count <= manifestLimit)
    let count = UInt32(json.count)
    var bytes = magic
    bytes.append(contentsOf: [
        UInt8(truncatingIfNeeded: count),
        UInt8(truncatingIfNeeded: count >> 8),
        UInt8(truncatingIfNeeded: count >> 16),
        UInt8(truncatingIfNeeded: count >> 24)
    ])
    bytes.append(json)
    bytes.append(payload)
    return bytes
}
private func decode(_ bytes: Data) throws -> [String: Data] {
    let header = magic.count + 4
    guard bytes.count >= header,
          bytes.prefix(magic.count) == magic else { throw Invalid.envelope }
    let length = (0..<4).reduce(UInt32(0)) { partial, index in
        partial | (UInt32(bytes[magic.count + index]) << (index * 8))
    }
    guard length > 0, length <= manifestLimit,
          Int(length) <= bytes.count - header else { throw Invalid.envelope }
    let start = header
    let end = start + Int(length)
    let manifest = try JSONDecoder().decode(Manifest.self, from: bytes.subdata(in: start..<end))
    guard manifest.schema == "mp3-shelf-backup", manifest.version == 1,
          Set(manifest.tracks.map(\.id)).count == manifest.tracks.count,
          Set(manifest.playlists.map(\.id)).count == manifest.playlists.count else {
        throw Invalid.envelope
    }
    let ids = Set(manifest.tracks.map(\.id))
    guard manifest.playlists.allSatisfy({ $0.trackIds.allSatisfy(ids.contains) }) else {
        throw Invalid.envelope
    }
    let payload = bytes.subdata(in: end..<bytes.count)
    var ranges: [(Int, Int, String)] = []
    for track in manifest.tracks {
        let part = track.audio
        guard part.offset >= 0, part.length > 0,
              part.offset <= Int64(payload.count),
              part.length <= Int64(payload.count) - part.offset else {
            throw Invalid.envelope
        }
        ranges.append((Int(part.offset), Int(part.offset + part.length), track.id))
    }
    ranges.sort { $0.0 < $1.0 }
    var cursor = 0
    var output: [String: Data] = [:]
    for (start, end, id) in ranges {
        guard start == cursor, output[id] == nil else { throw Invalid.envelope }
        output[id] = payload.subdata(in: start..<end)
        cursor = end
    }
    guard cursor == payload.count else { throw Invalid.envelope }
    return output
}
private func rejects(_ label: String, _ bytes: Data) {
    do {
        _ = try decode(bytes)
        fatalError("FAIL: accepted \(label)")
    } catch Invalid.envelope {
    } catch DecodingError.dataCorrupted {
    } catch DecodingError.keyNotFound {
    } catch DecodingError.typeMismatch {
    } catch DecodingError.valueNotFound {
    } catch {
        fatalError("FAIL: unexpected error for \(label): \(error)")
    }
}
private let payload = Data([0x49, 0x44, 0x33, 0x01, 0x02, 0x49, 0x44, 0x33, 0x03])
private let first = Track(id: "first", audio: Part(offset: 0, length: 5, type: "audio/mpeg"))
private let second = Track(id: "second", audio: Part(offset: 5, length: 4, type: "audio/mpeg"))
private func manifest(_ tracks: [Track] = [first, second],
                      _ links: [String] = ["second", "first", "second"]) -> Manifest {
    Manifest(schema: "mp3-shelf-backup", version: 1, tracks: tracks,
             playlists: [Playlist(id: "list", trackIds: links)])
}
let valid = try encode(manifest(), payload: payload)
let restored = try decode(valid)
precondition(restored["first"] == payload.prefix(5))
precondition(restored["second"] == payload.suffix(4))
rejects("wrong magic", Data("MP3SHELF0\n".utf8) + valid.dropFirst(magic.count))
rejects("truncated header", Data(valid.prefix(magic.count + 2)))
rejects("truncated manifest", Data(valid.prefix(magic.count + 4 + 2)))
var oversizedHeader = valid
oversizedHeader.replaceSubrange(magic.count..<(magic.count + 4), with: [255, 255, 255, 127])
rejects("oversized manifest length", oversizedHeader)
rejects("trailing payload", valid + Data([0xff]))
rejects("truncated payload", Data(valid.dropLast()))
rejects("overlapping parts", try encode(manifest([first,
    Track(id: "second", audio: Part(offset: 4, length: 5, type: "audio/mpeg"))]), payload: payload))
rejects("gap in parts", try encode(manifest([first,
    Track(id: "second", audio: Part(offset: 6, length: 3, type: "audio/mpeg"))]), payload: payload))
rejects("duplicate owner", try encode(manifest([first, first]), payload: payload))
rejects("dangling playlist", try encode(manifest([first, second], ["missing"]), payload: payload))
rejects("negative range", try encode(manifest([
    Track(id: "first", audio: Part(offset: -1, length: 5, type: "audio/mpeg")), second
]), payload: payload))
rejects("overflow range", try encode(manifest([
    Track(id: "first", audio: Part(offset: Int64.max, length: Int64.max, type: "audio/mpeg")), second
]), payload: payload))

// Each case mutates the actual binary envelope rather than a predecoded model.
for index in 0..<min(512, valid.count) {
    var mutation = valid
    mutation.remove(at: index)
    // Removing one byte from the manifest or media must never silently
    // preserve the original two byte-exact audio recordings.
    if let decoded = try? decode(mutation) {
        precondition(decoded != restored, "FAIL: deletion preserved original audio at \(index)")
    }
}
print("PASS: portable envelope corruption, manifest boundaries and byte-exact deletion mutations")


// Verify that reordering manifest records cannot change the bytes assigned
// to each stable track ID; offsets, not array position, define ownership.
let reversed = try encode(manifest([second, first]), payload: payload)
precondition(try decode(reversed) == restored, "FAIL: manifest order changed media ownership")

// Exhaustively test single-byte payload substitution. The v1 envelope does
// not authenticate media bytes: these substitutions remain structurally valid.
// Keep this explicit so a structural PASS is never reported as integrity proof.
let manifestByteCount = Int(UInt32(valid[magic.count]) |
    (UInt32(valid[magic.count + 1]) << 8) |
    (UInt32(valid[magic.count + 2]) << 16) |
    (UInt32(valid[magic.count + 3]) << 24))
let mediaStart = magic.count + 4 + manifestByteCount
precondition(mediaStart + payload.count == valid.count)
for index in mediaStart..<valid.count {
    var changed = valid
    changed[index] ^= 0xff
    let decoded = try decode(changed)
    precondition(decoded != restored, "FAIL: substituted audio not observable at \(index)")
    precondition(decoded.keys == restored.keys, "FAIL: substitution changed track ownership")
}

// Exercise all possible single-byte truncations, including the magic,
// length prefix, JSON and each audio offset. No truncated envelope may pass.
for size in 0..<valid.count {
    rejects("truncation at \(size)", Data(valid.prefix(size)))
}

// Manifest metadata corruption must never redirect a track to another range,
// allow a duplicate playlist identity, or accept a non-v1 schema.
rejects("duplicate playlist IDs", try encode(Manifest(schema: "mp3-shelf-backup",
    version: 1, tracks: [first, second], playlists: [
        Playlist(id: "same", trackIds: ["first"]),
        Playlist(id: "same", trackIds: ["second"])
    ]), payload: payload))
rejects("wrong schema", try encode(Manifest(schema: "untrusted",
    version: 1, tracks: [first, second], playlists: []), payload: payload))
rejects("future version", try encode(Manifest(schema: "mp3-shelf-backup",
    version: 2, tracks: [first, second], playlists: []), payload: payload))
rejects("zero length audio", try encode(manifest([
    Track(id: "first", audio: Part(offset: 0, length: 0, type: "audio/mpeg")),
    second
]), payload: payload))
print("PASS: archive structural mutation matrix; media-byte authenticity is NOT provided by v1")
