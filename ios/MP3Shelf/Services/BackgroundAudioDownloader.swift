import Foundation
import Combine
import UIKit
#if DEBUG
import CryptoKit
#endif

/// A persisted download ticket is independent of Spotify's OAuth session.
/// The direct audio file URL is transferred by iOS.
struct BackgroundAudioTicket: Codable, Identifiable {
    enum Status: String, Codable { case queued, imported, failed, cancelled }
    let id: UUID
    let playlistID: UUID
    let requested: PlaylistWish
    let downloadURL: URL
    let sourcePage: URL
    let licensePage: URL?
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
    // False for local storage failures, which another source cannot fix.
    var mayTryAnotherSource: Bool? = nil
}

/// URLSession's background transfer daemon survives ordinary app suspension
/// and OS-initiated process termination. Discovery still runs in foreground.
/// Staged media survives the delegate's short-lived temporary file callback.
@MainActor
final class BackgroundAudioDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var revision: Int = 0
    #if DEBUG
    private(set) var importedFixtureInput: (ticketID: UUID, bytes: Int, sha256: String)?
    #endif
    static let shared = BackgroundAudioDownloader()
    static let identifier = "com.jonnyt.mp3shelf.licensed-audio-v1"

    private let fm = FileManager.default
    private let manifestURL: URL
    private var tickets: [UUID: BackgroundAudioTicket] = [:]
    // Corrupt queue journals are recovery evidence, not an empty queue.
    private var manifestLoadError: String?
    // Exposed to Downloads so a damaged queue cannot masquerade as an empty history.
    var queueRecoveryWarning: String? {
        manifestLoadError.map { "Download recovery is paused because the saved queue cannot be read (\($0)). Existing audio and recovery files have been preserved. Do not reinstall the app; keep this data for recovery." }
    }
    private var processing: Set<UUID> = []
    private var sourceResolutionTasks: [UUID: Task<Void, Never>] = [:]
    private var conversions: [UUID: Progress] = [:]
    private var reconcilingOrphans = false
    private weak var library: MusicLibrary?
    // Explicit per-playlist consent must survive an OS kill: a replacement
    // background task created after relaunch otherwise silently reverts to
    // Wi-Fi-only even while the user is waiting on cellular.
    // Consent expires after 24 hours to avoid indefinite cellular use.
    private static let cellularConsentKey = "backgroundAudio.cellularConsent.v1"
    private static let cellularConsentLifetime: TimeInterval = 24 * 60 * 60
    private var cellularApprovedPlaylists = Set<UUID>()
    private var cellularConsentExpirations: [UUID: Date] = [:]

    private func restoreCellularConsent(now: Date = .now) {
        let stored = UserDefaults.standard.dictionary(forKey: Self.cellularConsentKey) as? [String: Date] ?? [:]
        cellularConsentExpirations = Dictionary(uniqueKeysWithValues: stored.compactMap { raw, expiry in
            guard let id = UUID(uuidString: raw), expiry > now,
                  expiry.timeIntervalSince(now) <= Self.cellularConsentLifetime else { return nil }
            return (id, expiry)
        })
        cellularApprovedPlaylists = Set(cellularConsentExpirations.keys)
        persistCellularConsent()
    }

    private func persistCellularConsent() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues:
            cellularConsentExpirations.map { ($0.key.uuidString, $0.value) }),
            forKey: Self.cellularConsentKey)
    }

    private func cellularAllowed(for playlistID: UUID, now: Date = .now) -> Bool {
        guard let expiry = cellularConsentExpirations[playlistID], expiry > now else {
            if cellularConsentExpirations.removeValue(forKey: playlistID) != nil {
                cellularApprovedPlaylists.remove(playlistID)
                persistCellularConsent()
            }
            return false
        }
        return true
    }
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
        let cellular = cellularAllowed(for: playlistID)
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
        cellularConsentExpirations[playlistID] = Date().addingTimeInterval(Self.cellularConsentLifetime)
        persistCellularConsent()
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for task in tasks {
                    guard let raw = task.taskDescription,
                          let oldID = UUID(uuidString: raw),
                          let oldTicket = self.tickets[oldID],
                          oldTicket.playlistID == playlistID,
                          oldTicket.status == .queued,
                          !self.fm.fileExists(atPath: Self.stagingURL(oldID).path),
                          task.originalRequest?.allowsCellularAccess == false
                    else { continue }
                    if BackgroundTransferRetryPolicy.linkExpiresByStart(
                        oldTicket.downloadURL, earliestBeginDate: oldTicket.nextRetryAt) {
                        self.setFailed(oldID, reason: AudioDownloadDiagnostics.expiredAudioLink,
                                       earliestRecovery: oldTicket.nextRetryAt)
                        task.cancel()
                        continue
                    }
                    var replacement = BackgroundAudioTicket(
                        id: UUID(), playlistID: oldTicket.playlistID,
                        requested: oldTicket.requested, downloadURL: oldTicket.downloadURL,
                        sourcePage: oldTicket.sourcePage, licensePage: oldTicket.licensePage,
                        provider: oldTicket.provider)
                    replacement.startedAt = .now
                    replacement.automaticRetryCount = oldTicket.automaticRetryCount
                    replacement.connectivityRetryCount = oldTicket.connectivityRetryCount
                    replacement.nextRetryAt = oldTicket.nextRetryAt
                    replacement.alternativeSources = oldTicket.alternativeSources
                    do {
                        try self.startTransfer(replacement, replacing: (oldID, "Replaced with a cellular-authorized transfer"))
                        task.cancel()
                    } catch {
                        self.noteQueueWriteFailure(error, for: oldID)
                    }
                }
            }
        }
    }

    override private init() {
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MP3Shelf", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        manifestURL = root.appendingPathComponent("background-audio-tickets.json")
        if fm.fileExists(atPath: manifestURL.path) {
            do {
                let data = try Data(contentsOf: manifestURL)
                let saved = try JSONDecoder().decode([BackgroundAudioTicket].self, from: data)
                guard Set(saved.map(\.id)).count == saved.count else {
                    throw NSError(domain: "MP3Shelf.BackgroundManifest", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Duplicate ticket identifiers in saved download queue"])
                }
                tickets = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
            } catch {
                manifestLoadError = error.localizedDescription
            }
        }
        super.init()
        restoreCellularConsent()
    }

    /// iOS calls this even when the user does not open a SwiftUI scene.
    func activate() {
        _ = session
    }

    func attach(to library: MusicLibrary) {
        self.library = library
        activate()
        cancelObsoleteTransfers(in: library)
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
                failed: ticket.status == .failed && ticket.mayTryAnotherSource != false,
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
                 alternatives: [AudioCatalogMatch] = [], replacingRetry previousID: UUID? = nil) throws -> Bool {
        // Discovery may have started before a manual import or another
        // playlist's transfer finished. Reconcile those completed recordings
        // before checking capacity, then refuse to enqueue a second copy.
        // A search result is not proof of a saved recording: only the
        // authoritative offline library can satisfy this request.
        reconcileAlreadyStoredDownloads()
        if library?.hasOfflineRecording(matching: requested) == true { return false }
        // Resolution suspends callers, so an earlier capacity check can be
        // stale. This MainActor check and ticket insertion have no await gap.
        guard BackgroundDownloadBackpressure.mayEnqueue(outstandingTransfers: pendingCount()),
              Self.allowedDownloadURL(source.downloadURL) else { return false }
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
        try startTransfer(ticket, replacing: previousID.map { ($0, "Replaced by manual retry") })
        return true
    }

    func ticketsForPlaylist(_ playlistID: UUID? = nil) -> [BackgroundAudioTicket] {
        tickets.values.filter {
            (playlistID == nil || $0.playlistID == playlistID) &&
            $0.failureReason != "Replaced with a cellular-authorized transfer" &&
            $0.failureReason != "Replaced by automatic retry" &&
            $0.failureReason != "Replaced by manual retry" &&
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

    func failedSourceTickets(for wish: PlaylistWish, playlistID: UUID) -> [BackgroundAudioTicket] {
        tickets.values.filter { ticket in
            guard ticket.playlistID == playlistID,
                  MusicMatching.sameRequestedRecording(ticket.requested, wish) else { return false }
            // Hidden predecessor rows still identify a failed URL when the
            // downloader already tried another catalog source for this wish.
            if ticket.status == .cancelled,
               ticket.failureReason == "Replaced by alternate verified source" { return true }
            return ticket.status == .failed && AudioDownloadDiagnostics.maySearchForAnotherSource(
                reason: ticket.failureReason, recordedAdvice: ticket.mayTryAnotherSource)
        }.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    func canRetry(_ id: UUID) -> Bool {
        guard sourceResolutionTasks[id] == nil, let ticket = tickets[id], let library,
              ticket.status == .failed || ticket.status == .cancelled,
              library.hasCurrentSourceRequest(ticket.requested, for: ticket.playlistID) else { return false }
        guard !sourceResolutionTasks.keys.contains(where: { key in
            guard let resolving = tickets[key] else { return false }
            return resolving.playlistID == ticket.playlistID &&
                MusicMatching.sameRequestedRecording(resolving.requested, ticket.requested)
        }) else { return false }
        if library.hasOfflineRecording(matching: ticket.requested) { return true }
        return Self.allowedDownloadURL(ticket.downloadURL) &&
            !isQueued(ticket.requested, for: ticket.playlistID) &&
            BackgroundDownloadBackpressure.mayEnqueue(outstandingTransfers: pendingCount())
    }

    var canRetryFailedDownloads: Bool {
        tickets.values.contains { $0.status == .failed && canRetry($0.id) }
    }

    func retryFailedDownloads() {
        // User-cancelled tickets require individual consent to restart.
        let failed = ticketsForPlaylist().filter { $0.status == .failed }.map(\.id)
        for id in failed where canRetry(id) { retry(id) }
    }

    func retry(_ id: UUID) {
        guard canRetry(id), let previous = tickets[id],
              previous.status == .failed || previous.status == .cancelled else { return }
        if let library, library.hasOfflineRecording(matching: previous.requested) {
            var fulfilled = previous
            fulfilled.status = .imported
            fulfilled.failureReason = "This recording is already saved offline"
            fulfilled.nextRetryAt = nil
            fulfilled.alternativeSources = nil
            // A retry may discover that another import already fulfilled this
            // recording. Commit the terminal ticket before acknowledging it to
            // the library; otherwise a failed manifest write resurrects the
            // obsolete failed ticket on the next launch.
            var updated = tickets
            updated[id] = fulfilled
            do {
                try writeManifest(Array(updated.values), to: manifestURL)
            } catch {
                noteQueueWriteFailure(error, for: id)
                return
            }
            tickets = updated
            library.finishedBackgroundDownload(for: previous.playlistID, succeeded: true)
            reconcileAlreadyStoredDownloads()
            updatePending()
            return
        }
        guard Self.allowedDownloadURL(previous.downloadURL),
              !isQueued(previous.requested, for: previous.playlistID) else { return }
        if let videoID = AudioSourceLinks.youtubeVideoID(previous.sourcePage) {
            retryResolvedRecording(previous, videoID: videoID)
            return
        }
        // Use a new identifier. A late didComplete callback from the old
        // cancelled task must never change the state of the new transfer.
        var ticket = BackgroundAudioTicket(
            id: UUID(), playlistID: previous.playlistID, requested: previous.requested,
            downloadURL: previous.downloadURL, sourcePage: previous.sourcePage,
            licensePage: previous.licensePage, provider: previous.provider)
        ticket.startedAt = .now
        ticket.alternativeSources = previous.alternativeSources
        do {
            try startTransfer(ticket, replacing: (id, "Replaced by manual retry"))
        } catch {
            noteQueueWriteFailure(error, for: id)
        }
    }

    func clearFinishedHistory() {
        let removed = tickets.values.filter { $0.status != .queued }
        guard !removed.isEmpty else { return }

        // A failed manifest write must not resurrect cleared history on the
        // next launch. Keep live state and staged files intact until the
        // replacement queue is durably recorded.
        let remaining = tickets.filter { $0.value.status == .queued }
        do {
            try writeManifest(Array(remaining.values), to: manifestURL)
        } catch {
            // Keep history visible so the user can retry clearing it when
            // storage becomes writable; do not discard recovery evidence.
            revision += 1
            return
        }
        tickets = remaining
        for item in removed {
            sourceResolutionTasks[item.id]?.cancel()
            sourceResolutionTasks.removeValue(forKey: item.id)
            // A conversion may still be reading its staged file. Cancel it,
            // but let the conversion's cleanup own removal of that file.
            let conversion = conversions[item.id]
            conversion?.cancel()
            // Conversion ownership can precede insertion into processing.
            // Retain staging until its completion handler performs cleanup.
            if !processing.contains(item.id) && conversion == nil {
                try? fm.removeItem(at: Self.stagingURL(item.id))
            }
        }
        updatePending()
    }

    func cancelTransfer(_ id: UUID, reason: String = "Cancelled") {
        guard var ticket = tickets[id], ticket.status == .queued else { return }
        ticket.status = .cancelled
        ticket.failureReason = reason

        // Commit the terminal state before touching a running conversion,
        // staged media or the OS-owned task. If storage is unavailable, keep
        // the existing transfer recoverable after process termination.
        var updated = tickets
        updated[id] = ticket
        do {
            try writeManifest(Array(updated.values), to: manifestURL)
        } catch {
            noteQueueWriteFailure(error, for: id)
            return
        }
        tickets = updated
        conversions[id]?.cancel()
        // An active import owns its staged file until its cancellation
        // check finishes; never remove the file underneath conversion.
        // A conversion can own the staging file before its ticket enters
        // processing. Its completion handler is responsible for cleanup;
        // deleting the input here races the decoder and can corrupt imports.
        if !processing.contains(id) && conversions[id] == nil {
            try? fm.removeItem(at: Self.stagingURL(id))
        }
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
            + sourceResolutionTasks.keys.filter { playlistID == nil || tickets[$0]?.playlistID == playlistID }.count
    }

    func isResolvingSource(_ id: UUID) -> Bool { sourceResolutionTasks[id] != nil }

    private func retryResolvedRecording(_ previous: BackgroundAudioTicket, videoID: String) {
        guard let library else { return }
        guard library.canResolveRecordingSources(for: previous.playlistID) else {
            var current = previous
            current.failureReason = NativeAudioEngine.Failure.networkUnavailable.localizedDescription
            tickets[previous.id] = current
            persist()
            revision += 1
            return
        }
        sourceResolutionTasks[previous.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.sourceResolutionTasks.removeValue(forKey: previous.id)
                self.revision += 1
                self.updatePending()
            }
            do {
                let wish = previous.requested
                let candidate = RecordingCandidate(id: videoID, title: wish.title,
                    uploader: wish.artistNames?.first ?? wish.artist, durationSeconds: wish.durationSeconds)
                let sources = try await NativeAudioEngine.shared.resolve(candidate, for: wish,
                    allowsCellular: library.cellularApproved(for: previous.playlistID), userSelected: true)
                try Task.checkCancellation()
                guard let source = sources.first,
                      let current = self.tickets[previous.id], current.status == previous.status,
                      library.canResolveRecordingSources(for: previous.playlistID),
                      library.hasCurrentSourceRequest(wish, for: previous.playlistID) else { return }
                self.sourceResolutionTasks.removeValue(forKey: previous.id)
                try self.enqueue(source: source, requested: wish, playlistID: previous.playlistID,
                                 alternatives: Array(sources.dropFirst()), replacingRetry: previous.id)
            } catch let error as NSError where error.domain == BackgroundTicketManifestPolicy.writeFailureDomain {
                self.noteQueueWriteFailure(error, for: previous.id)
            } catch {
                guard !Task.isCancelled, var current = self.tickets[previous.id], current.status == previous.status else { return }
                current.failureReason = "Source refresh failed: \(error.localizedDescription)"
                self.tickets[previous.id] = current
                self.persist()
            }
        }
        revision += 1
        updatePending()
    }

    func isFinalizing(_ id: UUID) -> Bool {
        processing.contains(id)
    }

    func hasStagedAudio(_ id: UUID) -> Bool {
        tickets[id]?.status == .queued && fm.fileExists(atPath: Self.stagingURL(id).path)
    }

    func finishSavingStagedAudio() {
        Task { await recoverStagedDownloads() }
    }

    func stopTransfers(for playlistID: UUID) {
        for (id, task) in sourceResolutionTasks where tickets[id]?.playlistID == playlistID { task.cancel() }
        let ids = tickets.values.filter { $0.playlistID == playlistID && $0.status == .queued }.map(\.id)
        for id in ids { cancelTransfer(id) }
    }

    private static let obsoleteRequestReason = "The song changed or was removed from the playlist."

    /// Compare each ticket with its loaded playlist, even after a relaunch.
    /// Leave tickets pending if their playlist data is unavailable.
    func cancelObsoleteTransfers(in library: MusicLibrary, for playlistID: UUID? = nil) {
        let loadedIDs = Set(library.playlists.map(\.id))
        let obsolete = tickets.values.filter { ticket in
            (playlistID == nil || ticket.playlistID == playlistID) &&
                loadedIDs.contains(ticket.playlistID) &&
                (ticket.status == .queued || sourceResolutionTasks[ticket.id] != nil) &&
                !library.hasCurrentSourceRequest(ticket.requested, for: ticket.playlistID)
        }
        for ticket in obsolete {
            sourceResolutionTasks[ticket.id]?.cancel()
            cancelTransfer(ticket.id, reason: Self.obsoleteRequestReason)
        }
    }

    func setBackgroundEventsCompletion(_ completion: @escaping () -> Void) {
        backgroundEventsCompletion = completion
        activate()
    }

    private func startTransfer(_ ticket: BackgroundAudioTicket,
                               replacing previous: (id: UUID, reason: String)? = nil) throws {
        var updated = tickets
        if let previous, var retired = updated[previous.id] {
            retired.status = .cancelled
            retired.failureReason = previous.reason
            updated[retired.id] = retired
        }
        updated[ticket.id] = ticket
        // Save both ticket changes together before the daemon can transfer
        // bytes. A failed save leaves the previous task and manifest intact.
        try writeManifest(Array(updated.values), to: manifestURL)
        tickets = updated

        let task = session.downloadTask(
            with: downloadRequest(for: ticket.downloadURL, playlistID: ticket.playlistID))
        task.taskDescription = ticket.id.uuidString
        task.earliestBeginDate = ticket.nextRetryAt
        task.resume()
        // The replacement is durable and scheduled. Retire the predecessor's
        // daemon task as well: changing its manifest status alone does not stop
        // URLSession from transferring the same bytes in parallel. Late
        // callbacks remain harmless because each attempt has a distinct ID.
        if let previous {
            let retiredID = previous.id.uuidString
            session.getAllTasks { tasks in
                for oldTask in tasks where oldTask.taskDescription == retiredID {
                    oldTask.cancel()
                }
            }
            // An active staged import owns its file until its cancellation
            // check completes; never remove that file underneath conversion.
            // A conversion can claim staging before it enters processing.
            // Its completion handler owns cleanup after cooperative cancellation.
            conversions[previous.id]?.cancel()
            if !processing.contains(previous.id) && conversions[previous.id] == nil {
                try? fm.removeItem(at: Self.stagingURL(previous.id))
            }
        }
        updatePending()
    }

    private func noteQueueWriteFailure(_ error: Error, for id: UUID) {
        guard var ticket = tickets[id] else { return }
        ticket.failureReason = error.localizedDescription
        ticket.mayTryAnotherSource = false
        tickets[id] = ticket
        revision += 1
    }

    private func writeManifest(_ values: [BackgroundAudioTicket]) throws {
        if let reason = manifestLoadError {
            throw NSError(domain: BackgroundTicketManifestPolicy.writeFailureDomain, code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Download queue journal cannot be overwritten: " + reason])
        }
        try BackgroundTicketManifestPolicy.write(values, to: manifestURL)
    }

    private func persist() {
        do {
            try writeManifest(Array(tickets.values))
        } catch {
            // Retain original queue and staged bytes for recovery.
            revision += 1
        }
    }

    private func updatePending() {
        library?.pendingBackgroundDownloads = pendingCount()
        revision += 1
        // A queued download has imported, failed, or been cancelled. If a
        // transfer slot opened, let the persisted discovery cursor advance.
        // Discovery must not enqueue new tickets into an unreadable journal.
        // Otherwise the UI appears to search forever while every write fails.
        if manifestLoadError == nil { library?.resumePendingDiscovery() }
    }

    /// Reconcile queue tickets against the authoritative on-device library.
    /// A different playlist, a previously completed transfer or a manual
    /// import can fulfill the same requested song while this download waits.
    /// Finish those tickets without re-downloading an already stored track.
    private func reconcileAlreadyStoredDownloads(excluding excluded: UUID? = nil) {
        guard let library else { return }
        // Build the entire transition before touching live state. If the
        // manifest cannot be saved, keep the daemon tasks alive so a relaunch
        // can still recover them instead of losing the only queue record.
        var updated = tickets
        var fulfilled: [BackgroundAudioTicket] = []
        for ticket in tickets.values where ticket.status == .queued && ticket.id != excluded {
            guard library.hasOfflineRecording(matching: ticket.requested),
                  var current = updated[ticket.id], current.status == .queued else { continue }
            current.status = .imported
            current.failureReason = "This recording is already saved offline"
            current.alternativeSources = nil
            current.nextRetryAt = nil
            updated[ticket.id] = current
            fulfilled.append(ticket)
        }
        guard !fulfilled.isEmpty else { return }
        do {
            try writeManifest(Array(updated.values), to: manifestURL)
        } catch {
            // Never cancel a background task when its terminal state was not
            // durably recorded. A later reconciliation can safely retry.
            return
        }
        tickets = updated
        let duplicateTaskIDs = Set(fulfilled.map { $0.id.uuidString })
        for ticket in fulfilled {
            conversions[ticket.id]?.cancel()
            library.finishedBackgroundDownload(for: ticket.playlistID, succeeded: true)
            // Cancellation is cooperative. An active decoder/converter still
            // owns this file until its next cancellation check completes.
            if !processing.contains(ticket.id) && conversions[ticket.id] == nil {
                try? fm.removeItem(at: Self.stagingURL(ticket.id))
            }
        }
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
        let retryAt = Date().addingTimeInterval(delay)
        if BackgroundTransferRetryPolicy.linkExpiresByStart(previous.downloadURL, earliestBeginDate: retryAt) {
            setFailed(id, reason: AudioDownloadDiagnostics.expiredAudioLink, earliestRecovery: retryAt)
            return
        }

        var replacement = BackgroundAudioTicket(
            id: UUID(), playlistID: previous.playlistID,
            requested: previous.requested, downloadURL: previous.downloadURL,
            sourcePage: previous.sourcePage, licensePage: previous.licensePage,
            provider: previous.provider)
        // Orphan recovery ages the *current daemon task*, not the original
        // playlist request. An old startedAt could immediately classify a
        // newly scheduled delayed retry as abandoned after app reattachment.
        replacement.startedAt = .now
        replacement.automaticRetryCount = connectivityInterruption ?
            previous.automaticRetryCount : nextServerAttempt
        replacement.connectivityRetryCount = connectivityInterruption ?
            nextConnectionAttempt : previous.connectivityRetryCount
        replacement.nextRetryAt = retryAt
        replacement.alternativeSources = previous.alternativeSources
        replacement.failureReason = reason
        do {
            try startTransfer(replacement, replacing: (id, "Replaced by automatic retry"))
        } catch {
            setFailed(id, reason: error.localizedDescription, allowAlternative: false)
        }
    }

    /// After the current file fails validation or exhausts network retries,
    /// switch to another previously verified catalog result. All candidates
    /// already passed the title, artist, license and (when available) duration
    /// checks before the phone was locked.
    private func startAlternateTransfer(after id: UUID, earliestBeginDate: Date?) throws -> Bool {
        guard let old = tickets[id], old.status == .queued,
              let remaining = old.alternativeSources else { return false }
        let candidates = remaining.filter { Self.allowedDownloadURL($0.downloadURL) }
        let now = Date()
        let retryAt = earliestBeginDate.flatMap { $0 > now ? $0 : nil }
        guard let next = AudioSourceFinder.nextAlternative(to: old.downloadURL,
                                                            from: candidates, at: retryAt ?? now) else { return false }

        var replacement = BackgroundAudioTicket(
            id: UUID(), playlistID: old.playlistID,
            requested: old.requested, downloadURL: next.source.downloadURL,
            sourcePage: next.source.itemURL, licensePage: next.source.licenseURL,
            provider: next.source.sourceName)
        // An alternate is a fresh daemon task even when the request is old.
        // Preserve nextRetryAt separately without inheriting orphan age.
        replacement.startedAt = .now
        replacement.nextRetryAt = retryAt
        replacement.alternativeSources = next.remaining
        try startTransfer(replacement, replacing: (id, "Replaced by alternate verified source"))
        return true
    }

    @discardableResult
    private func setFailed(_ id: UUID, reason: String = "Download or validation failed",
                           allowAlternative: Bool = true, earliestRecovery: Date? = nil) -> Bool {
        reconcileAlreadyStoredDownloads()
        guard var ticket = tickets[id], ticket.status == .queued else { return false }
        var failure = reason
        var canTryAnotherSource = allowAlternative
        if allowAlternative {
            do {
                if try startAlternateTransfer(after: id, earliestBeginDate: earliestRecovery) { return true }
            } catch {
                failure = error.localizedDescription
                canTryAnotherSource = false
            }
        }
        ticket.status = .failed
        ticket.failureReason = failure
        ticket.mayTryAnotherSource = canTryAnotherSource
        // A terminal failure must survive relaunch before notifying the
        // library or scheduling another source search. Otherwise a failed
        // manifest write can strand a phantom queued ticket after restart.
        // Keep the original ticket in memory and on disk if persistence fails.
        var updated = tickets
        updated[id] = ticket
        do {
            try writeManifest(Array(updated.values), to: manifestURL)
        } catch {
            noteQueueWriteFailure(error, for: id)
            return false
        }
        tickets = updated
        library?.finishedBackgroundDownload(for: ticket.playlistID, succeeded: false)
        if canTryAnotherSource { library?.recoverRecordingSource(after: ticket, notBefore: earliestRecovery) }
        updatePending()
        return true
    }

    private func updateProgress(_ id: UUID, received: Int64, total: Int64) {
        guard var ticket = tickets[id], ticket.status == .queued else { return }
        let knownTotal = total > 0 ? total : nil
        guard BackgroundTransferProgressPolicy.shouldPublish(
            received: received, total: total, previousReceived: ticket.bytesReceived
        ) || (knownTotal != nil && ticket.totalBytes != knownTotal) else { return }
        // Actual bytes prove the scheduled retry has begun. Persist this
        // transition once; subsequent byte updates remain coalesced in memory.
        let resumedRetry = received > 0 && ticket.nextRetryAt != nil
        if resumedRetry {
            ticket.nextRetryAt = nil
            ticket.failureReason = nil
        }
        ticket.bytesReceived = received
        ticket.totalBytes = knownTotal
        if resumedRetry {
            // Clearing a scheduled retry changes recovery semantics after a
            // process restart. Commit that transition before publishing it:
            // a failed manifest write must not silently discard retry state.
            var updated = tickets
            updated[id] = ticket
            do {
                try writeManifest(Array(updated.values), to: manifestURL)
            } catch {
                noteQueueWriteFailure(error, for: id)
                return
            }
            tickets = updated
        } else {
            // Byte-level progress is ephemeral and reconstructed from the OS
            // task on reattachment; avoid a disk write per progress callback.
            tickets[id] = ticket
        }
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
        // The persisted journal is the only mapping between daemon task IDs
        // and user-owned recordings. If it is unreadable, leave staged bytes
        // untouched for recovery instead of treating every task as unknown.
        guard manifestLoadError == nil else { return }
        // A queued transfer might have become redundant because a separate
        // playlist or manual import already saved the exact recording.
        reconcileAlreadyStoredDownloads()
        // A transfer can be cancelled or cleared while its delegate callback is
        // in flight. Remove files that no longer correspond to queued tickets.
        for ticket in tickets.values where ticket.status != .queued {
            // A terminal ticket may still own a live conversion. Cancelling
            // Progress is cooperative: the decoder can continue reading its
            // staged input until its completion handler exits. The conversion
            // path, not this sweep, must remove that input after it releases it.
            guard !processing.contains(ticket.id), conversions[ticket.id] == nil else { continue }
            let leftover = Self.stagingURL(ticket.id)
            if fm.fileExists(atPath: leftover.path) { try? fm.removeItem(at: leftover) }
        }
        guard let library else { return }
        let candidates = tickets.values.filter {
            $0.status == .queued && fm.fileExists(atPath: Self.stagingURL($0.id).path)
        }
        for ticket in candidates {
            if Task.isCancelled { break }
            // The candidate snapshot can become stale across earlier awaits.
            // Never import a ticket that was cancelled or already satisfied.
            guard tickets[ticket.id]?.status == .queued else { continue }
            guard library.hasCurrentSourceRequest(ticket.requested, for: ticket.playlistID) else {
                if library.playlists.contains(where: { $0.id == ticket.playlistID }) {
                    cancelTransfer(ticket.id, reason: Self.obsoleteRequestReason)
                }
                continue
            }
            guard processing.insert(ticket.id).inserted else { continue }
            let conversion = Progress()
            conversions[ticket.id] = conversion
            revision += 1
            defer {
                processing.remove(ticket.id)
                conversions.removeValue(forKey: ticket.id)
                revision += 1
            }
            let stagedURL = Self.stagingURL(ticket.id)
            do {
                #if DEBUG
                var fixtureInput: (ticketID: UUID, bytes: Int, sha256: String)?
                if let fixtureURL = DownloadPathProof.fixtureDownloadURL, ticket.downloadURL == fixtureURL {
                    let data = try Data(contentsOf: stagedURL, options: .mappedIfSafe)
                    guard (1...(1024 * 1024)).contains(data.count) else { throw CocoaError(.fileReadCorruptFile) }
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    fixtureInput = (ticket.id, data.count, digest)
                }
                #endif
                let attribution = AudioSourceAttribution(
                    pageURL: ticket.sourcePage.absoluteString,
                    licenseURL: ticket.licensePage?.absoluteString ?? "",
                    providerName: ticket.provider)
                let imported = try await library.importStagedAudio(
                    from: stagedURL, matching: ticket.requested, attribution: attribution, conversionProgress: conversion)
                if imported {
                    if var current = tickets[ticket.id], current.status == .queued {
                        #if DEBUG
                        if let fixtureInput { importedFixtureInput = fixtureInput }
                        #endif
                        current.status = .imported
                        // An earlier network retry is not an error once the
                        // recording has actually been decoded and imported.
                        // Leaving the transient reason here wrongly excludes
                        // successful retry downloads from provider scoring.
                        current.failureReason = nil
                        current.nextRetryAt = nil
                        current.alternativeSources = nil
                        // Import may have succeeded even when the queue manifest
                        // cannot be written (for example, during low storage).
                        // Keep the queued ticket and staged file until the
                        // completed transition is durable. On the next recovery
                        // pass, offline-recording reconciliation can finish it
                        // without downloading the recording a second time.
                        var updated = tickets
                        updated[ticket.id] = current
                        do {
                            try writeManifest(Array(updated.values), to: manifestURL)
                        } catch {
                            noteQueueWriteFailure(error, for: ticket.id)
                            continue
                        }
                        tickets = updated
                        revision += 1
                        library.finishedBackgroundDownload(for: ticket.playlistID, succeeded: true)
                        // One verified import can satisfy multiple playlists.
                        // Cancel redundant tasks and stop future fallback
                        // downloads for this recording immediately.
                        reconcileAlreadyStoredDownloads(excluding: ticket.id)
                    }
                } else {
                    // If the terminal manifest cannot be written, preserve the
                    // completed bytes for a later recovery pass instead of
                    // leaving a phantom queued ticket with no recoverable file.
                    guard setFailed(ticket.id, reason: "Audio already stored or could not be imported") else { continue }
                }
                try? fm.removeItem(at: stagedURL)
            } catch is CancellationError {
                // A system-expired import can resume from its staged audio.
                // User-cancelled/satisfied tickets no longer need that copy.
                if tickets[ticket.id]?.status != .queued {
                    try? fm.removeItem(at: stagedURL)
                }
            } catch {
                // Leave failed transfers retryable via the playlist's retry button.
                if setFailed(ticket.id, reason: AudioDownloadDiagnostics.message(for: error),
                             allowAlternative: AudioDownloadDiagnostics.shouldTryAlternateSource(for: error)) {
                    try? fm.removeItem(at: stagedURL)
                }
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
                let identified = tasks.compactMap { task -> UUID? in
                    guard let description = task.taskDescription else { return nil }
                    return UUID(uuidString: description)
                }
                // A daemon can temporarily expose two tasks for one ticket
                // during replacement. Duplicate known IDs are not unidentified
                // tasks: comparing Set.count with tasks.count would suppress
                // unrelated orphan recovery indefinitely.
                continuation.resume(returning: BackgroundTaskInventory(
                    ids: Set(identified), hasUnknownTasks: identified.count != tasks.count))
            }
        }
    }

    #if DEBUG
    func hasBackgroundTasksForProof() async -> Bool {
        let inventory = await backgroundTaskInventory()
        return !inventory.ids.isEmpty || inventory.hasUnknownTasks
    }
    #endif

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
            // URLSession may legitimately have no visible task while a delayed
            // retry is waiting for its earliestBeginDate. Do not replace that
            // persisted retry before its scheduled window even if the original
            // transfer has aged past the orphan threshold.
            ticket.status == .queued &&
            (ticket.nextRetryAt.map { $0 <= firstCheck } ?? true) &&
            BackgroundTransferRecoveryPolicy.shouldRecover(
                startedAt: ticket.startedAt, checkedAt: firstCheck,
                firstScanHasTask: first.ids.contains(ticket.id),
                secondScanHasTask: false,
                hasUnidentifiedTasks: first.hasUnknownTasks,
                hasStagedFile: fm.fileExists(atPath: Self.stagingURL(ticket.id).path),
                isImporting: processing.contains(ticket.id) || conversions[ticket.id] != nil)
        }.map(\.id)
        guard !possible.isEmpty else { return }

        // This wait is only for already-stale tickets on foreground attach.
        // It is not a background timer or an attempt to bypass iOS scheduling.
        do {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        } catch { return }
        let second = await backgroundTaskInventory()
        guard !second.hasUnknownTasks else { return }
        for id in possible {
            guard let current = tickets[id], current.status == .queued,
                  // Recheck after suspension: a new delayed retry can replace
                  // this ticket while the second daemon inventory is pending.
                  (current.nextRetryAt.map { $0 <= Date() } ?? true),
                  let library, library.hasCurrentSourceRequest(current.requested, for: current.playlistID),
                  BackgroundTransferRecoveryPolicy.shouldRecover(
                      startedAt: current.startedAt, checkedAt: Date(),
                      firstScanHasTask: first.ids.contains(id),
                      secondScanHasTask: second.ids.contains(id),
                      hasUnidentifiedTasks: second.hasUnknownTasks,
                      hasStagedFile: fm.fileExists(atPath: Self.stagingURL(id).path),
                      isImporting: processing.contains(id) || conversions[id] != nil) else { continue }

            // A recording might already have been imported before a crash
            // prevented the transfer manifest from being finalized.
            if library.hasOfflineRecording(matching: current.requested) {
                var finished = current
                finished.status = .imported
                finished.failureReason = nil
                finished.nextRetryAt = nil
                finished.alternativeSources = nil
                // The OS task has disappeared. Persist the completed ticket
                // before notifying the library, so a crash or a manifest write
                // failure cannot leave a phantom queued download on relaunch.
                var updated = tickets
                updated[id] = finished
                do {
                    try writeManifest(Array(updated.values), to: manifestURL)
                } catch {
                    // Preserve the queued ticket for a later reconciliation.
                    // Never acknowledge completion that cannot survive restart.
                    continue
                }
                tickets = updated
                library.finishedBackgroundDownload(for: current.playlistID, succeeded: true)
                updatePending()
                continue
            }
            guard Self.allowedDownloadURL(current.downloadURL) else {
                setFailed(id, reason: "The saved download URL is no longer supported")
                continue
            }
            if BackgroundTransferRetryPolicy.linkExpiresByStart(
                current.downloadURL, earliestBeginDate: current.nextRetryAt) {
                setFailed(id, reason: AudioDownloadDiagnostics.expiredAudioLink,
                          earliestRecovery: current.nextRetryAt)
                continue
            }
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
            // Explicit cellular approval is session-only; after relaunch,
            // replacement requests safely return to the Wi-Fi default.
            do {
                try startTransfer(replacement, replacing: (id, "Recovered missing background task"))
            } catch {
                setFailed(id, reason: error.localizedDescription, allowAlternative: false)
            }
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
        #if DEBUG && targetEnvironment(simulator)
        if url.scheme == "http", url == DownloadPathProof.fixtureDownloadURL { return true }
        #endif
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              !host.isEmpty, url.user == nil, url.password == nil else { return false }
        if host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") {
            return AudioSourceLinks.isResolvedAudioURL(url)
        }
        for blocked in ["spotify.com", "spotifycdn.com", "scdn.co", "jamendo.com", "youtube.com", "googlevideo.com"] {
            if host == blocked || host.hasSuffix("." + blocked) { return false }
        }
        return true
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        #if DEBUG && targetEnvironment(simulator)
        if let fixtureURL = DownloadPathProof.fixtureDownloadURL, task.originalRequest?.url == fixtureURL {
            completionHandler(nil)
            return
        }
        #endif
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
                    self.retryTemporaryTransfer(id, reason: AudioDownloadDiagnostics.http(http.statusCode))
                }
            } else {
                Task { @MainActor in self.setFailed(id, reason: AudioDownloadDiagnostics.http(http.statusCode)) }
            }
            return
        }
        // Copy/move BEFORE returning: URLSession deletes location at delegate return.
        let destination = Self.stagingURL(id)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard let bytes = (attributes[.size] as? NSNumber)?.int64Value else {
                throw CocoaError(.fileReadUnknown)
            }
            guard bytes > 0 else {
                Task { @MainActor in self.setFailed(id, reason: AudioDownloadDiagnostics.emptyResponse) }
                return
            }
            guard DownloadedAudioContentType.allows(http.mimeType) else {
                Task { @MainActor in self.setFailed(id, reason: AudioDownloadDiagnostics.contentType(http.mimeType)) }
                return
            }
            guard bytes <= BackgroundTransferProgressPolicy.maxBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
            guard DownloadedAudioRange.coversCompleteFile(status: http.statusCode,
                contentRange: http.value(forHTTPHeaderField: "Content-Range"), downloadedBytes: bytes) else {
                Task { @MainActor in self.setFailed(id, reason: DownloadedAudioRange.incompleteMessage) }
                return
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // A duplicate URLSession completion may arrive while the first
            // staged copy is being decoded. Never unlink or replace that input:
            // the conversion owns it until its completion handler finishes.
            // Retain the first complete staged file and let recovery validate it.
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: location, to: destination)
            }
            Task { @MainActor in
                // History may have been cleared after cancellation while this
                // delegate was moving the completed file. Unknown tickets must
                // never leave an orphan staged copy or import cancelled audio.
                guard self.tickets[id]?.status == .queued else {
                    // A damaged manifest hides valid ticket IDs. Keep completed
                    // bytes until the journal can be repaired; an empty in-memory
                    // queue is not evidence that the user cancelled this task.
                    if self.manifestLoadError != nil { return }
                    // A cancelled duplicate callback must not delete the
                    // first callback's file while a decoder still owns it.
                    if !self.processing.contains(id) && self.conversions[id] == nil {
                        try? self.fm.removeItem(at: destination)
                    }
                    return
                }
                await self.recoverStagedDownloads()
            }
        } catch {
            Task { @MainActor in
                self.setFailed(id, reason: AudioDownloadDiagnostics.message(for: error),
                               allowAlternative: AudioDownloadDiagnostics.shouldTryAlternateSource(for: error))
            }
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
            // A completed download is moved into staging by didFinishDownloadingTo.
            // A later error callback from a duplicate/retired daemon task must not
            // replace the queued ticket or discard a complete file awaiting import.
            // Staging is created only after HTTP, size, type and range checks.
            guard self.tickets[id]?.status == .queued else { return }
            if self.fm.fileExists(atPath: Self.stagingURL(id).path) {
                await self.recoverStagedDownloads()
                return
            }
            if shouldRetry {
                self.retryTemporaryTransfer(id, reason: AudioDownloadDiagnostics.message(for: error),
                                            connectivityInterruption: connectionLost)
            } else {
                self.setFailed(id, reason: AudioDownloadDiagnostics.message(for: error),
                               allowAlternative: AudioDownloadDiagnostics.shouldTryAlternateSource(for: error))
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in await self.finishBackgroundEvents() }
    }
}
