import Foundation

/// Independent downloadable recordings remain individual, recognizable files
/// in Files → On My iPhone → MP3 Shelf → Music, without filename collisions.
/// Accept a normal Spotify playlist share link without following redirects or
/// accidentally allowing unrelated hosts into authenticated API requests.
enum SpotifyPlaylistLinks {
    static func playlistID(from value: String) -> String? {
        guard let url = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "open.spotify.com",
              url.user == nil, url.password == nil else { return nil }
        let segments = url.path.split(separator: "/")
        guard segments.count == 2, segments[0] == "playlist" else { return nil }
        let identifier = String(segments[1])
        guard identifier.count == 22, identifier.allSatisfy({ $0.isASCII && $0.isLetter || $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return identifier
    }
}

enum LocalAudioFileNaming {
    static func storageName(originalName: String, id: UUID, fileExtension: String) -> String {
        let name = URL(fileURLWithPath: originalName)
            .deletingPathExtension().lastPathComponent
        let cleaned = String(name.map { character -> Character in
            "/\\:*?\"<>|".contains(character) || character.isNewline ? "-" : character
        })
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let stem = String((cleaned.isEmpty ? "Offline audio" : cleaned).prefix(96))
        return "\(stem) [\(id.uuidString.prefix(12))].\(fileExtension.lowercased())"
    }
}

/// A failed import must never delete an existing recording at its destination.
/// Validate a unique extension-preserving staging copy, then publish with a
/// no-replace hard link. The catalog commit is the last step; failed commits
/// unlink only the recording published by this transaction.
/// Only imports with a durable, app-created intent are eligible for automatic
/// recovery. Unidentified files and stale staging copies are never deleted.
struct LocalAudioRecoveryRecord: Codable {
    let version: Int
    let track: MusicTrack
    let stagingName: String
    let audioLength: Int64

    static func journalName(for id: UUID) -> String {
        ".mp3shelf-recovery-\(id.uuidString).json"
    }

    static func journalURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(journalName(for: id))
    }

    static func pending(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter {
            $0.lastPathComponent.hasPrefix(".mp3shelf-recovery-") &&
            $0.pathExtension == "json"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func read(_ journal: URL, in directory: URL) throws -> Self {
        guard LocalLibraryFileSafety.validName(journal.lastPathComponent),
              journal.deletingLastPathComponent().standardizedFileURL ==
                directory.standardizedFileURL,
              let bytes = try PortableShelfArchive.readSidecar(
                  named: journal.lastPathComponent, from: directory,
                  maximumBytes: 64 * 1024) else {
            throw PortableShelfArchive.ArchiveError.invalidManifest
        }
        let record = try JSONDecoder().decode(Self.self, from: bytes)
        let allowed = ["mp3", "m4a", "aac", "wav", "aif", "aiff"]
        guard record.version == 1,
              journal.lastPathComponent == journalName(for: record.track.id),
              LocalLibraryFileSafety.validName(record.track.fileName),
              LocalLibraryFileSafety.validName(record.stagingName),
              record.stagingName.hasPrefix(".mp3shelf-import-"),
              !record.track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.audioLength > 0,
              record.audioLength <= PortableShelfArchive.maxTrackBytes,
              record.track.duration.isFinite, record.track.duration > 0,
              allowed.contains(URL(fileURLWithPath: record.track.fileName).pathExtension.lowercased()),
              URL(fileURLWithPath: record.stagingName).pathExtension.lowercased() ==
                  URL(fileURLWithPath: record.track.fileName).pathExtension.lowercased() else {
            throw PortableShelfArchive.ArchiveError.invalidManifest
        }
        return record
    }

    /// Reattach only a validated, ordinary on-disk recording. Never overwrite
    /// a destination (including a symlink) or delete unidentified bytes.
    /// The verifier is AVFoundation in production and deterministic fixture
    /// bytes in the portable regression suite.
    /// Never discard an interrupted import's journal solely because the
    /// library entry exists. A protected/missing recording may still need
    /// its staged bytes; preserve existing catalog metadata on recovery.
    func restoreExistingTrack(_ existing: MusicTrack, in directory: URL,
                              verify: (URL) -> Bool) throws -> Bool {
        guard existing.id == track.id && existing.fileName == track.fileName else {
            return false
        }
        return try restorePublication(in: directory, verify: verify) != nil
    }

    func restorePublication(in directory: URL,
                            verify: (URL) -> Bool) throws -> URL? {
        guard LocalLibraryFileSafety.validName(track.fileName),
              LocalLibraryFileSafety.validName(stagingName) else { return nil }
        func eligible(_ name: String) -> URL? {
            guard let file = LocalLibraryFileSafety.regularFile(
                named: name, in: directory),
                  let attributes = try? FileManager.default.attributesOfItem(
                      atPath: file.path),
                  (attributes[.size] as? NSNumber)?.int64Value == audioLength,
                  verify(file) else { return nil }
            return file
        }
        if let published = eligible(track.fileName) { return published }
        // A preexisting but damaged/aliased destination is not ours to fix
        // by replacement: keep both files for manual recovery.
        let destination = directory.appendingPathComponent(track.fileName)
        guard !FileManager.default.fileExists(atPath: destination.path),
              let staged = eligible(stagingName) else { return nil }
        try FileManager.default.linkItem(at: staged, to: destination)
        return eligible(track.fileName)
    }
}

/// A new import validates a unique staged file before publishing an audio
/// destination with no-replace semantics. The optional recovery intent is
/// written before publication, so an OS termination between the hard link
/// and catalog commit never permanently hides the recording from the library.
enum LocalAudioImportTransaction {
    static func perform(from source: URL, to destination: URL,
                        validate: (URL) throws -> Void,
                        recoveryTrack: (() throws -> MusicTrack)? = nil,
                        rollbackPublished: (URL) throws -> Void = {
                            try FileManager.default.removeItem(at: $0)
                        },
                        persist: () throws -> Void) throws {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(
            ".mp3shelf-import-\(UUID().uuidString).\(destination.pathExtension)")
        // If rollback cannot unlink a published recording, retain BOTH the
        // staged bytes and the recovery journal. A later process can inspect
        // and repair the interrupted transaction without touching user audio.
        var preserveStagingForRecovery = false
        defer {
            if !preserveStagingForRecovery {
                try? manager.removeItem(at: staging)
            }
        }
        try manager.copyItem(at: source, to: staging)
        try validate(staging)
        var journal: URL?
        // Retain the intent when an attempted rollback cannot remove the
        // published file. On relaunch the durable journal can safely reattach
        // that recording instead of leaving inaccessible user-owned bytes.
        var mayRemoveJournal = true
        defer {
            if mayRemoveJournal, let journal {
                try? manager.removeItem(at: journal)
            }
        }
        if let recoveryTrack {
            let track = try recoveryTrack()
            guard track.fileName == destination.lastPathComponent,
                  LocalLibraryFileSafety.validName(track.fileName) else {
                throw PortableShelfArchive.ArchiveError.invalidManifest
            }
            let size = (try manager.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?
                .int64Value ?? -1
            guard size > 0, size <= PortableShelfArchive.maxTrackBytes else {
                throw PortableShelfArchive.ArchiveError.oversized
            }
            let record = LocalAudioRecoveryRecord(
                version: 1, track: track,
                stagingName: staging.lastPathComponent, audioLength: size)
            let bytes = try JSONEncoder().encode(record)
            guard bytes.count <= 64 * 1024 else {
                throw PortableShelfArchive.ArchiveError.oversized
            }
            let target = LocalAudioRecoveryRecord.journalURL(for: track.id, in: directory)
            // A temporary journal + no-replace publication prevents an old
            // interrupted intent from being overwritten by a new attempt.
            let temporaryJournal = directory.appendingPathComponent(
                ".mp3shelf-recovery-\(UUID().uuidString).partial")
            defer { try? manager.removeItem(at: temporaryJournal) }
            try bytes.write(to: temporaryJournal, options: .atomic)
            try manager.linkItem(at: temporaryJournal, to: target)
            journal = target
        }
        // Never overwrite an earlier recording, even on a filename collision.
        try manager.linkItem(at: staging, to: destination)
        do {
            try persist()
        } catch {
            // Only this transaction published the destination. A killed process
            // leaves the journal for recovery; ordinary failures roll back.
            // A failed unlink must NOT erase the only recovery intent.
            do {
                try rollbackPublished(destination)
            } catch {
                mayRemoveJournal = false
                preserveStagingForRecovery = journal != nil
            }
            throw error
        }
    }
}

/// Catalog filenames are data, not authorized filesystem paths. Only files
/// directly owned by MP3 Shelf may be copied into a backup or unlinked after
/// a successful catalog transaction. Fail closed for missing, linked or
/// malformed legacy paths instead of touching files outside the library.
enum LocalLibraryFileSafety {
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    /// APFS on iPhone is normally case-insensitive. Legacy catalogs can hold
    /// differently cased spellings of one physical filename. When deleting a
    /// track, conservatively retain any file still referenced under a spelling
    /// that could resolve to the same inode. An orphan is safer than data loss.
    static func isReferenced(_ filename: String, by remainingNames: [String?]) -> Bool {
        remainingNames.contains { other in
            guard let other else { return false }
            return filename.compare(other, options: [.caseInsensitive, .diacriticInsensitive],
                                    locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        }
    }
    static func regularFile(named name: String?, in directory: URL) -> URL? {
        guard let name, validName(name) else {
            return nil
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = directory.appendingPathComponent(name, isDirectory: false)
        // Resolve final-component symlinks as well as parent-directory links.
        guard file.resolvingSymlinksInPath().standardizedFileURL
                .deletingLastPathComponent() == root else { return nil }
        guard let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isSymbolicLink == false, values.isRegularFile == true else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return file
    }
}

enum RepeatMode: String, Codable, CaseIterable {
    case off, all, one

    var systemImage: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

struct MusicTrack: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var artist: String
    var album: String
    var fileName: String
    var originalFileName: String
    var artworkFileName: String?
    var lyricsFileName: String?
    var duration: TimeInterval
    var addedAt: Date
    var isFavorite: Bool
    // Set only for files obtained from a catalog with uploader-declared license metadata.
    var sourceAttribution: AudioSourceAttribution? = nil
    // Keeps stable IDs from browser backups so repeat restores are idempotent
    // even if the user renames the local file or edits the song metadata.
    var portableBackupID: String? = nil

    init(id: UUID = UUID(), title: String, artist: String, album: String,
         fileName: String, originalFileName: String, artworkFileName: String? = nil, lyricsFileName: String? = nil,
         duration: TimeInterval, addedAt: Date = .now, isFavorite: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.fileName = fileName
        self.originalFileName = originalFileName
        self.artworkFileName = artworkFileName
        self.lyricsFileName = lyricsFileName
        self.duration = duration
        self.addedAt = addedAt
        self.isFavorite = isFavorite
    }
}

struct PlaylistWish: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var artist: String
    var album: String
    var spotifyURL: String?
    // Used to reject alternate recordings when matching independent downloads.
    var durationSeconds: Double? = nil
    var artistNames: [String]? = nil
    var appleMusicItemID: String? = nil

    func matchesSourceRequest(_ other: PlaylistWish) -> Bool {
        id == other.id && title == other.title && artist == other.artist &&
            artistNames == other.artistNames && durationSeconds == other.durationSeconds
    }
}

/// Media-library IDs are local to a device. A persisted installation namespace
/// prevents a restored backup from syncing against an unrelated device's IDs.
enum AppleMusicLibraryIdentity {
    static func key(namespace: UUID, persistentID: UInt64) -> String {
        "\(namespace.uuidString):\(persistentID)"
    }

    static func canonical(_ value: String?) -> String? {
        // UUID, separator and at most 20 decimal UInt64 digits.
        guard let value, value.count <= 57 else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let namespace = UUID(uuidString: String(parts[0])),
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let id = UInt64(parts[1]), id > 0 else { return nil }
        return key(namespace: namespace, persistentID: id)
    }
}

enum ImportedPlaylistIdentity {
    static func key(sourceURL: String?, appleMusicLibraryID: String?) -> String? {
        if let id = sourceURL.flatMap(SpotifyPlaylistLinks.playlistID(from:)) { return "spotify:\(id)" }
        return AppleMusicLibraryIdentity.canonical(appleMusicLibraryID).map { "apple-music:\($0)" }
    }
}

struct AppleMusicPlaylistSummary: Identifiable, Sendable {
    let id: UInt64
    let name: String
    let itemCount: Int
}

struct AppleMusicTrackSnapshot: Sendable {
    let id: UInt64
    let title: String
    let artist: String
    let album: String
    let duration: Double
    var isMusic = true
}

struct AppleMusicPlaylistSnapshot: Sendable {
    static let maximumTracks = 20_000
    let id: UInt64
    let name: String
    let items: [AppleMusicTrackSnapshot]

    enum ImportFailure: LocalizedError {
        case empty, tooLarge, incomplete, unsupported
        var errorDescription: String? {
            switch self {
            case .empty: return "This Apple Music playlist has no songs."
            case .tooLarge: return "Import supports up to 20,000 songs per playlist."
            case .incomplete: return "Some songs are missing library details. Let the playlist finish syncing in Music, then refresh and retry."
            case .unsupported: return "This playlist contains non-music items. Choose a playlist of songs or music videos."
            }
        }
    }

    func wishes(namespace: UUID) throws -> [PlaylistWish] {
        guard !items.isEmpty else { throw ImportFailure.empty }
        guard items.count <= Self.maximumTracks else { throw ImportFailure.tooLarge }
        guard items.allSatisfy(\.isMusic) else { throw ImportFailure.unsupported }
        guard id > 0, items.allSatisfy({
            $0.id > 0 && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { throw ImportFailure.incomplete }
        return items.map { item in
            let artist = item.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            return PlaylistWish(title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                artist: artist, album: item.album, spotifyURL: nil,
                durationSeconds: item.duration.isFinite && item.duration > 0 ? item.duration : nil,
                artistNames: [artist],
                appleMusicItemID: AppleMusicLibraryIdentity.key(namespace: namespace, persistentID: item.id))
        }
    }
}

struct AudioSourceAttribution: Codable, Hashable {
    var pageURL: String
    var licenseURL: String
    var providerName: String
}

/// A direct file matching the requested recording. License metadata is optional.
struct AudioCatalogMatch: Codable, Sendable, Equatable {
    let downloadURL: URL
    let itemURL: URL
    let licenseURL: URL?
    let sourceName: String
}

struct RecordingCandidate: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let uploader: String
    let durationSeconds: Double?
    var verifiedArtist = false
    var isLive = false

    var pageURL: URL {
        var parts = URLComponents(string: "https://www.youtube.com/watch")!
        parts.queryItems = [URLQueryItem(name: "v", value: id)]
        return parts.url!
    }
}

enum AudioSourceLinks {
    static func youtubeVideoID(_ url: URL) -> String? {
        guard url.scheme == "https", ["youtube.com", "www.youtube.com"].contains(url.host?.lowercased() ?? ""),
              url.path == "/watch", url.user == nil, url.password == nil,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "v" })?.value,
              value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    static func isResolvedAudioURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host.hasSuffix(".googlevideo.com"), url.path == "/videoplayback",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let mime = items.filter { $0.name == "mime" || $0.name == "mimetype" }
        guard mime.count == 1, ["audio/mp4", "audio/m4a"].contains(mime[0].value ?? ""),
              items.contains(where: { ["sig", "signature", "lsig"].contains($0.name) && !($0.value ?? "").isEmpty })
        else { return false }
        if let size = items.first(where: { $0.name == "clen" })?.value {
            guard let bytes = Int64(size), bytes > 0, bytes <= 100 * 1024 * 1024 else { return false }
        }
        return true
    }

    static func hasExpired(_ url: URL, at date: Date = .now) -> Bool {
        guard isResolvedAudioURL(url),
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "expire" })?.value,
              let seconds = Double(raw), seconds.isFinite else { return false }
        return seconds <= date.timeIntervalSince1970
    }
}

struct MusicPlaylist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var trackIDs: [UUID] = []
    var missingTracks: [PlaylistWish] = []
    // Keeps the original CSV order when missing songs become available later.
    var sourceOrder: [PlaylistWish] = []
    var sourceURL: String? = nil
    var appleMusicLibraryID: String? = nil
    // Preserve non-UUID playlist IDs from web .mp3shelf archives across
    // app relaunches and repeat restores; not a Spotify account credential.
    var portableBackupID: String? = nil
    var createdAt: Date = .now

    /// A separate local playlist, sharing audio files but no sync/restore identity.
    func localCopy() -> MusicPlaylist {
        var copy = MusicPlaylist(name: name + " Copy")
        copy.trackIDs = trackIDs
        let missingIDs = Set(missingTracks.map(\.id))
        let orderedIDs = Set(sourceOrder.map(\.id))
        let entries = sourceOrder + missingTracks.filter { !orderedIDs.contains($0.id) }
        for wish in entries {
            let entry = PlaylistWish(title: wish.title, artist: wish.artist,
                                     album: wish.album, spotifyURL: wish.spotifyURL,
                                     durationSeconds: wish.durationSeconds,
                                     artistNames: wish.artistNames, appleMusicItemID: wish.appleMusicItemID)
            copy.sourceOrder.append(entry)
            if missingIDs.contains(wish.id) { copy.missingTracks.append(entry) }
        }
        return copy
    }

    func matchesPortableBackupID(_ backupID: String) -> Bool {
        // A browser restore may have assigned a different portable identity
        // to a playlist whose local UUID happens to match another archive.
        // Once a portable identity is established, it is authoritative.
        if let portableBackupID { return portableBackupID == backupID }
        return UUID(uuidString: backupID) == id
    }

    /// Restore a portable playlist without reusing another playlist's local
    /// UUID. The original archive identity is stored separately and survives
    /// re-export, so the new UUID does not break repeat-restore matching.
    static func restoredLocalID(for portableID: String, existing: [MusicPlaylist]) -> UUID {
        if let proposed = UUID(uuidString: portableID),
           !existing.contains(where: { $0.id == proposed }) {
            return proposed
        }
        var fresh = UUID()
        let occupied = Set(existing.map(\.id))
        while occupied.contains(fresh) { fresh = UUID() }
        return fresh
    }
}

struct PersistedLibrary: Codable {
    static let writeFailureDomain = "MP3Shelf.LibraryWrite"
    var tracks: [MusicTrack]
    var playlists: [MusicPlaylist]

