import Foundation

// Foundation-only contract for the portable MP3SHELF1 archive envelope.
// Run: swift ios/Tests/PortableBackupBoundaryTests.swift
// This independently models archive validation; it does not exercise app restore.
enum ArchiveFailure: Error { case invalid }
let magic = Data("MP3SHELF1\n".utf8)
let audio = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0, 0x11, 0x22])
let artwork = Data([0xff, 0xd8, 0xff, 0xd9])

func archive(_ manifest: [String: Any], payload: Data = audio + artwork) throws -> Data {
    let json = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    var output = magic
    let length = UInt32(json.count)
    for shift in stride(from: 0, to: 32, by: 8) {
        output.append(UInt8((length >> shift) & 255))
    }
    output.append(json)
    output.append(payload)
    return output
}
func manifest(audioOffset: Int = 0, audioLength: Int = audio.count,
              artOffset: Int = audio.count, artLength: Int = artwork.count,
              playlistIDs: [String] = ["track-A"]) -> [String: Any] {
    return [
        "schema": "mp3-shelf-backup", "version": 1,
        "tracks": [[
            "id": "track-A", "name": "Café 🎵", "importedAt": 123,
            "audio": ["offset": audioOffset, "length": audioLength, "type": "audio/mpeg"],
            "artwork": ["offset": artOffset, "length": artLength, "type": "image/jpeg"]
        ]],
        "playlists": [["id": "list-A", "name": "Saved", "trackIds": playlistIDs]]
    ]
}
func validate(_ bytes: Data) throws -> (Data, Data) {
    guard bytes.count >= magic.count + 4, bytes.prefix(magic.count) == magic else { throw ArchiveFailure.invalid }
    let start = magic.count
    let length = (0..<4).reduce(UInt32(0)) {
        $0 | (UInt32(bytes[start + $1]) << UInt32($1 * 8))
    }
    guard length > 0, length <= 4 * 1024 * 1024,
          Int(length) <= bytes.count - start - 4 else { throw ArchiveFailure.invalid }
    let payloadStart = start + 4 + Int(length)
    let raw = bytes.subdata(in: (start + 4)..<payloadStart)
    guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          object["schema"] as? String == "mp3-shelf-backup",
          object["version"] as? Int == 1,
          let tracks = object["tracks"] as? [[String: Any]],
          let playlists = object["playlists"] as? [[String: Any]],
          tracks.count == 1,
          let track = tracks.first,
          track["id"] as? String == "track-A",
          let audioPart = track["audio"] as? [String: Any],
          let artworkPart = track["artwork"] as? [String: Any],
          let ids = playlists.first?["trackIds"] as? [String],
          ids.allSatisfy({ $0 == "track-A" }) else { throw ArchiveFailure.invalid }
    let parts = [audioPart, artworkPart]
    let payload = bytes.subdata(in: payloadStart..<bytes.count)
    var ranges: [(Int, Int)] = []
    for part in parts {
        guard let offset = part["offset"] as? Int, let count = part["length"] as? Int,
              offset >= 0, count > 0, offset <= payload.count,
              count <= payload.count - offset else { throw ArchiveFailure.invalid }
        ranges.append((offset, offset + count))
    }
    ranges.sort { $0.0 < $1.0 }
    guard ranges[0].0 == 0, ranges[0].1 == ranges[1].0,
          ranges[1].1 == payload.count else { throw ArchiveFailure.invalid }
    return (payload.subdata(in: ranges[0].0..<ranges[0].1),
            payload.subdata(in: ranges[1].0..<ranges[1].1))
}
func rejected(_ name: String, _ bytes: Data) {
    do { _ = try validate(bytes); fatalError("FAIL accepted \(name)") }
    catch ArchiveFailure.invalid { }
    catch { fatalError("FAIL unexpected \(name): \(error)") }
}
let valid = try archive(manifest())
let restored = try validate(valid)
precondition(restored.0 == audio && restored.1 == artwork)
rejected("overlap", try archive(manifest(artOffset: 4)))
rejected("gap", try archive(manifest(artOffset: audio.count + 1)))
rejected("out of bounds", try archive(manifest(artLength: 1_000_000)))
rejected("zero audio", try archive(manifest(audioLength: 0)))
rejected("missing playlist audio", try archive(manifest(playlistIDs: ["missing"])))
rejected("truncated payload", Data(valid.dropLast()))
rejected("extra payload", valid + Data([0]))
rejected("bad magic", Data([0]) + valid.dropFirst())
var oversized = valid
oversized.replaceSubrange(magic.count..<(magic.count + 4), with: [255, 255, 255, 255])
rejected("oversized manifest", oversized)
var truncatedHeader = valid
truncatedHeader.replaceSubrange(magic.count..<(magic.count + 4), with: [255, 0, 0, 0])
rejected("truncated manifest", truncatedHeader.prefix(magic.count + 5))
let verifiedAgain = try validate(valid)
precondition(verifiedAgain.0 == audio)
print("PASS: portable backup envelope, Unicode metadata, ten corruption boundaries, byte-exact audio/artwork")
