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

struct PlaylistWish: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var artist: String
    var album: String
    var spotifyURL: String?
    // Used to reject alternate recordings when matching independent downloads.
    var durationSeconds: Double? = nil
}

struct AudioSourceAttribution: Codable, Hashable {
    var pageURL: String
    var licenseURL: String
    var providerName: String
}

struct MusicPlaylist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var trackIDs: [UUID] = []
    var missingTracks: [PlaylistWish] = []
    // Keeps the original CSV order when missing songs become available later.
    var sourceOrder: [PlaylistWish] = []
    var sourceURL: String? = nil
    // Preserve non-UUID playlist IDs from web .mp3shelf archives across
    // app relaunches and repeat restores; not a Spotify account credential.
    var portableBackupID: String? = nil
    var createdAt: Date = .now

    func matchesPortableBackupID(_ backupID: String) -> Bool {
        portableBackupID == backupID || UUID(uuidString: backupID) == id
    }
}

struct PersistedLibrary: Codable {
    var tracks: [MusicTrack]
    var playlists: [MusicPlaylist]
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
