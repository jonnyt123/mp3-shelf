import Foundation
import Combine
@preconcurrency import MediaPlayer

/// Reads metadata only. Protected assets and preview URLs never enter the downloader.
@MainActor
final class AppleMusicService: ObservableObject {
    @Published private(set) var playlists: [AppleMusicPlaylistSummary] = []
    @Published private(set) var isBusy = false
    @Published private(set) var authorization = MPMediaLibrary.authorizationStatus()
    let namespace: UUID

    var isAuthorized: Bool { authorization == .authorized }
    var needsSettings: Bool { authorization == .denied || authorization == .restricted }

    init() {
        let key = "MP3Shelf.appleMusicLibraryNamespace"
        let value = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        namespace = value
        UserDefaults.standard.set(value.uuidString, forKey: key)
    }

    enum Failure: LocalizedError {
        case access, restricted, missingPlaylist, busy
        var errorDescription: String? {
            switch self {
            case .access: return "Allow Media & Apple Music access in Settings to read your playlists."
            case .restricted: return "Music library access is restricted on this iPhone."
            case .missingPlaylist: return "This playlist is no longer in the Music library. Refresh the playlist list."
            case .busy: return "A Music library read is already running."
            }
        }
    }

    func checkAuthorization() {
        authorization = MPMediaLibrary.authorizationStatus()
        if !isAuthorized { playlists = [] }
    }

    private func requireAccess() throws {
        checkAuthorization()
        guard isAuthorized else {
            throw authorization == .restricted ? Failure.restricted : Failure.access
        }
    }

    func refresh(requestAccess: Bool = false) async throws {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        checkAuthorization()
        if requestAccess && authorization == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        try Task.checkCancellation()
        try requireAccess()
        let loaded = try await readInBackground {
            // Do not filter out cloud or protected items: only metadata is read.
            let collections = MPMediaQuery.playlists().collections ?? []
            var seen = Set<UInt64>()
            var results: [AppleMusicPlaylistSummary] = []
            for collection in collections {
                try Task.checkCancellation()
                guard let playlist = collection as? MPMediaPlaylist,
                      playlist.persistentID > 0, seen.insert(playlist.persistentID).inserted else { continue }
                let name = (playlist.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(AppleMusicPlaylistSummary(id: playlist.persistentID,
                    name: name.isEmpty ? "Untitled playlist" : name, itemCount: playlist.count))
            }
            return results.sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        }
        try Task.checkCancellation()
        try requireAccess()
        playlists = loaded
    }

    func snapshot(for id: UInt64) async throws -> AppleMusicPlaylistSnapshot {
        guard !isBusy else { throw Failure.busy }
        isBusy = true
        defer { isBusy = false }
        try requireAccess()
        let snapshot = try await readInBackground {
            let playlist = (MPMediaQuery.playlists().collections ?? [])
                .compactMap { $0 as? MPMediaPlaylist }.first { $0.persistentID == id }
            guard let playlist else { throw Failure.missingPlaylist }
            guard playlist.count <= AppleMusicPlaylistSnapshot.maximumTracks else { throw AppleMusicPlaylistSnapshot.ImportFailure.tooLarge }
            let items = try playlist.items.map { item in
                try Task.checkCancellation()
                return AppleMusicTrackSnapshot(id: item.persistentID, title: item.title ?? "",
                    artist: item.artist ?? "", album: item.albumTitle ?? "", duration: item.playbackDuration,
                    isMusic: item.mediaType.contains(.music) || item.mediaType.contains(.musicVideo))
            }
            let name = (playlist.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return AppleMusicPlaylistSnapshot(id: id, name: name.isEmpty ? "Untitled playlist" : name, items: items)
        }
        try Task.checkCancellation()
        try requireAccess()
        return snapshot
    }

    private func readInBackground<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
