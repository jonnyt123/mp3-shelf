import AVFoundation
import Foundation
import Combine
import UIKit

@MainActor
final class MusicLibrary: ObservableObject {
    @Published private(set) var tracks: [MusicTrack] = []
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published var isImporting = false

    private let manager = FileManager.default
    private let storageRoot: URL
    private let musicDirectory: URL
    private let artworkDirectory: URL
    private let lyricsDirectory: URL
    private let databaseURL: URL

    init() {
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageRoot = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MP3Shelf", isDirectory: true)
        musicDirectory = documents.appendingPathComponent("Music", isDirectory: true)
        artworkDirectory = storageRoot.appendingPathComponent("Artwork", isDirectory: true)
        lyricsDirectory = storageRoot.appendingPathComponent("Lyrics", isDirectory: true)
        databaseURL = storageRoot.appendingPathComponent("library.json")
        do {
            try manager.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            try manager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
            try manager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
            try manager.createDirectory(at: lyricsDirectory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: databaseURL) {
                let saved = try JSONDecoder().decode(PersistedLibrary.self, from: data)
                tracks = saved.tracks.filter { manager.fileExists(atPath: musicDirectory.appendingPathComponent($0.fileName).path) }
                playlists = saved.playlists
            }
        } catch {
            print("MP3 Shelf could not initialize local storage: \(error)")
        }
    }

    func fileURL(for track: MusicTrack) -> URL { musicDirectory.appendingPathComponent(track.fileName) }

    func artwork(for track: MusicTrack) -> UIImage? {
        guard let name = track.artworkFileName,
              let data = try? Data(contentsOf: artworkDirectory.appendingPathComponent(name)) else { return nil }
        return UIImage(data: data)
    }

    func lyrics(for track: MusicTrack) -> [LyricLine] {
        guard let filename = track.lyricsFileName,
              let bytes = try? Data(contentsOf: lyricsDirectory.appendingPathComponent(filename)),
              let content = String(data: bytes, encoding: .utf8) else { return [] }
        return LyricsParser.parse(content)
    }

    func importLyrics(from url: URL, for trackID: UUID) throws {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard ["lrc", "txt"].contains(url.pathExtension.lowercased()) else { throw LyricsError.unsupported }
        let data = try Data(contentsOf: url)
        guard data.count <= 512_000, String(data: data, encoding: .utf8) != nil else { throw LyricsError.unsupported }
        let filename = trackID.uuidString + ".lrc"
        try data.write(to: lyricsDirectory.appendingPathComponent(filename), options: .atomic)
        tracks[index].lyricsFileName = filename
        save()
    }

    func song(with id: UUID?) -> MusicTrack? {
        guard let id else { return nil }
        return tracks.first { $0.id == id }
    }

    func songs(in playlist: MusicPlaylist) -> [MusicTrack] {
        playlist.trackIDs.compactMap(song(with:))
    }

    func save() {
        do {
            let payload = try JSONEncoder().encode(PersistedLibrary(tracks: tracks, playlists: playlists))
            try payload.write(to: databaseURL, options: .atomic)
        } catch {
            print("MP3 Shelf could not save the music library: \(error)")
        }
    }

    func importAudio(urls: [URL]) async -> ImportReport {
        isImporting = true
        defer { isImporting = false }
        var report = ImportReport()
        for source in urls {
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            do {
                let outcome = try await addLocalAudio(sourceURL: source, originalName: source.lastPathComponent)
                if outcome { report.imported += 1 } else { report.skipped += 1 }
            } catch {
                report.errors.append(source.lastPathComponent + ": " + error.localizedDescription)
            }
        }
        if report.imported > 0 { reconcileMissingSongs() }
        return report
    }

