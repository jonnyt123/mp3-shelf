import Foundation
import UIKit

/// A persisted download ticket is independent of Spotify's OAuth session.
/// Only the authorized, direct audio file URL is transferred by iOS.
struct BackgroundAudioTicket: Codable, Identifiable {
    enum Status: String, Codable { case queued, imported, failed }
    let id: UUID
    let playlistID: UUID
    let requested: PlaylistWish
    let downloadURL: URL
    let sourcePage: URL
    let licensePage: URL
    let provider: String
    var status: Status = .queued
}

/// URLSession's background transfer daemon survives ordinary app suspension
/// and OS-initiated process termination. Discovery still runs in foreground.
/// Staged media survives the delegate's short-lived temporary file callback.
@MainActor
final class BackgroundAudioDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundAudioDownloader()
    static let identifier = "com.jonnyt.mp3shelf.licensed-audio-v1"

    private let fm = FileManager.default
    private let manifestURL: URL
    private var tickets: [UUID: BackgroundAudioTicket] = [:]
    private var processing: Set<UUID> = []
    private weak var library: MusicLibrary?
    private var backgroundEventsCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    override private init() {
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MP3Shelf", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        manifestURL = root.appendingPathComponent("background-audio-tickets.json")
        if let data = try? Data(contentsOf: manifestURL),
           let saved = try? JSONDecoder().decode([BackgroundAudioTicket].self, from: data) {
            tickets = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        }
        super.init()
    }

    /// iOS calls this even when the user does not open a SwiftUI scene.
    func activate() {
        _ = session
    }

    func attach(to library: MusicLibrary) {
        self.library = library
        activate()
        updatePending()
        Task { await recoverStagedDownloads() }
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let active = Set(tasks.compactMap { UUID(uuidString: $0.taskDescription ?? "") })
                for (id, ticket) in self.tickets where ticket.status == .queued
                    && !active.contains(id) && !self.fm.fileExists(atPath: Self.stagingURL(id).path) {
                    self.setFailed(id)
                }
            }
        }
    }

    @discardableResult
    func enqueue(source: AudioCatalogMatch, requested: PlaylistWish, playlistID: UUID) -> Bool {
        guard Self.allowedDownloadURL(source.downloadURL) else { return false }
        if tickets.values.contains(where: {
            $0.status == .queued && $0.playlistID == playlistID &&
            MusicMatching.key($0.requested.title) == MusicMatching.key(requested.title) &&
            MusicMatching.key($0.requested.artist) == MusicMatching.key(requested.artist)
        }) { return false }
        let ticket = BackgroundAudioTicket(
            id: UUID(), playlistID: playlistID, requested: requested,
            downloadURL: source.downloadURL, sourcePage: source.itemURL,
            licensePage: source.licenseURL, provider: source.sourceName)
        tickets[ticket.id] = ticket
        persist()
        let task = session.downloadTask(with: source.downloadURL)
        task.taskDescription = ticket.id.uuidString
        task.resume()
        updatePending()
        return true
    }

    func pendingCount(for playlistID: UUID? = nil) -> Int {
        tickets.values.filter { $0.status == .queued && (playlistID == nil || $0.playlistID == playlistID) }.count
    }

    func stopTransfers(for playlistID: UUID) {
        let ids = Set(tickets.values.filter { $0.playlistID == playlistID && $0.status == .queued }.map(\.id))
        session.getAllTasks { [weak self] tasks in
            for task in tasks where ids.contains(UUID(uuidString: task.taskDescription ?? "") ?? UUID()) {
                task.cancel()
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for id in ids { self.setFailed(id) }
            }
        }
    }

    func setBackgroundEventsCompletion(_ completion: @escaping () -> Void) {
        backgroundEventsCompletion = completion
        activate()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(tickets.values)) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private func updatePending() {
        library?.pendingBackgroundDownloads = pendingCount()
    }

    private func setFailed(_ id: UUID) {
        guard var ticket = tickets[id], ticket.status == .queued else { return }
        ticket.status = .failed
        tickets[id] = ticket
        persist()
        library?.finishedBackgroundDownload(for: ticket.playlistID, succeeded: false)
        updatePending()
    }

    private func recoverStagedDownloads() async {
        guard let library else { return }
        let candidates = tickets.values.filter {
            $0.status == .queued && fm.fileExists(atPath: Self.stagingURL($0.id).path)
        }
        for ticket in candidates {
            guard processing.insert(ticket.id).inserted else { continue }
            defer { processing.remove(ticket.id) }
            let stagedURL = Self.stagingURL(ticket.id)
            do {
                let attribution = AudioSourceAttribution(
                    pageURL: ticket.sourcePage.absoluteString,
                    licenseURL: ticket.licensePage.absoluteString,
                    providerName: ticket.provider)
                let imported = try await library.importStagedAudio(
                    from: stagedURL, matching: ticket.requested, attribution: attribution)
                if var current = tickets[ticket.id], current.status == .queued {
                    current.status = imported ? .imported : .failed
                    tickets[ticket.id] = current
                    persist()
                    library.finishedBackgroundDownload(for: ticket.playlistID, succeeded: imported)
                }
                try? fm.removeItem(at: stagedURL)
            } catch {
                // Leave failed transfers retryable via the playlist's retry button.
                setFailed(ticket.id)
                try? fm.removeItem(at: stagedURL)
            }
        }
        updatePending()
    }

    private func finishBackgroundEvents() async {
        await recoverStagedDownloads()
        let completion = backgroundEventsCompletion
        backgroundEventsCompletion = nil
        completion?()
    }

    nonisolated private static func stagingURL(_ id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MP3Shelf", isDirectory: true)
            .appendingPathComponent("IncomingDownloads", isDirectory: true)
            .appendingPathComponent(id.uuidString + ".mp3")
    }

    nonisolated private static func allowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              !host.isEmpty, url.user == nil, url.password == nil else { return false }
        for blocked in ["spotify.com", "spotifycdn.com", "scdn.co", "jamendo.com", "youtube.com", "googlevideo.com"] {
            if host == blocked || host.hasSuffix("." + blocked) { return false }
        }
        return true
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { Self.allowedDownloadURL($0) } == true ? request : nil)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let id = UUID(uuidString: downloadTask.taskDescription ?? "") else { return }
        guard let http = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              http.url.map({ Self.allowedDownloadURL($0) }) == true,
              let mime = http.mimeType?.lowercased(),
              ["audio/mpeg", "audio/mp3", "application/octet-stream", "audio/x-mpeg"].contains(mime)
        else {
            Task { @MainActor in self.setFailed(id) }
            return
        }
        // Copy/move BEFORE returning: URLSession deletes location at delegate return.
        let destination = Self.stagingURL(id)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let bytes = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0 && bytes <= 100 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in await self.recoverStagedDownloads() }
        } catch {
            Task { @MainActor in self.setFailed(id) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard error != nil, let id = UUID(uuidString: task.taskDescription ?? "") else { return }
        Task { @MainActor in self.setFailed(id) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in await self.finishBackgroundEvents() }
    }
}
