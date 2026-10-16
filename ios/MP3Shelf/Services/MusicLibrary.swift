import AVFoundation
import Foundation
import Combine
import UIKit

struct AutomaticDownloadProgress {
    let playlistID: UUID
    let total: Int
    var processed: Int = 0
    var downloaded: Int = 0
    var queued: Int = 0
    var unavailable: Int = 0
    var failed: Int = 0
    var currentSong: String = ""
    var isRunning: Bool = true
    var wasCancelled: Bool = false
}

@MainActor
final class MusicLibrary: ObservableObject {
    @Published private(set) var tracks: [MusicTrack] = []
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published var isImporting = false
    @Published var pendingBackgroundDownloads = 0
    @Published private(set) var automaticDownloadProgress: AutomaticDownloadProgress?
    private var automaticDownloadTask: Task<Void, Never>?
    @Published private(set) var discoveryJobs: [SourceDiscoveryJob] = []

    private let manager = FileManager.default
    private let storageRoot: URL
    private let musicDirectory: URL
    private let artworkDirectory: URL
    private let lyricsDirectory: URL
    private let databaseURL: URL
    private let discoveryURL: URL

    init() {
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageRoot = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MP3Shelf", isDirectory: true)
        musicDirectory = documents.appendingPathComponent("Music", isDirectory: true)
        artworkDirectory = storageRoot.appendingPathComponent("Artwork", isDirectory: true)
        lyricsDirectory = storageRoot.appendingPathComponent("Lyrics", isDirectory: true)
        databaseURL = storageRoot.appendingPathComponent("library.json")
        discoveryURL = storageRoot.appendingPathComponent("source-discovery.json")
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
            if let saved = try? Data(contentsOf: discoveryURL),
               let decoded = try? JSONDecoder().decode([SourceDiscoveryJob].self, from: saved) {
                discoveryJobs = decoded.filter { job in playlists.contains { $0.id == job.playlistID } }
            }
        } catch {
            print("MP3 Shelf could not initialize local storage: \(error)")
        }
    }

    /// Creates the same v1 .mp3shelf archive used by the browser PWA.
    /// No Spotify tokens, account secrets or discovery queue internals are exported.
    func exportPortableBackup() throws -> URL {
        let items = tracks.map { track in
            let lyrics = track.lyricsFileName.flatMap {
                try? String(contentsOf: lyricsDirectory.appendingPathComponent($0), encoding: .utf8)
            }
            return PortableShelfArchive.MediaInput(
                track: track, audioURL: fileURL(for: track),
                artwork: artwork(for: track)?.jpegData(compressionQuality: 0.9),
                lyrics: lyrics
            )
        }
        let destination = manager.temporaryDirectory
            .appendingPathComponent("MP3Shelf-\(UUID().uuidString).mp3shelf")
        try PortableShelfArchive.export(items, playlists: playlists, to: destination)
        return destination
    }

    /// Adds valid files from a browser or native backup without deleting
    /// anything already on this iPhone. Archive metadata is validated first.
    func importPortableBackup(from url: URL) async throws -> ImportReport {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let archive = try PortableShelfArchive.open(url)
        var report = ImportReport()
        var restoredIDs: [String: UUID] = [:]
        for archived in archive.manifest.tracks {
            var temporary: URL?
            do {
                let ext = try PortableShelfArchive.audioExtension(for: archived)
                let file = try PortableShelfArchive.extract(
                    archived.audio, from: archive, extensionName: ext)
                temporary = file
                defer { try? manager.removeItem(at: file) }
                let initialName = archived.originalName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawName = initialName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? archived.name + "." + ext
                let original = URL(fileURLWithPath: rawName).lastPathComponent
                let imported = try await addLocalAudio(
                    sourceURL: file, originalName: original)
                if imported { report.imported += 1 }
                else { report.skipped += 1 }

                // Existing duplicate audio remains intact; don't overwrite its
                // favorite, title, artwork, lyrics or license information.
                guard imported, let index = tracks.indices.last else { continue }
                restoredIDs[archived.id] = tracks[index].id
                tracks[index].title = archived.name
                if let artist = archived.artist { tracks[index].artist = artist }
                if let album = archived.album { tracks[index].album = album }
                tracks[index].isFavorite = archived.isFavorite ?? false
                let epoch = archived.importedAt / 1000
                if epoch.isFinite && epoch > 0 {
                    tracks[index].addedAt = Date(timeIntervalSince1970: epoch)
                }
                if let attribution = archived.attribution,
                   attribution.sourceURL.hasPrefix("https://"),
                   attribution.licenseURL.hasPrefix("https://") {
                    tracks[index].sourceAttribution = AudioSourceAttribution(
                        pageURL: attribution.sourceURL,
                        licenseURL: attribution.licenseURL,
                        providerName: attribution.provider
                    )
                }
                if let artwork = archived.artwork {
                    let bytes = try PortableShelfArchive.readBytes(artwork, from: archive)
                    if UIImage(data: bytes) != nil {
                        let filename = tracks[index].id.uuidString + ".img"
                        try bytes.write(to: artworkDirectory.appendingPathComponent(filename),
                                        options: .atomic)
                        tracks[index].artworkFileName = filename
                    }
                }
                if let lyrics = archived.lyrics, !lyrics.isEmpty {
                    let filename = tracks[index].id.uuidString + ".lrc"
                    try Data(lyrics.utf8).write(
                        to: lyricsDirectory.appendingPathComponent(filename), options: .atomic)
                    tracks[index].lyricsFileName = filename
                }
                save()
            } catch {
                report.errors.append("\(archived.name): \(error.localizedDescription)")
            }
            if let temporary { try? manager.removeItem(at: temporary) }
        }
        for item in archive.manifest.playlists {
            let id = UUID(uuidString: item.id) ?? UUID()
            // A repeated restore must not duplicate the same native playlist ID.
            if playlists.contains(where: { $0.id == id }) { continue }
            var playlist = MusicPlaylist(id: id, name: item.name)
            playlist.sourceURL = item.sourceURL
            playlist.trackIDs = item.trackIds.compactMap { restoredIDs[$0] }
            playlist.sourceOrder = (item.wishes ?? []).map {
                PlaylistWish(title: $0.title, artist: $0.artist,
                             album: $0.album, spotifyURL: $0.spotifyURL)
            }
            playlist.missingTracks = playlist.sourceOrder
            playlists.append(playlist)
        }
        reconcileMissingSongs()
        save()
        return report
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

    private func addLocalAudio(sourceURL: URL, originalName: String,
                               expectedDuration: TimeInterval? = nil) async throws -> Bool {
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
            if let expectedDuration, abs(duration - expectedDuration) > 4 {
                throw MusicLibraryError.recordingDurationMismatch
            }
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


    /// Persist each search cursor so interrupted foreground discovery resumes.
    func startAutomaticDownloads(for playlistID: UUID) {
        guard let playlist = playlists.first(where: { $0.id == playlistID }),
              !playlist.missingTracks.isEmpty else { return }
        if let index = discoveryJobs.firstIndex(where: { $0.playlistID == playlistID && !$0.isComplete }) {
            discoveryJobs[index].isPaused = false
            discoveryJobs[index].lastError = nil
        } else {
            discoveryJobs.removeAll { $0.playlistID == playlistID }
            discoveryJobs.append(SourceDiscoveryJob(playlistID: playlistID, wishes: playlist.missingTracks))
        }
        persistDiscovery()
        resumePendingDiscovery()
    }

    func discoveryJob(for playlistID: UUID) -> SourceDiscoveryJob? {
        discoveryJobs.first(where: { $0.playlistID == playlistID })
    }

    func pauseSourceDiscovery(for playlistID: UUID) {
        guard let index = discoveryJobs.firstIndex(where: { $0.playlistID == playlistID }) else { return }
        discoveryJobs[index].isPaused = true
        persistDiscovery()
        if automaticDownloadProgress?.playlistID == playlistID { automaticDownloadTask?.cancel() }
    }

    func resumeSourceDiscovery(for playlistID: UUID) {
        guard let index = discoveryJobs.firstIndex(where: { $0.playlistID == playlistID }) else { return }
        discoveryJobs[index].isPaused = false
        discoveryJobs[index].lastError = nil
        persistDiscovery()
        resumePendingDiscovery()
    }

    func resumePendingDiscovery() {
        guard automaticDownloadTask == nil,
              let job = discoveryJobs.first(where: { !$0.isPaused && !$0.isComplete }) else { return }
        var progress = AutomaticDownloadProgress(playlistID: job.playlistID, total: job.wishes.count)
        progress.processed = job.nextIndex
        progress.queued = job.queued
        progress.failed = job.failed
        progress.unavailable = job.unavailable
        automaticDownloadProgress = progress
        automaticDownloadTask = Task { [weak self] in
            await self?.runAutomaticDownloads(playlistID: job.playlistID)
        }
    }

    private func persistDiscovery() {
        if let data = try? JSONEncoder().encode(discoveryJobs) {
            try? data.write(to: discoveryURL, options: .atomic)
        }
    }

    /// Resolved URLs transfer via Apple's background daemon. The UI receives
    /// results when the app is running or next reactivated by the system.
    func finishedBackgroundDownload(for playlistID: UUID, succeeded: Bool) {
        guard var progress = automaticDownloadProgress, progress.playlistID == playlistID else { return }
        if succeeded { progress.downloaded += 1 }
        else { progress.failed += 1 }
        automaticDownloadProgress = progress
    }

    func stopBackgroundTransfers(for playlistID: UUID) {
        BackgroundAudioDownloader.shared.stopTransfers(for: playlistID)
    }

    func importStagedAudio(from fileURL: URL, matching wish: PlaylistWish,
                           attribution: AudioSourceAttribution) async throws -> Bool {
        let bytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0 && bytes <= 100 * 1024 * 1024 else {
            throw MusicLibraryError.downloadFailed
        }
        let original = "\(wish.artist) - \(wish.title).mp3"
        let imported = try await addLocalAudio(sourceURL: fileURL,
                                               originalName: original,
                                               expectedDuration: wish.durationSeconds)
        if imported {
            // Metadata comes from the playlist's exact-match catalog entry, not
            // from arbitrary downloaded file tags that may be absent.
            if let last = tracks.indices.last {
                tracks[last].title = wish.title
                tracks[last].artist = wish.artist
                if !wish.album.isEmpty { tracks[last].album = wish.album }
                tracks[last].sourceAttribution = attribution
                save()
            }
            reconcileMissingSongs()
        }
        return imported
    }

    func cancelAutomaticDownloads() {
        if let playlistID = automaticDownloadProgress?.playlistID {
            pauseSourceDiscovery(for: playlistID)
        }
    }

    private func runAutomaticDownloads(playlistID: UUID) async {
        var blockedByNetwork = false
        while let index = discoveryJobs.firstIndex(where: { $0.playlistID == playlistID }) {
            var job = discoveryJobs[index]
            if Task.isCancelled || job.isPaused || job.isComplete { break }
            guard let wish = job.currentWish else { break }
            if var progress = automaticDownloadProgress {
                progress.currentSong = "\(wish.artist) — \(wish.title)"
                automaticDownloadProgress = progress
            }
            if MusicMatching.matchingTrack(for: wish, in: tracks) != nil ||
                BackgroundAudioDownloader.shared.isQueued(wish, for: playlistID) {
                job.record(.alreadyPresent)
            } else {
                do {
                    let source = try await AudioSourceFinder.findAcrossCatalogs(for: wish)
                    if Task.isCancelled { break }
                    if let source {
                        if BackgroundAudioDownloader.shared.enqueue(source: source, requested: wish, playlistID: playlistID) {
                            job.record(.queued)
                        } else { job.record(.failed) }
                    } else { job.record(.unavailable) }
                } catch is CancellationError {
                    break
                } catch {
                    job.lastError = error.localizedDescription
                    blockedByNetwork = true
                }
            }
            discoveryJobs[index] = job
            persistDiscovery()
            if var progress = automaticDownloadProgress {
                progress.processed = job.nextIndex
                progress.queued = job.queued
                progress.unavailable = job.unavailable
                progress.failed = job.failed
                automaticDownloadProgress = progress
            }
            if blockedByNetwork { break }
        }
        if var progress = automaticDownloadProgress {
            progress.isRunning = false
            progress.wasCancelled = Task.isCancelled
            progress.currentSong = ""
            automaticDownloadProgress = progress
        }
        automaticDownloadTask = nil
        if !blockedByNetwork { resumePendingDiscovery() }
    }

    func downloadAudio(from remoteURL: URL, matching wish: PlaylistWish? = nil,
                       attribution: AudioSourceAttribution? = nil) async throws -> ImportReport {
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
        let downloadedBytes = (try? manager.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard downloadedBytes > 0 && downloadedBytes <= 100 * 1024 * 1024 else {
            throw MusicLibraryError.downloadFailed
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
        let imported = try await addLocalAudio(sourceURL: staging,
                                               originalName: filename + "." + actualExtension,
                                               expectedDuration: wish?.durationSeconds)
        if imported {
            if let wish, let last = tracks.indices.last {
                // The catalog had to match title/artist (and known duration)
                // before the file was downloaded. Apply that playlist metadata
                // so this song immediately occupies its original playlist slot.
                tracks[last].title = wish.title
                tracks[last].artist = wish.artist
                if !wish.album.isEmpty { tracks[last].album = wish.album }
                tracks[last].sourceAttribution = attribution
                save()
            }
            reconcileMissingSongs()
        }
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
        reconcileMissingSongs()
    }

    func createPlaylist(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        playlists.append(MusicPlaylist(name: clean))
        save()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        discoveryJobs.removeAll { $0.playlistID == id }
        persistDiscovery()
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

    func trackSizeBytes(_ track: MusicTrack) -> Int64 {
        let size = (try? fileURL(for: track).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(max(size, 0))
    }

    var totalStorageBytes: Int64 {
        tracks.reduce(0) { $0 + trackSizeBytes($1) }
    }
}

enum MusicLibraryError: LocalizedError {
    case unsupportedFormat, invalidDownloadURL, downloadFailed, recordingDurationMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Only supported audio files (MP3, M4A, AAC, WAV, AIFF) can be imported."
        case .invalidDownloadURL: return "Enter a direct HTTPS audio URL. Spotify streaming links cannot be downloaded."
        case .downloadFailed: return "The audio download did not complete successfully."
        case .recordingDurationMismatch: return "The downloaded MP3 duration did not match the requested recording."
        }
    }
}
