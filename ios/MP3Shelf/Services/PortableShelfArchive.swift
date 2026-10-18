import Foundation

/// The same portable v1 container used by the browser's .mp3shelf backups.
/// Binary media are stored as length-checked slices after a JSON manifest.
enum PortableShelfArchive {
    static let magic = Data("MP3SHELF1\n".utf8)
    static let maxManifestBytes = 4 * 1024 * 1024
    static let maxTrackBytes: Int64 = 250 * 1024 * 1024

    enum ArchiveError: LocalizedError {
        case invalidFile, invalidManifest, oversized, unsupportedAudio, invalidRange

        var errorDescription: String? {
            switch self {
            case .invalidFile: return "This is not an MP3 Shelf backup."
            case .invalidManifest: return "The MP3 Shelf backup contains invalid metadata."
            case .oversized: return "This backup item is larger than the supported limit."
            case .unsupportedAudio: return "This backup contains an unsupported audio format."
            case .invalidRange: return "The backup contains an invalid media range."
            }
        }
    }

    struct Part: Codable {
        var offset: Int64
        var length: Int64
        var type: String
    }

    struct Attribution: Codable {
        var sourceURL: String
        var licenseURL: String
        var creator: String
        var license: String
        var provider: String
    }

    struct Track: Codable {
        var id: String
        var name: String
        var originalName: String?
        var artist: String?
        var album: String?
        var lyrics: String?
        var isFavorite: Bool?
        var attribution: Attribution?
        var importedAt: Double
        var audio: Part
        var artwork: Part?
    }

    struct Wish: Codable {
        var title: String
        var artist: String
        var album: String
        var spotifyURL: String?
    }

    struct Playlist: Codable {
        var id: String
        var name: String
        var trackIds: [String]
        var sourceURL: String?
        var wishes: [Wish]?
    }

    struct Manifest: Codable {
        var schema: String
        var version: Int
        var createdAt: String
        var tracks: [Track]
        var playlists: [Playlist]
    }

    struct MediaInput {
        var track: MusicTrack
        var audioURL: URL
        var artwork: Data?
        var lyrics: String?
    }

    struct Opened {
        var manifest: Manifest
        var url: URL
        var payloadOffset: UInt64
    }

