import Foundation

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
    var errors: [String] = []

    var description: String {
        var result = "Imported \(imported) song\(imported == 1 ? "" : "s")."
        if skipped > 0 { result += " Skipped \(skipped) duplicate\(skipped == 1 ? "" : "s")." }
        if !errors.isEmpty { result += " \(errors.count) failed: " + errors.prefix(2).joined(separator: "; ") }
        return result
    }
}

struct PlaylistImportReport {
    var playlistName: String
    var matched: Int
    var missing: Int
}
