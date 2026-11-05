import AVFoundation
import ShelfEncoder
import Foundation
import Combine
import UIKit
import Network

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

enum LibraryTrackSort: String, CaseIterable, Identifiable {
    case title = "Title"
    case recent = "Recently added"
    case artist = "Artist"
    case album = "Album"

    var id: String { rawValue }
}

@MainActor
final class MusicLibrary: ObservableObject {
    @Published private(set) var tracks: [MusicTrack] = [] {
        didSet { trackRevision &+= 1 }
    }
    // Do not rebuild thousands of lookup entries on each single-track edit.
    // The next read refreshes both indexes once and then uses O(1) UUID lookup
    // or normalized-title buckets for exact-match Spotify reconciliation.
    private var trackRevision: UInt64 = 0
    private var indexedRevision: UInt64 = .max
    private var indexedTracksByID: [UUID: MusicTrack] = [:]
    private var indexedByTitle = OfflineTrackIndex(tracks: [])
    private var sortedByTitle: [MusicTrack] = []
    private var sortedByRecent: [MusicTrack] = []
    private var sortedByArtist: [MusicTrack] = []
    private var sortedByAlbum: [MusicTrack] = []
    private let artworkCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published var isImporting = false
    @Published var pendingBackgroundDownloads = 0
    @Published private(set) var automaticDownloadProgress: AutomaticDownloadProgress?
    private var automaticDownloadTask: Task<Void, Never>?
    // Serializes bounded BGProcessingTask scans with network-triggered foreground scans.
    // All access runs on the MusicLibrary main actor.
    private var backgroundDiscoveryInProgress = false
    // False in URLSession-only headless launches: they may import completed
    // transfers but must not begin unrestricted catalog discovery.
    private var foregroundDiscoveryEnabled = false
    private var catalogRetryTask: Task<Void, Never>?
    private var scheduledCatalogRetryAt: Date?
    @Published private(set) var discoveryJobs: [SourceDiscoveryJob] = []

