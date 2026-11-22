import Foundation
// Standalone portable v1 stress fixture; not the production restore implementation.
// Run: swift ios/Tests/PortableArchiveLargePayloadTests.swift
struct Part: Codable { let offset: Int64; let length: Int64; let type: String }
struct Track: Codable { let id: String; let audio: Part }
struct Playlist: Codable { let id: String; let trackIds: [String] }
struct Manifest: Codable { let schema: String; let version: Int; let tracks: [Track]; let playlists: [Playlist] }
enum Invalid: Error { case archive }
let magic = Data("MP3SHELF1\n".utf8)
func pack(_ m: Manifest, _ payload: Data) throws -> Data {
    let json = try JSONEncoder().encode(m)
    precondition(json.count <= 4 * 1024 * 1024)
    let n = UInt32(json.count)
    var result = magic
    for shift in stride(from: 0, through: 24, by: 8) { result.append(UInt8(truncatingIfNeeded: n >> shift)) }
    result.append(json); result.append(payload)
    return result
}
func unpack(_ archive: Data) throws -> [String: Data] {
    let header = magic.count + 4
    guard archive.count >= header, archive.prefix(magic.count) == magic else { throw Invalid.archive }
    var count: UInt32 = 0
    for i in 0..<4 { count |= UInt32(archive[magic.count + i]) << (i * 8) }
    guard count > 0, count <= 4 * 1024 * 1024, Int(count) <= archive.count - header else { throw Invalid.archive }
    let end = header + Int(count)
    let m = try JSONDecoder().decode(Manifest.self, from: archive.subdata(in: header..<end))
    guard m.schema == "mp3-shelf-backup", m.version == 1,
          Set(m.tracks.map(\.id)).count == m.tracks.count,
          Set(m.playlists.map(\.id)).count == m.playlists.count else { throw Invalid.archive }
    let ids = Set(m.tracks.map(\.id))
    guard m.playlists.allSatisfy({ $0.trackIds.allSatisfy(ids.contains) }) else { throw Invalid.archive }
    let payload = archive.subdata(in: end..<archive.count)
    var cursor: Int64 = 0
    var result: [String: Data] = [:]
    for track in m.tracks.sorted(by: { $0.audio.offset < $1.audio.offset }) {
        let p = track.audio
        guard p.offset == cursor, p.length > 0, p.length <= Int64(payload.count) - cursor else { throw Invalid.archive }
        let next = cursor + p.length
        result[track.id] = payload.subdata(in: Int(cursor)..<Int(next))
        cursor = next
    }
    guard cursor == Int64(payload.count) else { throw Invalid.archive }
    return result
}
func reject(_ label: String, _ bytes: Data) {
    do { _ = try unpack(bytes); fatalError("accepted \(label)") }
    catch Invalid.archive { }
    catch { fatalError("unexpected \(label): \(error)") }
}
let count = 2048
let chunk = 1024
var payload = Data(capacity: count * chunk)
var tracks: [Track] = []
var expected: [String: Data] = [:]
for index in 0..<count {
    let bytes = Data((0..<chunk).map { byte in
        UInt8(truncatingIfNeeded: (index &* 131) ^ (byte &* 17) ^ (index >> 8))
    })
    let id = "audio-\(index)"
    expected[id] = bytes
    tracks.append(Track(id: id, audio: Part(offset: Int64(index * chunk), length: Int64(chunk), type: "audio/mpeg")))
    payload.append(bytes)
}
let playlist = Playlist(id: "ordered", trackIds: ["audio-2047", "audio-0", "audio-2047"])
let manifest = Manifest(schema: "mp3-shelf-backup", version: 1, tracks: tracks.reversed(), playlists: [playlist])
let archive = try pack(manifest, payload)
let restored = try unpack(archive)
precondition(restored == expected, "reversed manifest corrupted audio ownership")
var overlap = tracks
overlap[count - 1] = Track(id: overlap[count - 1].id,
    audio: Part(offset: Int64((count - 2) * chunk), length: Int64(chunk), type: "audio/mpeg"))
reject("overlap", try pack(Manifest(schema: manifest.schema, version: 1, tracks: overlap, playlists: [playlist]), payload))
var gap = tracks
gap[1] = Track(id: gap[1].id, audio: Part(offset: Int64(2 * chunk), length: Int64(chunk), type: "audio/mpeg"))
reject("gap", try pack(Manifest(schema: manifest.schema, version: 1, tracks: gap, playlists: [playlist]), payload))
var duplicate = tracks
duplicate[0] = Track(id: tracks[1].id, audio: tracks[0].audio)
reject("duplicate identity", try pack(Manifest(schema: manifest.schema, version: 1, tracks: duplicate, playlists: [playlist]), payload))
reject("dangling playlist", try pack(Manifest(schema: manifest.schema, version: 1, tracks: tracks,
    playlists: [Playlist(id: "ordered", trackIds: ["missing"])]), payload))
reject("truncated media", Data(archive.dropLast()))
reject("trailing media", archive + Data([0x7f]))
// v1 has no media digest: structurally valid substitution must not be called authenticated.
var tampered = archive
tampered[tampered.count - 512] ^= 0xff
let tamperedOutput = try unpack(tampered)
precondition(tamperedOutput != expected, "substitution should alter audio")
print("PASS: 2048 x 1024-byte v1 ownership, corruption and playlist references")
print("LIMITATION: v1 cannot authenticate media-byte substitutions")
