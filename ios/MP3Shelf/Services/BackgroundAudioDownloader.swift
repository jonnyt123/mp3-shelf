import Foundation
import Combine
import UIKit

/// A persisted download ticket is independent of Spotify's OAuth session.
/// Only the authorized, direct audio file URL is transferred by iOS.
struct BackgroundAudioTicket: Codable, Identifiable {
    enum Status: String, Codable { case queued, imported, failed, cancelled }
    let id: UUID
    let playlistID: UUID
    let requested: PlaylistWish
    let downloadURL: URL
    let sourcePage: URL
    let licensePage: URL
    let provider: String
    var status: Status = .queued
    var bytesReceived: Int64? = nil
    var totalBytes: Int64? = nil
    var failureReason: String? = nil
    var startedAt: Date? = nil
}

/// URLSession's background transfer daemon survives ordinary app suspension
/// and OS-initiated process termination. Discovery still runs in foreground.
/// Staged media survives the delegate's short-lived temporary file callback.
@MainActor
final class BackgroundAudioDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var revision: Int = 0
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
        // Do not classify jobs as orphaned here: a completed transfer can
        // disappear from getAllTasks before its completion delegate is delivered.
        // The download delegate (or later explicit user cancellation) owns
        // terminal transitions, preserving valid files across cold relaunches.
    }

    @discardableResult
    func enqueue(source: AudioCatalogMatch, requested: PlaylistWish, playlistID: UUID) -> Bool {
        guard Self.allowedDownloadURL(source.downloadURL) else { return false }
        if tickets.values.contains(where: {
            $0.status == .queued && $0.playlistID == playlistID &&
            MusicMatching.key($0.requested.title) == MusicMatching.key(requested.title) &&
            MusicMatching.key($0.requested.artist) == MusicMatching.key(requested.artist)
        }) { return false }
        var ticket = BackgroundAudioTicket(
            id: UUID(), playlistID: playlistID, requested: requested,
            downloadURL: source.downloadURL, sourcePage: source.itemURL,
            licensePage: source.licenseURL, provider: source.sourceName)
        ticket.startedAt = .now
        tickets[ticket.id] = ticket
        persist()
        revision += 1
        let task = session.downloadTask(with: source.downloadURL)
        task.taskDescription = ticket.id.uuidString
        task.resume()
        updatePending()
        return true
    }

    func ticketsForPlaylist(_ playlistID: UUID? = nil) -> [BackgroundAudioTicket] {
        tickets.values.filter { playlistID == nil || $0.playlistID == playlistID }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    func isQueued(_ wish: PlaylistWish, for playlistID: UUID) -> Bool {
        tickets.values.contains {
            $0.status == .queued && $0.playlistID == playlistID &&
            MusicMatching.key($0.requested.title) == MusicMatching.key(wish.title) &&
            MusicMatching.key($0.requested.artist) == MusicMatching.key(wish.artist)
        }
    }

    func retry(_ id: UUID) {
        guard var ticket = tickets[id], ticket.status == .failed || ticket.status == .cancelled,
              Self.allowedDownloadURL(ticket.downloadURL) else { return }
        ticket.status = .queued
        ticket.failureReason = nil
        ticket.bytesReceived = nil
        ticket.totalBytes = nil
        ticket.startedAt = .now
        tickets[id] = ticket
        persist()
        revision += 1
        let task = session.downloadTask(with: ticket.downloadURL)
        task.taskDescription = id.uuidString
        task.resume()
        updatePending()
    }

    func clearFinishedHistory() {
        tickets = tickets.filter { $0.value.status == .queued }
        persist()
        revision += 1
    }

    func cancelTransfer(_ id: UUID) {
        guard var ticket = tickets[id], ticket.status == .queued else { return }
        ticket.status = .cancelled
        ticket.failureReason = "Cancelled"
        tickets[id] = ticket
        persist()
        revision += 1
        library?.finishedBackgroundDownload(for: ticket.playlistID, succeeded: false)
        updatePending()
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == id.uuidString {
                task.cancel()
            }
        }
    }

    func pendingCount(for playlistID: UUID? = nil) -> Int {
        tickets.values.filter { $0.status == .queued && (playlistID == nil || $0.playlistID == playlistID) }.count
    }

    func stopTransfers(for playlistID: UUID) {
        let ids = tickets.values.filter { $0.playlistID == playlistID && $0.status == .queued }.map(\.id)
        for id in ids { cancelTransfer(id) }
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
        revision += 1
    }

    private func setFailed(_ id: UUID, reason: String = "Download or validation failed") {
        guard var ticket = tickets[id], ticket.status == .queued else { return }
        ticket.status = .failed
        ticket.failureReason = reason
        tickets[id] = ticket
        persist()
        library?.finishedBackgroundDownload(for: ticket.playlistID, succeeded: false)
        updatePending()
    }

    private func updateProgress(_ id: UUID, received: Int64, total: Int64) {
        guard var ticket = tickets[id], ticket.status == .queued else { return }
        ticket.bytesReceived = received
        ticket.totalBytes = total > 0 ? total : nil
        tickets[id] = ticket
        revision += 1
        // Byte-level progress is intentionally not flushed to disk for each callback;
        // the OS restores actual task progress after process reattachment.
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
                    revision += 1
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

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = UUID(uuidString: downloadTask.taskDescription ?? "") else { return }
        Task { @MainActor in
            self.updateProgress(id, received: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard error != nil, let id = UUID(uuidString: task.taskDescription ?? "") else { return }
        Task { @MainActor in self.setFailed(id, reason: error?.localizedDescription ?? "Transfer error") }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in await self.finishBackgroundEvents() }
    }
}
