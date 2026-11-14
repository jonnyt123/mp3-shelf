import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        var durationSeconds: Double? = nil
        var artistNames: [String]? = nil
        var appleMusicItemID: String? = nil
    }

    struct Playlist: Codable {
        var id: String
        var name: String
        var trackIds: [String]
        var sourceURL: String?
        var wishes: [Wish]?
        var appleMusicLibraryID: String? = nil
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
        // Identity captured from the descriptor that validated the manifest.
        // Each later extraction must read that same unchanged regular file.
        fileprivate var sourceIdentity: ArchiveSourceIdentity
        // Indexed once at open: repeated extraction of large shelves must not
        // rescan all manifest tracks for every audio/artwork part.
        fileprivate var audioParts: Set<MediaPartKey>
        fileprivate var artworkParts: Set<MediaPartKey>
    }

    fileprivate struct MediaPartKey: Hashable {
        let offset: Int64
        let length: Int64
        let type: String

        init(_ part: Part) {
            offset = part.offset
            length = part.length
            type = part.type
        }
    }

    fileprivate struct ArchiveSourceIdentity {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            #if canImport(Darwin)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
            #else
            modifiedSeconds = Int64(info.st_mtim.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
            changedSeconds = Int64(info.st_ctim.tv_sec)
            changedNanoseconds = Int64(info.st_ctim.tv_nsec)
            #endif
        }

        func matches(_ info: stat) -> Bool {
            (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) &&
            device == info.st_dev && inode == info.st_ino &&
            size == info.st_size &&
            modifiedSeconds == ArchiveSourceIdentity(info).modifiedSeconds &&
            modifiedNanoseconds == ArchiveSourceIdentity(info).modifiedNanoseconds &&
            changedSeconds == ArchiveSourceIdentity(info).changedSeconds &&
            changedNanoseconds == ArchiveSourceIdentity(info).changedNanoseconds
        }
    }

    /// Validate the opened archive and its current pathname, without following
    /// symlinks. This prevents a replaced backup from supplying bytes under a
    /// previously validated manifest and rejects same-inode edits/size changes.
    private static func archiveIdentity(of handle: FileHandle, at url: URL) throws -> ArchiveSourceIdentity {
        var opened = stat()
        var named = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0,
              lstat(url.path, &named) == 0,
              (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ArchiveError.invalidFile
        }
        let identity = ArchiveSourceIdentity(opened)
        guard identity.matches(named) else { throw ArchiveError.invalidFile }
        return identity
    }

    private static func verifyArchive(_ handle: FileHandle, from archive: Opened) throws -> UInt64 {
        let current = try archiveIdentity(of: handle, at: archive.url)
        guard current.device == archive.sourceIdentity.device,
              current.inode == archive.sourceIdentity.inode,
              current.size == archive.sourceIdentity.size,
              current.modifiedSeconds == archive.sourceIdentity.modifiedSeconds,
              current.modifiedNanoseconds == archive.sourceIdentity.modifiedNanoseconds,
              current.changedSeconds == archive.sourceIdentity.changedSeconds,
              current.changedNanoseconds == archive.sourceIdentity.changedNanoseconds,
              current.size >= 0 else { throw ArchiveError.invalidFile }
        return UInt64(current.size)
    }

    /// Resolve archive-only IDs without letting a native UUID overwrite an
    /// explicit portable identity owned by a different track or playlist.
    /// Duplicate explicit IDs keep their first occurrence; all fallback IDs
    /// avoid every reserved explicit ID, even when it appears later in input.
    private static func resolvedArchiveIDs(_ candidates: [(localID: UUID, portableID: String?)],
                                           namespace: String) -> [String] {
        let reserved = Set(candidates.compactMap { candidate -> String? in
            guard let id = candidate.portableID,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return id
        })
        var assigned = Set<String>()
        return candidates.map { candidate in
            if let id = candidate.portableID,
               !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               assigned.insert(id).inserted {
                return id
            }
            let fallback = candidate.localID.uuidString
            if !reserved.contains(fallback), assigned.insert(fallback).inserted {
                return fallback
            }
            // A random replacement changes on every export. Stable IDs
            // allow repeated backups of a repaired legacy library to restore
            // into the same playlist instead of creating duplicate collections.
            // Namespace track and playlist IDs independently, and probe only
            // when an explicit ID already occupies the deterministic value.
            let stem = "mp3shelf-\(namespace)-\(candidate.localID.uuidString)"
            var replacement = stem
            var suffix = 1
            while reserved.contains(replacement) || !assigned.insert(replacement).inserted {
                replacement = stem + "-\(suffix)"
                suffix += 1
            }
            return replacement
        }
    }

    /// Read a catalog-referenced lyrics/artwork sidecar without treating an
    /// inaccessible file as optional. Nil means no reference was saved; a
    /// referenced but missing or damaged file must abort backup export.
    /// Read from one handle in bounded chunks so growth/truncation is detected.
    static func readSidecar(named fileName: String?, from directory: URL,
                            maximumBytes: Int) throws -> Data? {
        guard let fileName else { return nil }
        guard !fileName.isEmpty, fileName != ".", fileName != "..",
              !fileName.contains("/"), !fileName.contains("\\"),
              !fileName.contains("\0"),
              maximumBytes > 0, maximumBytes <= 20 * 1024 * 1024 else {
            throw ArchiveError.invalidManifest
        }
        let url = directory.appendingPathComponent(fileName)
        // A corrupted/restored catalog must not turn an artwork or lyrics
        // reference into a read outside the app's sidecar directory. Do not
        // follow symbolic links (including chains) or open directories/FIFOs.
        // Resolve both paths before opening and require an ordinary file.
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent() == root else {
            throw ArchiveError.invalidManifest
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw ArchiveError.invalidManifest
        }
        // attributesOfItem follows symlinks; the original path must also be
        // checked without following the final component.
        let properties = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard properties.isSymbolicLink != true, properties.isRegularFile == true else {
            throw ArchiveError.invalidManifest
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        // Resource-value checks precede open and are vulnerable to pathname
        // replacement. Bind the read to the regular file actually opened.
        let source = try archiveIdentity(of: input, at: url)
        guard source.size >= 0 else { throw ArchiveError.invalidManifest }
        let size = try input.seekToEnd()
        guard Int64(size) == source.size else { throw ArchiveError.invalidRange }
        guard size <= UInt64(maximumBytes) else { throw ArchiveError.oversized }
        try input.seek(toOffset: 0)
        var bytes = Data()
        bytes.reserveCapacity(Int(size))
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
            guard !chunk.isEmpty else { throw ArchiveError.invalidRange }
            bytes.append(chunk)
            remaining -= UInt64(chunk.count)
        }
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else {
            throw ArchiveError.invalidRange
        }
        // Reject same-size edits and replaced catalog paths during the read.
        // Do not return bytes from a sidecar that changed after validation.
        let afterRead = try archiveIdentity(of: input, at: url)
        guard source.device == afterRead.device,
              source.inode == afterRead.inode,
              source.size == afterRead.size,
              source.modifiedSeconds == afterRead.modifiedSeconds,
              source.modifiedNanoseconds == afterRead.modifiedNanoseconds,
              source.changedSeconds == afterRead.changedSeconds,
              source.changedNanoseconds == afterRead.changedNanoseconds else {
            throw ArchiveError.invalidManifest
        }
        try Task.checkCancellation()
        return bytes
    }

    /// A backup can repair a missing or damaged sidecar without replacing the
    /// original file. A non-nil catalog reference alone is not proof that its
    /// contents are still readable. Leave the old bytes in place for recovery.
    static func sidecarNeedsRecovery(named fileName: String?, from directory: URL,
                                     maximumBytes: Int,
                                     isValid: (Data) -> Bool) -> Bool {
        guard let fileName else { return true }
        guard let bytes = try? readSidecar(named: fileName, from: directory,
                                           maximumBytes: maximumBytes) else { return true }
        return !isValid(bytes)
    }

    /// The audio catalog is expected to reference actual app-owned recordings.
    /// Refuse symbolic links, directories and other special files rather than
    /// following a damaged catalog entry into unrelated device content.
    /// Repeat at the copy boundary to catch changes after manifest sizing.
    private static func validateAudioSource(_ url: URL) throws {
        let properties = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard properties.isSymbolicLink != true, properties.isRegularFile == true else {
            throw ArchiveError.invalidManifest
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw ArchiveError.invalidManifest
        }
    }

    static func export(_ inputs: [MediaInput], playlists: [MusicPlaylist], to destination: URL) throws {
        var parts: [(url: URL?, bytes: Data?, expectedLength: Int64, sourceIdentity: ArchiveSourceIdentity?)] = []
        var offset: Int64 = 0
        var tracks: [Track] = []

        // Match open() limits before writing a potentially multi-gigabyte
        // backup. Otherwise export can succeed but its own reader rejects it.
        guard inputs.count <= 20_000, playlists.count <= 2_000 else {
            throw ArchiveError.invalidManifest
        }
        for item in inputs {
            try Task.checkCancellation()
            try validateAudioSource(item.audioURL)
            let ext = item.audioURL.pathExtension.lowercased()
            guard ["mp3", "m4a", "aac", "wav", "aif", "aiff"].contains(ext) else {
                throw ArchiveError.unsupportedAudio
            }
            guard !item.track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ArchiveError.invalidManifest
            }
            if let lyrics = item.lyrics, lyrics.utf8.count > 500 * 1024 {
                throw ArchiveError.oversized
            }
            let bytes = try FileManager.default.attributesOfItem(
                atPath: item.audioURL.path)[.size] as? NSNumber
            let length = bytes?.int64Value ?? -1
            guard length > 0, length <= maxTrackBytes else { throw ArchiveError.oversized }
            let audio = Part(offset: offset, length: length,
                             type: audioMIME(for: item.audioURL.pathExtension))
            // Capture the identity used to size this manifest entry. Reject a
            // same-size replacement between preflight and streaming.
            let preflight = try FileHandle(forReadingFrom: item.audioURL)
            let sourceIdentity: ArchiveSourceIdentity
            do {
                sourceIdentity = try verifyOpenedAudioSource(preflight, at: item.audioURL,
                                                               expectedLength: length)
            } catch {
                try? preflight.close()
                throw error
            }
            try preflight.close()
            parts.append((item.audioURL, nil, length, sourceIdentity))
            offset += length

            var artwork: Part?
            if let bytes = item.artwork, !bytes.isEmpty {
                guard bytes.count <= 20 * 1024 * 1024 else { throw ArchiveError.oversized }
                artwork = Part(offset: offset, length: Int64(bytes.count), type: "image/jpeg")
                parts.append((nil, bytes, Int64(bytes.count), nil))
                offset += Int64(bytes.count)
            }
            let source = item.track.sourceAttribution
            let attribution = source.map {
                Attribution(sourceURL: $0.pageURL, licenseURL: $0.licenseURL,
                            creator: item.track.artist,
                            license: $0.licenseURL.isEmpty ? "Not supplied" : "See license",
                            provider: $0.providerName)
            }
            tracks.append(Track(
                id: item.track.portableBackupID ?? item.track.id.uuidString, name: item.track.title,
                originalName: item.track.originalFileName, artist: item.track.artist,
                album: item.track.album, lyrics: item.lyrics,
                isFavorite: item.track.isFavorite, attribution: attribution,
                importedAt: item.track.addedAt.timeIntervalSince1970 * 1000,
                audio: audio, artwork: artwork
            ))
        }
        // Local UUIDs must be unique because playlist links use them. An
        // ambiguous source catalog cannot be exported without losing links.
        guard Set(inputs.map { $0.track.id }).count == inputs.count else {
            throw ArchiveError.invalidManifest
        }
        // Reserve all explicit portable IDs before assigning local-UUID
        // fallbacks. Input order must not steal a later browser identity.
        let exportedTrackIDs = resolvedArchiveIDs(inputs.map {
            (localID: $0.track.id, portableID: $0.track.portableBackupID)
        }, namespace: "track")
        var portableIDs: [UUID: String] = [:]
        for (item, id) in zip(inputs, exportedTrackIDs) {
            portableIDs[item.track.id] = id
        }
        for index in tracks.indices {
            tracks[index].id = exportedTrackIDs[index]
        }
        let playlistIDs = resolvedArchiveIDs(playlists.map {
            (localID: $0.id, portableID: $0.portableBackupID)
        }, namespace: "playlist")
        // A stale/corrupt catalog can contain playlist links whose audio is
        // absent from the export snapshot. Dropping those IDs with compactMap
        // would silently publish a backup that loses playlist membership.
        // Reject the snapshot before writing any archive, leaving the saved
        // catalog and source recordings untouched for recovery.
        let availableTrackIDs = Set(portableIDs.keys)
        guard playlists.allSatisfy({ playlist in
            !playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            playlist.trackIDs.allSatisfy { availableTrackIDs.contains($0) }
        }) else {
            throw ArchiveError.invalidManifest
        }
        let lists = playlists.enumerated().map { index, list in
            let wishes = list.sourceOrder.isEmpty ? list.missingTracks : list.sourceOrder
            return Playlist(
                id: playlistIDs[index], name: list.name,
                // All links were validated against the export snapshot.
                trackIds: list.trackIDs.map { portableIDs[$0]! },
                sourceURL: list.sourceURL,
                wishes: wishes.isEmpty ? nil : wishes.map {
                    Wish(title: $0.title, artist: $0.artist, album: $0.album,
                         spotifyURL: $0.spotifyURL, durationSeconds: $0.durationSeconds,
                         artistNames: $0.artistNames, appleMusicItemID: $0.appleMusicItemID)
                },
                appleMusicLibraryID: list.appleMusicLibraryID
            )
        }
        let manifest = Manifest(schema: "mp3-shelf-backup", version: 1,
                                createdAt: ISO8601DateFormatter().string(from: Date()),
                                tracks: tracks, playlists: lists)
        let JSON = try JSONEncoder().encode(manifest)
        guard !JSON.isEmpty, JSON.count <= maxManifestBytes else { throw ArchiveError.oversized }

        // Write to a sibling temporary file first: failed source reads, disk-full
        // errors or interrupted exports must not leave a corrupt final archive.
        // Refuse to overwrite an existing user backup.
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + "." + UUID().uuidString + ".partial")
        guard manager.createFile(atPath: staging.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
        let output = try FileHandle(forWritingTo: staging)
        defer { try? output.close() }
        try output.write(contentsOf: magic)
        let n = UInt32(JSON.count)
        try output.write(contentsOf: Data([
            UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF),
            UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)
        ]))
        try output.write(contentsOf: JSON)
        for part in parts {
            try Task.checkCancellation()
            if let bytes = part.bytes {
                try output.write(contentsOf: bytes)
            } else if let url = part.url {
                // Scope each source handle to this part. A defer directly in
                // the export loop would keep every file descriptor open until
                // the whole backup completes, exhausting limits on large shelves.
                guard let sourceIdentity = part.sourceIdentity else {
                    throw ArchiveError.invalidManifest
                }
                try copyAudioPart(from: url, expectedLength: part.expectedLength,
                                  preflightIdentity: sourceIdentity, to: output)
            }
        }
        try output.synchronize()
        try output.close()
        // Re-open and validate the staged archive before publishing it.
        // Failed validation removes only the unpublished partial file.
        try Task.checkCancellation()
        let staged = try open(staging)
        guard staged.manifest.tracks.count == tracks.count,
              staged.manifest.playlists.count == lists.count else {
            throw ArchiveError.invalidManifest
        }
        // Sources can change after their individual copy completes while the
        // remaining tracks are exported. Recheck every preflight identity
        // immediately before publication so an already-copied recording that
        // was replaced or edited during a later track cannot be silently
        // included in a supposedly consistent backup.
        for part in parts {
            try Task.checkCancellation()
            guard let url = part.url else { continue }
            guard let expected = part.sourceIdentity else {
                throw ArchiveError.invalidManifest
            }
            let input = try FileHandle(forReadingFrom: url)
            let current: ArchiveSourceIdentity
            do {
                current = try verifyOpenedAudioSource(input, at: url,
                                                       expectedLength: part.expectedLength)
            } catch {
                try? input.close()
                throw error
            }
            try input.close()
            guard expected.device == current.device,
                  expected.inode == current.inode,
                  expected.size == current.size,
                  expected.modifiedSeconds == current.modifiedSeconds,
                  expected.modifiedNanoseconds == current.modifiedNanoseconds,
                  expected.changedSeconds == current.changedSeconds,
                  expected.changedNanoseconds == current.changedNanoseconds else {
                throw ArchiveError.invalidRange
            }
        }
        // Publish without replacing an existing user backup. A fileExists
        // check followed by rename/move is not atomic: another export can
        // create the destination between those operations, and POSIX rename
        // may replace it. A same-directory hard link creates the final name
        // atomically and fails with EEXIST instead of overwriting any bytes.
        // Keep staging until publication succeeds so errors remain recoverable.
        try Task.checkCancellation()
        let published = staging.path.withCString { source in
            destination.path.withCString { target in link(source, target) }
        }
        guard published == 0 else {
            let code = errno
            if code == EEXIST { throw CocoaError(.fileWriteFileExists) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        // The final name is already complete. Failure to unlink staging is
        // harmless to the published archive; the outer catch cleans it up.
        try? manager.removeItem(at: staging)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// Verify the actual open descriptor, not just the pathname checked
    /// before open. lstat deliberately does not follow a replaced symlink.
    /// Keep the descriptor alive for the subsequent streaming copy.
    private static func verifyOpenedAudioSource(_ handle: FileHandle, at url: URL,
                                                 expectedLength: Int64) throws -> ArchiveSourceIdentity {
        var opened = stat()
        var named = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0,
              lstat(url.path, &named) == 0,
              (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (named.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              opened.st_size == expectedLength,
              named.st_size == expectedLength else {
            throw ArchiveError.invalidRange
        }
        let identity = ArchiveSourceIdentity(opened)
        guard identity.matches(named) else { throw ArchiveError.invalidRange }
        return identity
    }

    /// Stream one source into an archive and close its descriptor before the
    /// next source opens. A failed read or write propagates to export(), which
    /// removes its unpublished partial archive without touching user audio.
    private static func copyAudioPart(from url: URL, expectedLength: Int64,
                                      preflightIdentity: ArchiveSourceIdentity,
                                      to output: FileHandle) throws {
        try validateAudioSource(url)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        // Path validation and open are separate operations. A replaced path
        // must not let the exporter read a symlink target or a different inode.
        // Compare the opened descriptor with a fresh non-following path stat.
        let originalIdentity = try verifyOpenedAudioSource(input, at: url,
                                                           expectedLength: expectedLength)
        // Reject changes after manifest preflight, even with identical length.
        guard originalIdentity.device == preflightIdentity.device,
              originalIdentity.inode == preflightIdentity.inode,
              originalIdentity.size == preflightIdentity.size,
              originalIdentity.modifiedSeconds == preflightIdentity.modifiedSeconds,
              originalIdentity.modifiedNanoseconds == preflightIdentity.modifiedNanoseconds,
              originalIdentity.changedSeconds == preflightIdentity.changedSeconds,
              originalIdentity.changedNanoseconds == preflightIdentity.changedNanoseconds else {
            throw ArchiveError.invalidRange
        }
        // The manifest records the size measured before export. Reject both
        // shrinking and growing files to avoid misaligned payload offsets.
        var remaining = expectedLength
        while remaining > 0 {
            // A large offline library can take minutes to export. Cancellation
            // must interrupt the audio copy itself, not merely the gap between
            // tracks, or the UI keeps writing gigabytes after the user cancels.
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
            guard !chunk.isEmpty else { throw ArchiveError.invalidRange }
            try output.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
        try Task.checkCancellation()
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else {
            throw ArchiveError.invalidRange
        }
        // A file may be rewritten in place without changing its inode or
        // length while a backup is streaming. Reject a torn recording even
        // when the final pathname still resolves to the same regular file.
        let finalIdentity = try verifyOpenedAudioSource(input, at: url,
                                                        expectedLength: expectedLength)
        guard originalIdentity.device == finalIdentity.device,
              originalIdentity.inode == finalIdentity.inode,
              originalIdentity.size == finalIdentity.size,
              originalIdentity.modifiedSeconds == finalIdentity.modifiedSeconds,
              originalIdentity.modifiedNanoseconds == finalIdentity.modifiedNanoseconds,
              originalIdentity.changedSeconds == finalIdentity.changedSeconds,
              originalIdentity.changedNanoseconds == finalIdentity.changedNanoseconds else {
            throw ArchiveError.invalidRange
        }
    }

    static func open(_ url: URL) throws -> Opened {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let identity = try archiveIdentity(of: handle, at: url)
        guard identity.size >= 0 else { throw ArchiveError.invalidFile }
        let headerSize = magic.count + 4
        // FileHandle is permitted to return short reads before EOF. Collect
        // the entire fixed header before checking its magic and length.
        let header = try readExactly(headerSize, from: handle)
        guard header.count == headerSize, header.prefix(magic.count) == magic else {
            throw ArchiveError.invalidFile
        }
        let tail = header.suffix(4)
        let length = tail.enumerated().reduce(UInt32(0)) { value, entry in
            value | (UInt32(entry.element) << (UInt32(entry.offset) * 8))
        }
        guard length > 0, Int(length) <= maxManifestBytes else {
            throw ArchiveError.invalidManifest
        }
        let bytes = try readExactly(Int(length), from: handle)
        guard bytes.count == Int(length) else { throw ArchiveError.invalidManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
        guard manifest.schema == "mp3-shelf-backup", manifest.version == 1,
              manifest.tracks.count <= 20_000, manifest.playlists.count <= 2_000 else {
            throw ArchiveError.invalidManifest
        }
        let size = UInt64(identity.size)
        let payloadOffset = UInt64(headerSize) + UInt64(length)
        guard size >= payloadOffset else { throw ArchiveError.invalidManifest }
        let payloadSize = Int64(size - payloadOffset)
        // A malformed backup must not silently alias two song IDs, discard
        // playlist links, or create unpredictable duplicate collections.
        // Every media slice must own distinct payload bytes. Bounds checks alone
        // allow two tracks (or artwork and audio) to alias the same recording.
        // Collect half-open ranges, then reject overlaps in O(n log n).
        var mediaRanges: [(start: Int64, end: Int64)] = []
        var trackIDs = Set<String>()
        var audioParts = Set<MediaPartKey>()
        var artworkParts = Set<MediaPartKey>()
        for track in manifest.tracks {
            try Task.checkCancellation()
            guard !track.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  trackIDs.insert(track.id).inserted,
                  !track.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  track.audio.length > 0, track.audio.length <= maxTrackBytes,
                  track.importedAt.isFinite else { throw ArchiveError.invalidManifest }
            // Reject unsupported media before any recording is restored.
            // A late unsupported item must not leave a partial library restore.
            _ = try audioExtension(for: track)
            try validate(track.audio, payloadSize: payloadSize)
            mediaRanges.append((track.audio.offset, track.audio.offset + track.audio.length))
            audioParts.insert(MediaPartKey(track.audio))
            if let artwork = track.artwork {
                // An artwork reference is not optional once present in the
                // manifest. A zero-length reference passes range validation,
                // but readBytes() rejects it after earlier tracks may already
                // have been restored. Reject the entire manifest up front so
                // malformed late artwork cannot produce a partial restore.
                guard artwork.length > 0 else { throw ArchiveError.invalidManifest }
                guard artwork.length <= 20 * 1024 * 1024 else { throw ArchiveError.oversized }
                try validate(artwork, payloadSize: payloadSize)
                mediaRanges.append((artwork.offset, artwork.offset + artwork.length))
                artworkParts.insert(MediaPartKey(artwork))
            }
            if let lyrics = track.lyrics, Data(lyrics.utf8).count > 500 * 1024 {
                throw ArchiveError.oversized
            }
        }
        // Every payload byte must be accounted for by exactly one media
        // slice. Bounds and overlap checks alone permit hidden trailing data
        // or gaps that a restore would silently ignore.
        mediaRanges.sort { $0.start < $1.start }
        var expectedStart: Int64 = 0
        for range in mediaRanges {
            try Task.checkCancellation()
            guard range.start == expectedStart else {
                throw ArchiveError.invalidRange
            }
            expectedStart = range.end
        }
        guard expectedStart == payloadSize else {
            throw ArchiveError.invalidRange
        }
        var playlistIDs = Set<String>()
        for playlist in manifest.playlists {
            try Task.checkCancellation()
            guard !playlist.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  playlistIDs.insert(playlist.id).inserted else {
                throw ArchiveError.invalidManifest
            }
            // A single large playlist can contain thousands of links. Check
            // cancellation within reconciliation, not only between playlists.
            for trackID in playlist.trackIds {
                try Task.checkCancellation()
                guard trackIDs.contains(trackID) else {
                    throw ArchiveError.invalidManifest
                }
            }
        }
        // Reject concurrent edits while the manifest was being inspected.
        let checked = try archiveIdentity(of: handle, at: url)
        guard checked.device == identity.device, checked.inode == identity.inode,
              checked.size == identity.size,
              checked.modifiedSeconds == identity.modifiedSeconds,
              checked.modifiedNanoseconds == identity.modifiedNanoseconds,
              checked.changedSeconds == identity.changedSeconds,
              checked.changedNanoseconds == identity.changedNanoseconds else {
            throw ArchiveError.invalidFile
        }
        try Task.checkCancellation()
        return Opened(manifest: manifest, url: url, payloadOffset: payloadOffset,
                      sourceIdentity: identity, audioParts: audioParts,
                      artworkParts: artworkParts)
    }

    /// Only restore slices declared in the inspected manifest. A caller must
    /// not be able to extract a different song's bytes (or arbitrary offsets)
    /// by constructing a Part with otherwise valid bounds.
    private static func containsAudioPart(_ part: Part, in archive: Opened) -> Bool {
        archive.audioParts.contains(MediaPartKey(part))
    }

    private static func containsArtworkPart(_ part: Part, in archive: Opened) -> Bool {
        archive.artworkParts.contains(MediaPartKey(part))
    }

    static func extract(_ part: Part, from archive: Opened, extensionName: String) throws -> URL {
        guard containsAudioPart(part, in: archive) else { throw ArchiveError.invalidRange }
        let ext = extensionName.lowercased()
        guard ["mp3", "m4a", "aac", "wav", "aif", "aiff"].contains(ext) else {
            throw ArchiveError.unsupportedAudio
        }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        let input = try FileHandle(forReadingFrom: archive.url)
        defer { try? input.close() }
        guard part.offset >= 0, part.length > 0, part.length <= maxTrackBytes,
              UInt64(part.offset) <= UInt64.max - archive.payloadOffset else {
            throw ArchiveError.invalidRange
        }
        // open() validates the archive at inspection time, but Files may
        // replace or truncate it before extraction. Check the live handle
        // before creating any output, and reject impossible seek arithmetic.
        let size = try verifyArchive(input, from: archive)
        let start = archive.payloadOffset + UInt64(part.offset)
        guard start <= size, UInt64(part.length) <= size - start else {
            throw ArchiveError.invalidRange
        }
        try input.seek(toOffset: start)
        // Cancellation before publication must not create even an empty staging file.
        try Task.checkCancellation()
        // A backup may still be truncated while streaming. Remove partial
        // output on every read/write failure rather than importing bad audio.
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: target)
            // A successful write is not a successful extraction until the
            // destination has been flushed and closed. In particular, do not
            // hand a partially persisted audio file to the library importer.
            do {
                var remaining = part.length
                while remaining > 0 {
                    try Task.checkCancellation()
                    let amount = Int(min(remaining, 64 * 1024))
                    guard let data = try input.read(upToCount: amount), !data.isEmpty else {
                        throw ArchiveError.invalidRange
                    }
                    try output.write(contentsOf: data)
                    remaining -= Int64(data.count)
                }
                try verifyArchive(input, from: archive)
                try Task.checkCancellation()
                try output.synchronize()
                try output.close()
                try verifyArchive(input, from: archive)
                // The last archive verification may complete after cancellation.
                // Throw inside the cleanup scope so no completed temporary audio
                // is handed to an importer whose restore was already cancelled.
                try Task.checkCancellation()
            } catch {
                try? output.close()
                throw error
            }
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /// Publish an optional archive sidecar without leaving orphaned files when
    /// cancellation or a post-write verification fails. The caller must choose
    /// a fresh UUID-based filename and only persist its reference after return.
    /// The preflight refuses existing paths rather than replacing user data.
    static func writeRestoredSidecar(_ bytes: Data, to destination: URL,
                                     validate: () throws -> Void = {}) throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        // Data.write(.atomic) may replace a destination created after an
        // existence check. Stage privately in the same directory and publish
        // with a hard link: link(2) fails atomically if any entry already
        // occupies the destination, including a dangling symbolic link.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".mp3shelf-sidecar-\(UUID().uuidString).tmp")
        var published = false
        defer { try? manager.removeItem(at: staging) }
        do {
            try bytes.write(to: staging, options: .atomic)
            let handle = try FileHandle(forWritingTo: staging)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try Task.checkCancellation()
            try manager.linkItem(at: staging, to: destination)
            published = true
            try validate()
            try Task.checkCancellation()
        } catch {
            // Only remove the destination after *our* no-replace link won.
            // Never remove a pre-existing file or symlink on a failed link.
            if published { try? manager.removeItem(at: destination) }
            throw error
        }
    }

    static func readBytes(_ part: Part, from archive: Opened) throws -> Data {
        guard containsArtworkPart(part, in: archive) else { throw ArchiveError.invalidRange }
        // Only small artwork/metadata slices belong in memory. A malformed
        // Part must not turn a backup restore into an unbounded allocation or
        // overflow the seek offset before the file is read.
        guard part.offset >= 0, part.length > 0, part.length <= 20 * 1024 * 1024,
              UInt64(part.offset) <= UInt64.max - archive.payloadOffset else {
            throw ArchiveError.invalidRange
        }
        let handle = try FileHandle(forReadingFrom: archive.url)
        defer { try? handle.close() }
        let size = try verifyArchive(handle, from: archive)
        let start = archive.payloadOffset + UInt64(part.offset)
        guard start <= size, UInt64(part.length) <= size - start else {
            throw ArchiveError.invalidRange
        }
        try handle.seek(toOffset: start)
        // FileHandle.read(upToCount:) may return fewer bytes than requested
        // without reaching EOF. Accumulate bounded metadata slices until the
        // declared range is complete; never accept a truncated sidecar.
        var result = Data()
        result.reserveCapacity(Int(part.length))
        var remaining = Int(part.length)
        while remaining > 0 {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(remaining, 64 * 1024)),
                  !chunk.isEmpty else { throw ArchiveError.invalidRange }
            result.append(chunk)
            remaining -= chunk.count
        }
        try verifyArchive(handle, from: archive)
        // Do not return recovered sidecar bytes after a cancellation that raced
        // with the final archive identity verification.
        try Task.checkCancellation()
        return result
    }

    /// Compare recordings byte-for-byte without loading either audio file into memory.
    /// Filename and size alone are not reliable duplicate identifiers: different
    /// recordings can have identical names and byte counts.
    static func audioFilesIdentical(_ firstURL: URL, _ secondURL: URL) -> Bool {
        // Restore cancellation must not spend minutes comparing large files
        // or treat an interrupted comparison as proof of a duplicate.
        guard !Task.isCancelled else { return false }
        guard let first = try? FileHandle(forReadingFrom: firstURL) else { return false }
        defer { try? first.close() }
        guard let second = try? FileHandle(forReadingFrom: secondURL) else { return false }
        defer { try? second.close() }
        do {
            // Reject different lengths immediately and cap the comparison to
            // the sizes observed at open. A concurrently growing source must
            // never turn duplicate detection into an unbounded read.
            // Duplicate detection controls whether restore skips an incoming
            // recording. Never trust a comparison against a symlink or a
            // concurrently replaced/modified catalog audio file.
            var firstBefore = stat()
            var secondBefore = stat()
            guard fstat(first.fileDescriptor, &firstBefore) == 0,
                  fstat(second.fileDescriptor, &secondBefore) == 0,
                  (firstBefore.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  (secondBefore.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                return false
            }
            let firstIdentity = ArchiveSourceIdentity(firstBefore)
            let secondIdentity = ArchiveSourceIdentity(secondBefore)
            var firstNamed = stat()
            var secondNamed = stat()
            guard lstat(firstURL.path, &firstNamed) == 0,
                  lstat(secondURL.path, &secondNamed) == 0,
                  firstIdentity.matches(firstNamed),
                  secondIdentity.matches(secondNamed) else { return false }
            let firstLength = try first.seekToEnd()
            let secondLength = try second.seekToEnd()
            guard firstLength == secondLength,
                  firstLength > 0,
                  firstLength <= UInt64(maxTrackBytes),
                  firstIdentity.size == off_t(firstLength),
                  secondIdentity.size == off_t(secondLength) else { return false }
            try first.seek(toOffset: 0)
            try second.seek(toOffset: 0)
            var remaining = firstLength
            while remaining > 0 {
                guard !Task.isCancelled else { return false }
                let amount = Int(min(remaining, 64 * 1024))
                // Independent handles may return different short-read
                // boundaries for identical bytes. Compare complete chunks.
                let a = try readExactly(amount, from: first)
                let b = try readExactly(amount, from: second)
                guard a.count == amount, b.count == amount, a == b else {
                    return false
                }
                remaining -= UInt64(amount)
            }
            // An equal byte stream is insufficient if either source changed
            // while being read. Fail closed so restore never skips audio based
            // on a torn comparison. Existing user files are never modified.
            guard (try first.read(upToCount: 1) ?? Data()).isEmpty,
                  (try second.read(upToCount: 1) ?? Data()).isEmpty else {
                return false
            }
            var firstAfter = stat()
            var secondAfter = stat()
            return !Task.isCancelled &&
                   fstat(first.fileDescriptor, &firstAfter) == 0 &&
                   fstat(second.fileDescriptor, &secondAfter) == 0 &&
                   firstIdentity.matches(firstAfter) &&
                   secondIdentity.matches(secondAfter) &&
                   lstat(firstURL.path, &firstNamed) == 0 &&
                   lstat(secondURL.path, &secondNamed) == 0 &&
                   firstIdentity.matches(firstNamed) &&
                   secondIdentity.matches(secondNamed)
        } catch {
            return false
        }
    }

    /// Read at most the requested bytes in bounded chunks. Short reads are
    /// legal even for regular files; callers decide whether EOF is an error.
    /// The archive header, JSON manifest and duplicate comparisons all use
    /// this to avoid accepting incomplete data or rejecting valid short reads.
    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(remaining, 64 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            result.append(chunk)
            remaining -= chunk.count
        }
        return result
    }

    static func audioExtension(for track: Track) throws -> String {
        // A portable archive's original filename is display metadata, not
        // authoritative media identity. Browser imports can preserve a stale
        // ".mp3" filename for AAC/MP4 bytes. Selecting the suffix from that
        // name first causes AVFoundation to use the wrong container parser.
        // Prefer the declared media type, retaining the filename only as a
        // compatibility fallback for older archives without a known MIME type.
        let ext = URL(fileURLWithPath: track.originalName ?? "").pathExtension.lowercased()
        // MIME parameters (e.g. audio/mp4; codecs="mp4a.40.2") do not
        // change the media container. Preserve valid browser exports.
        let mediaType = track.audio.type.split(separator: ";", maxSplits: 1,
                                               omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch mediaType {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/aac": return "aac"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "", "application/octet-stream":
            if ["mp3", "m4a", "aac", "wav", "aif", "aiff"].contains(ext) { return ext }
            throw ArchiveError.unsupportedAudio
        default:
            // Do not reinterpret a declared but unsupported container as MP3
            // just because the untrusted filename ends in ".mp3".
            throw ArchiveError.unsupportedAudio
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