    /// Only a truly absent catalog means first launch. An existing but unreadable
    /// or malformed library must throw instead of masquerading as an empty one.
    static func readIfPresent(from url: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func write(to url: URL) throws {
        do {
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            throw NSError(domain: Self.writeFailureDomain, code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The music library could not be saved. The audio was not imported; check local storage and retry.",
                NSUnderlyingErrorKey: error
            ])
        }
    }
}

struct ImportReport {
    var imported = 0
    var skipped = 0
    var playlistsAdded = 0
    var playlistsUpdated = 0
    var errors: [String] = []

    var description: String {
        var result = "Imported \(imported) song\(imported == 1 ? "" : "s")."
        if skipped > 0 { result += " Skipped \(skipped) duplicate\(skipped == 1 ? "" : "s")." }
        if playlistsAdded > 0 {
            result += " Added \(playlistsAdded) playlist\(playlistsAdded == 1 ? "" : "s")."
        }
        if playlistsUpdated > 0 {
            result += " Reconnected songs in \(playlistsUpdated) existing playlist\(playlistsUpdated == 1 ? "" : "s")."
        }
        if !errors.isEmpty { result += " \(errors.count) failed: " + errors.prefix(2).joined(separator: "; ") }
        return result
    }
}

struct PlaylistImportReport {
    var playlistID: UUID
    var playlistName: String
    var matched: Int
    var missing: Int
}

#if canImport(AVFoundation)
import AVFoundation
import AudioToolbox

/// Inspect actual compressed file format; a suffix is not codec evidence.
enum DownloadedAudioFormat {
    static func isMP3(_ url: URL) throws -> Bool {
        let audio = try AVAudioFile(forReading: url)
        return audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEGLayer3
    }
}
#endif

/// A manual pause, stop or route loss cancels any pending automatic resume.
struct PlaybackInterruptionState {
    private(set) var wantsResume = false

