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
    // Optional properties preserve previously persisted queue manifests.
    var automaticRetryCount: Int? = nil
    // Independent from server errors; missing in legacy manifests.
    var connectivityRetryCount: Int? = nil
    var nextRetryAt: Date? = nil
    // Preverified source alternatives survive app termination, so iOS can
    // switch providers even after the phone is locked. Legacy manifests omit it.
    var alternativeSources: [AudioCatalogMatch]? = nil
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
    private var reconcilingOrphans = false
    private weak var library: MusicLibrary?
    private var cellularApprovedPlaylists = Set<UUID>()
    private var backgroundEventsCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    private func downloadRequest(for url: URL, playlistID: UUID) -> URLRequest {
        var request = URLRequest(url: url)
        // Background session is configured to support manual cellular opt-in,
        // but EVERY task defaults to Wi-Fi-only at the request level.
        let cellular = cellularApprovedPlaylists.contains(playlistID)
        request.allowsCellularAccess = cellular
        request.allowsExpensiveNetworkAccess = cellular
        request.allowsConstrainedNetworkAccess = cellular
        return request
    }

    /// Upgrade already-queued Wi-Fi tasks when the user explicitly approves
    /// cellular for this playlist. We use new ticket IDs so late delegate
    /// callbacks from cancelled tasks cannot corrupt the replacement.
    func enableCellular(for playlistID: UUID) {
        cellularApprovedPlaylists.insert(playlistID)
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var changed = false
                for task in tasks {
                    guard let raw = task.taskDescription,
                          let oldID = UUID(uuidString: raw),
                          let oldTicket = self.tickets[oldID],
                          oldTicket.playlistID == playlistID,
                          oldTicket.status == .queued,
                          !self.fm.fileExists(atPath: Self.stagingURL(oldID).path),
                          task.originalRequest?.allowsCellularAccess == false
                    else { continue }
                    var old = oldTicket
                    old.status = .cancelled
                    old.failureReason = "Replaced with a cellular-authorized transfer"
                    self.tickets[oldID] = old
                    var replacement = BackgroundAudioTicket(
                        id: UUID(), playlistID: old.playlistID,
                        requested: old.requested, downloadURL: old.downloadURL,
                        sourcePage: old.sourcePage, licensePage: old.licensePage,
                        provider: old.provider)
                    replacement.startedAt = .now
                    replacement.automaticRetryCount = old.automaticRetryCount
                    replacement.connectivityRetryCount = old.connectivityRetryCount
                    replacement.nextRetryAt = old.nextRetryAt
                    replacement.alternativeSources = old.alternativeSources
                    self.tickets[replacement.id] = replacement
                    let next = self.session.downloadTask(
                        with: self.downloadRequest(for: replacement.downloadURL, playlistID: playlistID))
                    next.taskDescription = replacement.id.uuidString
                    next.earliestBeginDate = replacement.nextRetryAt
                    next.resume()
                    task.cancel()
                    changed = true
                }
                if changed {
                    self.persist()
                    self.updatePending()
                }
            }
        }
    }

    override private init() {
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MP3Shelf", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        manifestURL = root.appendingPathComponent("background-audio-tickets.json")
        if let data = try? Data(contentsOf: manifestURL),
           let saved = try? JSONDecoder().decode([BackgroundAudioTicket].self, from: data) {
            tickets = BackgroundTicketManifestPolicy.distinctByIdentifier(
                saved, id: { $0.id }, startedAt: { $0.startedAt })
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
        Task { [weak self] in
            await self?.recoverStagedDownloads()
            self?.reconcileAlreadyStoredDownloads()
            // Two delayed URLSession inventory checks avoid treating a file
            // whose completion callback is still arriving as abandoned.
            await self?.recoverAbandonedBackgroundTasks()
        }
    }

    /// Learn from completed media imports, not search hits. Transfer history
    /// survives restarts; abandoned, duplicate, cancelled and retry tickets
    /// never count as successes or failures. The most recent 200 terminal
    /// outcomes keep decisions responsive and bound scoring cost.
    func prioritize(_ candidates: [AudioCatalogMatch]) -> [AudioCatalogMatch] {
        func outcome(_ ticket: BackgroundAudioTicket) -> BackgroundProviderHistoryPolicy.Outcome {
            BackgroundProviderHistoryPolicy.Outcome(
                provider: ticket.provider,
                imported: ticket.status == .imported,
                failed: ticket.status == .failed,
                failureReason: ticket.failureReason)
        }
        let recent = tickets.values.filter {
            BackgroundProviderHistoryPolicy.counts(outcome($0))
        }.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            .prefix(BackgroundProviderHistoryPolicy.maxOutcomes)
        let proven = BackgroundProviderHistoryPolicy.sources(in: recent.map(outcome))
        return AudioSourceFinder.prioritize(
            candidates, successfulProviders: proven.successful,
            failedProviders: proven.failed)
    }

    @discardableResult
    func enqueue(source: AudioCatalogMatch, requested: PlaylistWish, playlistID: UUID,
                 alternatives: [AudioCatalogMatch] = []) -> Bool {
        guard Self.allowedDownloadURL(source.downloadURL) else { return false }
        if tickets.values.contains(where: {
            $0.status == .queued && $0.playlistID == playlistID &&
            MusicMatching.sameRequestedRecording($0.requested, requested)
        }) { return false }
        var ticket = BackgroundAudioTicket(
            id: UUID(), playlistID: playlistID, requested: requested,
            downloadURL: source.downloadURL, sourcePage: source.itemURL,
            licensePage: source.licenseURL, provider: source.sourceName)
        ticket.startedAt = .now
        ticket.alternativeSources = AudioSourceFinder.uniqueDownloadSources(
            alternatives.filter { $0.downloadURL != source.downloadURL &&
                Self.allowedDownloadURL($0.downloadURL) })
        tickets[ticket.id] = ticket
        persist()
        revision += 1
        let task = session.downloadTask(
            with: downloadRequest(for: source.downloadURL, playlistID: playlistID))
        task.taskDescription = ticket.id.uuidString
        task.resume()
        updatePending()
        return true
    }

    func ticketsForPlaylist(_ playlistID: UUID? = nil) -> [BackgroundAudioTicket] {
        tickets.values.filter {
            (playlistID == nil || $0.playlistID == playlistID) &&
            $0.failureReason != "Replaced with a cellular-authorized transfer" &&
            $0.failureReason != "Replaced by automatic retry" &&
            $0.failureReason != "Replaced by alternate verified source" &&
            $0.failureReason != "Recovered missing background task"
        }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    func isQueued(_ wish: PlaylistWish, for playlistID: UUID) -> Bool {
        tickets.values.contains {
            $0.status == .queued && $0.playlistID == playlistID &&
            MusicMatching.sameRequestedRecording($0.requested, wish)
        }
    }

    func retry(_ id: UUID) {
        guard let previous = tickets[id],
              previous.status == .failed || previous.status == .cancelled,
              Self.allowedDownloadURL(previous.downloadURL),
              !isQueued(previous.requested, for: previous.playlistID) else { return }
        // Use a new identifier. A late didComplete callback from the old
        // cancelled task must never change the state of the new transfer.
        let newID = UUID()
        var ticket = BackgroundAudioTicket(
            id: newID, playlistID: previous.playlistID, requested: previous.requested,
            downloadURL: previous.downloadURL, sourcePage: previous.sourcePage,
            licensePage: previous.licensePage, provider: previous.provider)
        ticket.startedAt = .now
        ticket.alternativeSources = previous.alternativeSources
        tickets[newID] = ticket
        persist()
        let task = session.downloadTask(
            with: downloadRequest(for: ticket.downloadURL, playlistID: ticket.playlistID))
        task.taskDescription = newID.uuidString
        task.resume()
        updatePending()
    }

    func clearFinishedHistory() {
        let removed = tickets.values.filter { $0.status != .queued }
        for item in removed {
            try? fm.removeItem(at: Self.stagingURL(item.id))
        }
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

    /// When the user refreshes a Spotify playlist, stop background transfers
    /// for tracks removed from that playlist. Do not delete library recordings
    /// or cancel tasks belonging to another playlist.
    func cancelRemovedTracks(for playlistID: UUID, keepingIDs: Set<UUID>) {
        let removed = tickets.values.filter {
            $0.playlistID == playlistID && $0.status == .queued &&
            !keepingIDs.contains($0.requested.id)
        }.map(\.id)
        for id in removed { cancelTransfer(id) }
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

    /// Reconcile queue tickets against the authoritative on-device library.
    /// A different playlist, a previously completed transfer or a manual
    /// import can fulfill the same requested song while this download waits.
    /// Finish those tickets without re-downloading an already stored track.
    private func reconcileAlreadyStoredDownloads(excluding excluded: UUID? = nil) {
        guard let library else { return }
        var duplicateTaskIDs: Set<String> = []
        for ticket in tickets.values where ticket.status == .queued && ticket.id != excluded {
            guard library.hasOfflineRecording(matching: ticket.requested),
                  var current = tickets[ticket.id], current.status == .queued else { continue }
            current.status = .imported
            current.failureReason = "This recording is already saved offline"
            current.alternativeSources = nil
            current.nextRetryAt = nil
            tickets[ticket.id] = current
            duplicateTaskIDs.insert(ticket.id.uuidString)
            library.finishedBackgroundDownload(for: ticket.playlistID, succeeded: true)
            // Completed transfer may already have left a staging copy.
            try? fm.removeItem(at: Self.stagingURL(ticket.id))
        }
        guard !duplicateTaskIDs.isEmpty else { return }
        persist()
        updatePending()
        session.getAllTasks { tasks in
            for task in tasks where duplicateTaskIDs.contains(task.taskDescription ?? "") {
                task.cancel()
            }
        }
    }

    /// Recover *only* temporary network/server failures. A replacement
    /// URLSession background task is scheduled immediately with an
    /// earliestBeginDate, so iOS can perform it while the app is suspended.
    /// New task/ticket IDs also prevent stale callbacks from older attempts
    /// from mutating the live download.
    private func retryTemporaryTransfer(_ id: UUID, reason: String,
                                        connectivityInterruption: Bool = false) {
        reconcileAlreadyStoredDownloads()
        guard let previous = tickets[id], previous.status == .queued else { return }
        guard Self.allowedDownloadURL(previous.downloadURL) else {
            setFailed(id, reason: "Source URL is no longer accepted")
            return
        }
        let nextServerAttempt = (previous.automaticRetryCount ?? 0) + 1
        let nextConnectionAttempt = min((previous.connectivityRetryCount ?? 0) + 1, 16)
        let delay: TimeInterval
        if connectivityInterruption {
            // Wi-Fi loss must not consume the separate server retry budget.
            delay = BackgroundTransferRetryPolicy.connectivityDelay(
                afterFailure: nextConnectionAttempt)
        } else {
            guard let allowedDelay = BackgroundTransferRetryPolicy.delay(
                afterFailure: nextServerAttempt) else {
                setFailed(id, reason: "\(reason) (automatic retries exhausted)")
                return
            }
            delay = allowedDelay
        }

        var retired = previous
        retired.status = .cancelled
        retired.failureReason = "Replaced by automatic retry"
        tickets[id] = retired

        var replacement = BackgroundAudioTicket(
            id: UUID(), playlistID: previous.playlistID,
            requested: previous.requested, downloadURL: previous.downloadURL,
            sourcePage: previous.sourcePage, licensePage: previous.licensePage,
            provider: previous.provider)
        replacement.startedAt = previous.startedAt ?? .now
        replacement.automaticRetryCount = connectivityInterruption ?
            previous.automaticRetryCount : nextServerAttempt
        replacement.connectivityRetryCount = connectivityInterruption ?
            nextConnectionAttempt : previous.connectivityRetryCount
        replacement.nextRetryAt = Date().addingTimeInterval(delay)
        replacement.alternativeSources = previous.alternativeSources
        replacement.failureReason = reason
        tickets[replacement.id] = replacement
        persist()

        let task = session.downloadTask(
            with: downloadRequest(for: replacement.downloadURL, playlistID: replacement.playlistID))
        task.taskDescription = replacement.id.uuidString
        task.earliestBeginDate = replacement.nextRetryAt
        task.resume()
        updatePending()
    }

    /// After the current file fails validation or exhausts network retries,
    /// switch to another previously verified catalog result. All candidates
    /// already passed the title, artist, license and (when available) duration
    /// checks before the phone was locked.
    private func tryNextDownloadSource(after id: UUID) -> Bool {
        guard let old = tickets[id], old.status == .queued,
              let remaining = old.alternativeSources else { return false }
        let candidates = remaining.filter { Self.allowedDownloadURL($0.downloadURL) }
        guard let next = AudioSourceFinder.nextAlternative(to: old.downloadURL,
                                                            from: candidates) else { return false }

        var superseded = old
        superseded.status = .cancelled
        superseded.failureReason = "Replaced by alternate verified source"
        tickets[id] = superseded

        var replacement = BackgroundAudioTicket(
            id: UUID(), playlistID: old.playlistID,
            requested: old.requested, downloadURL: next.source.downloadURL,
            sourcePage: next.source.itemURL, licensePage: next.source.licenseURL,
            provider: next.source.sourceName)
        replacement.startedAt = old.startedAt ?? .now
        replacement.alternativeSources = next.remaining
        tickets[replacement.id] = replacement
        persist()

        let task = session.downloadTask(
            with: downloadRequest(for: replacement.downloadURL, playlistID: replacement.playlistID))
        task.taskDescription = replacement.id.uuidString
        task.resume()
        updatePending()
        return true
    }

    private func setFailed(_ id: UUID, reason: String = "Download or validation failed") {
        reconcileAlreadyStoredDownloads()
        guard var ticket = tickets[id], ticket.status == .queued else { return }
        if tryNextDownloadSource(after: id) { return }
        ticket.status = .failed
        ticket.failureReason = reason
        tickets[id] = ticket
        persist()
        library?.finishedBackgroundDownload(for: ticket.playlistID, succeeded: false)
        updatePending()
    }

    private func updateProgress(_ id: UUID, received: Int64, total: Int64) {
        guard var ticket = tickets[id], ticket.status == .queued else { return }
        let knownTotal = total > 0 ? total : nil
        guard BackgroundTransferProgressPolicy.shouldPublish(
            received: received, total: total, previousReceived: ticket.bytesReceived
        ) || (knownTotal != nil && ticket.totalBytes != knownTotal) else { return }
        ticket.bytesReceived = received
        ticket.totalBytes = knownTotal
        tickets[id] = ticket
        revision += 1
        // Byte-level progress is intentionally not flushed to disk for each callback;
        // the OS restores actual task progress after process reattachment.
    }

    private let stagedRecoveryCoordinator = StagedAudioRecoveryCoordinator()

    /// A URLSession callback, foreground attach and didFinishEvents may all
    /// request staging concurrently. Await the whole serialized import queue
    /// before acknowledging system background events; never report completion
    /// while a separately-started import is still awaiting file validation.
    private func recoverStagedDownloads() async {
        await stagedRecoveryCoordinator.run {
            await self.importStagedDownloadsPass()
        }
    }

    private func importStagedDownloadsPass() async {
        // A queued transfer might have become redundant because a separate
        // playlist or manual import already saved the exact recording.
        reconcileAlreadyStoredDownloads()
        // A transfer can be cancelled or cleared while its delegate callback is
        // in flight. Remove files that no longer correspond to queued tickets.
        for ticket in tickets.values where ticket.status != .queued {
            let leftover = Self.stagingURL(ticket.id)
            if fm.fileExists(atPath: leftover.path) { try? fm.removeItem(at: leftover) }
        }
        guard let library else { return }
        let candidates = tickets.values.filter {
            $0.status == .queued && fm.fileExists(atPath: Self.stagingURL($0.id).path)
        }
        for ticket in candidates {
            // The candidate snapshot can become stale across earlier awaits.
            // Never import a ticket that was cancelled or already satisfied.
            guard tickets[ticket.id]?.status == .queued,
                  processing.insert(ticket.id).inserted else { continue }
            defer { processing.remove(ticket.id) }
            let stagedURL = Self.stagingURL(ticket.id)
            do {
                let attribution = AudioSourceAttribution(
                    pageURL: ticket.sourcePage.absoluteString,
                    licenseURL: ticket.licensePage.absoluteString,
                    providerName: ticket.provider)
                let imported = try await library.importStagedAudio(
                    from: stagedURL, matching: ticket.requested, attribution: attribution)
                if imported {
                    if var current = tickets[ticket.id], current.status == .queued {
                        current.status = .imported
                        // An earlier network retry is not an error once the
                        // recording has actually been decoded and imported.
                        // Leaving the transient reason here wrongly excludes
                        // successful retry downloads from provider scoring.
                        current.failureReason = nil
                        current.nextRetryAt = nil
                        current.alternativeSources = nil
                        tickets[ticket.id] = current
                        persist()
                        revision += 1
                        library.finishedBackgroundDownload(for: ticket.playlistID, succeeded: true)
                        // One verified import can satisfy multiple playlists.
                        // Cancel redundant tasks and stop future fallback
                        // downloads for this recording immediately.
                        reconcileAlreadyStoredDownloads(excluding: ticket.id)
                    }
                } else {
                    setFailed(ticket.id, reason: "Audio already stored or could not be imported")
                }
                try? fm.removeItem(at: stagedURL)
            } catch {
                // Leave failed transfers retryable via the playlist's retry button.
                setFailed(ticket.id, reason: error.localizedDescription)
                try? fm.removeItem(at: stagedURL)
            }
        }
        updatePending()
    }

    private struct BackgroundTaskInventory {
        let ids: Set<UUID>
        let hasUnknownTasks: Bool
    }

    private func backgroundTaskInventory() async -> BackgroundTaskInventory {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let ids = Set(tasks.compactMap { task -> UUID? in
                    guard let description = task.taskDescription else { return nil }
                    return UUID(uuidString: description)
                })
                continuation.resume(returning: BackgroundTaskInventory(
                    ids: ids, hasUnknownTasks: ids.count != tasks.count))
            }
        }
    }

    /// Reconnect a persisted ticket that iOS no longer knows about. A single
    /// getAllTasks query is NOT sufficient: a completed task can vanish before
    /// its file-move callback finishes. Require an aged ticket and two scans,
    /// and re-check the current ticket and staging/import status after the wait.
    private func recoverAbandonedBackgroundTasks() async {
        guard !reconcilingOrphans else { return }
        reconcilingOrphans = true
        defer { reconcilingOrphans = false }

        let first = await backgroundTaskInventory()
        let firstCheck = Date()
        let possible = tickets.values.filter { ticket in
            ticket.status == .queued &&
            BackgroundTransferRecoveryPolicy.shouldRecover(
                startedAt: ticket.startedAt, checkedAt: firstCheck,
                firstScanHasTask: first.ids.contains(ticket.id),
                secondScanHasTask: false,
                hasUnidentifiedTasks: first.hasUnknownTasks,
                hasStagedFile: fm.fileExists(atPath: Self.stagingURL(ticket.id).path),
                isImporting: processing.contains(ticket.id))
        }.map(\.id)
        guard !possible.isEmpty else { return }

        // This wait is only for already-stale tickets on foreground attach.
        // It is not a background timer or an attempt to bypass iOS scheduling.
        do {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        } catch { return }
        let second = await backgroundTaskInventory()
        guard !second.hasUnknownTasks else { return }
        var restored = false
        for id in possible {
            guard let current = tickets[id], current.status == .queued,
                  BackgroundTransferRecoveryPolicy.shouldRecover(
                      startedAt: current.startedAt, checkedAt: Date(),
                      firstScanHasTask: first.ids.contains(id),
                      secondScanHasTask: second.ids.contains(id),
                      hasUnidentifiedTasks: second.hasUnknownTasks,
                      hasStagedFile: fm.fileExists(atPath: Self.stagingURL(id).path),
                      isImporting: processing.contains(id)) else { continue }

            // A recording might already have been imported before a crash
            // prevented the transfer manifest from being finalized.
            if let library, library.hasOfflineRecording(matching: current.requested) {
                var finished = current
                finished.status = .imported
                finished.failureReason = nil
                finished.nextRetryAt = nil
                finished.alternativeSources = nil
                tickets[id] = finished
                library.finishedBackgroundDownload(for: current.playlistID, succeeded: true)
                restored = true
                continue
            }
            guard Self.allowedDownloadURL(current.downloadURL) else {
                setFailed(id, reason: "The saved download URL is no longer supported")
                continue
            }
            var replaced = current
            replaced.status = .cancelled
            replaced.failureReason = "Recovered missing background task"
            tickets[id] = replaced

            var replacement = BackgroundAudioTicket(
                id: UUID(), playlistID: current.playlistID,
                requested: current.requested, downloadURL: current.downloadURL,
                sourcePage: current.sourcePage, licensePage: current.licensePage,
                provider: current.provider)
            replacement.startedAt = .now
            replacement.automaticRetryCount = current.automaticRetryCount
            replacement.connectivityRetryCount = current.connectivityRetryCount
            replacement.nextRetryAt = current.nextRetryAt
            replacement.alternativeSources = current.alternativeSources
            tickets[replacement.id] = replacement
            persist()

            // Explicit cellular approval is session-only; after relaunch,
            // replacement requests safely return to the Wi-Fi default.
            let task = session.downloadTask(
                with: downloadRequest(for: replacement.downloadURL,
                                      playlistID: replacement.playlistID))
            task.taskDescription = replacement.id.uuidString
            task.earliestBeginDate = replacement.nextRetryAt
            task.resume()
            restored = true
        }
        if restored {
            persist()
            updatePending()
        }
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
              http.url.map({ Self.allowedDownloadURL($0) }) == true else {
            Task { @MainActor in self.setFailed(id, reason: "Invalid download response or destination") }
            return
        }
        guard (200...299).contains(http.statusCode) else {
            if BackgroundTransferRetryPolicy.isTemporaryHTTP(http.statusCode) {
                Task { @MainActor in
                    self.retryTemporaryTransfer(id, reason: "Source server returned HTTP \(http.statusCode)")
                }
            } else {
                Task { @MainActor in self.setFailed(id, reason: "Source server returned HTTP \(http.statusCode)") }
            }
            return
        }
        guard let mime = http.mimeType?.lowercased(),
              ["audio/mpeg", "audio/mp3", "application/octet-stream", "audio/x-mpeg"].contains(mime)
        else {
            Task { @MainActor in self.setFailed(id, reason: "Source returned non-audio content") }
            return
        }
        // Copy/move BEFORE returning: URLSession deletes location at delegate return.
        let destination = Self.stagingURL(id)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let bytes = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0 && bytes <= BackgroundTransferProgressPolicy.maxBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
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
        if BackgroundTransferProgressPolicy.exceedsLimit(
            received: totalBytesWritten, expected: totalBytesExpectedToWrite) {
            // Refuse oversized downloads before the entire file reaches disk.
            // A queued alternative can take over after the failure is recorded.
            downloadTask.cancel()
            Task { @MainActor in
                self.setFailed(id, reason: "Source exceeds the 100 MB download limit")
            }
            return
        }
        Task { @MainActor in
            self.updateProgress(id, received: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error, let id = UUID(uuidString: task.taskDescription ?? "") else { return }
        let systemError = error as NSError
        let shouldRetry = systemError.domain == NSURLErrorDomain &&
            BackgroundTransferRetryPolicy.isTemporaryURLFailure(systemError.code)
        let connectionLost = systemError.domain == NSURLErrorDomain &&
            BackgroundTransferRetryPolicy.isConnectivityInterruption(systemError.code)
        Task { @MainActor in
            if shouldRetry {
                self.retryTemporaryTransfer(id, reason: error.localizedDescription,
                                            connectivityInterruption: connectionLost)
            } else {
                self.setFailed(id, reason: error.localizedDescription)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in await self.finishBackgroundEvents() }
    }
}