    // Wi-Fi is the default. Cellular downloads require explicit, session-only
    // permission for the individual playlist.
    @Published private(set) var isOnWiFi = false
    @Published private(set) var isOnCellular = false
    @Published private(set) var networkStatusKnown = false
    private var cellularApprovedPlaylists = Set<UUID>()
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "MP3Shelf.wifi-download-policy")

    func cellularApproved(for playlistID: UUID) -> Bool {
        cellularApprovedPlaylists.contains(playlistID)
    }

    private func networkAllowsDiscovery(for playlistID: UUID) -> Bool {
        networkStatusKnown && DownloadNetworkPolicy.canDiscover(
            onWiFi: isOnWiFi, onCellular: isOnCellular,
            explicitlyAllowCellular: cellularApprovedPlaylists.contains(playlistID))
    }

    /// User-initiated cellular override; never persisted or inferred.
    func downloadUsingCellular(for playlistID: UUID) {
        guard isOnCellular else { return }
        cellularApprovedPlaylists.insert(playlistID)
        BackgroundAudioDownloader.shared.enableCellular(for: playlistID)
        if discoveryJob(for: playlistID) == nil {
            startAutomaticDownloads(for: playlistID)
        } else {
            resumePendingDiscovery()
        }
    }

    /// A visible, active SwiftUI scene owns unbounded source lookups. iOS may
    /// create MusicLibrary for a background URLSession callback without a scene.
    func setForegroundDiscoveryEnabled(_ enabled: Bool) {
        guard foregroundDiscoveryEnabled != enabled else { return }
        foregroundDiscoveryEnabled = enabled
        if enabled {
            resumePendingDiscovery()
        } else {
            // Keep the persisted cursor intact; the system's bounded background
            // task can still look up additional songs when iOS grants it time.
            automaticDownloadTask?.cancel()
            catalogRetryTask?.cancel()
            catalogRetryTask = nil
            scheduledCatalogRetryAt = nil
        }
    }

    private func connectivityChanged(wifi: Bool, cellular: Bool) {
        isOnWiFi = wifi
        isOnCellular = cellular
        networkStatusKnown = true
        if let current = automaticDownloadProgress,
           current.isRunning && !networkAllowsDiscovery(for: current.playlistID) {
            automaticDownloadTask?.cancel()
        } else {
            resumePendingDiscovery()
        }
    }

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
                discoveryJobs = decoded.filter { job in
                    playlists.contains { $0.id == job.playlistID }
                }.map { checkpoint in
                    var repaired = checkpoint
                    repaired.repairPersistedCheckpoint()
                    return repaired
                }
            }
        } catch {
            print("MP3 Shelf could not initialize local storage: \(error)")
        }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            let cellular = path.status == .satisfied && path.usesInterfaceType(.cellular)
            Task { @MainActor [weak self] in
                self?.connectivityChanged(wifi: wifi, cellular: cellular)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    /// Creates the same v1 .mp3shelf archive used by the browser PWA.
    /// No Spotify tokens, account secrets or discovery queue internals are exported.
    func exportPortableBackup() async throws -> URL {
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
        // Gather UI-dependent artwork before leaving the main actor, then
        // stream potentially gigabytes of audio to disk off the UI thread.
        let playlistSnapshot = playlists
        return try await Task.detached(priority: .userInitiated) {
            try PortableShelfArchive.export(items, playlists: playlistSnapshot, to: destination)
            return destination
        }.value
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
                // Match an existing recording by its portable identity only
                // when the bytes still match. A reused ID with different audio
                // must not silently link a playlist to the wrong song.
                if let existing = tracks.first(where: { candidate in
                    (candidate.portableBackupID == archived.id ||
                     candidate.id.uuidString == archived.id) &&
                    PortableShelfArchive.audioFilesIdentical(file, fileURL(for: candidate))
                }) {
                    restoredIDs[archived.id] = existing.id
                    report.skipped += 1
                    continue
                }

                let imported = try await addLocalAudio(
                    sourceURL: file, originalName: original)
                if imported { report.imported += 1 }
                else { report.skipped += 1 }

                if !imported {
                    // Names and sizes alone are not sufficient: multiple local
                    // recordings can share both while containing different audio.
                    if let index = tracks.firstIndex(where: { candidate in
                        candidate.originalFileName.caseInsensitiveCompare(original) == .orderedSame &&
                        PortableShelfArchive.audioFilesIdentical(file, fileURL(for: candidate))
                    }) {
                        restoredIDs[archived.id] = tracks[index].id
                        if !tracks.contains(where: {
                            $0.id != tracks[index].id &&
                            ($0.portableBackupID == archived.id || $0.id.uuidString == archived.id)
                        }) {
                            tracks[index].portableBackupID = archived.id
                            save()
                        }
                    }
                    continue
                }
                guard let index = tracks.indices.last else { continue }
                restoredIDs[archived.id] = tracks[index].id
                // If the archived identifier belongs to a different local
                // recording, keep this song's new UUID as its export identity.
                if !tracks.contains(where: {
                    $0.id != tracks[index].id &&
                            ($0.portableBackupID == archived.id || $0.id.uuidString == archived.id)
                }) {
                    tracks[index].portableBackupID = archived.id
                }
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
                   (attribution.licenseURL.isEmpty || attribution.licenseURL.hasPrefix("https://")) {
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
                        artworkCache.removeObject(forKey: filename as NSString)
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
            // Web backups use string playlist IDs, not necessarily UUIDs.
            // Keep their source ID so restoring the same archive again (or
            // after an app restart) does not create another copy.
            let resolvedTrackIDs = item.trackIds.compactMap { restoredIDs[$0] }
            if let index = playlists.firstIndex(where: { $0.matchesPortableBackupID(item.id) }) {
                // A previous restore might have imported only some recordings.
                // Complete missing links on retry, preserving user-customized order.
                var addedLinks = 0
                for id in resolvedTrackIDs where !playlists[index].trackIDs.contains(id) {
                    playlists[index].trackIDs.append(id)
                    addedLinks += 1
                }
                if addedLinks > 0 { report.playlistsUpdated += 1 }
                continue
            }
            let id = UUID(uuidString: item.id) ?? UUID()
            var playlist = MusicPlaylist(id: id, name: item.name)
            playlist.portableBackupID = item.id
            playlist.sourceURL = item.sourceURL
            playlist.trackIDs = resolvedTrackIDs
            playlist.sourceOrder = (item.wishes ?? []).map {
                PlaylistWish(title: $0.title, artist: $0.artist,
                             album: $0.album, spotifyURL: $0.spotifyURL)
            }
            playlist.missingTracks = playlist.sourceOrder
            playlists.append(playlist)
            report.playlistsAdded += 1
        }
        reconcileMissingSongs()
        save()
        return report
    }

    func fileURL(for track: MusicTrack) -> URL { musicDirectory.appendingPathComponent(track.fileName) }

    func artwork(for track: MusicTrack) -> UIImage? {
        guard let name = track.artworkFileName else { return nil }
        let key = name as NSString
        if let cached = artworkCache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: artworkDirectory.appendingPathComponent(name)),
              let image = UIImage(data: data) else { return nil }
        // Cache is automatically evicted under memory pressure. Decoding the
        // same cover on every library row render would be unnecessarily costly.
        let estimatedBytes = image.size.width * image.size.height * 4
        let cost = estimatedBytes.isFinite
            ? Int(min(CGFloat(32 * 1024 * 1024), max(1, estimatedBytes)))
            : 32 * 1024 * 1024
        artworkCache.setObject(image, forKey: key, cost: cost)
        return image
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

    private func refreshTrackIndexIfNeeded() {
        guard indexedRevision != trackRevision else { return }
        indexedTracksByID = Dictionary(tracks.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
        indexedByTitle = OfflineTrackIndex(tracks: tracks)
        sortedByTitle = tracks.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        sortedByRecent = tracks.sorted {
            $0.addedAt == $1.addedAt
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : $0.addedAt > $1.addedAt
        }
        sortedByArtist = tracks.sorted {
            let comparison = $0.artist.localizedStandardCompare($1.artist)
            return comparison == .orderedSame
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : comparison == .orderedAscending
        }
        sortedByAlbum = tracks.sorted {
            let album = $0.album.localizedStandardCompare($1.album)
            if album != .orderedSame { return album == .orderedAscending }
            let artist = $0.artist.localizedStandardCompare($1.artist)
            return artist == .orderedSame
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : artist == .orderedAscending
        }
        indexedRevision = trackRevision
    }

    /// Pre-sorted revision snapshots avoid sorting the full collection on
    /// every playback tick while searching thousands of local recordings.
    func browseTracks(query rawQuery: String, favoritesOnly: Bool,
                      order: LibraryTrackSort) -> [MusicTrack] {
        refreshTrackIndexIfNeeded()
        let source: [MusicTrack]
        switch order {
        case .title: source = sortedByTitle
        case .recent: source = sortedByRecent
        case .artist: source = sortedByArtist
        case .album: source = sortedByAlbum
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty && !favoritesOnly { return source }
        return source.filter { track in
            (!favoritesOnly || track.isFavorite) && (query.isEmpty ||
                [track.title, track.artist, track.album].contains {
                    $0.localizedCaseInsensitiveContains(query)
                })
        }
    }

    func recentlyAddedTracks(limit: Int = 8) -> [MusicTrack] {
        refreshTrackIndexIfNeeded()
        return Array(sortedByRecent.prefix(max(0, limit)))
    }

    func song(with id: UUID?) -> MusicTrack? {
        guard let id else { return nil }
        refreshTrackIndexIfNeeded()
        return indexedTracksByID[id]
    }

    func songs(in playlist: MusicPlaylist) -> [MusicTrack] {
        refreshTrackIndexIfNeeded()
        return playlist.trackIDs.compactMap { indexedTracksByID[$0] }
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
        if fileSize >= 0 && tracks.contains(where: { track in
            let existingURL = fileURL(for: track)
            return track.originalFileName.caseInsensitiveCompare(originalName) == .orderedSame &&
                ((try? existingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2) == fileSize &&
                PortableShelfArchive.audioFilesIdentical(sourceURL, existingURL)
        }) { return false }

        let id = UUID()
        let destinationName = LocalAudioFileNaming.storageName(
            originalName: originalName, id: id, fileExtension: extensionName)
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
            discoveryJobs[index].nextRetryAt = nil
            discoveryJobs[index].transientFailureCount = nil
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
        discoveryJobs[index].nextRetryAt = nil
        discoveryJobs[index].transientFailureCount = nil
        persistDiscovery()
        resumePendingDiscovery()
    }

    var hasPendingDiscoveryWork: Bool {
        BackgroundDiscoveryPolicy.hasPending(discoveryJobs)
    }

    var nextBackgroundDiscoveryDate: Date? {
        BackgroundDiscoveryPolicy.earliestUsefulDate(for: discoveryJobs, at: Date())
    }

    /// BGProcessingTask does at most five catalogue lookups per system-granted
    /// window. Its requests are forced to Wi-Fi-only, regardless of any
    /// foreground cellular opt-in that may have been granted earlier.
    func runBackgroundDiscoveryBatch() async -> Bool {
        guard !backgroundDiscoveryInProgress && automaticDownloadTask == nil else { return true }
        // Claim the queue before the first suspension; NWPathMonitor may fire
        // while we await the initial network path or an external catalog.
        backgroundDiscoveryInProgress = true
        defer {
            backgroundDiscoveryInProgress = false
            // A foreground activation may arrive while the bounded background
            // lookup is awaiting a provider response. Re-check after releasing
            // ownership so the pending foreground request is not lost.
            if BackgroundDiscoveryPolicy.shouldResumeForegroundDiscovery(
                isSceneActive: foregroundDiscoveryEnabled,
                foregroundRequestPending: hasPendingDiscoveryWork,
                hasBackgroundBatch: backgroundDiscoveryInProgress) {
                resumePendingDiscovery()
            }
        }
        // A headless launch starts NWPathMonitor asynchronously. Wait briefly
        // for its first update rather than treating an unknown path as cellular.
        for _ in 0..<16 where !networkStatusKnown && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !Task.isCancelled else { return false }
        let previousID = UserDefaults.standard
            .string(forKey: "mp3shelf.backgroundDiscoveryLastPlaylistID")
            .flatMap(UUID.init(uuidString:))
        guard let next = BackgroundDiscoveryPolicy.nextJob(
            in: discoveryJobs, lastPlaylistID: previousID,
            onWiFi: isOnWiFi, at: Date()) else { return true }
        UserDefaults.standard.set(next.playlistID.uuidString,
                                  forKey: "mp3shelf.backgroundDiscoveryLastPlaylistID")

        var progress = AutomaticDownloadProgress(
            playlistID: next.playlistID, total: next.wishes.count)
        progress.processed = next.nextIndex
        progress.queued = next.queued
        progress.failed = next.failed
        progress.unavailable = next.unavailable
        automaticDownloadProgress = progress
        await runAutomaticDownloads(
            playlistID: next.playlistID,
            maxProcessedSongs: BackgroundDiscoveryPolicy.maxSongsPerPass,
            backgroundWiFiOnly: true)
        return !Task.isCancelled
    }

    func resumePendingDiscovery() {
        guard BackgroundDiscoveryPolicy.canStartForegroundScan(
            isSceneActive: foregroundDiscoveryEnabled,
            hasForegroundTask: automaticDownloadTask != nil,
            hasBackgroundBatch: backgroundDiscoveryInProgress,
            hasPendingWork: hasPendingDiscoveryWork
        ) else { return }
        guard BackgroundDownloadBackpressure.mayEnqueue(
            outstandingTransfers: BackgroundAudioDownloader.shared.pendingCount()
        ) else { return }
        let eligible = discoveryJobs.filter {
            !$0.isPaused && !$0.isComplete &&
            networkAllowsDiscovery(for: $0.playlistID)
        }
        let now = Date()
        guard let job = eligible.first(where: { $0.canAttemptLookup(at: now) }) else {
            if let next = eligible.compactMap(\.nextRetryAt).filter({ $0 > now }).min() {
                scheduleCatalogRetry(at: next)
            }
            return
        }
        catalogRetryTask?.cancel()
        catalogRetryTask = nil
        scheduledCatalogRetryAt = nil
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

    /// iOS can suspend foreground discovery at any time. Retry checkpoints
    /// survive app termination and will also be considered on next app launch.
    private func scheduleCatalogRetry(at deadline: Date) {
        if catalogRetryTask != nil,
           let scheduled = scheduledCatalogRetryAt,
           scheduled <= deadline { return }
        catalogRetryTask?.cancel()
        scheduledCatalogRetryAt = deadline
        catalogRetryTask = Task { [weak self] in
            let delay = max(0, deadline.timeIntervalSinceNow)
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch { return }
            guard !Task.isCancelled else { return }
            self?.scheduledCatalogRetryAt = nil
            self?.catalogRetryTask = nil
            self?.resumePendingDiscovery()
        }
    }

    private func persistDiscovery() {
        if let data = try? JSONEncoder().encode(discoveryJobs) {
            try? data.write(to: discoveryURL, options: .atomic)
        }
    }

    /// Resolved URLs transfer via Apple's background daemon. The UI receives
    /// results when the app is running or next reactivated by the system.
    /// Used by the background transfer manager before starting a retry,
    /// falling back to another provider or importing a staged duplicate.
    /// Check that the file still exists as well as its metadata/duration.
    func hasOfflineRecording(matching wish: PlaylistWish) -> Bool {
        refreshTrackIndexIfNeeded()
        return indexedByTitle.reusableTrack(for: wish, isAvailable: {
            self.manager.fileExists(atPath: self.fileURL(for: $0).path)
        }) != nil
    }

    func finishedBackgroundDownload(for playlistID: UUID, succeeded: Bool) {
        guard var progress = automaticDownloadProgress, progress.playlistID == playlistID else { return }
        if succeeded { progress.downloaded += 1 }
        else { progress.failed += 1 }
        automaticDownloadProgress = progress
    }

    func stopBackgroundTransfers(for playlistID: UUID) {
        // Explicit Cancel All must not immediately queue replacements when a
        // transfer slot opens; pause discovery before cancelling any task.
        pauseSourceDiscovery(for: playlistID)
        BackgroundAudioDownloader.shared.stopTransfers(for: playlistID)
    }

    /// A filename or search-result title is not evidence of recording identity.
    /// If the media file explicitly tags a different title/artist, reject it
    /// rather than overwrite those tags with the playlist's desired metadata.
    private func validateEmbeddedIdentity(fileURL: URL, matching wish: PlaylistWish) throws {
        let metadata = AVURLAsset(url: fileURL).commonMetadata
        func tag(_ key: AVMetadataKey) -> String? {
            AVMetadataItem.metadataItems(from: metadata, withKey: key,
                                         keySpace: .common).first?.stringValue
        }
        if let conflict = SourceAudioIdentity.conflictingField(
            title: tag(.commonKeyTitle), artist: tag(.commonKeyArtist),
            requested: wish) {
            throw MusicLibraryError.recordingMetadataMismatch(conflict.rawValue)
        }
    }

    func importStagedAudio(from fileURL: URL, matching wish: PlaylistWish,
                           attribution: AudioSourceAttribution, conversionProgress: Progress = Progress()) async throws -> Bool {
        let bytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0 && bytes <= 100 * 1024 * 1024 else {
            throw MusicLibraryError.downloadFailed
        }
        try validateEmbeddedIdentity(fileURL: fileURL, matching: wish)
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? manager.removeItem(at: temporary) }
        var importURL = fileURL
        if try !DownloadedAudioFormat.isMP3(fileURL) {
            try await withTaskCancellationHandler(operation: {
                try await Task.detached(priority: .utility) {
                    try ShelfPCMConversion.encode(fileURL, to: temporary, expectedDuration: wish.durationSeconds, progress: conversionProgress)
                }.value
            }, onCancel: { conversionProgress.cancel() })
            guard try DownloadedAudioFormat.isMP3(temporary) else {
                throw MusicLibraryError.downloadedFormatIsNotMP3
            }
            importURL = temporary
        }
        try Task.checkCancellation()
        guard !conversionProgress.isCancelled else { throw CancellationError() }
        let original = "\(wish.artist) - \(wish.title).mp3"
        let imported = try await addLocalAudio(sourceURL: importURL,
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

    private func runAutomaticDownloads(
        playlistID: UUID, maxProcessedSongs: Int? = nil,
        backgroundWiFiOnly: Bool = false
    ) async {
        var retryScheduled = false
        var processedThisPass = 0
        while let index = discoveryJobs.firstIndex(where: { $0.playlistID == playlistID }) {
            if let maximum = maxProcessedSongs, processedThisPass >= maximum { break }
            var job = discoveryJobs[index]
            if Task.isCancelled || job.isPaused || job.isComplete ||
                !networkAllowsDiscovery(for: playlistID) ||
                (backgroundWiFiOnly && !isOnWiFi) { break }
            // Keep the original playlist cursor untouched while all four
            // transfer slots are occupied. A completed/cancelled transfer
            // triggers resumePendingDiscovery via updatePending().
            if !BackgroundDownloadBackpressure.mayEnqueue(
                outstandingTransfers: BackgroundAudioDownloader.shared.pendingCount()
            ) { break }
            guard let wish = job.currentWish else { break }
            if var progress = automaticDownloadProgress {
                progress.currentSong = "\(wish.artist) — \(wish.title)"
                automaticDownloadProgress = progress
            }
            if !playlists.contains(where: {
                $0.id == playlistID && $0.sourceOrder.contains(where: { $0.id == wish.id })
            }) {
                // Deleted Spotify entries stay in historical discovery results
                // but do not trigger new catalog requests or MP3 transfers.
                job.record(.removed)
            } else if hasOfflineRecording(matching: wish) ||
                BackgroundAudioDownloader.shared.isQueued(wish, for: playlistID) {
                job.record(.alreadyPresent)
            } else {
                do {
                    let allowsCellular = !backgroundWiFiOnly && cellularApprovedPlaylists.contains(playlistID)
                    let report: AudioSourceFinder.CatalogSearchReport
                    var catalogError: Error?
                    do {
                        report = try await AudioSourceFinder.discover(for: wish, allowsCellular: allowsCellular)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        catalogError = error
                        report = .init(candidates: [], warnings: [error.localizedDescription],
                                       details: [error.localizedDescription])
                    }
                    guard job.isCurrent(in: discoveryJobs, at: index) else { break }
                    if Task.isCancelled || !networkAllowsDiscovery(for: playlistID) ||
                        (backgroundWiFiOnly && !isOnWiFi) { break }
                    guard BackgroundDownloadBackpressure.mayEnqueue(
                        outstandingTransfers: BackgroundAudioDownloader.shared.pendingCount()
                    ) else { break }
                    let failedTickets = BackgroundAudioDownloader.shared.failedSourceTickets(for: wish,
                                                                                              playlistID: playlistID)
                    let failedURLs = Set(failedTickets.map(\.downloadURL))
                    var candidates = report.candidates.filter { !failedURLs.contains($0.downloadURL) }
                    var details = report.details
                    for ticket in failedTickets.prefix(2) {
                        details.append("Previous file \(ticket.downloadURL.host ?? "source"): \(ticket.failureReason ?? "failed"); looking for another source")
                    }
                    var healthyLookup = catalogError == nil
                    if candidates.isEmpty {
                        if let cached = job.webSources?[wish.id.uuidString] {
                            candidates = cached.filter { !failedURLs.contains($0.downloadURL) }
                            healthyLookup = true
                            details += (job.lookupDetails?[wish.id.uuidString] ?? []).filter { $0.hasPrefix("Web") }
                            details.append("Web fallback: using saved result; no additional search credit")
                        } else if !WebAudioSearch.automaticFallbackEnabled {
                            details.append("Web fallback: disabled in Web Search settings")
                        } else if let key = WebAudioSearch.loadKey(), !key.isEmpty {
                            if job.reserveWebSearch(for: wish.id) {
                                details.append("Web search: request \(job.webSearchWishIDs?.count ?? 0)/\(SourceDiscoveryJob.maxAutomaticWebSearches) reserved")
                                job.saveLookupDetails(details, for: wish.id)
                                discoveryJobs[index] = job
                                persistDiscovery()
                                do {
                                    let web = try await AutomaticWebAudioFinder.find(for: wish, apiKey: key,
                                        allowsCellular: allowsCellular, excluding: failedURLs)
                                    guard job.isCurrent(in: discoveryJobs, at: index) else { break }
                                    candidates = web.sources
                                    healthyLookup = true
                                    details.append(contentsOf: web.details)
                                    if job.webSources == nil { job.webSources = [:] }
                                    job.webSources?[wish.id.uuidString] = web.sources
                                } catch is CancellationError { throw CancellationError() }
                                catch {
                                    guard job.isCurrent(in: discoveryJobs, at: index) else { break }
                                    try Task.checkCancellation()
                                    details.append("Web search failed: \(error.localizedDescription)")
                                    if let failure = error as? WebAudioSearch.SearchFailure {
                                        switch failure {
                                        case .rejectedKey, .rateLimited:
                                            job.webSearchStoppedReason = error.localizedDescription
                                        default: break
                                        }
                                    }
                                }
                            } else {
                                details.append("Web fallback: " + (job.webSearchStoppedReason ??
                                    ((job.webSearchWishIDs ?? []).contains(wish.id)
                                     ? "already attempted for this song; retry unmatched songs to start a new run"
                                     : "20-request budget reached; retry unmatched songs to start a new run")))
                            }
                        } else {
                            details.append("Web fallback: add and save a Brave API key in Web Search, then retry unmatched songs")
                        }
                    }
                    job.saveLookupDetails(details, for: wish.id)
                    discoveryJobs[index] = job
                    persistDiscovery()
                    if let catalogError, candidates.isEmpty && !healthyLookup { throw catalogError }
                    if Task.isCancelled || !networkAllowsDiscovery(for: playlistID) ||
                        (backgroundWiFiOnly && !isOnWiFi) { break }
                    let sources = BackgroundAudioDownloader.shared.prioritize(candidates)
                    // Capacity can change during the awaited catalog request.
                    // Keep this wish pending until a transfer slot opens.
                    guard BackgroundDownloadBackpressure.mayEnqueue(
                        outstandingTransfers: BackgroundAudioDownloader.shared.pendingCount()
                    ) else { break }
                    if let source = sources.first {
                        if BackgroundAudioDownloader.shared.enqueue(
                            source: source, requested: wish, playlistID: playlistID,
                            alternatives: Array(sources.dropFirst())) {
                            job.record(.queued)
                        } else { job.record(.failed) }
                    } else {
                        job.record(.unavailable)
                        job.catalogWarnings = Array(Set((job.catalogWarnings ?? []) + report.warnings)).sorted()
                    }
                } catch is CancellationError {
                    break
                } catch {
                    guard job.isCurrent(in: discoveryJobs, at: index) else { break }
                    // A network handoff or user pause must not burn through
                    // the catalog's retry budget.
                    guard BackgroundDiscoveryPolicy.canRecordLookupFailure(
                        isCancelled: Task.isCancelled,
                        isPaused: job.isPaused,
                        networkAllowed: networkAllowsDiscovery(for: playlistID),
                        backgroundWiFiOnly: backgroundWiFiOnly,
                        onWiFi: isOnWiFi
                    ) else { break }
                    job.recordTransientFailure(error.localizedDescription)
                    // Continue to the NEXT song after five failed attempts,
                    // preserving the .failed outcome and source discovery log.
                    retryScheduled = !job.finishExhaustedRetriesIfNeeded()
                }
            }
            processedThisPass += 1
            discoveryJobs[index] = job
            persistDiscovery()
            if var progress = automaticDownloadProgress {
                progress.processed = job.nextIndex
                progress.queued = job.queued
                progress.unavailable = job.unavailable
                progress.failed = job.failed
                automaticDownloadProgress = progress
            }
            if retryScheduled { break }
        }
        if var progress = automaticDownloadProgress {
            progress.isRunning = false
            progress.wasCancelled = Task.isCancelled
            progress.currentSong = ""
            automaticDownloadProgress = progress
        }
        automaticDownloadTask = nil
        // Never start an unbounded foreground scan at the end of a
        // system-granted, time-limited background processing window.
        if !backgroundWiFiOnly {
            // If a catalog is down, resumePendingDiscovery schedules the
            // persisted backoff instead of hammering the provider.
            resumePendingDiscovery()
        }
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
        if let wish { try validateEmbeddedIdentity(fileURL: staging, matching: wish) }
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
            artworkCache.removeObject(forKey: artwork as NSString)
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

    func duplicatePlaylist(_ id: UUID) {
        guard let original = playlists.first(where: { $0.id == id }) else { return }
        playlists.append(original.localCopy())
        save()
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = clean
        save()
    }

    func deletePlaylist(_ id: UUID) {
        stopBackgroundTransfers(for: id)
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
           let wishIndex = playlists[index].sourceOrder.firstIndex(where: { MusicMatching.reusableOfflineTrack(for: $0, in: [track]) != nil }) {
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
        refreshTrackIndexIfNeeded()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "Imported Playlist" : trimmed
        let spotifyID = sourceURL.flatMap(SpotifyPlaylistLinks.playlistID(from:))
        // Refreshing an existing Spotify link updates the actual song list,
        // not just the dashboard. Preserve stable per-occurrence wish IDs,
        // pending transfer IDs and completed discovery outcomes.
        if let spotifyID,
           let index = playlists.firstIndex(where: {
               $0.sourceURL.flatMap(SpotifyPlaylistLinks.playlistID(from:)) == spotifyID
           }) {
            let old = playlists[index]
            let updated = SpotifyPlaylistSync.merge(previous: old.sourceOrder, latest: wishes)
            let previousIDs = old.sourceOrder.map(\.id)
            let currentIDs = updated.map(\.id)
            let listChanged = previousIDs != currentIDs ||
                zip(old.sourceOrder, updated).contains(where: { pair in
                    pair.0.title != pair.1.title || pair.0.artist != pair.1.artist ||
                    pair.0.album != pair.1.album ||
                    pair.0.durationSeconds != pair.1.durationSeconds
                })
            if listChanged {
                if automaticDownloadProgress?.playlistID == old.id {
                    automaticDownloadTask?.cancel()
                }
                // Distinguish manually added local files from tracks that
                // belonged to the previous Spotify source-order mapping.
                let formerlySourced = Set(old.sourceOrder.compactMap {
                    indexedByTitle.reusableTrack(for: $0)?.id
                })
                playlists[index].trackIDs.removeAll { formerlySourced.contains($0) }
                playlists[index].sourceOrder = updated
                playlists[index].name = displayName
                playlists[index].sourceURL = sourceURL
                reconcileMissingSongs()
                BackgroundAudioDownloader.shared.cancelRemovedTracks(
                    for: old.id, keepingIDs: Set(currentIDs))
            } else {
                reconcileMissingSongs()
            }
            // A finished job stays complete when Spotify has not added songs;
            // a refresh should NOT rescan all old unavailable songs.
            if let jobIndex = discoveryJobs.firstIndex(where: { $0.playlistID == old.id }) {
                let previousJob = discoveryJobs[jobIndex]
                let newTracks = discoveryJobs[jobIndex].appendNewMissingWishes(
                    playlists[index].missingTracks)
                // Metadata can change without appending IDs. Keep pending
                // duration/title corrections after the next app relaunch too.
                if discoveryJobs[jobIndex] != previousJob { persistDiscovery() }
                if newTracks > 0 { resumePendingDiscovery() }
            } else if !playlists[index].missingTracks.isEmpty {
                discoveryJobs.append(SourceDiscoveryJob(
                    playlistID: old.id, wishes: playlists[index].missingTracks))
                persistDiscovery()
                resumePendingDiscovery()
            }
            return PlaylistImportReport(playlistID: old.id,
                                        playlistName: playlists[index].name,
                                        matched: playlists[index].trackIDs.count,
                                        missing: playlists[index].missingTracks.count)
        }
        var playlist = MusicPlaylist(name: displayName)
        if spotifyID != nil { playlist.sourceURL = sourceURL }
        playlist.sourceOrder = wishes
        for wish in wishes {
            if let track = indexedByTitle.reusableTrack(for: wish, isAvailable: {
                self.manager.fileExists(atPath: self.fileURL(for: $0).path)
            }) {
                playlist.trackIDs.append(track.id)
            } else {
                playlist.missingTracks.append(wish)
            }
        }
        playlists.append(playlist)
        save()
        return PlaylistImportReport(playlistID: playlist.id, playlistName: playlist.name,
                                    matched: playlist.trackIDs.count,
                                    missing: playlist.missingTracks.count)
    }

    func recheckSavedAudio() { reconcileMissingSongs() }

    private func reconcileMissingSongs() {
        refreshTrackIndexIfNeeded()
        let available = tracks.filter { manager.fileExists(atPath: fileURL(for: $0).path) }
        let availableIndex = OfflineTrackIndex(tracks: available)
        for index in playlists.indices where !playlists[index].sourceOrder.isEmpty {
            let existing = playlists[index].trackIDs
            var ordered: [UUID] = []
            var missing: [PlaylistWish] = []
            var sourcedTrackIDs = Set<UUID>()
            for wish in playlists[index].sourceOrder {
                if let previous = indexedByTitle.reusableTrack(for: wish) {
                    sourcedTrackIDs.insert(previous.id)
                }
                if let track = availableIndex.reusableTrack(for: wish) {
                    ordered.append(track.id)
                } else {
                    missing.append(wish)
                }
            }
            // Retain user-added songs with O(1) membership checks rather than
            // O(n²) repeated scans on multi-thousand-track playlists.
            var recorded = Set(ordered)
            ordered.append(contentsOf: existing.filter {
                !sourcedTrackIDs.contains($0) && recorded.insert($0).inserted
            })
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
    case downloadedFormatIsNotMP3, conversionUnsupportedFormat, conversionTooLong
    case recordingMetadataMismatch(String)

    var errorDescription: String? {
        switch self {
        case .conversionUnsupportedFormat: return "MP3 conversion supports mono or stereo audio at 32, 44.1 or 48 kHz."
        case .conversionTooLong: return "MP3 conversion supports recordings up to one hour long."
        case .downloadedFormatIsNotMP3: return "The downloaded audio could not be converted to a valid MP3."
        case .unsupportedFormat: return "Only supported audio files (MP3, M4A, AAC, WAV, AIFF) can be imported."
        case .invalidDownloadURL: return "Enter a direct HTTPS audio URL. Spotify streaming links cannot be downloaded."
        case .downloadFailed: return "The audio download did not complete successfully."
        case .recordingDurationMismatch: return "The downloaded audio duration did not match the requested recording."
        case .recordingMetadataMismatch(let field):
            return "The downloaded audio's embedded \(field) does not match the requested song. It was not added to your playlist."
        }
    }
}


/// C callbacks run synchronously on a utility task; context lives until encode returns.
private final class ShelfPCMConversion {
    let file: AVAudioFile
    let progress: Progress
    let buffer: AVAudioPCMBuffer
    var readError: Error?
    init(_ url: URL, progress: Progress) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        self.file = file
        self.progress = progress
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw MusicLibraryError.downloadFailed
        }
        self.buffer = buffer
    }
    static func encode(_ source: URL, to destination: URL, expectedDuration: TimeInterval?, progress: Progress) throws {
        guard !progress.isCancelled else { throw CancellationError() }
        let context = try ShelfPCMConversion(source, progress: progress)
        let format = context.file.processingFormat
        guard [32000.0, 44100.0, 48000.0].contains(format.sampleRate),
              [1, 2].contains(Int(format.channelCount)) else {
            throw MusicLibraryError.conversionUnsupportedFormat
        }
        let duration = Double(context.file.length) / format.sampleRate
        guard duration.isFinite, duration > 0 else { throw MusicLibraryError.downloadFailed }
        guard duration <= 3600 else { throw MusicLibraryError.conversionTooLong }
        if let expectedDuration, abs(duration - expectedDuration) > 4 {
            throw MusicLibraryError.recordingDurationMismatch
        }
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        let result = shelf_encode(destination.path, Int32(format.sampleRate), Int32(format.channelCount),
            { raw, output, capacity in
                guard let raw, let output else { return -1 }
                let state = Unmanaged<ShelfPCMConversion>.fromOpaque(raw).takeUnretainedValue()
                let buffer = state.buffer
                guard capacity > 0, capacity <= Int(buffer.frameCapacity) else { return -1 }
                do {
                    try state.file.read(into: buffer, frameCount: AVAudioFrameCount(capacity))
                    if buffer.frameLength == 0 { return 0 }
                    guard let data = buffer.int16ChannelData else { return -1 }
                    output.update(from: data.pointee,
                        count: Int(buffer.frameLength * buffer.format.channelCount))
                    return Int(buffer.frameLength)
                } catch { state.readError = error; return -1 }
            }, { raw in
                guard let raw else { return 1 }
                return Unmanaged<ShelfPCMConversion>.fromOpaque(raw).takeUnretainedValue().progress.isCancelled ? 1 : 0
            }, pointer)
        if result == SHELF_CANCELLED { throw CancellationError() }
        if let error = context.readError { throw error }
        guard result == SHELF_OK else { throw MusicLibraryError.downloadFailed }
    }
}