    mutating func began(wasPlaying: Bool) {
        wantsResume = wantsResume || wasPlaying
    }

    mutating func ended(systemAllowsResume: Bool) -> Bool {
        let resume = wantsResume && systemAllowsResume
        wantsResume = false
        return resume
    }

    mutating func cancelResume() { wantsResume = false }
}

/// Response admission only; decoding, identity and duration still determine import.
enum DownloadedAudioContentType {
    static func allows(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let mime = raw.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["audio/mpeg", "audio/mp3", "audio/x-mpeg", "application/octet-stream",
                "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac", "audio/x-aac",
                "audio/wav", "audio/wave", "audio/x-wav", "audio/aiff", "audio/x-aiff",
                "audio/flac", "audio/x-flac"].contains(mime)
    }
}

enum DownloadedAudioRange {
    static let incompleteMessage = "The source sent only part of the audio file. Try another source."

    static func coversCompleteFile(status: Int, contentRange: String?, downloadedBytes: Int64) -> Bool {
        guard downloadedBytes > 0 else { return false }
        guard status == 206 || contentRange != nil else { return true }
        // A standalone file must cover byte zero through the end of the
        // representation. The decoder may accept a truncated MP3 prefix.
        let fields = contentRange?.split(whereSeparator: { $0 == " " || $0 == "\t" }) ?? []
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return false }
        let extent = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard extent.count == 2 else { return false }
        let bounds = extent[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              [bounds[0], bounds[1], extent[1]].allSatisfy({
                  !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
              }) else { return false }
        return Int64(bounds[0]) == 0 && Int64(bounds[1]) == downloadedBytes - 1 &&
            Int64(extent[1]) == downloadedBytes
    }
}