    private func addLocalAudio(sourceURL: URL, originalName: String) async throws -> Bool {
        let extensionName = sourceURL.pathExtension.lowercased()
        let allowed = ["mp3", "m4a", "aac", "wav", "aif", "aiff"]
        guard allowed.contains(extensionName) else { throw MusicLibraryError.unsupportedFormat }
        let fileSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        // Avoid importing the same file more than once, without treating all tracks with the same title as duplicates.
        if tracks.contains(where: { track in
            track.originalFileName.caseInsensitiveCompare(originalName) == .orderedSame &&
            ((try? fileURL(for: track).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2) == fileSize
        }) { return false }

        let id = UUID()
        let destinationName = id.uuidString + "." + extensionName
        let destination = musicDirectory.appendingPathComponent(destinationName)
        try manager.copyItem(at: sourceURL, to: destination)
        do {
            let asset = AVURLAsset(url: destination)
            // Fail immediately for renamed HTML, corrupt files or codecs that AVAudioPlayer cannot decode.
            let playbackProbe = try AVAudioPlayer(contentsOf: destination)
            let duration = playbackProbe.duration
            let metadata = asset.commonMetadata
            func metadataString(_ key: AVMetadataKey) -> String? {
                AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common)
                    .first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let title = metadataString(.commonKeyTitle).flatMap { $0.isEmpty ? nil : $0 }
                ?? URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
            let artist = metadataString(.commonKeyArtist).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Artist"
            let album = metadataString(.commonKeyAlbumName).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Album"
            var artworkName: String?
            if let imageData = AVMetadataItem.metadataItems(from: metadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first?.dataValue,
               UIImage(data: imageData) != nil {
                let proposedName = id.uuidString + ".img"
                if (try? imageData.write(to: artworkDirectory.appendingPathComponent(proposedName), options: .atomic)) != nil {
                    artworkName = proposedName
                }
            }
            tracks.append(MusicTrack(id: id, title: title, artist: artist, album: album,
                                     fileName: destinationName, originalFileName: originalName,
                                     artworkFileName: artworkName, duration: duration))
            save()
            return true
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    func downloadAudio(from remoteURL: URL) async throws -> ImportReport {
        guard remoteURL.scheme?.lowercased() == "https", let host = remoteURL.host?.lowercased(),
              !host.hasSuffix("spotify.com"), !host.hasSuffix("spotifycdn.com"),
              !host.hasSuffix("scdn.co") else { throw MusicLibraryError.invalidDownloadURL }
        isImporting = true
        defer { isImporting = false }
        let (temporary, response) = try await URLSession.shared.download(from: remoteURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MusicLibraryError.downloadFailed
        }
        if let finalHost = http.url?.host?.lowercased(),
           ["spotify.com", "spotifycdn.com", "scdn.co"].contains(where: { finalHost == $0 || finalHost.hasSuffix("." + $0) }) {
            throw MusicLibraryError.invalidDownloadURL
        }
        let ext = remoteURL.pathExtension.lowercased()
        let mime = (http.mimeType ?? "").lowercased()
        let supported = ["mp3", "m4a", "aac", "wav", "aif", "aiff"]
        let mimeExtensions = ["audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mp4": "m4a",
                              "audio/x-m4a": "m4a", "audio/aac": "aac", "audio/wav": "wav",
                              "audio/x-wav": "wav", "audio/aiff": "aiff", "audio/x-aiff": "aiff"]
        guard (supported.contains(ext) || mimeExtensions[mime] != nil),
              !mime.contains("text/") && !mime.contains("html") else { throw MusicLibraryError.unsupportedFormat }
        let actualExtension = supported.contains(ext) ? ext : (mimeExtensions[mime] ?? "mp3")
        let filename = remoteURL.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "Downloaded audio"
        let staging = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + actualExtension)
        try manager.moveItem(at: temporary, to: staging)
        defer { try? manager.removeItem(at: staging) }
        let imported = try await addLocalAudio(sourceURL: staging, originalName: filename + "." + actualExtension)
        if imported { reconcileMissingSongs() }
        return ImportReport(imported: imported ? 1 : 0, skipped: imported ? 0 : 1)
    }

    func rename(_ track: MusicTrack, title: String, artist: String) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        tracks[index].title = cleanTitle
        tracks[index].artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].isFavorite.toggle()
        save()
    }

    func removeTrack(_ id: UUID) {
        guard let track = song(with: id) else { return }
        try? manager.removeItem(at: fileURL(for: track))
        if let artwork = track.artworkFileName {
            try? manager.removeItem(at: artworkDirectory.appendingPathComponent(artwork))
        }
        if let lyrics = track.lyricsFileName {
            try? manager.removeItem(at: lyricsDirectory.appendingPathComponent(lyrics))
        }
        tracks.removeAll { $0.id == id }
        for index in playlists.indices { playlists[index].trackIDs.removeAll { $0 == id } }
        save()
    }

    func createPlaylist(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        playlists.append(MusicPlaylist(name: clean))
        save()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func addTrack(_ trackID: UUID, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[index].trackIDs.contains(trackID) else { return }
        playlists[index].trackIDs.append(trackID)
        save()
    }

    func removeTrack(_ trackID: UUID, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.removeAll { $0 == trackID }
        if let track = song(with: trackID),
           let wishIndex = playlists[index].sourceOrder.firstIndex(where: { MusicMatching.matchingTrack(for: $0, in: [track]) != nil }) {
            playlists[index].sourceOrder.remove(at: wishIndex)
        }
        save()
    }

    func moveTracks(in playlistID: UUID, from offsets: IndexSet, to index: Int) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var items = playlists[playlistIndex].trackIDs
        // SwiftUI's move semantics: remove then insert at destination adjusted for removed positions.
        let moved = offsets.sorted().map { items[$0] }
        let insertionIndex = index - offsets.filter { $0 < index }.count
        for offset in offsets.sorted(by: >) { items.remove(at: offset) }
        items.insert(contentsOf: moved, at: max(0, min(insertionIndex, items.count)))
        playlists[playlistIndex].trackIDs = items
        save()
    }

    func importPlaylistCSV(data: Data, name: String, spotifyURL: String? = nil) throws -> PlaylistImportReport {
        importPlaylist(wishes: try PlaylistCSV.parse(data), name: name, sourceURL: spotifyURL)
    }

    func importPlaylist(wishes: [PlaylistWish], name: String, sourceURL: String? = nil) -> PlaylistImportReport {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var playlist = MusicPlaylist(name: trimmed.isEmpty ? "Imported Playlist" : trimmed)
        if let sourceURL, let parsed = URL(string: sourceURL),
           parsed.scheme == "https", parsed.host == "open.spotify.com", parsed.path.hasPrefix("/playlist/") {
            playlist.sourceURL = sourceURL
        }
        playlist.sourceOrder = wishes
        for wish in wishes {
            if let track = MusicMatching.matchingTrack(for: wish, in: tracks) {
                playlist.trackIDs.append(track.id)
            } else {
                playlist.missingTracks.append(wish)
            }
        }
        playlists.append(playlist)
        save()
        return PlaylistImportReport(playlistName: playlist.name, matched: playlist.trackIDs.count,
                                    missing: playlist.missingTracks.count)
    }

    private func reconcileMissingSongs() {
        for index in playlists.indices where !playlists[index].sourceOrder.isEmpty {
            let existing = playlists[index].trackIDs
            var ordered: [UUID] = []
            var missing: [PlaylistWish] = []
            for wish in playlists[index].sourceOrder {
                if let track = MusicMatching.matchingTrack(for: wish, in: tracks) {
                    ordered.append(track.id)
                } else {
                    missing.append(wish)
                }
            }
            // Retain songs the user manually added to the imported playlist.
            ordered.append(contentsOf: existing.filter { !ordered.contains($0) })
            playlists[index].trackIDs = ordered
            playlists[index].missingTracks = missing
        }
        save()
    }

    var totalStorageBytes: Int64 {
        tracks.reduce(0) { total, track in
            let size = (try? fileURL(for: track).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }
}

enum MusicLibraryError: LocalizedError {
    case unsupportedFormat, invalidDownloadURL, downloadFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Only supported audio files (MP3, M4A, AAC, WAV, AIFF) can be imported."
        case .invalidDownloadURL: return "Enter a direct HTTPS audio URL. Spotify streaming links cannot be downloaded."
        case .downloadFailed: return "The audio download did not complete successfully."
        }
    }
}
