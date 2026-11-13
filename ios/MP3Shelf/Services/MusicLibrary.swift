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
    // Fail closed if the saved catalog exists but cannot be read (for example,
    // while iOS file protection is active). Never replace it with an empty one.
    @Published private(set) var libraryStorageError: String?
    private var isLibraryPersistenceSafe = false
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
        // Foreground activation is the first safe opportunity to retry an
        // iOS protected-file read after a locked background launch. Retry even
        // when the discovery flag was already enabled on a previous scene.
        if enabled && !isLibraryPersistenceSafe {
            let recovered = recoverLibraryIfAccessible()
            if recovered && foregroundDiscoveryEnabled {
                resumePendingDiscovery()
            }
        }
        if enabled && isLibraryPersistenceSafe {
            // Retry interrupted imports when protected files become accessible.
            recoverInterruptedImports()
        }
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
            if let saved = try PersistedLibrary.readIfPresent(from: databaseURL) {
                // Keep metadata even when a recording is temporarily unavailable
                // (Files, protection or storage interruption). Removing its entry
                // here would permanently erase its identity on the next save.
                tracks = saved.tracks
                playlists = saved.playlists
            }
            isLibraryPersistenceSafe = true
            recoverInterruptedImports()
            if let saved = try? Data(contentsOf: discoveryURL),
               let decoded = try? JSONDecoder().decode([SourceDiscoveryJob].self, from: saved) {
                discoveryJobs = decoded.compactMap { checkpoint in
                    guard let playlist = playlists.first(where: { $0.id == checkpoint.playlistID }) else { return nil }
                    var repaired = checkpoint
                    repaired.repairPersistedCheckpoint()
                    // A saved playlist can be newer than the last discovery checkpoint.
                    repaired.refreshMissingWishes(playlist.missingTracks)
                    return repaired
                }
            }
        } catch {
            isLibraryPersistenceSafe = false
            libraryStorageError = "Saved music library could not be opened. Your existing files and playlists are preserved, but changes are disabled until storage becomes available."
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

    /// Reattach only audio with an app-created, validated recovery intent.
    /// An ordinary orphan (including failed intentional deletion) has no
    /// journal and is deliberately left alone, never silently resurrected.
    private func recoverInterruptedImports() {
        guard isLibraryPersistenceSafe else { return }
        for journal in LocalAudioRecoveryRecord.pending(in: musicDirectory) {
            do {
                let record = try LocalAudioRecoveryRecord.read(journal, in: musicDirectory)
                let candidate = record.track
                // The old catalog may already contain this recording: a crash
                // after its atomic write must not duplicate it on relaunch.
                if let existing = tracks.first(where: { $0.id == candidate.id }) {
                    // A committed catalog entry is not proof its audio is
                    // readable. Protected/missing files must retain recovery
                    // intent until staged bytes can be safely reattached.
                    let repaired = try record.restoreExistingTrack(
                        existing, in: musicDirectory) { file in
                        guard let probe = try? AVAudioPlayer(contentsOf: file) else {
                            return false
                        }
                        return probe.duration.isFinite && probe.duration > 0 &&
                            abs(probe.duration - existing.duration) <= 4
                    }
                    if repaired { try? manager.removeItem(at: journal) }
                    continue
                }
                guard !LocalLibraryFileSafety.isReferenced(
                    candidate.fileName, by: tracks.map(\.fileName)) else { continue }
                let audio = try record.restorePublication(in: musicDirectory) { file in
                    guard let probe = try? AVAudioPlayer(contentsOf: file) else {
                        return false
                    }
                    return probe.duration.isFinite && probe.duration > 0 &&
                        abs(probe.duration - candidate.duration) <= 4
                }
                guard audio != nil else { continue }
                let updatedTracks = tracks + [candidate]
                let updatedPlaylists = reconciledPlaylists(using: updatedTracks)
                // One atomic catalog write is the recovery commit point. A
                // storage failure retains both journal and audio for retry.
                try PersistedLibrary(tracks: updatedTracks, playlists: updatedPlaylists)
                    .write(to: databaseURL)
                tracks = updatedTracks
                playlists = updatedPlaylists
                try? manager.removeItem(at: journal)
            } catch {
                // Keep unrecognized/invalid intents and original bytes for
                // manual diagnosis; never auto-delete an orphaned recording.
                print("MP3 Shelf deferred interrupted import recovery: \(error)")
            }
        }
    }

    /// Creates the same v1 .mp3shelf archive used by the browser PWA.
    /// No Spotify tokens, account secrets or discovery queue internals are exported.
    func exportPortableBackup() async throws -> URL {
        // A protected or damaged catalog can make the in-memory library appear
        // empty. Never export that fallback as an apparently valid backup.
        try requireLibraryPersistence()
        // A sidecar reference is user-owned library data, not an optional
        // decoding hint. Never publish a backup that silently omits referenced
        // artwork/lyrics because the file was protected, missing or corrupt.
        // Only a nil reference means the recording genuinely has no sidecar.
        let items = try tracks.map { track -> PortableShelfArchive.MediaInput in
            try Task.checkCancellation()
            // Do not let a malformed/legacy catalog export bytes from outside
            // the Music directory. The archive exporter revalidates identity
            // while streaming to catch later pathname replacement.
            guard let ownedAudio = LocalLibraryFileSafety.regularFile(
                named: track.fileName, in: musicDirectory) else {
                throw PortableShelfArchive.ArchiveError.invalidManifest
            }
            let lyricBytes = try PortableShelfArchive.readSidecar(
                named: track.lyricsFileName, from: lyricsDirectory,
                maximumBytes: 500 * 1024)
            let lyrics: String?
            if let lyricBytes {
                guard let text = String(data: lyricBytes, encoding: .utf8) else {
                    throw PortableShelfArchive.ArchiveError.invalidManifest
                }
                lyrics = text
            } else {
                lyrics = nil
            }

            let imageBytes = try PortableShelfArchive.readSidecar(
                named: track.artworkFileName, from: artworkDirectory,
                maximumBytes: 20 * 1024 * 1024)
            let artwork: Data?
            if let imageBytes {
                guard let image = UIImage(data: imageBytes),
                      let jpeg = image.jpegData(compressionQuality: 0.9),
                      !jpeg.isEmpty else {
                    throw PortableShelfArchive.ArchiveError.invalidManifest
                }
                artwork = jpeg
            } else {
                artwork = nil
            }
            return PortableShelfArchive.MediaInput(
                track: track, audioURL: ownedAudio,
                artwork: artwork, lyrics: lyrics
            )
        }
        let destination = manager.temporaryDirectory
            .appendingPathComponent("MP3Shelf-\(UUID().uuidString).mp3shelf")
        // Gather UI-dependent artwork before leaving the main actor, then
        // stream potentially gigabytes of audio to disk off the UI thread.
        let playlistSnapshot = playlists
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            // The export may finish publishing just as cancellation arrives.
            // Own the output until a successful return; remove it on every
            // thrown path, including cancellation after publication.
            var published = false
            defer {
                if !published {
                    try? FileManager.default.removeItem(at: destination)
                }
            }
            try Task.checkCancellation()
            try PortableShelfArchive.export(items, playlists: playlistSnapshot, to: destination)
            try Task.checkCancellation()
            published = true
            return destination
        }
        // Detached work does not inherit the caller's cancellation. Without
        // forwarding it, dismissing the export UI can leave a large archive
        // streaming for minutes and publish a backup nobody requested.
        return try await withTaskCancellationHandler {
            let exported = try await worker.value
            do {
                try Task.checkCancellation()
                return exported
            } catch {
                // The worker may have completed just as cancellation arrived.
                // Remove only our unique temporary export, never source audio.
                try? manager.removeItem(at: exported)
                throw error
            }
        } onCancel: {
            worker.cancel()
        }
    }

    /// Adds valid files from a browser or native backup without deleting
    /// anything already on this iPhone. Archive metadata is validated first.
    func importPortableBackup(from url: URL) async throws -> ImportReport {
        try requireLibraryPersistence()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let archive = try PortableShelfArchive.open(url)
        try Task.checkCancellation()
        var report = ImportReport()
        var restoredIDs: [String: UUID] = [:]
        // Index candidate sizes once per restore instead of scanning every
        // recording for each archive entry (quadratic on large libraries).
        // Verify actual bytes before reuse; equal sizes are not identity.
        var recordingsBySize: [Int64: [MusicTrack]] = [:]
        for track in tracks {
            try Task.checkCancellation()
            if let size = try? fileURL(for: track).resourceValues(forKeys: [.fileSizeKey]).fileSize {
                recordingsBySize[Int64(size), default: []].append(track)
            }
        }
        // Byte-identical audio is often already present when restoring a
        // backup over a partial library. Restore missing sidecars too; otherwise
        // the early duplicate-audio path silently drops backed-up artwork and
        // lyrics. Never replace a user's existing sidecar or audio file.
        func restoreMissingSidecars(for archived: PortableShelfArchive.Track,
                                    existingID: UUID) throws {
            try Task.checkCancellation()
            guard let index = tracks.firstIndex(where: { $0.id == existingID }) else { return }
            let current = tracks[index]
            // A non-nil filename may refer to a deleted, protected, corrupt,
            // or non-regular file. Repeated restores must repair that state
            // rather than silently keeping a broken artwork/lyrics reference.
            // Never modify or delete the previous sidecar: recovery uses a
            // fresh filename and publishes it only after the catalog commits.
            let needsArtwork = archived.artwork != nil &&
                PortableShelfArchive.sidecarNeedsRecovery(
                    named: current.artworkFileName, from: artworkDirectory,
                    maximumBytes: 20 * 1024 * 1024,
                    isValid: { UIImage(data: $0) != nil })
            let needsLyrics = !(archived.lyrics ?? "").isEmpty &&
                PortableShelfArchive.sidecarNeedsRecovery(
                    named: current.lyricsFileName, from: lyricsDirectory,
                    maximumBytes: 500 * 1024,
                    isValid: { String(data: $0, encoding: .utf8) != nil })
            try Task.checkCancellation()
            guard needsArtwork || needsLyrics else { return }

            var restored = current
            var created: [URL] = []
            // Cancellation must discard unpublished sidecars, not leave orphans.
            var committed = false
            defer {
                if !committed {
                    for url in created { try? manager.removeItem(at: url) }
                }
            }
            if needsArtwork, let artwork = archived.artwork {
                do {
                    try Task.checkCancellation()
                    let bytes = try PortableShelfArchive.readBytes(artwork, from: archive)
                    try Task.checkCancellation()
                    guard UIImage(data: bytes) != nil else {
                        throw PortableShelfArchive.ArchiveError.invalidManifest
                    }
                    let name = existingID.uuidString + "-" + UUID().uuidString + ".img"
                    let destination = artworkDirectory.appendingPathComponent(name)
                    try bytes.write(to: destination, options: .atomic)
                    created.append(destination)
                    restored.artworkFileName = name
                } catch {
                    try Task.checkCancellation()
                    report.errors.append("\(archived.name): missing cover artwork could not be restored (\(error.localizedDescription)).")
                }
            }
            if needsLyrics, let lyrics = archived.lyrics {
                do {
                    try Task.checkCancellation()
                    let name = existingID.uuidString + "-" + UUID().uuidString + ".lrc"
                    let destination = lyricsDirectory.appendingPathComponent(name)
                    try Data(lyrics.utf8).write(to: destination, options: .atomic)
                    created.append(destination)
                    restored.lyricsFileName = name
                } catch {
                    try Task.checkCancellation()
                    report.errors.append("\(archived.name): missing lyrics could not be restored (\(error.localizedDescription)).")
                }
            }
            try Task.checkCancellation()
            guard !created.isEmpty else { return }
            do {
                var candidate = tracks
                candidate[index] = restored
                try Task.checkCancellation()
                try PersistedLibrary(tracks: candidate, playlists: playlists).write(to: databaseURL)
                tracks = candidate
                committed = true
            } catch {
                // Never publish a reference to an uncommitted sidecar. An
                // interrupted/low-storage restore must preserve old catalog.
                throw error
            }
        }

        for archived in archive.manifest.tracks {
            try Task.checkCancellation()
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
                // An earlier restore may have imported these exact audio bytes
                // under a different filename, or the user may have renamed the
                // recording. Compare same-sized files before copying another
                // potentially large track; never trust names or portable IDs
                // without checking the actual bytes.
                try Task.checkCancellation()
                let extractedSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                // Compare candidates explicitly rather than using first(where:).
                // The byte comparator cannot throw, and cancellation inside
                // its read loop returns false; check between candidates and
                // before accepting a match so cancellation never becomes a miss.
                var identicalRecording: MusicTrack?
                if extractedSize >= 0 {
                    for candidate in recordingsBySize[Int64(extractedSize)] ?? [] {
                        try Task.checkCancellation()
                        let identical = PortableShelfArchive.audioFilesIdentical(
                            file, fileURL(for: candidate))
                        try Task.checkCancellation()
                        if identical {
                            identicalRecording = candidate
                            break
                        }
                    }
                }
                if let existing = identicalRecording {
                    try Task.checkCancellation()
                    // Byte-identical reuse must also retain the browser's
                    // portable identity for a later native re-export. Never
                    // replace an established identity or steal another song's.
                    if let index = tracks.firstIndex(where: { $0.id == existing.id }),
                       tracks[index].portableBackupID == nil,
                       !tracks.contains(where: {
                           $0.id != existing.id &&
                           ($0.portableBackupID == archived.id || $0.id.uuidString == archived.id)
                       }) {
                        var updatedTracks = tracks
                        updatedTracks[index].portableBackupID = archived.id
                        try PersistedLibrary(tracks: updatedTracks, playlists: playlists).write(to: databaseURL)
                        tracks = updatedTracks
                    }
                    try restoreMissingSidecars(for: archived, existingID: existing.id)
                    restoredIDs[archived.id] = existing.id
                    report.skipped += 1
                    continue
                }

                // The byte comparator deliberately returns false on cancellation;
                // do not interpret that as permission to import another copy.
                try Task.checkCancellation()
                let imported = try addLocalAudio(
                    sourceURL: file, originalName: original,
                    cancellationAware: true)
                if imported { report.imported += 1 }
                else { report.skipped += 1 }

                if !imported {
                    // Names and sizes alone are not sufficient: multiple local
                    // recordings can share both while containing different audio.
                    var duplicateIndex: Int?
                    for index in tracks.indices {
                        try Task.checkCancellation()
                        let candidate = tracks[index]
                        guard candidate.originalFileName.caseInsensitiveCompare(original) == .orderedSame else {
                            continue
                        }
                        let identical = PortableShelfArchive.audioFilesIdentical(
                            file, fileURL(for: candidate))
                        try Task.checkCancellation()
                        if identical {
                            duplicateIndex = index
                            break
                        }
                    }
                    if let index = duplicateIndex {
                        if !tracks.contains(where: {
                            $0.id != tracks[index].id &&
                            ($0.portableBackupID == archived.id || $0.id.uuidString == archived.id)
                        }) {
                            if tracks[index].portableBackupID == nil {
                                var updatedTracks = tracks
                                updatedTracks[index].portableBackupID = archived.id
                                try PersistedLibrary(tracks: updatedTracks, playlists: playlists).write(to: databaseURL)
                                tracks = updatedTracks
                            }
                        }
                        try restoreMissingSidecars(for: archived, existingID: tracks[index].id)
                        restoredIDs[archived.id] = tracks[index].id
                    }
                    continue
                }
                guard let index = tracks.indices.last else { continue }
                if extractedSize >= 0 {
                    recordingsBySize[Int64(extractedSize), default: []].append(tracks[index])
                }
                restoredIDs[archived.id] = tracks[index].id
                // Keep archive metadata private until its catalog write succeeds.
                // Published tracks must never expose references to uncommitted sidecars.
                var restoredTrack = tracks[index]
                // If the archived identifier belongs to a different local
                // recording, keep this song's new UUID as its export identity.
                if !tracks.contains(where: {
                    $0.id != tracks[index].id &&
                            ($0.portableBackupID == archived.id || $0.id.uuidString == archived.id)
                }) {
                    restoredTrack.portableBackupID = archived.id
                }
                restoredTrack.title = archived.name
                if let artist = archived.artist { restoredTrack.artist = artist }
                if let album = archived.album { restoredTrack.album = album }
                restoredTrack.isFavorite = archived.isFavorite ?? false
                let epoch = archived.importedAt / 1000
                if epoch.isFinite && epoch > 0 {
                    restoredTrack.addedAt = Date(timeIntervalSince1970: epoch)
                }
                if let attribution = archived.attribution,
                   attribution.sourceURL.hasPrefix("https://"),
                   (attribution.licenseURL.isEmpty || attribution.licenseURL.hasPrefix("https://")) {
                    restoredTrack.sourceAttribution = AudioSourceAttribution(
                        pageURL: attribution.sourceURL,
                        licenseURL: attribution.licenseURL,
                        providerName: attribution.provider
                    )
                }
                // Imported audio is already durable. Never overwrite existing
                // artwork/lyrics sidecars before their new catalog references
                // are durable: a failed catalog write must preserve old bytes.
                // Optional sidecar failures are reported without losing audio.
                var createdSidecars: [URL] = []
                var sidecarsCommitted = false
                // The catalog is the commit point. Cancellation, low storage,
                // or a failed write must never strand unpublished sidecars.
                defer {
                    if !sidecarsCommitted {
                        for sidecar in createdSidecars { try? manager.removeItem(at: sidecar) }
                    }
                }
                if let artwork = archived.artwork {
                    do {
                        try Task.checkCancellation()
                        let bytes = try PortableShelfArchive.readBytes(artwork, from: archive)
                        if UIImage(data: bytes) != nil {
                            let filename = tracks[index].id.uuidString + "-" + UUID().uuidString + ".img"
                            let destination = artworkDirectory.appendingPathComponent(filename)
                            try bytes.write(to: destination, options: .atomic)
                            createdSidecars.append(destination)
                            try Task.checkCancellation()
                            restoredTrack.artworkFileName = filename
                        } else {
                            report.errors.append("\(archived.name): invalid cover artwork; audio restored.")
                        }
                    } catch {
                        try Task.checkCancellation()
                        report.errors.append("\(archived.name): cover artwork not restored (\(error.localizedDescription)); audio restored.")
                    }
                }
                if let lyrics = archived.lyrics, !lyrics.isEmpty {
                    do {
                        try Task.checkCancellation()
                        let filename = tracks[index].id.uuidString + "-" + UUID().uuidString + ".lrc"
                        let destination = lyricsDirectory.appendingPathComponent(filename)
                        try Data(lyrics.utf8).write(to: destination, options: .atomic)
                        createdSidecars.append(destination)
                        try Task.checkCancellation()
                        restoredTrack.lyricsFileName = filename
                    } catch {
                        try Task.checkCancellation()
                        report.errors.append("\(archived.name): lyrics not restored (\(error.localizedDescription)); audio restored.")
                    }
                }
                do {
                    // save() only logs errors; archive restore must surface them.
                    try Task.checkCancellation()
                    var candidateTracks = tracks
                    candidateTracks[index] = restoredTrack
                    try PersistedLibrary(tracks: candidateTracks, playlists: playlists).write(to: databaseURL)
                    tracks = candidateTracks
                    sidecarsCommitted = true
                } catch {
                    // Audio was already committed by addLocalAudio. Leave its
                    // published metadata unchanged when this write fails.
                    throw error
                }
            } catch is CancellationError {
                // Previously completed track writes remain durable; do not
                // continue importing or publish incomplete playlist links.
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                report.errors.append("\(archived.name): \(error.localizedDescription)")
            }
            if let temporary { try? manager.removeItem(at: temporary) }
        }
        // Track imports above are individually durable. Playlist edits below
        // are not: stage playlist changes until their final durable write.
        var candidatePlaylists = playlists
        for item in archive.manifest.playlists {
            try Task.checkCancellation()
            // Web backups use string playlist IDs, not necessarily UUIDs.
            // Keep their source ID so restoring the same archive again (or
            // after an app restart) does not create another copy.
            // Different archive IDs can resolve to the same local recording
            // after byte-identical duplicate reuse. Keep one occurrence in the
            // playlist, in first-seen archive order, even for malformed backups.
            var resolvedTrackIDs: [UUID] = []
            var resolvedSet = Set<UUID>()
            for backupID in item.trackIds {
                try Task.checkCancellation()
                if let localID = restoredIDs[backupID], resolvedSet.insert(localID).inserted {
                    resolvedTrackIDs.append(localID)
                }
            }
            if let index = candidatePlaylists.firstIndex(where: { $0.matchesPortableBackupID(item.id) }) {
                // A previous restore might have imported only some recordings.
                // Complete missing links on retry, preserving user-customized order.
                // A set also avoids quadratic lookups on very large playlists.
                var linked = Set(candidatePlaylists[index].trackIDs)
                var addedLinks = 0
                for id in resolvedTrackIDs {
                    // Check every archived link, including links already present
                    // in the destination. A large repeat restore can otherwise
                    // skip every cancellation checkpoint in this loop.
                    try Task.checkCancellation()
                    if linked.insert(id).inserted {
                        candidatePlaylists[index].trackIDs.append(id)
                        addedLinks += 1
                    }
                }
                if addedLinks > 0 { report.playlistsUpdated += 1 }
                continue
            }
            // An archive ID can parse as a UUID already occupied by a
            // different local playlist. Do not create duplicate local IDs:
            // they make playlist selection, edits and later restores ambiguous.
            let id = MusicPlaylist.restoredLocalID(for: item.id, existing: candidatePlaylists)
            var playlist = MusicPlaylist(id: id, name: item.name)
            playlist.portableBackupID = item.id
            playlist.sourceURL = item.sourceURL
            playlist.appleMusicLibraryID = AppleMusicLibraryIdentity.canonical(item.appleMusicLibraryID)
            playlist.trackIDs = resolvedTrackIDs
            // Large imported playlists can contain thousands of wishes. Do not
            // let cancellation finish an expensive metadata rebuild and publish
            // a playlist the user explicitly stopped restoring.
            playlist.sourceOrder = try (item.wishes ?? []).map {
                try Task.checkCancellation()
                return PlaylistWish(title: $0.title, artist: $0.artist,
                             album: $0.album, spotifyURL: $0.spotifyURL,
                             durationSeconds: $0.durationSeconds, artistNames: $0.artistNames,
                             appleMusicItemID: AppleMusicLibraryIdentity.canonical($0.appleMusicItemID))
            }
            playlist.missingTracks = playlist.sourceOrder
            candidatePlaylists.append(playlist)
            report.playlistsAdded += 1
        }
        // A restore is not complete until playlist links are durably saved.
        // The ordinary save() helper logs failures because most UI edits are
        // synchronous, but backup restore is throwing and must report storage
        // exhaustion or file-protection errors to its caller.
        // Do not call reconcileMissingSongs() here: it calls save(), which
        // swallows write failures and could publish a partially restored catalog.
        // Reconcile in memory, then commit exactly once. A failed commit must
        // never publish a candidate playlist before its write succeeds.
        try Task.checkCancellation()
        candidatePlaylists = reconciledPlaylists(using: tracks, from: candidatePlaylists)
        try Task.checkCancellation()
        try requireLibraryPersistence()
        try PersistedLibrary(tracks: tracks, playlists: candidatePlaylists).write(to: databaseURL)
        playlists = candidatePlaylists
        return report
    }

    func fileURL(for track: MusicTrack) -> URL { musicDirectory.appendingPathComponent(track.fileName) }

    func artwork(for track: MusicTrack) -> UIImage? {
        guard let name = track.artworkFileName else { return nil }
        let key = name as NSString
        if let cached = artworkCache.object(forKey: key) { return cached }
        // Catalog filenames are untrusted after legacy restores or corruption.
        // Reuse the archive reader's descriptor-bound, symlink-safe and size-
        // limited sidecar checks rather than reading arbitrary paths into memory.
        guard let data = try? PortableShelfArchive.readSidecar(
                  named: name, from: artworkDirectory, maximumBytes: 20 * 1024 * 1024),
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
              let bytes = try? PortableShelfArchive.readSidecar(
                  named: filename, from: lyricsDirectory, maximumBytes: 500 * 1024),
              let content = String(data: bytes, encoding: .utf8) else { return [] }
        return LyricsParser.parse(content)
    }

    func importLyrics(from url: URL, for trackID: UUID) throws {
        // Do not overwrite an existing sidecar while protected storage or
        // catalog persistence is unavailable. A failed save must leave the
        // previous lyrics and their persisted reference untouched.
        try requireLibraryPersistence()
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard ["lrc", "txt"].contains(url.pathExtension.lowercased()) else { throw LyricsError.unsupported }
        // A Files provider may expose a very large or growing text file.
        // Never load it unbounded into memory before checking the limit.
        // Read one byte beyond the cap so an oversized input is rejected
        // without publishing a sidecar or changing the catalog.
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var data = Data()
        while data.count <= 512_000 {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: min(64 * 1024, 512_001 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= 512_000, String(data: data, encoding: .utf8) != nil else {
            throw LyricsError.unsupported
        }
        try Task.checkCancellation()

        let previousLyrics = tracks[index].lyricsFileName
        let filename = trackID.uuidString + "-" + UUID().uuidString + ".lrc"
        let destination = lyricsDirectory.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        do {
            var updatedTracks = tracks
            updatedTracks[index].lyricsFileName = filename
            try PersistedLibrary(tracks: updatedTracks, playlists: playlists).write(to: databaseURL)
            tracks = updatedTracks
            // Cleanup follows the durable catalog write. Restored/legacy
            // recordings can share a lyrics filename; preserve shared files.
            if let previousLyrics,
               previousLyrics != filename,
               !LocalLibraryFileSafety.isReferenced(
                   previousLyrics, by: updatedTracks.map(\.lyricsFileName)),
               let owned = LocalLibraryFileSafety.regularFile(
                   named: previousLyrics, in: lyricsDirectory) {
                do {
                    try manager.removeItem(at: owned)
                } catch {
                    print("MP3 Shelf retained an unreferenced lyrics sidecar: \(error)")
                }
            }
        } catch {
            // Only delete the new, unreferenced sidecar. The previous lyrics
            // and catalog remain available for recovery.
            try? manager.removeItem(at: destination)
            throw error
        }
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

    /// Recover only from the saved on-disk snapshot. Never merge an in-memory
    /// empty fallback into an existing catalog, and never write during retry.
    /// A corrupt catalog stays blocked until it can be repaired independently.
    @discardableResult
    func recoverLibraryIfAccessible() -> Bool {
        guard !isLibraryPersistenceSafe else { return true }
        do {
            // If startup failed while creating storage directories, a missing
            // catalog is not proof of first launch. Only recover a real file.
            guard manager.fileExists(atPath: databaseURL.path),
                  let restored = try PersistedLibrary.readIfPresent(from: databaseURL) else {
                return false
            }
            tracks = restored.tracks
            playlists = restored.playlists
            isLibraryPersistenceSafe = true
            libraryStorageError = nil
            recoverInterruptedImports()
            // Discovery checkpoints may also have been protected at startup.
            if let saved = try? Data(contentsOf: discoveryURL),
               let decoded = try? JSONDecoder().decode([SourceDiscoveryJob].self, from: saved) {
                discoveryJobs = decoded.compactMap { checkpoint in
                    guard let playlist = playlists.first(where: { $0.id == checkpoint.playlistID }) else { return nil }
                    var repaired = checkpoint
                    repaired.repairPersistedCheckpoint()
                    repaired.refreshMissingWishes(playlist.missingTracks)
                    return repaired
                }
            }
            return true
        } catch {
            // Do not discard metadata or weaken the guard on a failed retry.
            print("MP3 Shelf could not reopen the saved library: \(error)")
            return false
        }
    }

    private func requireLibraryPersistence() throws {
        guard isLibraryPersistenceSafe else {
            throw NSError(domain: PersistedLibrary.writeFailureDomain, code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            libraryStorageError ?? "The existing music library is unavailable; changes are disabled to prevent data loss."])
        }
    }

    func save() {
        // A headless iOS background wake can occur before protected files are
        // accessible. Never replace an unreadable catalog with an empty snapshot.
        guard isLibraryPersistenceSafe else { return }
        do {
            try PersistedLibrary(tracks: tracks, playlists: playlists).write(to: databaseURL)
        } catch {
            print("MP3 Shelf could not save the music library: \(error)")
        }
    }

    func importAudio(urls: [URL]) async -> ImportReport {
        isImporting = true
        defer { isImporting = false }
        var report = ImportReport()
        for source in urls {
            // A defer in this loop's enclosing function would retain every
            // security-scoped Files grant until the entire batch finished.
            // Release each grant before starting the next recording, including
            // failed copies, invalid audio and duplicate imports.
            let accessing = source.startAccessingSecurityScopedResource()
            let result: Result<Bool, Error> = {
                defer { if accessing { source.stopAccessingSecurityScopedResource() } }
                return Result {
                    try addLocalAudio(sourceURL: source, originalName: source.lastPathComponent)
                }
            }()
            switch result {
            case .success(true): report.imported += 1
            case .success(false): report.skipped += 1
            case .failure(let error):
                report.errors.append(source.lastPathComponent + ": " + error.localizedDescription)
            }
        }
        // Each successful import commits its playlist reconciliation together
        // with the track. Never perform a second nonthrowing save here: that
        // could leave the visible playlists ahead of the durable catalog.
        return report
    }

    private func addLocalAudio(sourceURL: URL, originalName: String,
                               expectedDuration: TimeInterval? = nil,
                               matching wish: PlaylistWish? = nil,
                               attribution: AudioSourceAttribution? = nil,
                               cancellationAware: Bool = false) throws -> Bool {
        // Archive restoration is cancellable; ordinary synchronous imports
        // retain their existing behavior. Check at expensive I/O boundaries
        // before publishing any new catalog entry.
        if cancellationAware { try Task.checkCancellation() }
        try requireLibraryPersistence()
        // A different import may have saved this recording while a download
        // or AAC conversion was suspended. Recheck at the library write boundary.
        if let wish, hasOfflineRecording(matching: wish) { return false }
        let extensionName = sourceURL.pathExtension.lowercased()
        let allowed = ["mp3", "m4a", "aac", "wav", "aif", "aiff"]
        guard allowed.contains(extensionName) else { throw MusicLibraryError.unsupportedFormat }
        let fileSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        // Detect identical audio even when Files renamed the source (for example,
        // "song (1).mp3"). Names and metadata are not reliable content identities.
        // Compare only equal-sized candidates; the archive comparator streams in
        // bounded chunks rather than loading entire recordings into memory.
        // An unreadable candidate is never considered a duplicate.
        if fileSize > 0 {
            for track in tracks {
                // The comparator deliberately returns false when cancelled,
                // because its nonthrowing API also serves ordinary imports.
                // A cancellable restore must not interpret that false result
                // as permission to import a duplicate recording.
                if cancellationAware { try Task.checkCancellation() }
                let existingURL = fileURL(for: track)
                guard ((try? existingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) == fileSize else {
                    continue
                }
                let identical = PortableShelfArchive.audioFilesIdentical(sourceURL, existingURL)
                if cancellationAware { try Task.checkCancellation() }
                if identical { return false }
            }
        }

        if cancellationAware { try Task.checkCancellation() }
        let id = UUID()
        let destinationName = LocalAudioFileNaming.storageName(
            originalName: originalName, id: id, fileExtension: extensionName)
        let destination = musicDirectory.appendingPathComponent(destinationName)
        var artworkName: String?
        do {
            var preparedTrack: MusicTrack?
            try LocalAudioImportTransaction.perform(
                from: sourceURL, to: destination,
                validate: { staged in
                    if cancellationAware { try Task.checkCancellation() }
                    // Staging preserves the extension so AVFoundation can
                    // validate the audio before any final filename is created.
                    let asset = AVURLAsset(url: staged)
                    let playbackProbe = try AVAudioPlayer(contentsOf: staged)
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
                    if let imageData = AVMetadataItem.metadataItems(from: metadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first?.dataValue,
                       UIImage(data: imageData) != nil {
                        let proposedName = id.uuidString + ".img"
                        if (try? imageData.write(to: artworkDirectory.appendingPathComponent(proposedName), options: .atomic)) != nil {
                            artworkName = proposedName
                        }
                    }
                    var track = MusicTrack(id: id, title: title, artist: artist, album: album,
                                           fileName: destinationName, originalFileName: originalName,
                                           artworkFileName: artworkName, duration: duration)
                    if let wish {
                        track.title = wish.title
                        track.artist = wish.artist
                        if !wish.album.isEmpty { track.album = wish.album }
                        track.sourceAttribution = attribution
                    }
                    if cancellationAware { try Task.checkCancellation() }
                    preparedTrack = track
                },
                recoveryTrack: {
                    guard let preparedTrack else {
                        throw MusicLibraryError.unsupportedFormat
                    }
                    return preparedTrack
                },
                persist: {
                    guard let preparedTrack else {
                        throw MusicLibraryError.unsupportedFormat
                    }
                    if cancellationAware { try Task.checkCancellation() }
                    let updatedTracks = tracks + [preparedTrack]
                    // Imported recording and reconciled playlist links commit
                    // together, after no-replace publication of the audio.
                    let updatedPlaylists = reconciledPlaylists(using: updatedTracks)
                    if cancellationAware { try Task.checkCancellation() }
                    try PersistedLibrary(tracks: updatedTracks, playlists: updatedPlaylists)
                        .write(to: databaseURL)
                    tracks = updatedTracks
                    playlists = updatedPlaylists
                }
            )
            return true
        } catch {
            // The transaction cleans only its own staging/published file.
            // A colliding destination existed before us and is never removed.
            if let artworkName {
                try? manager.removeItem(at: artworkDirectory.appendingPathComponent(artworkName))
            }
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
            if let next = eligible.compactMap(\.nextLookupAt).filter({ $0 > now }).min() {
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

    func canResolveRecordingSources(for playlistID: UUID) -> Bool {
        foregroundDiscoveryEnabled && networkAllowsDiscovery(for: playlistID) &&
            playlists.contains { $0.id == playlistID }
    }

    func hasCurrentSourceRequest(_ wish: PlaylistWish, for playlistID: UUID) -> Bool {
        playlists.first(where: { $0.id == playlistID })?.sourceOrder.contains(where: {
            $0.matchesSourceRequest(wish)
        }) == true
    }

    func queueRecording(_ candidate: RecordingCandidate, matching wish: PlaylistWish,
                        playlistID: UUID) async throws {
        guard canResolveRecordingSources(for: playlistID) else { throw NativeAudioEngine.Failure.networkUnavailable }
        guard hasCurrentSourceRequest(wish, for: playlistID), BackgroundDownloadBackpressure.mayEnqueue(
            outstandingTransfers: BackgroundAudioDownloader.shared.pendingCount()) else { throw NativeAudioEngine.Failure.queueUnavailable }
        let sources = try await NativeAudioEngine.shared.resolve(candidate, for: wish,
            allowsCellular: cellularApproved(for: playlistID), userSelected: true)
        try Task.checkCancellation()
        guard let source = sources.first,
              canResolveRecordingSources(for: playlistID), hasCurrentSourceRequest(wish, for: playlistID),
              try BackgroundAudioDownloader.shared.enqueue(source: source, requested: wish, playlistID: playlistID,
                                                          alternatives: Array(sources.dropFirst())) else {
            throw NativeAudioEngine.Failure.queueUnavailable
        }
    }

    func recoverRecordingSource(after ticket: BackgroundAudioTicket, notBefore: Date? = nil) {
        guard hasCurrentSourceRequest(ticket.requested, for: ticket.playlistID),
              let index = discoveryJobs.firstIndex(where: { $0.playlistID == ticket.playlistID }),
              !hasOfflineRecording(matching: ticket.requested) else { return }
        // Discovery can still find a catalog or cached web file after the
        // recording matcher has no candidates left or has been disabled.
        let now = Date()
        let lookupAt = notBefore.flatMap { $0 > now ? $0 : nil }
        guard discoveryJobs[index].requeueFailedSource(for: ticket.requested.id, notBefore: lookupAt) else { return }
        persistDiscovery()
        resumePendingDiscovery()
        if !foregroundDiscoveryEnabled && !backgroundDiscoveryInProgress {
            MP3ShelfBackgroundDiscovery.schedule(nextUsefulDate: nextBackgroundDiscoveryDate)
        }
    }

    private func failedRecordingIDs(for wish: PlaylistWish, playlistID: UUID) -> Set<String> {
        let now = Date()
        return Set(BackgroundAudioDownloader.shared.failedSourceTickets(for: wish, playlistID: playlistID)
            .filter { !AudioSourceLinks.hasExpired($0.downloadURL, at: now) }
            .compactMap { AudioSourceLinks.youtubeVideoID($0.sourcePage) })
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
        let imported = try addLocalAudio(sourceURL: importURL,
                                               originalName: original,
                                               expectedDuration: wish.durationSeconds,
                                               matching: wish, attribution: attribution)
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
            let previousWishID = job.currentWish?.id
            guard job.prepareLookup(at: Date()), let wish = job.currentWish else { break }
            if wish.id != previousWishID {
                // Persist the selected cursor before any asynchronous work.
                // Subsequent lookups reject stale checkpoints by equality.
                discoveryJobs[index] = job
                persistDiscovery()
            }
            if var progress = automaticDownloadProgress {
                progress.currentSong = "\(wish.artist) — \(wish.title)"
                automaticDownloadProgress = progress
            }
            if !hasCurrentSourceRequest(wish, for: playlistID) {
                // Obsolete entries advance without another lookup.
                job.record(.removed)
            } else if hasOfflineRecording(matching: wish) {
                job.record(.alreadyPresent)
            } else if BackgroundAudioDownloader.shared.isQueued(wish, for: playlistID) {
                job.record(.queued)
            } else {
                do {
                    let allowsCellular = !backgroundWiFiOnly && cellularApprovedPlaylists.contains(playlistID)
                    var ownedSources: [AudioCatalogMatch] = []
                    var ownedDetails: [String] = []
                    var recordingFailure: Error?
                    if RecordingMatcher.isEnabled {
                        do {
                            let found: [RecordingCandidate]
                            if let saved = job.recordingCandidates?[wish.id.uuidString] {
                                found = saved
                            } else {
                                found = try await NativeAudioEngine.shared.search(for: wish, allowsCellular: allowsCellular)
                                guard job.isCurrent(in: discoveryJobs, at: index) else { break }
                                if job.recordingCandidates == nil { job.recordingCandidates = [:] }
                                job.recordingCandidates?[wish.id.uuidString] = found
                                discoveryJobs[index] = job
                                persistDiscovery()
                            }
                            let ranked = RecordingMatcher.rank(found, for: wish)
                            ownedDetails.append("MP3 Shelf matching: \(found.count) recordings examined")
                            for match in ranked.prefix(2) {
                                ownedDetails.append("Match \(match.score): \(match.candidate.title) — \(match.reason)")
                            }
                            var excluded = failedRecordingIDs(for: wish, playlistID: playlistID)
                            for _ in 0..<2 {
                                guard let choice = RecordingMatcher.automaticChoice(ranked, excluding: excluded) else { break }
                                do {
                                    let sources = try await NativeAudioEngine.shared.resolve(choice, for: wish, allowsCellular: allowsCellular)
                                    guard job.isCurrent(in: discoveryJobs, at: index) else { break }
                                    ownedSources = sources
                                    ownedDetails.append("MP3 Shelf matching: selected \(choice.title); audio resolved on this iPhone")
                                    break
                                } catch is CancellationError { throw CancellationError() }
                                catch {
                                    try Task.checkCancellation()
                                    ownedDetails.append("Recording \(choice.id): \(error.localizedDescription)")
                                    if SourceLookupRetryPolicy.isTemporary(error) { recordingFailure = error }
                                    excluded.insert(choice.id)
                                }
                            }
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            try Task.checkCancellation()
                            ownedDetails.append("MP3 Shelf matching: \(error.localizedDescription)")
                            if SourceLookupRetryPolicy.isTemporary(error) { recordingFailure = error }
                        }
                        guard job.isCurrent(in: discoveryJobs, at: index) else { break }
                    }
                    let report: AudioSourceFinder.CatalogSearchReport
                    var catalogError: Error?
                    if !ownedSources.isEmpty {
                        report = .init(candidates: ownedSources, warnings: [], details: ownedDetails)
                    } else {
                        do {
                            let catalog = try await AudioSourceFinder.discover(for: wish, allowsCellular: allowsCellular)
                            report = .init(candidates: catalog.candidates, warnings: catalog.warnings, details: ownedDetails + catalog.details)
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            catalogError = error
                            report = .init(candidates: [], warnings: [error.localizedDescription],
                                           details: ownedDetails + [error.localizedDescription])
                        }
                    }
                    guard job.isCurrent(in: discoveryJobs, at: index),
                          hasCurrentSourceRequest(wish, for: playlistID) else { break }
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
                    guard hasCurrentSourceRequest(wish, for: playlistID) else { break }
                    let retryFailure = SourceLookupRetryPolicy.failureToRetry(
                        recordingFailure, hasCandidates: !candidates.isEmpty)
                    if retryFailure != nil {
                        details.append("Recording lookup was interrupted; retrying with the existing five-attempt limit")
                    }
                    job.saveLookupDetails(details, for: wish.id)
                    discoveryJobs[index] = job
                    persistDiscovery()
                    if let retryFailure { throw retryFailure }
                    if let catalogError, candidates.isEmpty && !healthyLookup { throw catalogError }
                    if Task.isCancelled || !networkAllowsDiscovery(for: playlistID) ||
                        (backgroundWiFiOnly && !isOnWiFi) { break }
                    let sources = BackgroundAudioDownloader.shared.prioritize(candidates)
                    // Capacity can change during the awaited catalog request.
                    // Keep this wish pending until a transfer slot opens.
                    guard BackgroundDownloadBackpressure.mayEnqueue(
                        outstandingTransfers: BackgroundAudioDownloader.shared.pendingCount()
                    ) else { break }
                    if hasOfflineRecording(matching: wish) {
                        job.record(.alreadyPresent)
                    } else if BackgroundAudioDownloader.shared.isQueued(wish, for: playlistID) {
                        job.record(.queued)
                    } else if let source = sources.first {
                        if try BackgroundAudioDownloader.shared.enqueue(
                            source: source, requested: wish, playlistID: playlistID,
                            alternatives: Array(sources.dropFirst())) {
                            job.record(.queued)
                        } else { job.record(.failed) }
                    } else {
                        job.record(.unavailable)
                        job.catalogWarnings = Array(Set((job.catalogWarnings ?? []) + report.warnings)).sorted()
                    }
                } catch let error as NSError where error.domain == BackgroundTicketManifestPolicy.writeFailureDomain {
                    // Storage needs attention. Preserve this wish and the
                    // saved search budget until the user resumes discovery.
                    job.isPaused = true
                    job.lastError = error.localizedDescription
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
        defer { try? manager.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MusicLibraryError.downloadFailed
        }
        if let finalHost = http.url?.host?.lowercased(),
           ["spotify.com", "spotifycdn.com", "scdn.co"].contains(where: { finalHost == $0 || finalHost.hasSuffix("." + $0) }) {
            throw MusicLibraryError.invalidDownloadURL
        }
        let attributes = try manager.attributesOfItem(atPath: temporary.path)
        guard let downloadedBytes = (attributes[.size] as? NSNumber)?.int64Value,
              downloadedBytes <= BackgroundTransferProgressPolicy.maxBytes else {
            throw MusicLibraryError.downloadFailed
        }
        guard downloadedBytes > 0 else { throw MusicLibraryError.emptyDownload }
        guard DownloadedAudioRange.coversCompleteFile(status: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"), downloadedBytes: downloadedBytes) else {
            throw MusicLibraryError.incompleteDownload
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
        let imported = try addLocalAudio(sourceURL: staging,
                                               originalName: filename + "." + actualExtension,
                                               expectedDuration: wish?.durationSeconds,
                                               matching: wish, attribution: attribution)
        // addLocalAudio already commits the imported recording and resolved playlist
        // references in one atomic catalog write, including manual URL imports.
        return ImportReport(imported: imported ? 1 : 0, skipped: imported ? 0 : 1)
    }

    func rename(_ track: MusicTrack, title: String, artist: String) {
        guard isLibraryPersistenceSafe else { return }
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        var updatedTracks = tracks
        updatedTracks[index].title = cleanTitle
        updatedTracks[index].artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never publish a rename that has not been durably committed.
        do {
            try PersistedLibrary(tracks: updatedTracks, playlists: playlists).write(to: databaseURL)
            tracks = updatedTracks
            libraryStorageError = nil
        } catch {
            libraryStorageError = "Could not save the recording name. Your previous metadata was preserved."
            print("MP3 Shelf could not persist recording rename: \(error)")
        }
    }

    func toggleFavorite(_ id: UUID) {
        guard isLibraryPersistenceSafe else { return }
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        var updatedTracks = tracks
        updatedTracks[index].isFavorite.toggle()
        // Publish the favorite change only after the catalog is durable.
        // A best-effort save previously left an unsaved favorite visible.
        do {
            try PersistedLibrary(tracks: updatedTracks, playlists: playlists).write(to: databaseURL)
            tracks = updatedTracks
        } catch {
            libraryStorageError = "Could not save the favorite change. Your music library was preserved."
            print("MP3 Shelf could not persist favorite change: \(error)")
        }
    }

    func removeTrack(_ id: UUID) {
        guard isLibraryPersistenceSafe else { return }
        guard let track = song(with: id) else { return }
        // Commit the catalog change before deleting user-owned audio. If the
        // database is protected, full, or otherwise unwritable, leave both the
        // recording and its playlist references untouched.
        let remainingTracks = tracks.filter { $0.id != id }
        var remainingPlaylists = playlists
        for index in remainingPlaylists.indices {
            remainingPlaylists[index].trackIDs.removeAll { $0 == id }
        }
        // Reconcile source-backed playlists in the SAME durable transaction.
        // A second best-effort save after deleting audio could leave the live
        // playlist state different from the last committed catalog.
        remainingPlaylists = reconciledPlaylists(using: remainingTracks, from: remainingPlaylists)
        do {
            try PersistedLibrary(tracks: remainingTracks, playlists: remainingPlaylists)
                .write(to: databaseURL)
        } catch {
            libraryStorageError = "Could not save the music library. The recording was not deleted."
            print("MP3 Shelf refused to delete audio before saving its catalog: \\(error)")
            return
        }
        tracks = remainingTracks
        playlists = remainingPlaylists
        // A crash here may leave an orphan file, never a catalog referencing
        // audio already deleted. Sidecar removal remains best effort.
        // Restored or legacy catalogs may share a stored filename across
        // multiple track records. Only delete files with no remaining owner.
        if !LocalLibraryFileSafety.isReferenced(track.fileName, by: remainingTracks.map(\.fileName)),
           let ownedAudio = LocalLibraryFileSafety.regularFile(
               named: track.fileName, in: musicDirectory) {
            do {
                try manager.removeItem(at: ownedAudio)
            } catch {
                print("MP3 Shelf retained an orphaned audio file after catalog removal: \(error)")
            }
        }
        if let artwork = track.artworkFileName,
           !LocalLibraryFileSafety.isReferenced(artwork, by: remainingTracks.map(\.artworkFileName)) {
            artworkCache.removeObject(forKey: artwork as NSString)
            if let ownedArtwork = LocalLibraryFileSafety.regularFile(
                named: artwork, in: artworkDirectory) {
                try? manager.removeItem(at: ownedArtwork)
            }
        }
        if let lyrics = track.lyricsFileName,
           !LocalLibraryFileSafety.isReferenced(lyrics, by: remainingTracks.map(\.lyricsFileName)),
           let ownedLyrics = LocalLibraryFileSafety.regularFile(
               named: lyrics, in: lyricsDirectory) {
            try? manager.removeItem(at: ownedLyrics)
        }
    }

    /// Playlist edits must be durable before SwiftUI observes the new state.
    /// A failed atomic catalog write leaves the previous playlist snapshot intact.
    @discardableResult
    private func commitPlaylistEdit(_ updated: [MusicPlaylist]) -> Bool {
        guard isLibraryPersistenceSafe else { return false }
        do {
            try PersistedLibrary(tracks: tracks, playlists: updated).write(to: databaseURL)
            playlists = updated
            libraryStorageError = nil
            return true
        } catch {
            libraryStorageError = "Could not save playlist changes. Your previous playlists were preserved."
            print("MP3 Shelf could not persist playlist edit: \(error)")
            return false
        }
    }

    func createPlaylist(_ name: String) {
        guard isLibraryPersistenceSafe else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var updated = playlists
        updated.append(MusicPlaylist(name: clean))
        commitPlaylistEdit(updated)
    }

    func duplicatePlaylist(_ id: UUID) {
        guard isLibraryPersistenceSafe else { return }
        guard let original = playlists.first(where: { $0.id == id }) else { return }
        var updated = playlists
        updated.append(original.localCopy())
        commitPlaylistEdit(updated)
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard isLibraryPersistenceSafe else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var updated = playlists
        updated[index].name = clean
        commitPlaylistEdit(updated)
    }

    func deletePlaylist(_ id: UUID) {
        guard isLibraryPersistenceSafe, playlists.contains(where: { $0.id == id }) else { return }
        let updated = playlists.filter { $0.id != id }
        // Do not cancel transfers or discard discovery checkpoints unless
        // the playlist deletion has actually been committed to disk.
        do {
            try PersistedLibrary(tracks: tracks, playlists: updated).write(to: databaseURL)
            playlists = updated
            libraryStorageError = nil
            stopBackgroundTransfers(for: id)
            discoveryJobs.removeAll { $0.playlistID == id }
            persistDiscovery()
        } catch {
            libraryStorageError = "Could not delete the playlist. Your previous playlists were preserved."
            print("MP3 Shelf could not persist playlist deletion: \(error)")
        }
    }

    func addTrack(_ trackID: UUID, to playlistID: UUID) {
        guard isLibraryPersistenceSafe, tracks.contains(where: { $0.id == trackID }),
              let index = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[index].trackIDs.contains(trackID) else { return }
        var updated = playlists
        updated[index].trackIDs.append(trackID)
        commitPlaylistEdit(updated)
    }

    func removeTrack(_ trackID: UUID, from playlistID: UUID) {
        guard isLibraryPersistenceSafe,
              let index = playlists.firstIndex(where: { $0.id == playlistID }),
              playlists[index].trackIDs.contains(trackID) else { return }
        var updated = playlists
        updated[index].trackIDs.removeAll { $0 == trackID }
        if let track = song(with: trackID),
           let wishIndex = updated[index].sourceOrder.firstIndex(where: {
               MusicMatching.reusableOfflineTrack(for: $0, in: [track]) != nil
           }) {
            updated[index].sourceOrder.remove(at: wishIndex)
        }
        commitPlaylistEdit(updated)
    }

    func moveTracks(in playlistID: UUID, from offsets: IndexSet, to index: Int) {
        guard isLibraryPersistenceSafe,
              let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var items = playlists[playlistIndex].trackIDs
        guard index >= 0, index <= items.count,
              offsets.allSatisfy({ $0 >= 0 && $0 < items.count }),
              !offsets.isEmpty else { return }
        let moved = offsets.sorted().map { items[$0] }
        let insertionIndex = index - offsets.filter { $0 < index }.count
        for offset in offsets.sorted(by: >) { items.remove(at: offset) }
        items.insert(contentsOf: moved, at: max(0, min(insertionIndex, items.count)))
        var updated = playlists
        updated[playlistIndex].trackIDs = items
        commitPlaylistEdit(updated)
    }

    func importPlaylistCSV(data: Data, name: String, spotifyURL: String? = nil) throws -> PlaylistImportReport {
        importPlaylist(wishes: try PlaylistCSV.parse(data), name: name, sourceURL: spotifyURL)
    }

    func importPlaylist(wishes: [PlaylistWish], name: String, sourceURL: String? = nil,
                        appleMusicLibraryID: String? = nil) -> PlaylistImportReport {
        refreshTrackIndexIfNeeded()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "Imported Playlist" : trimmed
        let spotifyID = sourceURL.flatMap(SpotifyPlaylistLinks.playlistID(from:))
        let appleID = spotifyID == nil ? AppleMusicLibraryIdentity.canonical(appleMusicLibraryID) : nil
        let sourceIdentity = ImportedPlaylistIdentity.key(sourceURL: sourceURL, appleMusicLibraryID: appleID)
        // Refresh the source order while preserving occurrence IDs and
        // discovery results that still match the requested recordings.
        if let sourceIdentity,
           let index = playlists.firstIndex(where: {
               ImportedPlaylistIdentity.key(sourceURL: $0.sourceURL,
                                            appleMusicLibraryID: $0.appleMusicLibraryID) == sourceIdentity
           }) {
            let old = playlists[index]
            let updated = SpotifyPlaylistSync.merge(previous: old.sourceOrder, latest: wishes)
            let previousIDs = old.sourceOrder.map(\.id)
            let currentIDs = updated.map(\.id)
            let listChanged = previousIDs != currentIDs ||
                zip(old.sourceOrder, updated).contains(where: { pair in
                    pair.0.title != pair.1.title || pair.0.artist != pair.1.artist ||
                    pair.0.album != pair.1.album ||
                    pair.0.durationSeconds != pair.1.durationSeconds ||
                    pair.0.artistNames != pair.1.artistNames || pair.0.appleMusicItemID != pair.1.appleMusicItemID
                })
            if listChanged {
                // Distinguish manually added local files from tracks that
                // belonged to the previous Spotify source-order mapping.
                let formerlySourced = Set(old.sourceOrder.compactMap {
                    indexedByTitle.reusableTrack(for: $0)?.id
                })
                var candidate = playlists
                candidate[index].trackIDs.removeAll { formerlySourced.contains($0) }
                candidate[index].sourceOrder = updated
                candidate[index].name = displayName
                candidate[index].sourceURL = sourceURL
                candidate[index].appleMusicLibraryID = appleID
                candidate = reconciledPlaylists(using: tracks, from: candidate)
                guard commitPlaylistEdit(candidate) else {
                    return PlaylistImportReport(playlistID: old.id, playlistName: old.name,
                                                matched: old.trackIDs.count, missing: old.missingTracks.count)
                }
                if automaticDownloadProgress?.playlistID == old.id {
                    automaticDownloadTask?.cancel()
                }
            } else {
                let candidate = reconciledPlaylists(using: tracks)
                guard commitPlaylistEdit(candidate) else {
                    return PlaylistImportReport(playlistID: old.id, playlistName: old.name,
                                                matched: old.trackIDs.count, missing: old.missingTracks.count)
                }
            }
            var hasNewLookups = false
            if let jobIndex = discoveryJobs.firstIndex(where: { $0.playlistID == old.id }) {
                let previousJob = discoveryJobs[jobIndex]
                hasNewLookups = discoveryJobs[jobIndex].refreshMissingWishes(
                    playlists[index].missingTracks) > 0
                if discoveryJobs[jobIndex] != previousJob { persistDiscovery() }
            } else if !playlists[index].missingTracks.isEmpty {
                discoveryJobs.append(SourceDiscoveryJob(
                    playlistID: old.id, wishes: playlists[index].missingTracks))
                persistDiscovery()
                hasNewLookups = true
            }
            if listChanged {
                BackgroundAudioDownloader.shared.cancelObsoleteTransfers(in: self, for: old.id)
            }
            if hasNewLookups { resumePendingDiscovery() }
            return PlaylistImportReport(playlistID: old.id,
                                        playlistName: playlists[index].name,
                                        matched: playlists[index].trackIDs.count,
                                        missing: playlists[index].missingTracks.count)
        }
        var playlist = MusicPlaylist(name: displayName)
        if spotifyID != nil { playlist.sourceURL = sourceURL }
        playlist.appleMusicLibraryID = appleID
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
        guard commitPlaylistEdit(playlists + [playlist]) else {
            // Preserve the previous catalog; the storage error is exposed to the UI.
            return PlaylistImportReport(playlistID: playlist.id, playlistName: playlist.name,
                                        matched: 0, missing: wishes.count)
        }
        return PlaylistImportReport(playlistID: playlist.id, playlistName: playlist.name,
                                    matched: playlist.trackIDs.count,
                                    missing: playlist.missingTracks.count)
    }

    func recheckSavedAudio() { reconcileMissingSongs() }

    private func reconcileMissingSongs() {
        // Rechecking offline availability must not publish unsaved playlist links.
        // A protected or full catalog leaves the last durable snapshot visible.
        let candidate = reconciledPlaylists(using: tracks)
        guard candidate != playlists else { return }
        commitPlaylistEdit(candidate)
    }

    private func reconciledPlaylists(using updatedTracks: [MusicTrack],
                                     from sourcePlaylists: [MusicPlaylist]? = nil) -> [MusicPlaylist] {
        let allTracksIndex = OfflineTrackIndex(tracks: updatedTracks)
        let available = updatedTracks.filter { manager.fileExists(atPath: fileURL(for: $0).path) }
        let availableIndex = OfflineTrackIndex(tracks: available)
        var updated = sourcePlaylists ?? playlists
        for index in updated.indices where !updated[index].sourceOrder.isEmpty {
            let existing = updated[index].trackIDs
            var ordered: [UUID] = []
            var missing: [PlaylistWish] = []
            var sourcedTrackIDs = Set<UUID>()
            for wish in updated[index].sourceOrder {
                if let previous = allTracksIndex.reusableTrack(for: wish) {
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
            updated[index].trackIDs = ordered
            updated[index].missingTracks = missing
        }
        return updated
    }

    func trackSizeBytes(_ track: MusicTrack) -> Int64 {
        // Never count arbitrary outside files or follow symlinked catalog paths.
        guard let owned = LocalLibraryFileSafety.regularFile(
                  named: track.fileName, in: musicDirectory),
              let size = try? owned.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return 0
        }
        return Int64(max(size, 0))
    }

    var totalStorageBytes: Int64 {
        tracks.reduce(0) { $0 + trackSizeBytes($1) }
    }
}

enum MusicLibraryError: LocalizedError {
    case unsupportedFormat, invalidDownloadURL, downloadFailed, emptyDownload, incompleteDownload, recordingDurationMismatch
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
        case .emptyDownload: return AudioDownloadDiagnostics.emptyResponse
        case .incompleteDownload: return DownloadedAudioRange.incompleteMessage
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