    static func export(_ inputs: [MediaInput], playlists: [MusicPlaylist], to destination: URL) throws {
        var parts: [(url: URL?, bytes: Data?)] = []
        var offset: Int64 = 0
        var tracks: [Track] = []

        for item in inputs {
            let bytes = try FileManager.default.attributesOfItem(
                atPath: item.audioURL.path)[.size] as? NSNumber
            let length = bytes?.int64Value ?? -1
            guard length > 0, length <= maxTrackBytes else { throw ArchiveError.oversized }
            let audio = Part(offset: offset, length: length,
                             type: audioMIME(for: item.audioURL.pathExtension))
            parts.append((item.audioURL, nil))
            offset += length

            var artwork: Part?
            if let bytes = item.artwork, !bytes.isEmpty {
                guard bytes.count <= 20 * 1024 * 1024 else { throw ArchiveError.oversized }
                artwork = Part(offset: offset, length: Int64(bytes.count), type: "image/jpeg")
                parts.append((nil, bytes))
                offset += Int64(bytes.count)
            }
            let source = item.track.sourceAttribution
            let attribution = source.map {
                Attribution(sourceURL: $0.pageURL, licenseURL: $0.licenseURL,
                            creator: item.track.artist, license: "See license",
                            provider: $0.providerName)
            }
            tracks.append(Track(
                id: item.track.id.uuidString, name: item.track.title,
                originalName: item.track.originalFileName, artist: item.track.artist,
                album: item.track.album, lyrics: item.lyrics,
                isFavorite: item.track.isFavorite, attribution: attribution,
                importedAt: item.track.addedAt.timeIntervalSince1970 * 1000,
                audio: audio, artwork: artwork
            ))
        }
        let lists = playlists.map { list in
            let wishes = list.sourceOrder.isEmpty ? list.missingTracks : list.sourceOrder
            return Playlist(
                id: list.portableBackupID ?? list.id.uuidString, name: list.name,
                trackIds: list.trackIDs.map(\.uuidString),
                sourceURL: list.sourceURL,
                wishes: wishes.isEmpty ? nil : wishes.map {
                    Wish(title: $0.title, artist: $0.artist, album: $0.album,
                         spotifyURL: $0.spotifyURL)
                }
            )
        }
        let manifest = Manifest(schema: "mp3-shelf-backup", version: 1,
                                createdAt: ISO8601DateFormatter().string(from: Date()),
                                tracks: tracks, playlists: lists)
        let JSON = try JSONEncoder().encode(manifest)
        guard !JSON.isEmpty, JSON.count <= maxManifestBytes else { throw ArchiveError.oversized }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: magic)
        let n = UInt32(JSON.count)
        try output.write(contentsOf: Data([
            UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF),
            UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)
        ]))
        try output.write(contentsOf: JSON)
        for part in parts {
            if let bytes = part.bytes {
                try output.write(contentsOf: bytes)
            } else if let url = part.url {
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
            }
        }
    }

    static func open(_ url: URL) throws -> Opened {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let headerSize = magic.count + 4
        guard let header = try handle.read(upToCount: headerSize),
              header.count == headerSize, header.prefix(magic.count) == magic else {
            throw ArchiveError.invalidFile
        }
        let tail = header.suffix(4)
        let length = tail.enumerated().reduce(UInt32(0)) { value, entry in
            value | (UInt32(entry.element) << (UInt32(entry.offset) * 8))
        }
        guard length > 0, Int(length) <= maxManifestBytes,
              let bytes = try handle.read(upToCount: Int(length)),
              bytes.count == Int(length) else { throw ArchiveError.invalidManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
        guard manifest.schema == "mp3-shelf-backup", manifest.version == 1,
              manifest.tracks.count <= 20_000, manifest.playlists.count <= 2_000 else {
            throw ArchiveError.invalidManifest
        }
        let size = (try FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let payloadOffset = UInt64(headerSize) + UInt64(length)
        guard size >= payloadOffset else { throw ArchiveError.invalidManifest }
        let payloadSize = Int64(size - payloadOffset)
        // A malformed backup must not silently alias two song IDs, discard
        // playlist links, or create unpredictable duplicate collections.
        var trackIDs = Set<String>()
        for track in manifest.tracks {
            guard !track.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  trackIDs.insert(track.id).inserted,
                  !track.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  track.audio.length > 0, track.audio.length <= maxTrackBytes,
                  track.importedAt.isFinite else { throw ArchiveError.invalidManifest }
            try validate(track.audio, payloadSize: payloadSize)
            if let artwork = track.artwork {
                guard artwork.length <= 20 * 1024 * 1024 else { throw ArchiveError.oversized }
                try validate(artwork, payloadSize: payloadSize)
            }
            if let lyrics = track.lyrics, Data(lyrics.utf8).count > 500 * 1024 {
                throw ArchiveError.oversized
            }
        }
        var playlistIDs = Set<String>()
        for playlist in manifest.playlists {
            guard !playlist.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  playlistIDs.insert(playlist.id).inserted else {
                throw ArchiveError.invalidManifest
            }
        }
        return Opened(manifest: manifest, url: url, payloadOffset: payloadOffset)
    }

    static func extract(_ part: Part, from archive: Opened, extensionName: String) throws -> URL {
        let ext = extensionName.lowercased()
        guard ["mp3", "m4a", "aac", "wav", "aif", "aiff"].contains(ext) else {
            throw ArchiveError.unsupportedAudio
        }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        let input = try FileHandle(forReadingFrom: archive.url)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try input.seek(toOffset: archive.payloadOffset + UInt64(part.offset))
        var remaining = part.length
        while remaining > 0 {
            let amount = Int(min(remaining, 64 * 1024))
            guard let data = try input.read(upToCount: amount), !data.isEmpty else {
                throw ArchiveError.invalidRange
            }
            try output.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
        return target
    }

    static func readBytes(_ part: Part, from archive: Opened) throws -> Data {
        let handle = try FileHandle(forReadingFrom: archive.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: archive.payloadOffset + UInt64(part.offset))
        guard let data = try handle.read(upToCount: Int(part.length)),
              data.count == Int(part.length) else { throw ArchiveError.invalidRange }
        return data
    }

    /// Compare recordings byte-for-byte without loading either audio file into memory.
    /// Filename and size alone are not reliable duplicate identifiers: different
    /// recordings can have identical names and byte counts.
    static func audioFilesIdentical(_ firstURL: URL, _ secondURL: URL) -> Bool {
        guard let first = try? FileHandle(forReadingFrom: firstURL) else { return false }
        defer { try? first.close() }
        guard let second = try? FileHandle(forReadingFrom: secondURL) else { return false }
        defer { try? second.close() }
        do {
            while true {
                let firstChunk = try first.read(upToCount: 64 * 1024) ?? Data()
                let secondChunk = try second.read(upToCount: 64 * 1024) ?? Data()
                guard firstChunk == secondChunk else { return false }
                if firstChunk.isEmpty { return true }
            }
        } catch {
            return false
        }
    }

    static func audioExtension(for track: Track) throws -> String {
        let ext = URL(fileURLWithPath: track.originalName ?? "").pathExtension.lowercased()
        if ["mp3", "m4a", "aac", "wav", "aif", "aiff"].contains(ext) { return ext }
        switch track.audio.type.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/aac": return "aac"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        default: throw ArchiveError.unsupportedAudio
        }
    }

    private static func audioMIME(for ext: String) -> String {
        switch ext.lowercased() {
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        default: return "audio/mpeg"
        }
    }

    private static func validate(_ part: Part, payloadSize: Int64) throws {
        guard part.offset >= 0, part.length >= 0,
              part.offset <= payloadSize,
              part.length <= payloadSize - part.offset else { throw ArchiveError.invalidRange }
    }
}
