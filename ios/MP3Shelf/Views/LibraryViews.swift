import SwiftUI
import UniformTypeIdentifiers

// A single cancellable SwiftUI task owns each refresh. Returning to the foreground
// triggers a fresh scan even when the library's track identifiers are unchanged.
private struct OfflineCountRefreshKey: Equatable {
    // A restored recording can retain its ID but move to a new file URL.
    // Snapshot both so an older scan cannot publish an obsolete offline count.
    let recordingLocations: [RecordingLocationKey]
    let scenePhase: ScenePhase
    let manualRefresh: Int
    let isImporting: Bool
    let isPickingFiles: Bool
    let isLocalImportPending: Bool
}

// A recording ID alone is not a stable identity during restore/import:
// duplicate IDs can refer to different on-disk recordings.
private struct RecordingLocationKey: Hashable {
    let id: UUID
    let url: URL
}

// Rows need occurrence identity independent of a potentially duplicated UUID.
// Including position and URL forces SwiftUI to discard stale row-local delete
// confirmations when a search, sort or restore replaces the visible recording.
private struct RecentRetryIdentity: Equatable {
    let id: UUID
    let url: URL
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval

    init(_ track: MusicTrack, url: URL) {
        id = track.id
        self.url = url
        title = track.title
        artist = track.artist
        album = track.album
        duration = track.duration
    }

    func matches(_ track: MusicTrack) -> Bool {
        track.id == id && track.title == title && track.artist == artist &&
            track.album == album && track.duration == duration
    }
}

// Bind a pending Play/Shuffle request to the complete recording, not just its
// UUID and location. Restores can reuse both while changing the actual song.
private struct RecordingPlaybackSnapshot: Equatable {
    let id: UUID
    let url: URL
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval

    init(_ track: MusicTrack, url: URL) {
        id = track.id
        self.url = url
        title = track.title
        artist = track.artist
        album = track.album
        duration = track.duration
    }
}

private struct RecordingRowIdentity: Hashable {
    let position: Int
    let id: UUID
    let url: URL
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval

    init(position: Int, track: MusicTrack, url: URL) {
        self.position = position
        id = track.id
        self.url = url
        title = track.title
        artist = track.artist
        album = track.album
        duration = track.duration
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @State private var showFilePicker = false
    @State private var searchText: String = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--mp3shelf-snapshot-search") {
            return "Velvet"
        }
        #endif
        return ""
    }()
    @State private var favoritesOnly = false
    // Avoid rescanning large collections on every intermediate keystroke.
    @State private var settledSearchText = ""
    @AccessibilityFocusState private var searchResultsFocused: Bool
    @State private var sortMode: LibraryTrackSort = .title
    @State private var message: String?
    // The file picker closes before asynchronous file copying finishes.
    @State private var importInProgress = false
    @State private var renaming: MusicTrack?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var offlineRecordingCount: Int?
    @State private var offlineCountRefreshRequest = 0
    @State private var recentPlaybackCheck: UUID?
    @State private var recentPlaybackTask: Task<Void, Never>?
    @State private var recentPlaybackGeneration: UUID?
    @State private var missingRecentRecording = false
    @State private var recentPlaybackNotice: String?
    @State private var recentRetrySelection: RecentRetryIdentity?
    @State private var bulkPlaybackPending = false
    @State private var bulkPlaybackNotice: String?
    @State private var bulkPlaybackTask: Task<Void, Never>?
    // An older scan must never clear a newer request's busy state or feedback.
    @State private var bulkPlaybackGeneration: UUID?
    // Keep the user's original Play/Shuffle intent for a safe, explicit retry.
    @State private var bulkRetryShuffle: Bool?
    // A successful partial queue still needs a visible, local-only repair path.
    @State private var bulkSkippedRecordingCount = 0
    // An entirely unavailable selection needs a visible Files recovery path.
    // Keep this distinct from partial playback, which already has a queue.
    @State private var bulkAllRecordingsUnavailable = false
    // A partial queue can be refreshed explicitly after restoring files.
    // Never mutate the currently playing queue as an import side effect.
    @State private var partialQueueShuffle: Bool?
    @State private var partialQueueNeedsRefresh = false
    // A retry or partial-queue refresh belongs to an exact visible selection.
    // Library edits can change it without changing search, Favorites or sorting.
    @State private var playbackSelectionSnapshot: [RecordingPlaybackSnapshot]?

    // Import completion is asynchronous: never scan or queue a file while the
    // importer may still be replacing it on disk.
    private var audioImportBusy: Bool {
        importInProgress || library.isImporting || showFilePicker
    }

    // Recently added artwork must observe the same missing-file safety rule
    // as a normal library row. Never perform coordinated file I/O on the UI actor.
    private func playRecentRecording(_ track: MusicTrack) {
        // Preserve the tapped recording for explicit retry when local files
        // cannot be inspected. Do not replace a scan already in progress.
        if recentPlaybackCheck != nil {
            recentPlaybackNotice = "A recording is already being checked. Wait or cancel the current check."
            return
        }
        if scenePhase != .active || audioImportBusy {
            let matches = library.tracks.filter { $0.id == track.id }
            let url = library.fileURL(for: track)
            guard matches.count == 1,
                  matches[0].title == track.title,
                  matches[0].artist == track.artist,
                  matches[0].album == track.album,
                  matches[0].duration == track.duration,
                  library.fileURL(for: matches[0]) == url else {
                recentRetrySelection = nil
                recentPlaybackNotice = "This recording changed or has an ambiguous identity. Choose a current song."
                return
            }
            recentRetrySelection = RecentRetryIdentity(track, url: url)
            recentPlaybackNotice = scenePhase != .active
                ? "Return to MP3 Shelf to retry this recording. No audio was started."
                : "Finish importing audio, then retry this recording. Your saved audio was not changed."
            return
        }
        let generation = UUID()
        recentPlaybackGeneration = generation
        recentPlaybackCheck = track.id
        let selectedURL = library.fileURL(for: track)
        // PlaybackController resolves recordings by UUID. Reject duplicate IDs
        // before scheduling disk work, even when the tapped row has a distinct
        // file URL. An ambiguous ID must never select another recording.
        let matches = library.tracks.filter { $0.id == track.id }
        guard matches.count == 1,
              matches[0].title == track.title,
              matches[0].artist == track.artist,
              matches[0].album == track.album,
              matches[0].duration == track.duration,
              library.fileURL(for: matches[0]) == selectedURL else {
            recentPlaybackGeneration = nil
            recentPlaybackCheck = nil
            recentRetrySelection = nil
            missingRecentRecording = true
            recentPlaybackNotice = "This song has an ambiguous or outdated recording identity. Choose a current library entry."
            return
        }
        recentRetrySelection = RecentRetryIdentity(track, url: selectedURL)
        recentPlaybackNotice = nil
        missingRecentRecording = false
        // Snapshot the visible queue and URLs before leaving the UI actor.
        // A missing neighbor must not be queued behind an otherwise playable song.
        let recent = recentlyAdded
        // A restore can reuse both UUID and URL while changing the recording.
        // Capture the visible metadata before asynchronous file inspection.
        let metadata = recent.map { ($0.title, $0.artist, $0.album, $0.duration) }
        let locations = recent.map { ($0.id, library.fileURL(for: $0)) }
        guard let selectedIndex = recent.indices.first(where: { index in
            let candidate = recent[index]
            return candidate.id == track.id && locations[index].1 == selectedURL &&
                candidate.title == track.title && candidate.artist == track.artist &&
                candidate.album == track.album && candidate.duration == track.duration
        }) else {
            recentPlaybackCheck = nil
            recentPlaybackGeneration = nil
            missingRecentRecording = true
            recentPlaybackNotice = "The selected recording changed. Choose another song or retry."
            return
        }
        recentPlaybackTask = Task {
            // Preserve each occurrence's file identity. A Set<UUID> would let an
            // available duplicate authorize a missing recording with the same ID.
            let scan = Task.detached(priority: .userInitiated) { () -> [Bool] in
                var results: [Bool] = []
                results.reserveCapacity(locations.count)
                for (_, url) in locations {
                    if Task.isCancelled { return [] }
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                          url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
                          size > 0 else {
                        results.append(false)
                        continue
                    }
                    results.append(true)
                }
                return results
            }
            let availability = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            // Scene/import changes can arrive before SwiftUI's onChange
            // cancellation. Always retire this generation without allowing an
            // obsolete scan to start audio or strand the busy indicator.
            // Files is only a selection sheet, not an import. Keep the completed
            // local scan pending while it is visible, rather than discarding the
            // user's request or starting audio behind the picker. A real import
            // cancels this task before replacing any recordings.
            var pickerInterruptedScan = showFilePicker
            while showFilePicker && scenePhase == .active &&
                    !importInProgress && !library.isImporting && !Task.isCancelled {
                pickerInterruptedScan = true
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard recentPlaybackGeneration == generation, !Task.isCancelled else { return }
            if scenePhase != .active || audioImportBusy {
                recentPlaybackGeneration = nil
                recentPlaybackCheck = nil
                recentPlaybackTask = nil
                missingRecentRecording = true
                recentPlaybackNotice = scenePhase != .active
                    ? "Playback check paused while MP3 Shelf is inactive. Return and retry this recording."
                    : "Audio import interrupted the playback check. Finish importing, then retry this recording."
                return
            }
            // Files may have been cancelled after a recording was moved or
            // removed. Revalidate the original URLs before authorizing playback.
            // This is local metadata I/O only; do not mutate the active queue.
            var currentAvailability = availability
            if pickerInterruptedScan {
                let refreshed = Task.detached(priority: .userInitiated) { () -> [Bool] in
                    var results: [Bool] = []
                    results.reserveCapacity(locations.count)
                    for (_, url) in locations {
                        if Task.isCancelled { return [] }
                        guard url.isFileURL,
                              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                              values.isRegularFile == true, values.isSymbolicLink != true,
                              let size = values.fileSize, size > 0 else {
                            results.append(false)
                            continue
                        }
                        results.append(true)
                    }
                    return results
                }
                currentAvailability = await withTaskCancellationHandler {
                    await refreshed.value
                } onCancel: {
                    refreshed.cancel()
                }
                guard recentPlaybackGeneration == generation, !Task.isCancelled,
                      scenePhase == .active, !audioImportBusy else { return }
            }
            recentPlaybackGeneration = nil
            recentPlaybackCheck = nil
            recentPlaybackTask = nil
            guard currentAvailability.count == recent.count,
                  recentlyAdded.map { RecordingLocationKey(id: $0.id, url: library.fileURL(for: $0)) } == locations.map { RecordingLocationKey(id: $0.0, url: $0.1) },
                  recentlyAdded.enumerated().allSatisfy({ index, song in
                      song.title == metadata[index].0 && song.artist == metadata[index].1 &&
                      song.album == metadata[index].2 && song.duration == metadata[index].3
                  }) else {
                missingRecentRecording = true
                recentPlaybackNotice = "Recently Added changed while checking local files. Retry to check the current recordings."
                return
            }
            // Never resolve duplicates through an ID-only dictionary. Match the
            // original URL as well so import/recovery cannot substitute a file.
            // Index the current library once: repeated linear searches made
            // playback preparation quadratic for large imported collections.
            // Include the URL so duplicate IDs cannot substitute recordings.
            guard let currentByLocation = recordingIndex() else {
                missingRecentRecording = true
                recentPlaybackNotice = "Duplicate recording identities were found in your library. Resolve the duplicates before playing."
                recentRetrySelection = nil
                return
            }
            // The current library must still describe the exact recording
            // selected before the scan, including metadata reused after restore.
            guard recent.enumerated().allSatisfy({ index, song in
                guard let current = currentByLocation[RecordingLocationKey(id: song.id, url: locations[index].1)] else { return false }
                return current.title == metadata[index].0 && current.artist == metadata[index].1 &&
                    current.album == metadata[index].2 && current.duration == metadata[index].3
            }) else {
                missingRecentRecording = true
                recentPlaybackNotice = "Recently Added recordings changed while checking local files. Choose a song again."
                recentRetrySelection = nil
                return
            }
            let queue: [MusicTrack] = recent.enumerated().compactMap { index, song in
                guard currentAvailability[index] else { return nil }
                return currentByLocation[RecordingLocationKey(id: song.id, url: locations[index].1)]
            }
            guard currentAvailability[selectedIndex],
                  let selected = currentByLocation[RecordingLocationKey(id: track.id, url: selectedURL)] else {
                missingRecentRecording = true
                recentPlaybackNotice = "This recording is unavailable offline. Retry after restoring its local file, or choose another song."
                return
            }
            guard !Task.isCancelled, scenePhase == .active else { return }
            playback.play(selected, queue: queue)
            // A successful start is not a failed attempt: never offer a stale
            // Retry action beside the partial-queue playback notice.
            recentRetrySelection = nil
            let skipped = recent.count - queue.count
            if skipped > 0 {
                recentPlaybackNotice = "\(skipped) unavailable recording\(skipped == 1 ? "" : "s") skipped. Playing \(queue.count) available song\(queue.count == 1 ? "" : "s")."
            }
        }
    }

    // Build once per completed availability scan, on the library's actor.
    // Preserve the first occurrence for a duplicate (ID, URL) pair, matching
    // the prior first(where:) behavior without O(results × library) lookups.
    // The playback service identifies recordings by UUID, not file URL.
    // A restored library with two entries sharing a UUID cannot safely
    // resolve either one, even if the two entries point to the same file.
    // Return nil instead of silently selecting the first duplicate.
    private func recordingIndex() -> [RecordingLocationKey: MusicTrack]? {
        var index: [RecordingLocationKey: MusicTrack] = [:]
        var seenIDs = Set<UUID>()
        index.reserveCapacity(library.tracks.count)
        for track in library.tracks {
            guard seenIDs.insert(track.id).inserted else { return nil }
            index[RecordingLocationKey(id: track.id, url: library.fileURL(for: track))] = track
        }
        return index
    }

    private func cancelRecentPlaybackPreparation(showFeedback: Bool) {
        if recentPlaybackCheck != nil {
            recentPlaybackGeneration = nil
            recentPlaybackTask?.cancel()
            recentPlaybackTask = nil
            recentPlaybackCheck = nil
        } else if showFeedback {
            return
        }
        if showFeedback {
            recentPlaybackNotice = "Playback preparation cancelled. Your saved recordings were not changed."
        } else {
            recentPlaybackNotice = nil
            recentRetrySelection = nil
        }
    }

    // Opening the Files picker is itself a navigation transition. Invalidate
    // preparation before presenting it: a slow disk scan must not start audio
    // behind the picker while the user is choosing a replacement recording.
    private func presentAudioImporter() {
        guard !audioImportBusy else {
            message = "Finish the current audio import before choosing more files."
            return
        }
        guard scenePhase == .active else {
            message = "Return to MP3 Shelf before opening Files."
            return
        }
        // Opening Files is not an import. The listener can cancel the picker,
        // leaving a running local playback check and its retry intent intact.
        // Only the fileImporter's nonempty successful selection invalidates
        // those checks, immediately before importAudio begins.
        showFilePicker = true
    }

    // Explicit cancellation preserves the requested mode for an intentional retry.
    // Background/navigation cancellation must not leave a stale retry affordance.
    private func cancelBulkPlaybackPreparation(showFeedback: Bool) {
        guard bulkPlaybackPending else { return }
        bulkPlaybackGeneration = nil
        bulkPlaybackTask?.cancel()
        bulkPlaybackTask = nil
        bulkPlaybackPending = false
        if showFeedback {
            bulkSkippedRecordingCount = 0
            bulkPlaybackNotice = "Playback preparation cancelled. Your saved recordings were not changed."
            // Retry mode is set when the request begins, before any disk I/O.
        } else {
            bulkPlaybackNotice = nil
            bulkRetryShuffle = nil
            bulkSkippedRecordingCount = 0
        }
    }

    // Invalidate an in-flight scan as soon as the user changes its scope.
    // Waiting for disk I/O to finish leaves the old busy indicator blocking
    // playback of the newly selected results on large libraries.
    private func playbackSelectionIsCurrent() -> Bool {
        guard let playbackSelectionSnapshot, !isSearchUpdating else { return false }
        let current = displayed.map { RecordingPlaybackSnapshot($0, url: library.fileURL(for: $0)) }
        // An ID collision can make a restored recording ambiguous even when
        // its visible position and file URL appear unchanged. Never authorize
        // recovery of a queue whose recording identities are not unique.
        guard Set(current.map(\.id)).count == current.count,
              Set(playbackSelectionSnapshot.map(\.id)).count == playbackSelectionSnapshot.count else {
            return false
        }
        return current == playbackSelectionSnapshot
    }

    private func invalidateStalePlaybackRecovery() {
        guard playbackSelectionSnapshot != nil,
              !playbackSelectionIsCurrent() else { return }
        // Invalidate the generation before a detached file scan can publish a
        // queue for a recording that has just been deleted or restored.
        if bulkPlaybackPending {
            cancelBulkPlaybackPreparation(showFeedback: false)
        }
        bulkRetryShuffle = nil
        bulkSkippedRecordingCount = 0
        bulkAllRecordingsUnavailable = false
        partialQueueShuffle = nil
        partialQueueNeedsRefresh = false
        playbackSelectionSnapshot = nil
        bulkPlaybackNotice = "Your library selection changed. Choose Play or Shuffle to check the current songs."
    }

    // A Recently Added scan can outlive a library edit. Cancel it immediately
    // rather than waiting for disk I/O, and never offer Retry for a removed or
    // relocated recording. A still-present selection can be retried explicitly.
    private func recentLibrarySelectionDidChange() {
        guard recentPlaybackCheck != nil || recentRetrySelection != nil else { return }
        let selectionIsValid: Bool
        if let selection = recentRetrySelection {
            let matches = library.tracks.filter { $0.id == selection.id }
            selectionIsValid = matches.count == 1 &&
                matches.first.map { selection.matches($0) && library.fileURL(for: $0) == selection.url } == true
        } else {
            selectionIsValid = false
        }
        let wasPreparing = recentPlaybackCheck != nil
        if wasPreparing {
            cancelRecentPlaybackPreparation(showFeedback: selectionIsValid)
            missingRecentRecording = true
            recentPlaybackNotice = selectionIsValid
                ? "Your library changed while checking local files. Retry this recording when ready."
                : "The selected recording was removed or replaced. Choose another song."
        }
        if !selectionIsValid {
            // A restored file may move while retaining the same unique track ID.
            // Keep an idle, explicit Retry in that case: retryRecentRecording()
            // resolves the current URL and performs a fresh local-file scan.
            // Never retain the retry for duplicates, deletions, or an in-flight
            // scan, which could otherwise authorize a different recording.
            let uniqueReplacement: Bool
            if !wasPreparing, let selection = recentRetrySelection {
                let matches = library.tracks.filter { $0.id == selection.id }
                uniqueReplacement = matches.count == 1 &&
                    recentlyAdded.contains(where: { selection.matches($0) }) &&
                    matches.first.map { selection.matches($0) } == true
            } else {
                uniqueReplacement = false
            }
            if uniqueReplacement {
                recentPlaybackNotice = "This recording moved after import. Retry to check its current local file before playing."
            } else {
                recentRetrySelection = nil
                if recentPlaybackCheck == nil {
                    recentPlaybackNotice = "The selected recording was removed or replaced. Choose another song."
                }
            }
        }
    }

    private func browsingScopeDidChange() {
        // Every recovery action is scoped to the exact result snapshot. In
        // particular, an entirely missing offline selection has no skipped
        // count or retry mode, so it must be invalidated explicitly.
        let hadRecovery = bulkPlaybackPending || bulkSkippedRecordingCount > 0 ||
            bulkAllRecordingsUnavailable || partialQueueNeedsRefresh ||
            partialQueueShuffle != nil || bulkRetryShuffle != nil ||
            playbackSelectionSnapshot != nil
        let wasPreparing = bulkPlaybackPending
        if wasPreparing {
            cancelBulkPlaybackPreparation(showFeedback: false)
        }
        guard hadRecovery else { return }
        bulkSkippedRecordingCount = 0
        bulkAllRecordingsUnavailable = false
        partialQueueShuffle = nil
        partialQueueNeedsRefresh = false
        bulkRetryShuffle = nil
        playbackSelectionSnapshot = nil
        // Preserve a useful explanation only for interrupted preparation.
        // Otherwise remove the old restore/retry notice as well as its actions:
        // it no longer describes the newly filtered or sorted recordings.
        bulkPlaybackNotice = wasPreparing
            ? "Your song selection changed. Choose Play or Shuffle for the new results."
            : nil
    }

    private func retryRecentRecording() {
        // The retry button must not silently do nothing while the app is
        // backgrounded or another file scan is still preparing playback.
        // Retry remains visible when the app is backgrounded or Files is still
        // importing. Do not silently discard the listener's recovery request.
        guard let selection = recentRetrySelection else {
            recentPlaybackNotice = "Choose a recording from Recently Added to start a new playback check."
            return
        }
        guard scenePhase == .active else {
            recentPlaybackNotice = "Return to MP3 Shelf to retry this recording. Your saved audio was not changed."
            return
        }
        guard !audioImportBusy else {
            recentPlaybackNotice = "Wait for the audio import to finish, then retry this recording."
            return
        }
        guard recentPlaybackCheck == nil else {
            recentPlaybackNotice = "This recording is already being checked. Wait for the current check or cancel it."
            return
        }
        let candidates = recentlyAdded.filter { $0.id == selection.id }
        // Prefer the exact recording originally selected. After a successful
        // reimport, its URL may change; accept that replacement only if the ID
        // uniquely identifies one current recording. The normal playback scan
        // still validates the replacement's actual bytes before queueing it.
        // Never retry an ambiguous UUID, even if one candidate retains the
        // original URL. PlaybackController resolves track identity by UUID.
        let allMatches = library.tracks.filter { $0.id == selection.id }
        guard allMatches.count == 1 else {
            recentPlaybackNotice = allMatches.isEmpty
                ? "This recording is no longer in your library."
                : "Duplicate recording identities were found. Resolve the duplicates before playing."
            recentRetrySelection = nil
            return
        }
        // A restore can reuse a UUID and URL for a different song. Retry must
        // never authorize that replacement, even when its local bytes exist.
        guard selection.matches(allMatches[0]) else {
            recentPlaybackNotice = "This recording's details changed. Choose the current song again."
            recentRetrySelection = nil
            return
        }
        let exact = candidates.first { selection.matches($0) && library.fileURL(for: $0) == selection.url }
        guard let current = exact ?? (candidates.count == 1 && selection.matches(candidates[0]) ? candidates[0] : nil) else {
            recentPlaybackNotice = candidates.isEmpty
                ? "This song is no longer in Recently Added. Choose another recording."
                : "Multiple recordings match this song. Choose the correct recording to play."
            recentRetrySelection = nil
            return
        }
        playRecentRecording(current)
    }

    // Resolve file URLs on the library's actor, then check disk off the UI thread.
    // A nil count is deliberately not presented as zero while scanning.
    private func refreshOfflineRecordingCount() async {
        let urls = library.tracks.map { library.fileURL(for: $0) }
        if urls.isEmpty {
            offlineRecordingCount = 0
            return
        }
        let scan = Task.detached(priority: .utility) { () -> Int? in
            var count = 0
            for url in urls {
                if Task.isCancelled { return nil }
                // fileExists also returns true for directories and empty staging
                // placeholders; neither is an offline-playable recording.
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
                      size > 0 else { continue }
                count += 1
            }
            return count
        }
        // Cancelling the SwiftUI task also cancels the detached filesystem scan.
        // This prevents a superseded scan from competing with the current one.
        let count = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        guard !Task.isCancelled, let count else { return }
        offlineRecordingCount = count
    }

    private var recentlyAdded: [MusicTrack] {
        library.recentlyAddedTracks(limit: 8)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Do not run a stale query or construct a large result array while typing.
    // The search task determines when the latest query is ready for display.
    private var displayed: [MusicTrack] {
        guard !isSearchUpdating else { return [] }
        return library.browseTracks(query: settledSearchText, favoritesOnly: favoritesOnly,
                                    order: sortMode)
    }

    private var isSearchUpdating: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            != settledSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Search submission bypasses the typing debounce; stale tasks cannot publish
    // results after a newer query or a clear action.
    private func submitSearch() {
        settledSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResultsFocused = true
    }

    private func clearSearch() {
        searchText = ""
        settledSearchText = ""
        searchResultsFocused = false
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort songs", selection: $sortMode) {
                ForEach(LibraryTrackSort.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
        } label: {
            Label(sortMode.rawValue, systemImage: "arrow.up.arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ShelfTheme.accent)
        }
        .frame(minHeight: 44)
        .accessibilityLabel("Sort songs by \(sortMode.rawValue)")
        .accessibilityHint("Choose the order of songs in your library")
    }

    private var searchHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            PremiumEyebrow(title: "SEARCH YOUR LIBRARY")
            Text("Search results")
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($searchResultsFocused)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            // Keep a recovery action in the scroll content even when the
            // navigation search field is offscreen or the keyboard is hidden.
            Button {
                clearSearch()
            } label: {
                Label("Clear song search", systemImage: "xmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ShelfTheme.accent)
            .accessibilityHint("Show your complete music library")
        }
    }

    private func searchSortSummary(matchingCount: Int) -> some View {
        return VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 9) {
            Text(isSearchUpdating ? "Updating search…" : "\(matchingCount) of \(library.tracks.count) songs found")
                .font(.caption.monospacedDigit())
                .foregroundStyle(ShelfTheme.subdued)
                .accessibilityLabel(isSearchUpdating ? "Updating search results" : "\(matchingCount) matching songs out of \(library.tracks.count)")
                .accessibilityAddTraits(.updatesFrequently)
            sortMenu
        }
    }

    private var filterControls: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    filterChoices
                }
            } else {
                HStack(spacing: 10) {
                    filterChoices
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var filterChoices: some View {
        filterButton("All music", selected: !favoritesOnly) { favoritesOnly = false }
        filterButton("Favorites", symbol: "heart.fill", selected: favoritesOnly) {
            favoritesOnly = true
        }
    }

    private func browsingPlaybackControls(hasResults: Bool) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading) { browsingActions }
            } else {
                HStack { browsingActions }
            }
        }
        .buttonStyle(.bordered)
        .tint(ShelfTheme.accent)
        // Import is not a disabled state: listeners need an actionable reason
        // why their selected recordings cannot play yet. The handler retains
        // the exact Play/Shuffle selection for a deliberate retry.
        .disabled(!hasResults || isSearchUpdating || bulkPlaybackPending)
        .accessibilityHint(audioImportBusy
            ? "Audio is importing. Choose Play or Shuffle to save a retry request without starting playback."
            : "Checks locally stored recordings before starting playback.")
    }

    @ViewBuilder private var browsingActions: some View {
        Button { playDisplayed(shuffled: false) } label: {
            Label("Play results", systemImage: "play.fill").frame(minHeight: 44)
        }
        Button { playDisplayed(shuffled: true) } label: {
            Label("Shuffle results", systemImage: "shuffle").frame(minHeight: 44)
        }
    }

    private var bulkPlaybackFeedback: some View {
        VStack(alignment: .leading, spacing: 10) {
            if bulkPlaybackPending {
                HStack(spacing: 12) {
                    ProgressView().accessibilityHidden(true)
                    Text("Checking recordings stored on this iPhone…")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                Button("Cancel playback preparation", systemImage: "xmark.circle") {
                    cancelBulkPlaybackPreparation(showFeedback: true)
                }
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityHint("Stops checking local files without changing your music library")
            }
            if let bulkPlaybackNotice {
                VStack(alignment: .leading, spacing: 8) {
                    Text(bulkPlaybackNotice)
                        .font(.footnote)
                        .foregroundStyle(ShelfTheme.subdued)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                    // An empty offline queue has no playing audio to disrupt.
                    // Offer a local-only recovery journey instead of a dead-end notice.
                    if bulkAllRecordingsUnavailable && !bulkPlaybackPending && playbackSelectionIsCurrent() {
                        Button {
                            presentAudioImporter()
                        } label: {
                            Label("Restore unavailable recordings", systemImage: "square.and.arrow.down")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled(audioImportBusy || scenePhase != .active)
                        .accessibilityHint("Choose audio files already on this device. No downloads or playback start automatically")
                    }
                    // Partial playback has already started: restoring missing files
                    // must not reset the active queue or unexpectedly replay songs.
                    if bulkSkippedRecordingCount > 0 && !bulkPlaybackPending && playbackSelectionIsCurrent() {
                        Button {
                            presentAudioImporter()
                        } label: {
                            Label("Restore skipped recordings", systemImage: "square.and.arrow.down")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled(audioImportBusy || scenePhase != .active)
                        .accessibilityHint("Choose missing local audio files from Files. Currently playing music will not restart.")
                    }
                    if partialQueueNeedsRefresh, let originalShuffle = partialQueueShuffle,
                       !bulkPlaybackPending && playbackSelectionIsCurrent() {
                        Button {
                            playDisplayed(shuffled: originalShuffle)
                        } label: {
                            Label(originalShuffle ? "Refresh restored Shuffle" : "Refresh restored Play queue", systemImage: "arrow.clockwise")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled(audioImportBusy || scenePhase != .active || isSearchUpdating || displayed.isEmpty)
                        .accessibilityHint("Recheck restored local files and start a new queue only when you choose; current playback is not changed automatically")
                    }
                    if let retryShuffle = bulkRetryShuffle, !bulkPlaybackPending && playbackSelectionIsCurrent() {
                        // A changed search or Favorites filter can leave no
                        // playable selection. Never offer a silent no-op Retry.
                        let canRetry = scenePhase == .active && !audioImportBusy && !isSearchUpdating && !displayed.isEmpty
                        if canRetry {
                            Button {
                                playDisplayed(shuffled: retryShuffle)
                            } label: {
                                Label(retryShuffle ? "Retry Shuffle" : "Retry Play", systemImage: "arrow.clockwise")
                                    .frame(minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityHint("Checks the current library results again without changing saved music")
                        } else {
                            Text(isSearchUpdating
                                 ? "Finish searching before retrying playback."
                                 : audioImportBusy
                                 ? "Finish importing audio, then retry the saved Play or Shuffle selection."
                                 : scenePhase != .active
                                 ? "Return to MP3 Shelf to retry the saved selection."
                                 : "Choose songs in your library to retry playback.")
                                .font(.footnote)
                                .foregroundStyle(ShelfTheme.subdued)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Restoring files is an explicit user action. This
                        // opens the existing local importer; no network access.
                        Button {
                            presentAudioImporter()
                        } label: {
                            Label("Restore audio files", systemImage: "square.and.arrow.down")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled(audioImportBusy)
                        .accessibilityHint("Choose existing audio recordings from Files, then retry playback")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Imports from other screens do not expose their per-file report here.
    // Offer an explicit local-only recheck, never an automatic queue replacement.
    private func markPartialQueueReadyForManualRefresh() {
        guard !audioImportBusy, bulkSkippedRecordingCount > 0,
              partialQueueShuffle != nil else { return }
        // Imports initiated outside Files do not provide a per-file report to
        // this view. Reconcile their visible selection before exposing Refresh:
        // an expanded or ambiguous library must require a new explicit Play.
        guard playbackSelectionIsCurrent() else {
            invalidateStalePlaybackRecovery()
            return
        }
        partialQueueNeedsRefresh = true
        bulkPlaybackNotice = "The library import finished. Refresh playback to recheck missing recordings; the current queue is unchanged."
    }

    // A failed or duplicate-only Files import cannot restore missing audio.
    // Partial success can be rechecked manually without replacing the queue.
    private func completeLocalAudioImport(importedCount: Int, skippedCount: Int,
                                          failureCount: Int) {
        guard bulkSkippedRecordingCount > 0, partialQueueShuffle != nil else { return }
        guard importedCount > 0 else {
            // A later failed/duplicate-only attempt must not revoke a manual
            // refresh already earned by an earlier successful restoration.
            // The active queue remains untouched until the listener refreshes.
            let canStillRefresh = partialQueueNeedsRefresh && playbackSelectionIsCurrent()
            partialQueueNeedsRefresh = canStillRefresh
            let explanation = failureCount > 0
                ? "No recordings were imported. Review the import errors or choose another audio file."
                : "No new recordings were imported. Duplicate files do not restore missing audio."
            bulkPlaybackNotice = explanation + (canStillRefresh
                ? " You can still refresh playback after your earlier import; the current queue is unchanged."
                : " The current queue is unchanged.")
            return
        }
        // This helper also handles future callers outside the Files completion
        // closure. A successful import cannot authorize a changed queue.
        guard playbackSelectionIsCurrent() else {
            invalidateStalePlaybackRecovery()
            return
        }
        partialQueueNeedsRefresh = true
        let detail = failureCount > 0 || skippedCount > 0
            ? "Some selected files were skipped or failed."
            : "Audio files were imported."
        bulkPlaybackNotice = "\(detail) Refresh playback to recheck missing recordings; the current queue is unchanged."
    }

    // Validate the whole playback queue off the main actor. A missing local
    // recording must not be selected by Play results or Shuffle results.
    private func playDisplayed(shuffled: Bool) {
        // Play and Shuffle remain actionable while an import is finishing.
        // Capture the exact selection and requested mode so a later explicit
        // Retry cannot silently switch to different search results or songs.
        if scenePhase != .active || audioImportBusy || isSearchUpdating || bulkPlaybackPending {
            if bulkPlaybackPending {
                bulkPlaybackNotice = "A playback check is already running. Wait or cancel it before starting another."
                return
            }
            if isSearchUpdating {
                bulkPlaybackNotice = "Finish searching before starting playback. Choose Play or Shuffle again when results settle."
                return
            }
            let songs = displayed
            guard !songs.isEmpty else {
                bulkRetryShuffle = nil
                playbackSelectionSnapshot = nil
                bulkPlaybackNotice = "No songs match the current library selection."
                return
            }
            // A failed request must not erase an already playing partial queue.
            // Retain the exact current selection, not just the search string.
            let snapshots = songs.map { RecordingPlaybackSnapshot($0, url: library.fileURL(for: $0)) }
            let ids = library.tracks.map(\.id)
            guard Set(ids).count == ids.count else {
                bulkRetryShuffle = nil
                playbackSelectionSnapshot = nil
                bulkPlaybackNotice = "Duplicate recording identities were found. Resolve them before playing."
                return
            }
            playbackSelectionSnapshot = snapshots
            bulkRetryShuffle = shuffled
            bulkPlaybackNotice = scenePhase != .active
                ? "Return to MP3 Shelf, then retry this selection. No playback was started."
                : "Finish importing audio, then retry this selection. Your current queue is unchanged."
            return
        }
        let songs = displayed
        guard !songs.isEmpty else {
            bulkRetryShuffle = nil
            playbackSelectionSnapshot = nil
            bulkPlaybackNotice = "No songs match the current library selection."
            return
        }
        // PlaybackController resolves tracks by UUID. A restored library can
        // contain duplicate IDs even when the visible results show only one of
        // them (for example under Favorites or a search query). Fail before
        // starting filesystem work; otherwise the scan may eventually queue an
        // ambiguous recording or leave the listener waiting unnecessarily.
        let allIDs = library.tracks.map(\.id)
        guard Set(allIDs).count == allIDs.count else {
            bulkRetryShuffle = nil
            bulkSkippedRecordingCount = 0
            partialQueueShuffle = nil
            partialQueueNeedsRefresh = false
            playbackSelectionSnapshot = nil
            bulkPlaybackNotice = "Duplicate recording identities were found in your library. Resolve the duplicates before playing."
            return
        }
        // A search, filter, sort or library edit during disk I/O invalidates
        // the requested results. Never start playback from an obsolete snapshot.
        let requestedQuery = settledSearchText
        let requestedFavorites = favoritesOnly
        let requestedSort = sortMode
        let locations = songs.map { ($0.id, library.fileURL(for: $0)) }
        let generation = UUID()
        bulkPlaybackGeneration = generation
        bulkPlaybackNotice = nil
        bulkSkippedRecordingCount = 0
        bulkAllRecordingsUnavailable = false
        partialQueueShuffle = nil
        partialQueueNeedsRefresh = false
        playbackSelectionSnapshot = zip(songs, locations).map { song, location in
            RecordingPlaybackSnapshot(song, url: location.1)
        }
        bulkRetryShuffle = shuffled
        bulkPlaybackPending = true
        bulkPlaybackTask = Task {
            // Keep one availability result per visible occurrence. An ID set can
            // incorrectly authorize a missing duplicate that shares a track ID.
            let scan = Task.detached(priority: .userInitiated) { () -> [Bool] in
                var availability: [Bool] = []
                availability.reserveCapacity(locations.count)
                for (_, url) in locations {
                    if Task.isCancelled { return [] }
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                          url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
                          size > 0 else {
                        availability.append(false)
                        continue
                    }
                    availability.append(true)
                }
                return availability
            }
            var availability = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            // Do not rely solely on the scene-phase observer to clear pending
            // state: a detached scan may complete before that observer runs.
            // Files is only a selection sheet, not an import. Keep the completed
            // local scan pending while it is visible, rather than discarding the
            // user's request or starting audio behind the picker. A real import
            // cancels this task before replacing any recordings.
            var pickerInterruptedScan = showFilePicker
            while showFilePicker && scenePhase == .active &&
                    !importInProgress && !library.isImporting && !Task.isCancelled {
                pickerInterruptedScan = true
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard bulkPlaybackGeneration == generation, !Task.isCancelled else { return }
            // The first scan may have finished before Files was dismissed.
            // Files can move or remove a recording without importing anything,
            // so never queue the old availability snapshot after a picker visit.
            // Recheck off the main actor and preserve the original selection.
            if pickerInterruptedScan && scenePhase == .active && !audioImportBusy {
                let refresh = Task.detached(priority: .userInitiated) { () -> [Bool] in
                    var refreshed: [Bool] = []
                    refreshed.reserveCapacity(locations.count)
                    for (_, url) in locations {
                        if Task.isCancelled { return [] }
                        guard url.isFileURL,
                              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                              values.isRegularFile == true,
                              values.isSymbolicLink != true,
                              let size = values.fileSize, size > 0 else {
                            refreshed.append(false)
                            continue
                        }
                        refreshed.append(true)
                    }
                    return refreshed
                }
                availability = await withTaskCancellationHandler {
                    await refresh.value
                } onCancel: {
                    refresh.cancel()
                }
                guard bulkPlaybackGeneration == generation, !Task.isCancelled else { return }
            }
            if scenePhase != .active || audioImportBusy {
                bulkPlaybackGeneration = nil
                bulkPlaybackPending = false
                bulkPlaybackTask = nil
                bulkSkippedRecordingCount = 0
                bulkPlaybackNotice = scenePhase != .active
                    ? "Playback check paused while MP3 Shelf is inactive. Return and retry Play or Shuffle."
                    : "Audio import interrupted playback preparation. Finish importing, then retry Play or Shuffle."
                return
            }
            bulkPlaybackGeneration = nil
            bulkPlaybackPending = false
            bulkPlaybackTask = nil
            guard !isSearchUpdating,
                  settledSearchText == requestedQuery,
                  favoritesOnly == requestedFavorites,
                  sortMode == requestedSort,
                  playbackSelectionIsCurrent(),
                  availability.count == songs.count else {
                // The previous retry belonged to the old visible selection.
                // Do not offer it for a different search, sort, or restored
                // recording: the listener must explicitly choose the new queue.
                bulkRetryShuffle = nil
                bulkSkippedRecordingCount = 0
                partialQueueShuffle = nil
                partialQueueNeedsRefresh = false
                playbackSelectionSnapshot = nil
                bulkPlaybackNotice = "Your library results changed while checking offline recordings. Choose Play or Shuffle to check the current songs."
                return
            }
            // Resolve the exact original file location, not just its ID.
            // A changed or removed recording invalidates this request; a file
            // that was already missing at scan time is simply skipped.
            guard let currentByLocation = recordingIndex() else {
                bulkPlaybackNotice = "Duplicate recording identities were found in your library. Resolve the duplicates before playing."
                bulkRetryShuffle = nil
                return
            }
            var queue: [MusicTrack] = []
            queue.reserveCapacity(songs.count)
            for (index, song) in songs.enumerated() {
                // Validate every selected recording, including those whose file
                // was missing during the scan. A restore may replace a missing
                // recording with a different song while the scan is suspended.
                // Skipping validation for unavailable entries would authorize a
                // partial queue from a stale library snapshot.
                let originalURL = locations[index].1
                guard let match = currentByLocation[RecordingLocationKey(id: song.id, url: originalURL)],
                      RecordingPlaybackSnapshot(match, url: originalURL) == playbackSelectionSnapshot?[index] else {
                    bulkPlaybackNotice = "Some recordings changed while preparing playback. Choose Play or Shuffle to use the current library."
                    bulkRetryShuffle = nil
                    return
                }
                // Missing audio is excluded without changing the user's library
                // or the order of the remaining playable recordings.
                guard availability[index] else { continue }
                queue.append(match)
            }
            guard let first = shuffled ? queue.randomElement() : queue.first else {
                bulkAllRecordingsUnavailable = true
                bulkPlaybackNotice = "No playable offline recordings were found in these results. Restore a recording from Files, then retry."
                bulkRetryShuffle = shuffled
                return
            }
            bulkAllRecordingsUnavailable = false
            playback.isShuffled = shuffled
            playback.play(first, queue: queue)
            bulkRetryShuffle = nil
            bulkPlaybackNotice = nil
            let skipped = songs.count - queue.count
            bulkSkippedRecordingCount = skipped
            partialQueueShuffle = skipped > 0 ? shuffled : nil
            partialQueueNeedsRefresh = false
            if skipped > 0 {
                bulkPlaybackNotice = "\(skipped) unavailable recording\(skipped == 1 ? "" : "s") skipped. Playing \(queue.count) available song\(queue.count == 1 ? "" : "s")."
            }
        }
    }

    var body: some View {
        // Share one sorted, filtered snapshot across the count, rows and queue.
        // Recomputing `displayed` per row repeatedly scans large libraries.
        let visibleTracks = displayed
        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if isSearching {
                    VStack(alignment: .leading, spacing: 15) {
                        Group {
                            if dynamicTypeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 12) {
                                    searchHeading
                                    searchSortSummary(matchingCount: visibleTracks.count)
                                }
                            } else {
                                HStack(alignment: .firstTextBaseline) {
                                    searchHeading
                                    Spacer(minLength: 8)
                                    searchSortSummary(matchingCount: visibleTracks.count)
                                }
                            }
                        }
                        filterControls
                        browsingPlaybackControls(hasResults: !visibleTracks.isEmpty)
                        bulkPlaybackFeedback
                        if isSearchUpdating {
                            ProgressView("Searching songs…")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 20)
                                .accessibilityLabel("Searching songs")
                        } else if visibleTracks.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                PremiumIcon(symbol: "magnifyingglass", color: ShelfTheme.accent,
                                            size: 56)
                                Text("No matching songs")
                                    .font(.system(.headline, design: .rounded, weight: .bold))
                                    .foregroundStyle(.white)
                                Text(favoritesOnly
                                     ? "No favorites match this search. Try All music or a different song, artist or album."
                                     : "Try a different song, artist or album.")
                                    .font(.subheadline)
                                    .foregroundStyle(ShelfTheme.subdued)
                                if favoritesOnly {
                                    Button {
                                        favoritesOnly = false
                                    } label: {
                                        Label("Search all music", systemImage: "music.note.list")
                                            .frame(minHeight: 44)
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityHint("Keep the search and include songs that are not favorites")
                                }
                                Button {
                                    clearSearch()
                                    favoritesOnly = false
                                } label: {
                                    Label("Show complete library", systemImage: "arrow.uturn.backward")
                                        .frame(minHeight: 44)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityHint("Clear the search and Favorites filter")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(22)
                            .premiumCard()
                        } else {
                            LazyVStack(spacing: 9) {
                                // A restored archive may contain duplicate recording UUIDs.
                                // Index-based ForEach keeps both rows visible instead of
                                // collapsing them into one SwiftUI identity. The explicit
                                // row identity also resets pending destructive/async row
                                // state when sorting moves a different file into a slot.
                                ForEach(Array(visibleTracks.enumerated()), id: \.offset) { offset, track in
                                    MusicTrackRow(track: track, context: visibleTracks, importBlocked: audioImportBusy,
                                                  renaming: $renaming)
                                        .id(RecordingRowIdentity(position: offset, track: track,
                                                                 url: library.fileURL(for: track)))
                                }
                            }
                        }
                    }
                    .padding(.top, 10)
                } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        PremiumEyebrow(title: "YOUR COLLECTION")
                        Text("Good music. Anywhere.")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    PremiumIcon(symbol: "waveform", color: ShelfTheme.coral, size: 48)
                }
                .padding(.top, 10)

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(ShelfTheme.mint)
                                    .frame(width: 7, height: 7)
                                Text("YOUR MUSIC LIBRARY")
                                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                                    .tracking(1.6)
                                    .foregroundStyle(ShelfTheme.mint)
                            }
                            Text(library.tracks.isEmpty
                                 ? "Start your\nsoundtrack."
                                 : "Your songs.\nOne place.")
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(library.tracks.isEmpty
                                 ? "Your favorite songs, right on your iPhone."
                                 : "\(library.tracks.count) songs in your library. " +
                                     (library.isImporting
                                      ? "Importing recordings…"
                                      : offlineRecordingCount.map { "\($0) recordings available offline." } ?? "Checking offline recordings…"))
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                            if !library.tracks.isEmpty {
                                Button {
                                    offlineRecordingCount = nil
                                    offlineCountRefreshRequest &+= 1
                                } label: {
                                    Label("Refresh offline availability", systemImage: "arrow.clockwise")
                                        .font(.caption.weight(.semibold))
                                        .frame(minHeight: 44, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white)
                                .accessibilityHint("Recheck recordings stored on this iPhone without connecting to the internet")
                                .disabled(audioImportBusy || scenePhase != .active || offlineRecordingCount == nil)
                            }
                        }
                        Spacer(minLength: 0)
                        if !dynamicTypeSize.isAccessibilitySize {
                            ArtworkTile(track: library.tracks.last,
                                        size: library.tracks.isEmpty ? 92 : 110)
                                .rotationEffect(.degrees(7))
                                .shadow(color: .black.opacity(0.3), radius: 12, y: 9)
                                .accessibilityHidden(true)
                        }
                    }
                    if library.tracks.isEmpty {
                        Button {
                            presentAudioImporter()
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "plus.circle.fill")
                                Text("Import your music")
                                Spacer()
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(ShelfTheme.background)
                            .padding(.horizontal, 17)
                            .frame(minHeight: 47)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Choose existing audio files from your iPhone")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ShelfTheme.heroGradient, in: RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1))

                if library.tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        PremiumSectionHeading(title: "More ways to listen")
                        NavigationLink { PlaylistSourcesView() } label: {
                            HStack(spacing: 14) {
                                PremiumIcon(symbol: "square.stack.3d.up",
                                            color: ShelfTheme.coral, size: 46)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Import a music playlist")
                                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                                        .foregroundStyle(.white)
                                    Text("Apple Music, Spotify or a track-list file")
                                        .font(.caption)
                                        .foregroundStyle(ShelfTheme.subdued)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(ShelfTheme.subdued)
                            }
                            .padding(14)
                            .premiumCard(radius: 20)
                        }
                        .buttonStyle(.plain)
                        Text("Your music stays on your device and plays without a connection.")
                            .font(.caption)
                            .foregroundStyle(ShelfTheme.subdued)
                            .padding(.horizontal, 3)
                    }
                } else {
                    if recentlyAdded.count >= 2 {
                        VStack(alignment: .leading, spacing: 13) {
                            PremiumSectionHeading(title: "Recently added",
                                                  detail: "FRESH ON YOUR SHELF")
                            ScrollView(.horizontal) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    // Imported/restored recordings may share UUIDs.
                                    // Use stable occurrence offsets for this bounded
                                    // eight-item snapshot instead of duplicate SwiftUI IDs.
                                    ForEach(Array(recentlyAdded.enumerated()), id: \.offset) { _, track in
                                        Button {
                                            playRecentRecording(track)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 8) {
                                                ArtworkTile(track: track, size: 122)
                                                    .shadow(color: .black.opacity(0.18),
                                                            radius: 10, y: 5)
                                                Text(track.title)
                                                    .font(.system(.subheadline,
                                                                  design: .rounded,
                                                                  weight: .semibold))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                                                Text(track.artist)
                                                    .font(.caption)
                                                    .foregroundStyle(ShelfTheme.subdued)
                                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                                            }
                                            .frame(width: dynamicTypeSize.isAccessibilitySize ? 190 : 122,
                                                   alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(recentPlaybackCheck != nil)
                                        .accessibilityLabel(recentPlaybackCheck == track.id
                                            ? "Checking \(track.title) for offline playback"
                                            : "Play \(track.title) by \(track.artist)")
                                        .accessibilityHint(audioImportBusy
                                            ? "Wait for audio import to finish before playing this recording"
                                            : scenePhase != .active
                                                ? "Return to MP3 Shelf to play this recording"
                                                : "Checks the local recording before playback without using the network")
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .scrollIndicators(.hidden)
                            if recentPlaybackCheck != nil {
                                VStack(alignment: .leading, spacing: 10) {
                                    ProgressView("Checking local recordings…")
                                        .accessibilityLabel("Checking Recently Added for offline playback")
                                    Button {
                                        cancelRecentPlaybackPreparation(showFeedback: true)
                                    } label: {
                                        Label("Cancel Recently Added playback", systemImage: "xmark.circle")
                                            .frame(minHeight: 44, alignment: .leading)
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityHint("Stop checking local files without deleting or changing any saved music")
                                }
                            }
                            if let recentPlaybackNotice {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(recentPlaybackNotice)
                                        .font(.footnote)
                                        .foregroundStyle(ShelfTheme.subdued)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityAddTraits(.updatesFrequently)
                                    if recentRetrySelection != nil && recentPlaybackCheck == nil {
                                        if audioImportBusy {
                                            Label("Finish importing audio before retrying playback.", systemImage: "clock")
                                                .font(.footnote)
                                                .foregroundStyle(ShelfTheme.subdued)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .accessibilityAddTraits(.updatesFrequently)
                                        }
                                        Button {
                                            retryRecentRecording()
                                        } label: {
                                            Label("Retry Recently Added playback", systemImage: "arrow.clockwise")
                                                .frame(minHeight: 44, alignment: .leading)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(audioImportBusy || scenePhase != .active)
                                        .accessibilityHint(audioImportBusy
                                            ? "Wait for the local audio import to finish"
                                            : "Recheck the restored local recording without downloading audio")
                                        Button {
                                            presentAudioImporter()
                                        } label: {
                                            Label("Restore Recently Added audio", systemImage: "square.and.arrow.down")
                                                .frame(minHeight: 44, alignment: .leading)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(audioImportBusy || scenePhase != .active)
                                        .accessibilityHint(audioImportBusy
                                            ? "Wait for the current import to finish"
                                            : "Choose a replacement audio file from Files, then retry the recording")
                                    }
                                }
                            }
                        }
                    }
                    filterControls

                    VStack(alignment: .leading, spacing: 13) {
                        Group {
                            if dynamicTypeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 8) {
                                    PremiumSectionHeading(title: favoritesOnly ? "Loved tracks" : "Your library",
                                                          detail: "\(visibleTracks.count) songs")
                                    sortMenu
                                }
                            } else {
                                HStack(spacing: 12) {
                                    PremiumSectionHeading(title: favoritesOnly ? "Loved tracks" : "Your library",
                                                          detail: "\(visibleTracks.count) songs")
                                    Spacer(minLength: 8)
                                    sortMenu
                                }
                            }
                        }
                        browsingPlaybackControls(hasResults: !visibleTracks.isEmpty)
                        bulkPlaybackFeedback
                        if visibleTracks.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                EmptyShelfView(
                                    title: "No favorites yet",
                                    subtitle: "Tap the heart on a song to collect it here.",
                                    symbol: "heart")
                                Button {
                                    favoritesOnly = false
                                } label: {
                                    Label("Show all music", systemImage: "music.note.list")
                                        .frame(minHeight: 44)
                                }
                                .buttonStyle(.bordered)
                                .tint(ShelfTheme.accent)
                                .accessibilityHint("Switch from Favorites to all saved songs")
                            }
                        } else {
                            LazyVStack(spacing: 9) {
                                // A restored archive may contain duplicate recording UUIDs.
                                // Index-based ForEach keeps both rows visible instead of
                                // collapsing them into one SwiftUI identity. The explicit
                                // row identity also resets pending destructive/async row
                                // state when sorting moves a different file into a slot.
                                ForEach(Array(visibleTracks.enumerated()), id: \.offset) { offset, track in
                                    MusicTrackRow(track: track, context: visibleTracks, importBlocked: audioImportBusy,
                                                  renaming: $renaming)
                                        .id(RecordingRowIdentity(position: offset, track: track,
                                                                 url: library.fileURL(for: track)))
                                }
                            }
                        }
                    }
                }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .task(id: OfflineCountRefreshKey(
            recordingLocations: library.tracks.map {
                RecordingLocationKey(id: $0.id, url: library.fileURL(for: $0))
            },
            scenePhase: scenePhase,
            manualRefresh: offlineCountRefreshRequest,
            isImporting: library.isImporting,
            isPickingFiles: showFilePicker,
            isLocalImportPending: importInProgress
        )) {
            // Picker and local-import state must invalidate an in-flight scan
            // even before MusicLibrary publishes its own isImporting flag.
            guard scenePhase == .active, !audioImportBusy else {
                offlineRecordingCount = nil
                return
            }
            offlineRecordingCount = nil
            await refreshOfflineRecordingCount()
        }
        .background(PremiumBackdrop())
        .alert("Recording unavailable", isPresented: $missingRecentRecording) {
            if recentRetrySelection != nil && !audioImportBusy && scenePhase == .active {
                Button("Retry playback") { retryRecentRecording() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(recentPlaybackNotice ?? "The selected recording is unavailable or the Recently Added queue changed. Your library entry is preserved. Retry after restoring the recording.")
        }
         .onDisappear {
            cancelRecentPlaybackPreparation(showFeedback: false)
            cancelBulkPlaybackPreparation(showFeedback: false)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            // A phone call or lock interrupts local-file validation. Keep the
            // original recording and Play/Shuffle intent available for a
            // deliberate retry when the user returns; never auto-start audio.
            let interruptedRecent = recentPlaybackCheck != nil
            let interruptedBulk = bulkPlaybackPending
            cancelRecentPlaybackPreparation(showFeedback: interruptedRecent)
            cancelBulkPlaybackPreparation(showFeedback: interruptedBulk)
            if interruptedRecent {
                recentPlaybackNotice = "Playback was interrupted when MP3 Shelf became inactive. Retry after returning to the app."
            }
            if interruptedBulk {
                bulkPlaybackNotice = "Playback was interrupted when MP3 Shelf became inactive. Retry to check the current selection."
            }
        }
        .onChange(of: library.isImporting) { _, importing in
            // Imports can start from another screen. Invalidate outstanding
            // file snapshots before a replacement recording is written.
            if importing {
                cancelRecentPlaybackPreparation(showFeedback: true)
                cancelBulkPlaybackPreparation(showFeedback: true)
            } else if !importInProgress {
                markPartialQueueReadyForManualRefresh()
            }
        }
        .navigationTitle("MP3 Shelf")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search songs, artists or albums")
        .onChange(of: searchText) { _, _ in browsingScopeDidChange() }
        .onChange(of: favoritesOnly) { _, _ in browsingScopeDidChange() }
        .onChange(of: sortMode) { _, _ in browsingScopeDidChange() }
        .onChange(of: library.tracks.map { RecordingPlaybackSnapshot($0, url: library.fileURL(for: $0)) }) { _, _ in
            // A Files import is an intentional library mutation. Preserve its
            // partial-queue recovery until the import report is available;
            // completion will bind recovery to the new visible selection.
            // All other mutations still invalidate obsolete playback intent.
            if !importInProgress {
                invalidateStalePlaybackRecovery()
            }
            recentLibrarySelectionDidChange()
        }
        .onSubmit(of: .search) { submitSearch() }
        .task(id: searchText) {
            // Clearing or whitespace-only input restores the full library
            // immediately; nonempty queries debounce until typing settles.
            let requestedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !requestedQuery.isEmpty {
                do {
                    try await Task.sleep(for: .milliseconds(220))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, searchText.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery else { return }
            settledSearchText = searchText
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if importInProgress || library.isImporting {
                    ProgressView()
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Importing local audio files")
                        .accessibilityAddTraits(.updatesFrequently)
                } else {
                    Button { presentAudioImporter() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(ShelfTheme.accent)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Import audio files")
                    .accessibilityHint("Choose audio files stored on your iPhone")
                }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                // Closing Files or selecting nothing must not cancel a playback
                // check or discard its retry state. Only a real import can
                // replace a recording being validated for playback.
                guard !urls.isEmpty, !importInProgress else { return }
                cancelRecentPlaybackPreparation(showFeedback: true)
                cancelBulkPlaybackPreparation(showFeedback: true)
                importInProgress = true
                Task { @MainActor in
                    let outcome = await library.importAudio(urls: urls)
                    // Importing unrelated songs can expand a search or the
                    // unfiltered Library. Never rebind an old partial queue to
                    // those new results: Refresh would silently play a different
                    // selection from the one the listener originally requested.
                    // An exact match may still offer an explicit local recheck.
                    if bulkSkippedRecordingCount > 0, partialQueueShuffle != nil,
                       !playbackSelectionIsCurrent() {
                        bulkSkippedRecordingCount = 0
                        partialQueueShuffle = nil
                        partialQueueNeedsRefresh = false
                        bulkRetryShuffle = nil
                        playbackSelectionSnapshot = nil
                        bulkPlaybackNotice = "Your library selection changed during import. Choose Play or Shuffle to check the new songs. The current queue is unchanged."
                    } else {
                        completeLocalAudioImport(importedCount: outcome.imported,
                                                 skippedCount: outcome.skipped,
                                                 failureCount: outcome.errors.count)
                    }
                    importInProgress = false
                    message = outcome.description
                }
            case .failure(let error):
                // Dismissing Files is not an import failure.
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain ||
                    nsError.code != CocoaError.userCancelled.rawValue {
                    message = error.localizedDescription
                }
            }
        }
        .alert("Import Result", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .sheet(item: $renaming) { track in RenameTrackView(track: track) }
    }

    private func filterButton(_ label: String, symbol: String? = nil,
                              selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol) }
                Text(label)
            }
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(selected ? ShelfTheme.background : .white.opacity(0.82))
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(selected ? ShelfTheme.accent : ShelfTheme.elevated,
                        in: Capsule())
            .overlay(Capsule().strokeBorder(
                selected ? ShelfTheme.accent : ShelfTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "Currently showing \(label.lowercased())" : "Show \(label.lowercased())")
    }
}

struct MusicTrackRow: View {
    let track: MusicTrack
    let context: [MusicTrack]
    var importBlocked: Bool = false
    @Binding var renaming: MusicTrack?
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @State private var confirmDelete = false
    // Bind destructive confirmation to the exact recording visible when opened.
    // A restore can replace the file URL while the dialog is on screen.
    @State private var pendingDeleteURL: URL?
    // A restore may replace the bytes at the SAME URL. Preserve file metadata
    // as well as the location before offering a destructive confirmation.
    @State private var pendingDeleteFingerprint: RecordingFingerprint?

    private struct RecordingFingerprint: Equatable {
        let size: UInt64
        let modified: Date?
        let created: Date?
        let volume: UInt64
        let fileNumber: UInt64

        init?(url: URL) {
            // Size and modification time alone do not identify a file. A restore
            // can replace a recording with equally sized bytes and preserved
            // timestamps while an old Delete confirmation is still visible.
            // The sandbox recording must be a regular local file with a stable
            // filesystem identity before a destructive action is authorized.
            guard url.isFileURL,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  size > 0,
                  let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                  let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
                return nil
            }
            self.size = size
            self.modified = attributes[.modificationDate] as? Date
            self.created = attributes[.creationDate] as? Date
            self.volume = volume
            self.fileNumber = fileNumber
        }
    }
    @State private var missingRecordingAlert = false
    @State private var playbackNotice: String?
    @State private var recoveryReason = "The local recording is unavailable."
    @State private var audioAvailability: Bool?
    @State private var isCheckingPlayback = false
    @State private var playbackCheckTask: Task<Void, Never>?
    @State private var playbackCheckGeneration: UUID?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    // File metadata is checked off the main actor. A nil snapshot means the
    // row has not been scanned, not that the recording is missing.
    nonisolated private static func isUsableRecording(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize else { return false }
        return size > 0
    }

    // A restored library can reuse a track UUID and file URL for different
    // metadata. Never let a stale row authorize a destructive action.
    private func matchesVisibleRecording(_ candidate: MusicTrack) -> Bool {
        candidate.id == track.id &&
        candidate.title == track.title &&
        candidate.artist == track.artist &&
        candidate.album == track.album &&
        candidate.duration == track.duration &&
        library.fileURL(for: candidate) == library.fileURL(for: track)
    }

    // VoiceOver custom actions and menu actions must share the same mutation
    // gate. A restored library can reuse a UUID while the row is still visible.
    private func currentEditableRecording() -> MusicTrack? {
        guard scenePhase == .active, !library.isImporting, !importBlocked else {
            playbackNotice = "Wait until the app is active and audio import finishes before editing this song."
            return nil
        }
        let matches = library.tracks.filter { $0.id == track.id }
        guard matches.count == 1, matchesVisibleRecording(matches[0]) else {
            playbackNotice = "This recording changed in your library. Reopen the current song before editing."
            return nil
        }
        return matches[0]
    }

    private func toggleCurrentFavorite() {
        guard let current = currentEditableRecording() else { return }
        library.toggleFavorite(current.id)
        // Never claim success for an ambiguous or replaced recording.
        let updated = library.tracks.filter { $0.id == current.id }
        if updated.count != 1 || !matchesVisibleRecording(updated[0]) {
            playbackNotice = "The library changed while updating favorites. Review the current song."
        }
    }

    private func editCurrentRecording() {
        guard let current = currentEditableRecording() else { return }
        renaming = current
    }

    private func requestDeleteConfirmation() {
        guard !library.isImporting, !importBlocked, scenePhase == .active else { return }
        // Never authorize a stale row that has already been removed or replaced.
        let current = library.tracks.filter { $0.id == track.id }
        guard current.count == 1, matchesVisibleRecording(current[0]) else {
            playbackNotice = "This song changed in your library. Reopen it before deleting."
            return
        }
        let url = library.fileURL(for: current[0])
        guard let fingerprint = RecordingFingerprint(url: url) else {
            playbackNotice = "The local audio file is unavailable. Nothing was deleted."
            return
        }
        pendingDeleteURL = url
        pendingDeleteFingerprint = fingerprint
        confirmDelete = true
    }

    private func confirmExactRecordingDeletion() {
        defer {
            pendingDeleteURL = nil
            pendingDeleteFingerprint = nil
        }
        guard !library.isImporting, !importBlocked, scenePhase == .active,
              let expectedURL = pendingDeleteURL,
              let expectedFingerprint = pendingDeleteFingerprint else { return }
        let current = library.tracks.filter { $0.id == track.id }
        guard current.count == 1,
              matchesVisibleRecording(current[0]),
              library.fileURL(for: current[0]) == expectedURL,
              RecordingFingerprint(url: expectedURL) == expectedFingerprint else {
            playbackNotice = "The recording changed while confirming deletion. Nothing was deleted."
            return
        }
        if playback.currentTrackID == track.id { playback.stop() }
        library.removeTrack(track.id)
    }

    private var availabilityRefreshKey: String {
        "\(library.fileURL(for: track).path)|\(scenePhase)|\(library.isImporting)|\(importBlocked)"
    }

    private func refreshAudioAvailability() async {
        audioAvailability = nil
        guard !library.isImporting, !importBlocked, scenePhase == .active else { return }
        let url = library.fileURL(for: track)
        let scan = Task.detached(priority: .utility) {
            Self.isUsableRecording(at: url)
        }
        let available = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        guard !Task.isCancelled, !library.isImporting, !importBlocked, scenePhase == .active else { return }
        audioAvailability = available
    }

    private func playOrExplainMissingAudio() {
        // A duplicated track ID must not allow one usable file to make a
        // different, missing occurrence appear playable.
        guard !isCheckingPlayback, !library.isImporting, !importBlocked, scenePhase == .active else { return }
        isCheckingPlayback = true
        playbackNotice = nil
        missingRecordingAlert = false
        let generation = UUID()
        playbackCheckGeneration = generation
        let selectedURL = library.fileURL(for: track)
        let queueSnapshot = context.map { ($0.id, library.fileURL(for: $0)) }
        // Restores can reuse a recording UUID and URL while replacing metadata.
        // Capture the complete visible selection before the asynchronous scan.
        let queueMetadata = context.map { ($0.title, $0.artist, $0.album, $0.duration) }
        // Capture the complete visible queue identity. A restore can retain a
        // UUID while relocating its file, so comparing IDs alone is insufficient.
        let requestedQueue = queueSnapshot.map { RecordingLocationKey(id: $0.0, url: $0.1) }
        playbackCheckTask = Task {
            let scan = Task.detached(priority: .userInitiated) { () -> [Bool] in
                var results: [Bool] = []
                results.reserveCapacity(queueSnapshot.count)
                for (_, url) in queueSnapshot {
                    if Task.isCancelled { return [] }
                    results.append(Self.isUsableRecording(at: url))
                }
                return results
            }
            let playable = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard !Task.isCancelled, playbackCheckGeneration == generation,
                  !library.isImporting, !importBlocked, scenePhase == .active else { return }
            playbackCheckGeneration = nil
            isCheckingPlayback = false
            playbackCheckTask = nil
            // A restore, deletion, or playlist edit invalidates the requested
            // queue. Validate every occurrence, not only its UUID.
            guard playable.count == queueSnapshot.count,
                  context.map({ RecordingLocationKey(id: $0.id, url: library.fileURL(for: $0)) }) == requestedQueue,
                  let currentTrack = library.tracks.first(where: {
                      $0.id == track.id && library.fileURL(for: $0) == selectedURL &&
                      $0.title == track.title && $0.artist == track.artist &&
                      $0.album == track.album && $0.duration == track.duration
                  }) else {
                audioAvailability = false
                recoveryReason = "The song or its location changed while checking offline audio. Retry to use the current library."
                missingRecordingAlert = true
                return
            }
            // The selected row must still belong to this exact queue. A row
            // reused after filtering or a playlist edit must not start a track
            // that is absent from the listener's current selection.
            guard requestedQueue.contains(RecordingLocationKey(id: track.id, url: selectedURL)) else {
                audioAvailability = false
                recoveryReason = "This song is no longer in the selected queue. Choose it again to play the updated selection."
                missingRecordingAlert = true
                return
            }
            // PlaybackController resolves tracks by UUID, so even two entries
            // with identical UUID and URL are ambiguous. Refuse to play either
            // occurrence rather than silently selecting the first recording.
            // Also require every selected queue occurrence to be unique.
            var currentByLocation: [RecordingLocationKey: MusicTrack] = [:]
            var seenRecordingIDs = Set<UUID>()
            currentByLocation.reserveCapacity(library.tracks.count)
            seenRecordingIDs.reserveCapacity(library.tracks.count)
            for current in library.tracks {
                guard seenRecordingIDs.insert(current.id).inserted else {
                    audioAvailability = false
                    recoveryReason = "Duplicate recording identities were found. Resolve the duplicates before playing."
                    missingRecordingAlert = true
                    return
                }
                let key = RecordingLocationKey(id: current.id, url: library.fileURL(for: current))
                currentByLocation[key] = current
            }
            // Playlists may intentionally contain the same recording more than
            // once. Keep those occurrences in queue order, but never permit a
            // repeated UUID to resolve to different files. The library-wide
            // uniqueness check above still rejects ambiguous restored records.
            var selectedLocations: [UUID: URL] = [:]
            selectedLocations.reserveCapacity(queueSnapshot.count)
            for (id, url) in queueSnapshot {
                if let existingURL = selectedLocations[id], existingURL != url {
                    audioAvailability = false
                    recoveryReason = "This selection contains conflicting recording locations. Reopen the playlist before playing."
                    missingRecordingAlert = true
                    return
                }
                selectedLocations[id] = url
            }
            var queue: [MusicTrack] = []
            queue.reserveCapacity(context.count)
            var changedRecording = false
            for index in context.indices {
                let entry = context[index]
                let originalURL = queueSnapshot[index].1
                guard let current = currentByLocation[
                    RecordingLocationKey(id: entry.id, url: originalURL)
                ] else {
                    changedRecording = true
                    break
                }
                let metadata = queueMetadata[index]
                guard current.title == metadata.0,
                      current.artist == metadata.1,
                      current.album == metadata.2,
                      current.duration == metadata.3 else {
                    changedRecording = true
                    break
                }
                if playable[index] { queue.append(current) }
            }
            guard !changedRecording else {
                audioAvailability = false
                recoveryReason = "A recording changed during playback preparation. Retry to use the current library."
                missingRecordingAlert = true
                return
            }
            // The selected occurrence must itself be usable. Another row
            // sharing the same ID is not evidence that this file exists.
            guard queueSnapshot.indices.contains(where: { index in
                queueSnapshot[index].0 == track.id &&
                queueSnapshot[index].1 == selectedURL &&
                playable[index]
            }) else {
                audioAvailability = false
                recoveryReason = "This recording is missing or empty. Restore its audio file and retry."
                missingRecordingAlert = true
                return
            }
            audioAvailability = true
            playback.play(currentTrack, queue: queue)
            let skipped = context.count - queue.count
            if skipped > 0 {
                playbackNotice = "\(skipped) unavailable \(skipped == 1 ? "recording was" : "recordings were") skipped. Playing \(queue.count) available \(queue.count == 1 ? "song" : "songs")."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 12) {
            Button { playOrExplainMissingAudio() } label: {
                HStack(spacing: 12) {
                    ArtworkTile(track: track)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(ShelfTheme.subdued)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    }
                    Spacer(minLength: 0)
                    if isCheckingPlayback {
                        ProgressView()
                            .accessibilityHidden(true)
                    } else if audioAvailability == false {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(ShelfTheme.coral)
                            .accessibilityHidden(true)
                    }
                    if track.id == playback.currentTrackID {
                        Image(systemName: "waveform")
                            .font(.caption.bold())
                            .foregroundStyle(ShelfTheme.mint)
                            .accessibilityLabel("Now playing")
                    } else {
                        Text(track.duration.shelfClock)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ShelfTheme.subdued)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isCheckingPlayback || library.isImporting || importBlocked || scenePhase != .active)
            .accessibilityLabel(library.isImporting || importBlocked
                                ? "Importing audio: \(track.title) by \(track.artist)"
                                : isCheckingPlayback
                                ? "Checking recording: \(track.title) by \(track.artist)"
                                : audioAvailability == false
                                ? "Audio missing: \(track.title) by \(track.artist)"
                                : track.id == playback.currentTrackID
                                ? "Now playing: \(track.title) by \(track.artist)"
                                : "Play \(track.title) by \(track.artist)")
            .accessibilityValue(track.duration.shelfClock)
            .accessibilityHint(library.isImporting || importBlocked
                               ? "Wait until audio import finishes before playing this recording"
                               : isCheckingPlayback
                               ? "Checking that the local audio file is ready to play"
                               : audioAvailability == false
                               ? "The local recording is unavailable. Double tap for recovery information."
                               : track.id == playback.currentTrackID
                               ? "Restart the current song"
                               : "Start playback from this song")
            // The row's playback button is the primary VoiceOver element.
            // Expose its management actions without requiring navigation to
            // the separate, visually small ellipsis menu.
            .accessibilityAction(named: track.isFavorite ? "Remove from favorites" : "Add to favorites") {
                toggleCurrentFavorite()
            }
            .accessibilityAction(named: "Edit song details") {
                editCurrentRecording()
            }
            .accessibilityAction(named: "Delete download") {
                requestDeleteConfirmation()
            }
            Menu {
                Button { toggleCurrentFavorite() } label: {
                    Label(track.isFavorite ? "Remove favorite" : "Favorite", systemImage: track.isFavorite ? "heart.slash" : "heart")
                }
                if library.playlists.isEmpty {
                    Text("Create a playlist first to add songs")
                } else {
                    // A restored library can contain thousands of playlists and
                    // duplicate UUIDs. Count once per menu evaluation rather than
                    // scanning the whole collection for every destination.
                    // Include hidden/unfiltered destinations in collision checks.
                    let playlistIdentityCounts = library.playlists.reduce(into: [UUID: Int]()) { counts, playlist in
                        counts[playlist.id, default: 0] += 1
                    }
                    Menu("Add to Playlist", systemImage: "text.badge.plus") {
                        // Restored archives may contain duplicate playlist IDs.
                        // Never let a menu action silently mutate the first match.
                        // Enumerated positions keep SwiftUI menu identity distinct
                        // even when the persisted UUIDs collide.
                        ForEach(Array(library.playlists.enumerated()), id: \.offset) { _, list in
                            let matchingCount = playlistIdentityCounts[list.id, default: 0]
                            Button {
                                // Revalidate at tap time: imports and restores can
                                // change identities while the menu is presented.
                                // The menu can remain open across a library restore.
                                // Recheck both the recording's on-disk identity and
                                // the destination snapshot before mutating user data.
                                // A reused UUID must never authorize a different
                                // recording or a replacement playlist.
                                guard !library.isImporting,
                                      let currentPlaylist = library.playlists.first(where: { $0.id == list.id }),
                                      library.playlists.filter({ $0.id == list.id }).count == 1,
                                      currentPlaylist.name == list.name,
                                      currentPlaylist.trackIDs == list.trackIDs,
                                      currentPlaylist.missingTracks == list.missingTracks,
                                      let currentTrack = library.tracks.first(where: { $0.id == track.id }),
                                      library.tracks.filter({ $0.id == track.id }).count == 1,
                                      library.fileURL(for: currentTrack) == library.fileURL(for: track),
                                      currentTrack.title == track.title,
                                      currentTrack.artist == track.artist,
                                      currentTrack.album == track.album,
                                      currentTrack.duration == track.duration,
                                      scenePhase == .active,
                                      !importBlocked
                                else {
                                    recoveryReason = "The library or app state changed while choosing a playlist. Return to MP3 Shelf and reopen the menu to select the current recording and destination."
                                    missingRecordingAlert = true
                                    return
                                }
                                // An already-saved song is not a new addition.
                                // Tell the user what happened rather than silently closing
                                // the menu, especially when using VoiceOver.
                                if currentPlaylist.trackIDs.contains(track.id) {
                                    playbackNotice = "\(currentTrack.title) is already in \(currentPlaylist.name)."
                                    return
                                }
                                library.addTrack(track.id, to: list.id)
                                // A restore/import can replace the destination while the
                                // action is running. Do not report success unless the
                                // exact destination snapshot still owns the new song.
                                let destinations = library.playlists.filter { $0.id == list.id }
                                let expectedTrackIDs = currentPlaylist.trackIDs + [track.id]
                                if destinations.count == 1,
                                   let saved = destinations.first,
                                   saved.name == currentPlaylist.name,
                                   saved.missingTracks == currentPlaylist.missingTracks,
                                   saved.trackIDs == expectedTrackIDs {
                                    playbackNotice = "Added \(currentTrack.title) to \(currentPlaylist.name)."
                                } else {
                                    playbackNotice = "Could not add the song to this playlist. Review the library and retry."
                                }
                            } label: {
                                Label(list.name,
                                      systemImage: matchingCount == 1 ? "text.badge.plus" : "exclamationmark.triangle")
                            }
                            .disabled(matchingCount != 1 || library.isImporting)
                            .accessibilityHint(matchingCount != 1
                                ? "Duplicate playlist identity. Adding songs is unavailable until repaired."
                                : library.isImporting
                                ? "Wait until the audio import finishes."
                                : "Add this recording to the selected playlist.")
                        }
                    }
                    .disabled(library.isImporting)
                }
                Button("Edit Details", systemImage: "pencil") { editCurrentRecording() }
                if audioAvailability == true {
                    ShareLink(item: library.fileURL(for: track)) {
                        Label("Share Audio File", systemImage: "square.and.arrow.up")
                    }
                }
                if let attribution = track.sourceAttribution {
                    if let sourceURL = URL(string: attribution.pageURL) {
                        Link(destination: sourceURL) {
                            Label("View Audio Source", systemImage: "link")
                        }
                    }
                    if let licenseURL = URL(string: attribution.licenseURL), licenseURL.scheme == "https" {
                        Link(destination: licenseURL) {
                            Label("View Source License", systemImage: "doc.text")
                        }
                    }
                }
                Divider()
                Button("Delete Download", systemImage: "trash", role: .destructive) {
                    requestDeleteConfirmation()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(ShelfTheme.subdued)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(library.isImporting || importBlocked || scenePhase != .active)
            .accessibilityLabel("More options for \(track.title) by \(track.artist)")
            .accessibilityHint("Favorite, add to playlist, edit, share or delete this download")
        }
        if isCheckingPlayback {
            HStack(spacing: 10) {
                ProgressView()
                    .accessibilityHidden(true)
                Text("Checking local recordings…")
                    .font(.caption)
                    .foregroundStyle(ShelfTheme.subdued)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    playbackCheckGeneration = nil
                    playbackCheckTask?.cancel()
                    playbackCheckTask = nil
                    isCheckingPlayback = false
                    playbackNotice = "Playback check cancelled. Your recordings are unchanged."
                } label: {
                    Label("Cancel check", systemImage: "xmark.circle")
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Stop checking local recordings without changing saved audio")
            }
            .accessibilityElement(children: .contain)
        }
        if let playbackNotice {
            Text(playbackNotice)
                .font(.caption)
                .foregroundStyle(ShelfTheme.mint)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(track.id == playback.currentTrackID
                    ? ShelfTheme.accent.opacity(0.13) : ShelfTheme.surface,
                    in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(track.id == playback.currentTrackID
                          ? ShelfTheme.accent.opacity(0.34) : ShelfTheme.border, lineWidth: 1))
        .task(id: availabilityRefreshKey) {
            await refreshAudioAvailability()
        }
        .onChange(of: availabilityRefreshKey) { _, _ in
            // Invalidate selection when a restore changes the recording path
            // or the app moves between foreground and background.
            playbackCheckGeneration = nil
            playbackCheckTask?.cancel()
            playbackCheckTask = nil
            isCheckingPlayback = false
            missingRecordingAlert = false
        }
        .onDisappear {
            playbackCheckGeneration = nil
            playbackCheckTask?.cancel()
            playbackCheckTask = nil
            isCheckingPlayback = false
        }
        .alert("Recording unavailable", isPresented: $missingRecordingAlert) {
            if !isCheckingPlayback && !library.isImporting && !importBlocked && scenePhase == .active {
                Button("Retry playback") { playOrExplainMissingAudio() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(recoveryReason) Your library entry and playlists are unchanged." +
                 (library.isImporting || importBlocked ? " Wait until audio import finishes before retrying." :
                  scenePhase != .active ? " Return to MP3 Shelf before retrying." : ""))
        }
        .confirmationDialog("Delete downloaded song?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Song", role: .destructive) {
                confirmExactRecordingDeletion()
            }
        } message: { Text("This removes the local audio file and its entries from playlists. If the file is replaced or changes before confirmation, nothing will be deleted.") }
    }
}

struct RenameTrackView: View {
    let track: MusicTrack
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var editError: String?
    @State private var requiresLatestSongReload = false
    @AccessibilityFocusState private var errorFocused: Bool
    @State private var showReloadConfirmation = false
    @State private var showCancelConfirmation = false
    @State private var originalRecordingURL: URL?
    @State private var originalTitle = ""
    @State private var originalArtist = ""
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var titleFocused: Bool

    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanArtist: String { artist.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasUnsavedChanges: Bool { title != originalTitle || artist != originalArtist }

    // Keep drafts safe when the user leaves the editor via the toolbar.
    // Cancelling is never a metadata or audio write.
    private func requestDismissal() {
        if hasUnsavedChanges {
            showCancelConfirmation = true
        } else {
            dismiss()
        }
    }

    // A track can disappear while this sheet is open (for example after a
    // library restore). Never silently dismiss an edit that did not apply.
    private func saveEdit() {
        guard !cleanTitle.isEmpty else {
            editError = "Enter a song title before saving."
            titleFocused = true
            return
        }
        // Restores can introduce duplicate track IDs with different recordings.
        // A first(where:) lookup would silently edit an arbitrary copy.
        let matchingTracks = library.tracks.filter { $0.id == track.id }
        guard let current = matchingTracks.first else {
            reportEditFailure("This song is no longer in your library. Your changes were not saved.", requiresReload: true)
            return
        }
        guard matchingTracks.count == 1 else {
            reportEditFailure("Multiple songs share this recording ID. Nothing was changed. Resolve the duplicate recordings before editing.", requiresReload: true)
            return
        }
        // The editor owns a snapshot, not the current library revision. A
        // restore, import, or second editor may replace it while this sheet is
        // open. Never overwrite that newer recording or its metadata.
        guard !library.isImporting, scenePhase == .active else {
            editError = "Return to MP3 Shelf after the audio import finishes, then reopen this song to review its details."
            return
        }
        guard current.title == originalTitle,
              current.artist == originalArtist,
              originalRecordingURL == library.fileURL(for: current) else {
            reportEditFailure("This song changed while you were editing. Reload the latest song details before saving. Nothing was overwritten.", requiresReload: true)
            return
        }
        if current.title == cleanTitle && current.artist == cleanArtist {
            dismiss()
            return
        }
        library.rename(current, title: cleanTitle, artist: cleanArtist)
        let updatedMatches = library.tracks.filter { $0.id == track.id }
        guard updatedMatches.count == 1, let updated = updatedMatches.first,
              updated.title == cleanTitle && updated.artist == cleanArtist else {
            reportEditFailure("The song could not be verified after saving. Reload the latest song details before trying another edit.", requiresReload: true)
            return
        }
        dismiss()
    }

    // Preserve stale-library warnings until the user explicitly reloads. Clearing
    // them on every keystroke hides the only recovery action and encourages
    // repeated writes against an outdated snapshot.
    private func reportEditFailure(_ message: String, requiresReload: Bool = false) {
        editError = message
        requiresLatestSongReload = requiresReload
        errorFocused = true
    }

    private func clearTransientValidationError() {
        guard !requiresLatestSongReload else { return }
        editError = nil
    }

    // Explicit reload is the only operation that discards an unsaved draft.
    // A restored or concurrently edited song can be recovered in-place.
    private func reloadCurrentSong() {
        guard !library.isImporting, scenePhase == .active else {
            editError = "Wait for the import to finish before reloading this song."
            return
        }
        let matches = library.tracks.filter { $0.id == track.id }
        guard matches.count == 1, let current = matches.first else {
            editError = matches.isEmpty
                ? "This song is no longer in your library. Your draft is still here."
                : "Multiple songs share this recording ID. Your draft is still here; resolve the duplicate first."
            return
        }
        originalTitle = current.title
        originalArtist = current.artist
        originalRecordingURL = library.fileURL(for: current)
        title = current.title
        artist = current.artist
        editError = nil
        requiresLatestSongReload = false
        errorFocused = false
        titleFocused = true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Song details") {
                    TextField("Song title", text: $title)
                        .focused($titleFocused)
                        .submitLabel(.next)
                        .accessibilityIdentifier("edit-song-title")
                    TextField("Artist", text: $artist)
                        .submitLabel(.done)
                        .accessibilityIdentifier("edit-song-artist")
                }
                if let editError {
                    Section {
                        Text(editError)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.updatesFrequently)
                            .accessibilityFocused($errorFocused)
                            .accessibilityIdentifier("edit-song-error")
                        if !requiresLatestSongReload {
                            Button("Try saving again", action: saveEdit)
                                .disabled(cleanTitle.isEmpty || library.isImporting || scenePhase != .active)
                                .frame(minHeight: 44)
                        }
                        Button("Reload latest song details") {
                            if title != originalTitle || artist != originalArtist {
                                showReloadConfirmation = true
                            } else {
                                reloadCurrentSong()
                            }
                        }
                            .disabled(library.isImporting || scenePhase != .active)
                            .frame(minHeight: 44)
                            .accessibilityHint("Review the latest library metadata; unsaved edits require confirmation")
                            .accessibilityIdentifier("edit-song-reload-latest")
                    }
                }
                Section {
                    Text("Changes affect your local library only, not the audio file's ID3 tags.")
                        .foregroundStyle(ShelfTheme.subdued)
                        .font(.caption)
                }
            }
            .navigationTitle("Edit Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: requestDismissal)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityHint(hasUnsavedChanges ? "Review before discarding your unsaved song details" : "Close song editing")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: saveEdit)
                        .disabled(cleanTitle.isEmpty || requiresLatestSongReload || library.isImporting || scenePhase != .active)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityHint(requiresLatestSongReload ? "Reload the latest song details before saving" : "Save song title and artist")
                }
            }
            // Keep the sheet open while a title/artist draft is modified.
            // Explicit Cancel still offers Keep editing or Discard changes;
            // unchanged drafts retain the standard swipe gesture.
            .interactiveDismissDisabled(hasUnsavedChanges)
            .onAppear {
                title = track.title
                artist = track.artist
                originalTitle = track.title
                originalArtist = track.artist
                originalRecordingURL = library.fileURL(for: track)
            }
            .onChange(of: title) { _, _ in clearTransientValidationError() }
            .onChange(of: artist) { _, _ in clearTransientValidationError() }
            .alert("Discard changes to this song?", isPresented: $showCancelConfirmation) {
                Button("Keep editing", role: .cancel) {}
                Button("Discard changes", role: .destructive) { dismiss() }
            } message: {
                Text("Your edited title and artist have not been saved. Keep editing to preserve your draft; discarding will not delete or modify the audio recording.")
            }
            .confirmationDialog(
                "Discard your unsaved song edits?",
                isPresented: $showReloadConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard edits and reload", role: .destructive) {
                    reloadCurrentSong()
                }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Reloading replaces your draft title and artist with the latest library details. Your audio recording will not be changed.")
            }
        }
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var playlistQuery = ""
    @AccessibilityFocusState private var playlistResultsFocused: Bool
    @State private var sortAlphabetically = false
    @State private var pendingRename: MusicPlaylist?
    @State private var renamedName = ""
    @State private var showCreate = false
    @State private var newName = ""
    @State private var pendingDelete: MusicPlaylist?
    @State private var playlistActionFeedback: String?
    @State private var failedPlaylistEdit: FailedPlaylistEdit?
    @AccessibilityFocusState private var playlistFeedbackFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum FailedPlaylistEdit {
        case create
        case copy(snapshot: MusicPlaylist)
        case rename(snapshot: MusicPlaylist)
        case delete(snapshot: MusicPlaylist)
    }

    // Restore the original input when a failed write is retried instead of
    // requiring the user to reconstruct a playlist name.
    private func retryPlaylistEdit() {
        guard let failedPlaylistEdit else { return }
        // A retry must not silently apply an old desired name to a playlist
        // restored or edited after the failed write. Keep the failure visible
        // until the user explicitly reviews the latest playlist state.
        switch failedPlaylistEdit {
        case .create:
            guard !library.isImporting else {
                playlistActionFeedback = "Finish importing audio before retrying playlist creation. Your name is saved."
                return
            }
            playlistActionFeedback = nil
            self.failedPlaylistEdit = nil
            showCreate = true
        case .copy(let snapshot):
            guard !library.isImporting else {
                playlistActionFeedback = "Finish importing audio before retrying this copy."
                return
            }
            guard let current = uniquePlaylist(withID: snapshot.id),
                  current.name == snapshot.name,
                  current.trackIDs == snapshot.trackIDs,
                  current.missingTracks == snapshot.missingTracks else {
                self.failedPlaylistEdit = nil
                playlistActionFeedback = "This playlist changed or was removed. Review its latest songs before copying."
                return
            }
            self.failedPlaylistEdit = nil
            playlistActionFeedback = nil
            copyPlaylist(current)
        case .rename(let snapshot):
            guard !library.isImporting else {
                playlistActionFeedback = "Finish importing audio before retrying this rename."
                return
            }
            guard let current = uniquePlaylist(withID: snapshot.id) else {
                self.failedPlaylistEdit = nil
                playlistActionFeedback = "This playlist is no longer available. Review your playlists before renaming."
                return
            }
            guard current.name == snapshot.name,
                  current.trackIDs == snapshot.trackIDs,
                  current.missingTracks == snapshot.missingTracks else {
                self.failedPlaylistEdit = nil
                playlistActionFeedback = "This playlist changed after the failed rename. Review its latest name and songs before editing again."
                return
            }
            playlistActionFeedback = nil
            self.failedPlaylistEdit = nil
            pendingRename = current
        case .delete(let snapshot):
            guard !library.isImporting else {
                playlistActionFeedback = "Finish importing audio before retrying deletion. Nothing was deleted."
                return
            }
            guard let current = uniquePlaylist(withID: snapshot.id),
                  current.name == snapshot.name,
                  current.trackIDs == snapshot.trackIDs,
                  current.missingTracks == snapshot.missingTracks else {
                self.failedPlaylistEdit = nil
                playlistActionFeedback = "This playlist changed or was removed. Review the current playlist before deleting anything."
                return
            }
            // A retry never deletes immediately: the user must confirm again.
            self.failedPlaylistEdit = nil
            playlistActionFeedback = nil
            pendingDelete = current
        }
    }

    // A restored archive may contain duplicate playlist IDs. Never route a
    // destructive or mutating action to an arbitrary first match.
    private func uniquePlaylist(withID id: UUID) -> MusicPlaylist? {
        let matches = library.playlists.filter { $0.id == id }
        return matches.count == 1 ? matches[0] : nil
    }

    // Adapt to the available width: compact iPhones must not squeeze playlist
    // names and status labels into two narrow cards. Accessibility sizes
    // always retain a full-width card for readable multi-line content.
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 13)]
            : [GridItem(.adaptive(minimum: 170), spacing: 13)]
    }

    // Clearing or completing a playlist edit must leave a reachable result target.
    private func revealPlaylists() {
        playlistQuery = ""
        playlistResultsFocused = true
    }

    // A duplicate must be discoverable even when the source was found through
    // a search that excludes the generated copy's name. Keep audio untouched.
    private func copyPlaylist(_ playlist: MusicPlaylist) {
        // A new action must not leave Retry attached to an older failed edit.
        failedPlaylistEdit = nil
        guard !library.isImporting else {
            playlistActionFeedback = "Finish importing audio before copying this playlist."
            return
        }
        guard let current = uniquePlaylist(withID: playlist.id),
              current.name == playlist.name,
              current.trackIDs == playlist.trackIDs,
              current.missingTracks == playlist.missingTracks else {
            playlistActionFeedback = "This playlist changed. Review its latest songs before copying it."
            return
        }
        // Snapshot every existing playlist, not only its UUID. A restore or
        // concurrent edit may replace metadata under an existing identity while
        // duplicatePlaylist is persisting; that is not a verified successful copy.
        let before = library.playlists
        let existingIDs = Set(before.map(\.id))
        guard existingIDs.count == before.count else {
            playlistActionFeedback = "Duplicate playlist identities were found. Review your playlists before copying."
            return
        }
        library.duplicatePlaylist(playlist.id)
        let after = library.playlists
        let newCopies = after.filter { !existingIDs.contains($0.id) }
        let preservedExisting = before.allSatisfy { original in
            let matches = after.filter { $0.id == original.id }
            return matches.count == 1 && matches[0].name == original.name
                && matches[0].trackIDs == original.trackIDs
                && matches[0].missingTracks == original.missingTracks
        }
        // A restore/import may introduce another playlist during a failed write.
        // Never report success or retry an ambiguous copy result. The new copy
        // must also have a unique ID and a nonempty, recognizable name.
        let uniqueAfter = Set(after.map(\.id)).count == after.count
        if preservedExisting, uniqueAfter, newCopies.count == 1,
           let copy = newCopies.first,
           !copy.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           copy.trackIDs == current.trackIDs,
           copy.missingTracks == current.missingTracks {
            revealPlaylists()
            playlistActionFeedback = "Created \(copy.name)."
        } else {
            // An allocated ID may represent a completed copy whose verification
            // failed. Only an unchanged library with no new IDs permits Retry;
            // otherwise a second attempt could duplicate or overwrite user data.
            let safeToRetry = newCopies.isEmpty && preservedExisting && uniqueAfter
            failedPlaylistEdit = safeToRetry ? .copy(snapshot: current) : nil
            playlistActionFeedback = safeToRetry
                ? "Could not copy this playlist. Retry after checking your library; your original songs were not changed."
                : "The copy result is uncertain or the library changed. Review your playlists before copying again to avoid duplicates."
        }
    }

    // The confirmation can outlive an import, restore, rename, or playlist edit.
    // Never delete a different playlist state merely because its UUID survived.
    private func deleteConfirmedPlaylist() {
        guard let requested = pendingDelete else { return }
        pendingDelete = nil
        // A deletion result replaces the old failure; never retry that edit.
        failedPlaylistEdit = nil
        // A confirmation can survive the start of an asynchronous import.
        // Reject destructive writes until the library has settled.
        guard !library.isImporting else {
            playlistActionFeedback = "Finish importing audio, then review this playlist before deleting it. Nothing was deleted."
            return
        }
        guard let current = uniquePlaylist(withID: requested.id) else {
            playlistActionFeedback = "This playlist is no longer available. Nothing was deleted."
            return
        }
        guard current.name == requested.name,
              current.trackIDs == requested.trackIDs,
              current.missingTracks == requested.missingTracks else {
            playlistActionFeedback = "This playlist changed while the confirmation was open. Review it and try again; nothing was deleted."
            return
        }
        library.deletePlaylist(requested.id)
        if library.playlists.contains(where: { $0.id == requested.id }) {
            // Keep a safe recovery path, but only after a fresh identity and
            // contents check followed by another destructive confirmation.
            failedPlaylistEdit = .delete(snapshot: requested)
            playlistActionFeedback = "Could not delete this playlist. Your existing playlists were preserved. Retry to review and confirm again."
        } else {
            revealPlaylists()
            playlistActionFeedback = "Deleted \(requested.name). Your songs remain in your library."
        }
    }

    // Keep the message readable at accessibility sizes and on narrow phones.
    // The controls are separate VoiceOver targets; no error is hidden behind
    // a single combined accessibility element.
    private var playlistFeedbackMessage: some View {
        Text(playlistActionFeedback ?? "")
            .font(.subheadline)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityFocused($playlistFeedbackFocused)
    }

    private var playlistFeedbackActions: some View {
        HStack(spacing: 8) {
            if failedPlaylistEdit != nil {
                Button("Retry", action: retryPlaylistEdit)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ShelfTheme.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("Review the failed playlist action before trying again")
            }
            Button {
                playlistActionFeedback = nil
                failedPlaylistEdit = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Dismiss playlist confirmation")
        }
    }

    private var playlistFeedbackContent: some View {
        HStack(spacing: 12) {
            playlistFeedbackMessage
            Spacer(minLength: 0)
            playlistFeedbackActions
        }
    }

    private var hasPlaylistQuery: Bool {
        !playlistQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visiblePlaylists: [MusicPlaylist] {
        let query = playlistQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lists = library.playlists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        return sortAlphabetically ? lists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : lists
    }

    // Keep the result count readable and the recovery control reachable on
    // compact phones and at accessibility text sizes.
    @ViewBuilder private func playlistSearchSummary(matchingCount: Int) -> some View {
        Text("\(matchingCount) of \(library.playlists.count) playlists")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(ShelfTheme.subdued)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(matchingCount) playlists match your search out of \(library.playlists.count)")
        if !dynamicTypeSize.isAccessibilitySize {
            Spacer(minLength: 0)
        }
        Button {
            revealPlaylists()
        } label: {
            Label("Clear search", systemImage: "xmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShelfTheme.accent)
        .accessibilityHint("Remove the playlist search filter")
    }

    var body: some View {
        // Use the same filtered, alphabetized list for counts and the grid.
        let playlists = visiblePlaylists
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                playlistHeading

                playlistImportLink

                playlistSection(playlists)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(PremiumBackdrop())
        .searchable(text: $playlistQuery, prompt: "Find playlists")
        .navigationTitle("Playlists")
        // Reserve space for action feedback instead of covering the final
        // playlist card or the search keyboard with a floating overlay.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let playlistActionFeedback {
                ViewThatFits(in: .horizontal) {
                    playlistFeedbackContent
                    VStack(alignment: .leading, spacing: 8) {
                        playlistFeedbackMessage
                        playlistFeedbackActions
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .background(ShelfTheme.background, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("playlist-action-feedback")
            }
        }
        .onChange(of: playlistActionFeedback) { _, message in
            // Announce actionable failures without moving focus away from
            // the playlist grid for routine success confirmations.
            if message != nil && failedPlaylistEdit != nil {
                playlistFeedbackFocused = true
            } else if message == nil {
                playlistFeedbackFocused = false
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus").foregroundStyle(ShelfTheme.accent)
                        .font(.system(size: 16, weight: .bold))
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Create a playlist")
                .accessibilityHint("Open the new playlist dialog")
            }
        }
        .alert("New Playlist", isPresented: $showCreate) {
            TextField("Playlist name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                // Reject duplicate submissions while preserving the draft.
                // A previous failure must not survive a fresh create attempt.
                failedPlaylistEdit = nil
                playlistActionFeedback = nil
                guard !library.isImporting else {
                    failedPlaylistEdit = .create
                    playlistActionFeedback = "Finish importing audio before creating a playlist. Your name is saved for retry."
                    return
                }
                // Confirm the *requested* playlist was created, not merely
                // that an unrelated playlist appeared during a library refresh.
                // Restored archives can also contain duplicate playlist UUIDs.
                let previousPlaylists = library.playlists
                let existingIDs = Set(previousPlaylists.map(\.id))
                // A restored archive may contain duplicate IDs. Refuse to
                // mutate an ambiguous library rather than trusting a set of
                // identities that has already collapsed distinct playlists.
                guard existingIDs.count == previousPlaylists.count else {
                    failedPlaylistEdit = nil
                    playlistActionFeedback = "Duplicate playlist identities were found. Review your playlists before creating another."
                    return
                }
                library.createPlaylist(name)
                let created = library.playlists.filter { !existingIDs.contains($0.id) }
                let exactCreation = created.count == 1
                    && created[0].name == name
                    && created[0].trackIDs.isEmpty
                    && created[0].missingTracks.isEmpty
                    && library.playlists.filter { $0.id == created[0].id }.count == 1
                let resultingPlaylists = library.playlists
                // Preserve the original order and exact membership of every
                // existing playlist. A concurrent restore can reorder or
                // duplicate entries without changing the set of UUIDs.
                let preservedPrefix = resultingPlaylists.count >= previousPlaylists.count
                    && zip(previousPlaylists, resultingPlaylists).allSatisfy { previous, current in
                        current.id == previous.id
                            && current.name == previous.name
                            && current.trackIDs == previous.trackIDs
                            && current.missingTracks == previous.missingTracks
                    }
                let previousEntriesUnchanged = preservedPrefix
                    && Set(resultingPlaylists.map(\.id)).count == resultingPlaylists.count
                if exactCreation && previousEntriesUnchanged {
                    revealPlaylists()
                    newName = ""
                    failedPlaylistEdit = nil
                    playlistActionFeedback = "Created \(name)."
                } else {
                    // An ambiguous write may already have created a playlist.
                    // Do not offer a blind Retry that can duplicate it.
                    // Preserve the typed name for a deliberate new attempt.
                    let safeToRetry = created.isEmpty && previousEntriesUnchanged
                    failedPlaylistEdit = safeToRetry ? .create : nil
                    playlistActionFeedback = safeToRetry
                        ? "Could not create this playlist. Your name is saved; retry after checking your library."
                        : "Playlist creation could not be confirmed. Review your playlists before creating another; your name is saved."
                }
            }
            // Keep Create reachable during an import so the user receives an
            // explicit explanation and can retry with the preserved name.
            // The action itself refuses to mutate the library until import ends.
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                newName = ""
                failedPlaylistEdit = nil
                // Cancelling the draft must also remove its obsolete retry.
                playlistActionFeedback = nil
            }
        } message: { Text("Songs stay on your device.") }
        .alert("Rename Playlist", isPresented: Binding(
            get: { pendingRename != nil },
            set: { if !$0 { pendingRename = nil } }
        )) {
            TextField("Playlist name", text: $renamedName)
            Button("Save") {
                let name = renamedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                if let playlist = pendingRename {
                    // A rename sheet can remain open while an import or another
                    // editor changes the playlist. Do not overwrite newer work.
                    guard !library.isImporting else {
                        playlistActionFeedback = "Wait for the audio import to finish, then review this playlist before renaming."
                        pendingRename = nil
                        return
                    }
                    guard let current = uniquePlaylist(withID: playlist.id) else {
                        playlistActionFeedback = "This playlist was removed while editing. Nothing was renamed."
                        pendingRename = nil
                        return
                    }
                    guard current.name == playlist.name,
                          current.trackIDs == playlist.trackIDs,
                          current.missingTracks == playlist.missingTracks else {
                        playlistActionFeedback = "This playlist changed while editing. Open it again to review the latest songs before renaming."
                        pendingRename = nil
                        return
                    }
                    if current.name == name {
                        revealPlaylists()
                        failedPlaylistEdit = nil
                        playlistActionFeedback = "Playlist name is already up to date."
                    } else {
                        // A successful name lookup alone is insufficient: a
                        // restore may have replaced the playlist or changed its
                        // membership during the write. Compare the full library
                        // snapshot before offering success or a safe retry.
                        let beforeRename = library.playlists
                        library.renamePlaylist(current.id, to: name)
                        let afterRename = library.playlists
                        let sameStructure = beforeRename.count == afterRename.count
                            && zip(beforeRename, afterRename).allSatisfy { before, after in
                                before.id == after.id
                                    && before.trackIDs == after.trackIDs
                                    && before.missingTracks == after.missingTracks
                                    && (before.id == current.id
                                        ? after.name == name
                                        : before.name == after.name)
                            }
                        let uniqueIDs = Set(afterRename.map(\.id)).count == afterRename.count
                        if sameStructure && uniqueIDs {
                            revealPlaylists()
                            failedPlaylistEdit = nil
                            playlistActionFeedback = "Renamed playlist to \(name)."
                        } else {
                            // Only retry when the old playlist is still unique
                            // and byte-for-byte unchanged. An ambiguous write
                            // may already have succeeded; retrying could
                            // overwrite a concurrent rename or restore.
                            let unchanged = beforeRename.count == afterRename.count
                                && zip(beforeRename, afterRename).allSatisfy { before, after in
                                    before.id == after.id && before.name == after.name
                                        && before.trackIDs == after.trackIDs
                                        && before.missingTracks == after.missingTracks
                                }
                            failedPlaylistEdit = unchanged && uniqueIDs
                                ? .rename(snapshot: current) : nil
                            playlistActionFeedback = unchanged && uniqueIDs
                                ? "Could not rename this playlist. Its previous name is intact; retry after checking your library."
                                : "Playlist rename could not be confirmed. Review the latest playlist names and songs before trying again."
                        }
                    }
                }
                pendingRename = nil
            }
            .disabled(renamedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { pendingRename = nil }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "playlist")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete playlist", role: .destructive) {
                deleteConfirmedPlaylist()
            }
            Button("Keep playlist", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Only this playlist will be removed. Your offline songs will remain on this iPhone.")
        }
    }

    private var playlistHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            PremiumEyebrow(title: "CURATED BY YOU", color: ShelfTheme.coral)
            Text("Made for every mood.")
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($playlistResultsFocused)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text("Your music, exactly how you like it.")
                .font(.subheadline).foregroundStyle(ShelfTheme.subdued)
        }
        .padding(.top, 10)
    }

    private var playlistImportLink: some View {
        NavigationLink { PlaylistSourcesView() } label: {
            HStack(spacing: 14) {
                PremiumIcon(symbol: "arrow.down.to.line.compact", color: ShelfTheme.mint, size: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bring your playlists")
                        .font(.headline).foregroundStyle(.white)
                    Text("Import track lists & match offline audio")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(ShelfTheme.mint)
            }
            .padding(16)
            .premiumCard()
        }
        .buttonStyle(.plain)
    }

    private var emptyPlaylistSearch: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No playlists match your search.")
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($playlistResultsFocused)
                .foregroundStyle(ShelfTheme.subdued)
                .fixedSize(horizontal: false, vertical: true)
            Text("Try a different name, or clear the search to browse your collections.")
                .font(.subheadline)
                .foregroundStyle(ShelfTheme.subdued)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                revealPlaylists()
            } label: {
                Label("Clear playlist search", systemImage: "xmark.circle")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Show all playlists again")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyPlaylistLibrary: some View {
        VStack(alignment: .leading, spacing: 13) {
            PremiumIcon(symbol: "square.stack.3d.up",
                        color: ShelfTheme.accent, size: 55)
            Text("Every great mix starts somewhere.")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("Create a playlist for the songs you'll never get tired of.")
                .font(.subheadline)
                .foregroundStyle(ShelfTheme.subdued)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showCreate = true
            } label: {
                Label("Create a playlist", systemImage: "plus")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(ShelfTheme.accent)
            .padding(.top, 5)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard(radius: 24)
    }

    private func playlistGrid(_ playlists: [MusicPlaylist]) -> some View {
        // Compute identity conflicts once for the entire restored library.
        // Filtering can hide a duplicate, so counting visible results alone
        // would incorrectly enable destructive actions on an ambiguous ID.
        // Avoid rescanning every playlist for every visible card (O(n²)).
        let identityCounts = library.playlists.reduce(into: [UUID: Int]()) { counts, playlist in
            counts[playlist.id, default: 0] += 1
        }
        return LazyVGrid(columns: columns, spacing: 13) {
            // Use the visible position as identity: restored archives can contain
            // duplicate playlist UUIDs, which otherwise break SwiftUI diffing.
            ForEach(Array(playlists.enumerated()), id: \.offset) { index, list in
                if identityCounts[list.id] != 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        playlistCard(list, index: index)
                        Label("Duplicate playlist identity. Editing and opening are unavailable until the library is repaired.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(ShelfTheme.coral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(list.name). Duplicate playlist identity; cannot safely open or edit.")
                } else {
                NavigationLink { PlaylistDetailView(playlistID: list.id) } label: {
                    playlistCard(list, index: index)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(list.name), \(list.trackIDs.count) saved songs, \(list.missingTracks.count) recordings still to find")
                .accessibilityHint("Open playlist to see songs and download status")
                // VoiceOver users should not need to discover a
                // long press to manage a playlist.
                .accessibilityAction(named: "Rename playlist") {
                    renamedName = list.name
                    pendingRename = list
                }
                .accessibilityAction(named: "Make local copy") {
                    copyPlaylist(list)
                }
                .accessibilityAction(named: "Delete playlist") {
                    pendingDelete = list
                }
                .contextMenu {
                    Button {
                        renamedName = list.name
                        pendingRename = list
                    } label: { Label("Rename Playlist", systemImage: "pencil") }
                    Button { copyPlaylist(list) } label: {
                        Label("Make local copy", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        pendingDelete = list
                    } label: { Label("Delete Playlist", systemImage: "trash") }
                }
                }
            }
        }
    }

    private func playlistSection(_ playlists: [MusicPlaylist]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PremiumSectionHeading(title: "Your playlists",
                                  detail: "\(library.playlists.count) collections")
            Toggle("Sort alphabetically", isOn: $sortAlphabetically)
                .tint(ShelfTheme.accent)
                .frame(minHeight: 44)
            if hasPlaylistQuery {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 6) {
                            playlistSearchSummary(matchingCount: playlists.count)
                        }
                    } else {
                        HStack(alignment: .center, spacing: 12) {
                            playlistSearchSummary(matchingCount: playlists.count)
                        }
                    }
                }
            }
            if hasPlaylistQuery && playlists.isEmpty {
                emptyPlaylistSearch
            }
            if library.playlists.isEmpty && !hasPlaylistQuery {
                emptyPlaylistLibrary
            } else if !playlists.isEmpty {
                playlistGrid(playlists)
            }
        }
    }

    private func playlistCard(_ list: MusicPlaylist, index: Int) -> some View {
        let palette = ShelfTheme.artworkColors(for: list.name)
        return VStack(alignment: .leading, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 17)
                    .fill(LinearGradient(colors: palette,
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    .frame(width: 108, height: 108)
                    .offset(x: 57, y: -33)
                // Resolve just the cover instead of materializing every song in
                // each visible playlist during grid updates and scrolling.
                if let cover = list.trackIDs.lazy.compactMap({ library.song(with: $0) }).first {
                    ArtworkTile(track: cover, size: 112)
                        .rotationEffect(.degrees(-7))
                        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                } else {
                    Image(systemName: ["waveform", "music.mic", "headphones", "record.circle"][index % 4])
                        .font(.system(size: 39, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.95))
                }
            }
            .frame(height: 125)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 17))
            Text(list.name)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Label("\(list.trackIDs.count) saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(ShelfTheme.subdued)
                if !list.missingTracks.isEmpty {
                    Text("\(list.missingTracks.count) to find")
                        .foregroundStyle(ShelfTheme.coral)
                }
            }
            .font(.caption.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard(radius: 23)
    }
}

// Keep the complete user-visible playlist revision observable while local
// file validation is running. PlaylistWish already supports equality because
// the playback completion path compares missingTracks snapshots.
private struct PlaylistPlaybackMetadata: Equatable {
    let name: String
    let trackIDs: [UUID]
    let missingTracks: [PlaylistWish]
}

struct PlaylistDetailView: View {
    @ObservedObject private var transfers = BackgroundAudioDownloader.shared
    let playlistID: UUID
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @State private var editing: MusicTrack?
    @State private var manuallyAdding: PlaylistWish?
    @State private var showWebDiscovery = false
    @State private var sourceReviewWishes: [PlaylistWish] = []
    @State private var sourceReviewFeedback: String?
    @State private var reviewingRecording: PlaylistWish?
    @State private var playlistPlaybackTask: Task<Void, Never>?
    @State private var playlistPlaybackPending = false
    // A cancelled scan cannot publish over a subsequent Play or Shuffle request.
    @State private var playlistPlaybackGeneration: UUID?
    @State private var playlistPlaybackError: String?
    @State private var playlistPlaybackNotice: String?
    // Retry eligibility is state, not a substring of localized user-facing copy.
    @State private var playlistPlaybackCanRetry = false
    @State private var lastPlaylistPlaybackWasShuffled = false
    @State private var playlistEditWarning: String?
    @Environment(\.scenePhase) private var playlistScenePhase
    // Import may replace local audio while a background file scan is running.
    private var playlistAudioImportBusy: Bool { library.isImporting }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("MP3Shelf.recordingMatching") private var recordingMatchingEnabled = true

    // Restored archives can contain duplicate playlist IDs. Never choose an
    // arbitrary copy for playback, editing or source discovery.
    private func uniquePlaylist(_ id: UUID) -> MusicPlaylist? {
        let matches = library.playlists.filter { $0.id == id }
        return matches.count == 1 ? matches[0] : nil
    }

    private var playlist: MusicPlaylist? { uniquePlaylist(playlistID) }
    private var hasAmbiguousPlaylistID: Bool {
        library.playlists.reduce(into: 0) { count, item in
            if item.id == playlistID { count += 1 }
        } > 1
    }

    // A restored or replaced file can change its URL while trackIDs stay the same.
    // Observe the exact recording identities used by the asynchronous disk scan.
    private var playlistPlaybackMetadata: PlaylistPlaybackMetadata? {
        guard let playlist else { return nil }
        return PlaylistPlaybackMetadata(name: playlist.name,
                                        trackIDs: playlist.trackIDs,
                                        missingTracks: playlist.missingTracks)
    }

    private var playlistRecordingLocations: [RecordingLocationKey] {
        guard let playlist else { return [] }
        return library.songs(in: playlist).map {
            RecordingLocationKey(id: $0.id, url: library.fileURL(for: $0))
        }
    }

    private func recordingLocationsDidChange() {
        guard playlistPlaybackPending || playlistPlaybackCanRetry else { return }
        if playlistPlaybackPending {
            cancelPlaylistPreparation(showFeedback: true)
        }
        playlistPlaybackError = nil
        if playlistRecordingLocations.isEmpty {
            playlistPlaybackCanRetry = false
            playlistPlaybackNotice = "This playlist has no available recordings. Restore or add a song before playing."
        } else {
            playlistPlaybackCanRetry = true
            playlistPlaybackNotice = "The playlist's local recordings changed. Retry to check the current audio files."
        }
    }

    private var jobHasNoMatches: Bool {
        guard let job = library.discoveryJob(for: playlistID) else { return false }
        return job.isComplete && job.queued == 0 && job.unavailable > 0
    }

    /// Report the real, persisted outcome for each song in the imported
    /// Spotify playlist. Downloading is not the same as already saved offline.
    private func mp3Status(for wish: PlaylistWish, isSavedOffline: Bool,
                           tickets: [BackgroundAudioTicket], job: SourceDiscoveryJob?, activeWishID: UUID?) -> (text: String, symbol: String) {
        if isSavedOffline {
            return ("Saved offline as an audio file", "checkmark.circle.fill")
        }
        if let ticket = tickets.first(where: {
            $0.requested.matchesSourceRequest(wish)
        }) {
            switch ticket.status {
            case .queued:
                if transfers.isFinalizing(ticket.id) { return ("Checking and saving audio…", "gearshape") }
                if transfers.hasStagedAudio(ticket.id) { return ("Downloaded — waiting to save", "tray.and.arrow.down") }
                if ticket.nextRetryAt != nil { return ("Automatic retry scheduled", "arrow.clockwise") }
                return (ticket.bytesReceived ?? 0) > 0
                    ? ("Downloading MP3…", "arrow.down.circle.fill")
                    : ("MP3 download queued", "clock.arrow.circlepath")
            case .imported:
                return ("No matching offline audio — recheck in Downloads", "exclamationmark.triangle")
            case .failed:
                return ("MP3 download failed — retry in Downloads", "exclamationmark.triangle")
            case .cancelled:
                return ("MP3 download cancelled", "xmark.circle")
            }
        }
        if let job {
            if activeWishID == wish.id && !job.isPaused && !job.isComplete {
                return ("Searching for a downloadable MP3…", "magnifyingglass")
            }
            switch job.outcome(for: wish) {
            case .unavailable:
                return ("No qualifying MP3 source found", "questionmark.circle")
            case .failed:
                return ("Source lookup failed", "exclamationmark.triangle")
            case .queued:
                return ("Previously queued — check Downloads", "arrow.down.circle")
            case .alreadyPresent:
                return ("Matched an existing recording", "checkmark.circle")
            case .removed:
                return ("Removed from the refreshed source playlist", "minus.circle")
            case .previous:
                return ("Previously checked — try search again", "clock.arrow.circlepath")
            case nil:
                break
            }
        }
        return ("Awaiting MP3 source search", "magnifyingglass")
    }

    // Resolve the current playlist at activation, not when the button was drawn.
    // An import or archive restore may replace the missing-song list meanwhile.
    private func openMissingSourceReview() {
        guard playlistScenePhase == .active else {
            sourceReviewFeedback = "Return to MP3 Shelf to review missing song sources."
            return
        }
        guard !playlistAudioImportBusy else {
            sourceReviewFeedback = "Wait for the audio import to finish, then review missing song sources."
            return
        }
        guard let current = uniquePlaylist(playlistID) else {
            sourceReviewFeedback = "This playlist was removed or its identity is ambiguous. Return to Library and reopen it."
            return
        }
        guard !current.missingTracks.isEmpty else {
            sourceReviewFeedback = "There are no missing song sources left to review in this playlist."
            return
        }
        sourceReviewWishes = current.missingTracks
        sourceReviewFeedback = nil
        showWebDiscovery = true
    }

    private func cancelPlaylistPreparation(showFeedback: Bool) {
        guard playlistPlaybackPending else { return }
        playlistPlaybackGeneration = nil
        playlistPlaybackTask?.cancel()
        playlistPlaybackTask = nil
        playlistPlaybackPending = false
        playlistPlaybackCanRetry = showFeedback
        if showFeedback {
            playlistPlaybackNotice = "Playback preparation cancelled. Your playlist and saved audio were not changed."
        } else {
            playlistPlaybackNotice = nil
        }
    }

    // Dismissing the alert must not strand an unavailable playlist without recovery.
    // Keep a nonmodal retry affordance for restored files and VoiceOver navigation.
    private func dismissPlaylistPlaybackError() {
        guard let message = playlistPlaybackError else { return }
        playlistPlaybackError = nil
        if playlistPlaybackCanRetry {
            playlistPlaybackNotice = message
        }
    }

    // Alert dismissal can race a scene transition or a new import. Keep the
    // listener's retry intent visible until an eligible foreground attempt begins.
    private func retryPlaylistPlaybackFromAlert() {
        let shuffled = lastPlaylistPlaybackWasShuffled
        guard playlistScenePhase == .active else {
            playlistPlaybackNotice = "Return to MP3 Shelf to retry this playlist. Playback was not changed."
            playlistPlaybackError = nil
            playlistPlaybackCanRetry = true
            return
        }
        guard !playlistPlaybackPending else {
            playlistPlaybackNotice = "Playlist playback is already being prepared. Wait for the current check."
            playlistPlaybackError = nil
            return
        }
        guard !playlistAudioImportBusy else {
            playlistPlaybackNotice = "Audio files are still importing. Retry after the import finishes."
            playlistPlaybackError = nil
            playlistPlaybackCanRetry = true
            return
        }
        guard let currentPlaylist = uniquePlaylist(playlistID) else {
            playlistPlaybackError = "This playlist was removed or its identity is ambiguous. Reopen the library before playing."
            playlistPlaybackCanRetry = false
            return
        }
        let currentTracks = library.songs(in: currentPlaylist)
        guard !currentTracks.isEmpty else {
            playlistPlaybackNotice = "This playlist has no songs to play. Add a recording before retrying."
            playlistPlaybackError = nil
            playlistPlaybackCanRetry = false
            return
        }
        playlistPlaybackError = nil
        playlistPlaybackCanRetry = false
        startPlaylist(currentTracks, shuffled: shuffled)
    }

    // Capture file URLs on the library actor and validate them away from the UI.
    // A playlist may contain saved metadata whose audio was removed by Files.
    private func startPlaylist(_ tracks: [MusicTrack], shuffled: Bool) {
        guard !playlistPlaybackPending, !tracks.isEmpty else { return }
        guard playlistScenePhase == .active else {
            lastPlaylistPlaybackWasShuffled = shuffled
            playlistPlaybackCanRetry = true
            playlistPlaybackError = nil
            playlistPlaybackNotice = "Return to MP3 Shelf to play this playlist. No audio was changed."
            return
        }
        guard !playlistAudioImportBusy else {
            lastPlaylistPlaybackWasShuffled = shuffled
            playlistPlaybackCanRetry = true
            playlistPlaybackError = nil
            playlistPlaybackNotice = "Audio files are being imported. Wait until the import finishes, then retry playback."
            return
        }
        guard let current = uniquePlaylist(playlistID),
              library.songs(in: current).map(\.id) == tracks.map(\.id) else {
            playlistPlaybackCanRetry = false
            playlistPlaybackError = "This playlist is missing, duplicated, or changed. Reopen its latest version before playing; no audio was changed."
            return
        }
        // A restored library can contain distinct recordings with the same UUID.
        // Never hand an ambiguous identity to playback, even when its file exists.
        // Repeated occurrences of the *same* recording in a playlist are valid.
        let requestedIDs = Set(tracks.map(\.id))
        let recordingCounts = library.tracks.reduce(into: [UUID: Int]()) { counts, track in
            if requestedIDs.contains(track.id) { counts[track.id, default: 0] += 1 }
        }
        guard requestedIDs.allSatisfy({ recordingCounts[$0] == 1 }) else {
            playlistPlaybackCanRetry = false
            playlistPlaybackError = "This playlist references duplicate or missing recording identities. Resolve the restored library entries before playing; no audio was changed."
            return
        }
        let generation = UUID()
        playlistPlaybackGeneration = generation
        playlistPlaybackPending = true
        lastPlaylistPlaybackWasShuffled = shuffled
        playlistPlaybackError = nil
        playlistPlaybackNotice = nil
        playlistPlaybackCanRetry = false
        let requestedPlaylistID = playlistID
        // Snapshot every occurrence, including duplicates with distinct file URLs.
        // Matching only UUIDs can incorrectly authorize a missing duplicate.
        let originalPlaylistName = current.name
        let originalPlaylistTrackIDs = current.trackIDs
        let originalPlaylistMissingTracks = current.missingTracks
        let snapshots = tracks.map { RecordingLocationKey(id: $0.id, url: library.fileURL(for: $0)) }
        playlistPlaybackTask = Task {
            let scan = Task.detached(priority: .userInitiated) { () -> [Bool] in
                var availability: [Bool] = []
                availability.reserveCapacity(snapshots.count)
                for location in snapshots {
                    if Task.isCancelled { break }
                    let values = try? location.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    availability.append(location.url.isFileURL && values?.isRegularFile == true && values?.isSymbolicLink != true && (values?.fileSize ?? 0) > 0)
                }
                return availability
            }
            let availability = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard !Task.isCancelled, playlistPlaybackGeneration == generation else { return }
            playlistPlaybackGeneration = nil
            playlistPlaybackPending = false
            playlistPlaybackTask = nil
            // The scan can finish after the app backgrounds or a restore removes
            // the playlist. Do not silently strand the user without a recovery
            // message, and never start playback while the scene is inactive.
            guard playlistScenePhase == .active else {
                playlistPlaybackCanRetry = true
                playlistPlaybackNotice = "Playback did not start because MP3 Shelf became inactive. Return to the app and retry."
                return
            }
            guard !playlistAudioImportBusy else {
                playlistPlaybackCanRetry = true
                playlistPlaybackNotice = "An audio import started while recordings were checked. Wait until it finishes, then retry playback."
                return
            }
            guard let currentPlaylist = uniquePlaylist(requestedPlaylistID) else {
                playlistPlaybackCanRetry = false
                playlistPlaybackError = "This playlist was removed or its identity became ambiguous while recordings were checked. Reopen the library before playing."
                return
            }
            guard currentPlaylist.name == originalPlaylistName,
                  currentPlaylist.trackIDs == originalPlaylistTrackIDs,
                  currentPlaylist.missingTracks == originalPlaylistMissingTracks else {
                playlistPlaybackCanRetry = true
                playlistPlaybackError = "This playlist changed while recordings were checked. Review the latest playlist before playing."
                return
            }
            let currentTracks = library.songs(in: currentPlaylist)
            // The library may have changed while disk checks ran. Revalidate
            // identity multiplicity, not just UUIDs and file locations.
            let currentIDs = Set(currentTracks.map(\.id))
            let currentCounts = library.tracks.reduce(into: [UUID: Int]()) { counts, track in
                if currentIDs.contains(track.id) { counts[track.id, default: 0] += 1 }
            }
            guard currentIDs.allSatisfy({ currentCounts[$0] == 1 }) else {
                playlistPlaybackCanRetry = false
                playlistPlaybackError = "Recording identities changed during playback preparation. Resolve duplicate or missing recordings before playing."
                return
            }
            let currentLocations = currentTracks.map {
                RecordingLocationKey(id: $0.id, url: library.fileURL(for: $0))
            }
            guard currentLocations == snapshots, availability.count == snapshots.count else {
                playlistPlaybackCanRetry = true
                playlistPlaybackError = "This playlist or its recording locations changed while files were checked. Retry playback to use the latest recordings."
                return
            }
            let queue = currentTracks.enumerated().compactMap { index, track in
                availability[index] ? track : nil
            }
            guard let first = shuffled ? queue.randomElement() : queue.first else {
                playlistPlaybackCanRetry = true
                playlistPlaybackError = "No playable offline recordings are available. Check Downloads or restore the missing audio files."
                return
            }
            let skippedCount = currentTracks.count - queue.count
            if skippedCount > 0 {
                playlistPlaybackCanRetry = true
                playlistPlaybackNotice = "\(skippedCount) unavailable \(skippedCount == 1 ? "recording was" : "recordings were") skipped. Playing \(queue.count) available \(queue.count == 1 ? "song" : "songs")."
            }
            playback.isShuffled = shuffled
            playback.play(first, queue: queue)
        }
    }

    private func playlistPlayButton(_ tracks: [MusicTrack]) -> some View {
        Button { startPlaylist(tracks, shuffled: false) } label: {
            Label(playlistPlaybackPending ? "Checking recordings…" : "Play", systemImage: "play.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(ShelfTheme.accent)
        .disabled(tracks.isEmpty || playlistPlaybackPending)
        .accessibilityLabel(playlistPlaybackPending ? "Checking playlist recordings" : "Play playlist in order")
        .accessibilityHint(playlistAudioImportBusy
            ? "Audio import is in progress. Activating Play explains when playback can be retried."
            : "Play available offline recordings in playlist order; missing files are skipped")
    }

    private func playlistShuffleButton(_ tracks: [MusicTrack]) -> some View {
        Button { startPlaylist(tracks, shuffled: true) } label: {
            Label("Shuffle", systemImage: "shuffle")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(tracks.isEmpty || playlistPlaybackPending)
        .accessibilityLabel("Shuffle playlist")
        .accessibilityHint(playlistAudioImportBusy
            ? "Audio import is in progress. Activating Shuffle explains when playback can be retried."
            : "Shuffle available offline recordings; missing files are skipped")
    }

    var body: some View {
        List {
            if hasAmbiguousPlaylistID {
                Section {
                    Label("Multiple playlists share this ID. Playback and editing are unavailable until the duplicate library entries are resolved.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            if let playlist {
                // Single consistent offline snapshot for progress and per-song actions.
                let savedWishIDs = Set(playlist.sourceOrder.compactMap { wish in
                    library.hasOfflineRecording(matching: wish) ? wish.id : nil
                })
                Section {
                    let availableTracks = library.songs(in: playlist)
                    HStack(alignment: .top, spacing: dynamicTypeSize.isAccessibilitySize ? 10 : 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(LinearGradient(
                                    colors: ShelfTheme.artworkColors(for: playlist.name),
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                            Image(systemName: "waveform")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(.white)
                        }
                        .frame(width: dynamicTypeSize.isAccessibilitySize ? 56 : 82,
                               height: dynamicTypeSize.isAccessibilitySize ? 56 : 82)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            PremiumEyebrow(title: "YOUR PLAYLIST", color: ShelfTheme.coral)
                            Text(playlist.name)
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(playlist.trackIDs.count) saved songs · \(playlist.missingTracks.count) recordings to find")
                                .font(.caption)
                                .foregroundStyle(ShelfTheme.subdued)
                        }
                    }
                    .padding(.vertical, 12)
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 10) {
                            playlistPlayButton(availableTracks)
                            playlistShuffleButton(availableTracks)
                        }
                    } else {
                        HStack(spacing: 12) {
                            playlistPlayButton(availableTracks)
                            playlistShuffleButton(availableTracks)
                        }
                    }
                    // An imported playlist can have source metadata but no playable local
                    // recordings. Disabled Play/Shuffle alone strands the listener.
                    // These actions are navigation only: neither starts a download nor
                    // performs source discovery without another explicit user action.
                    if availableTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("No audio saved for this playlist", systemImage: "externaldrive.badge.exclamationmark")
                                .font(.headline)
                                .foregroundStyle(.orange)
                                .accessibilityAddTraits(.isHeader)
                            Text(playlist.missingTracks.isEmpty
                                 ? "Add recordings to this playlist before playing."
                                 : "\(playlist.missingTracks.count) songs still need local audio. Review downloads or choose a source to restore playback.")
                                .font(.subheadline)
                                .foregroundStyle(ShelfTheme.subdued)
                                .fixedSize(horizontal: false, vertical: true)
                            NavigationLink {
                                DownloadManagerView()
                            } label: {
                                Label("Review downloads", systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .accessibilityHint("Review saved, pending and failed audio transfers without starting a download")
                            if !playlist.missingTracks.isEmpty {
                                Button {
                                    openMissingSourceReview()
                                } label: {
                                    Label("Review missing song sources", systemImage: "magnifyingglass")
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                                .accessibilityHint("Review current missing sources. If importing is underway, a recovery message explains when to retry; no download starts automatically")
                            }
                        }
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .contain)
                    }
                    if let sourceReviewFeedback {
                        Label(sourceReviewFeedback, systemImage: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(ShelfTheme.subdued)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.updatesFrequently)
                        Button("Dismiss source review message") { sourceReviewFeedback = nil }
                            .frame(minHeight: 44)
                    }
                    if playlistPlaybackPending {
                        HStack(spacing: 10) {
                            ProgressView().accessibilityHidden(true)
                            Text("Checking playlist recordings stored on this iPhone…")
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.updatesFrequently)
                        Button {
                            cancelPlaylistPreparation(showFeedback: true)
                        } label: {
                            Label("Cancel playlist playback preparation", systemImage: "xmark.circle")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .accessibilityHint("Stops checking local recordings without changing your playlist or audio files")
                    }
                    if let playlistPlaybackNotice {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(playlistPlaybackNotice, systemImage: "exclamationmark.circle")
                                .font(.callout)
                                .foregroundStyle(ShelfTheme.subdued)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.updatesFrequently)
                            // A partial queue or an entirely missing offline playlist needs
                            // a direct recovery journey, not just a Retry that scans the
                            // same unavailable files. Downloads is local-first and does
                            // not start a source lookup merely by opening it.
                            if playlistPlaybackCanRetry {
                                NavigationLink {
                                    DownloadManagerView()
                                } label: {
                                    Label("Review missing audio in Downloads", systemImage: "arrow.down.circle")
                                        .frame(minHeight: 44, alignment: .leading)
                                }
                                .disabled(playlistScenePhase != .active || playlistAudioImportBusy)
                                .accessibilityHint("Review failed and pending audio downloads, then return to retry this playlist")
                            }
                            // Retry also remains available after partial playback: restoring
                            // missing files should not require navigating away to replay them.
                            // Only offer it for the current nonempty playlist.
                            if !playlistPlaybackPending && playlistPlaybackCanRetry,
                               let currentPlaylist = uniquePlaylist(playlistID),
                               !library.songs(in: currentPlaylist).isEmpty {
                                Button {
                                    // Re-read the latest order and file locations on activation.
                                    startPlaylist(library.songs(in: currentPlaylist),
                                                  shuffled: lastPlaylistPlaybackWasShuffled)
                                } label: {
                                    Label(lastPlaylistPlaybackWasShuffled ? "Retry Shuffle" : "Retry Play",
                                          systemImage: "arrow.clockwise")
                                        .frame(minHeight: 44, alignment: .leading)
                                }
                                .disabled(playlistAudioImportBusy || playlistScenePhase != .active)
                                .accessibilityHint(playlistAudioImportBusy
                                    ? "Wait for the local audio import to finish before retrying"
                                    : "Rechecks restored offline files in the current playlist without modifying saved audio")
                            }
                        }
                    }
                    if playlist.appleMusicLibraryID != nil {
                        Label("Imported from your Apple Music library", systemImage: "music.note.list")
                            .font(.caption).foregroundStyle(ShelfTheme.subdued)
                    } else if let source = playlist.sourceURL, let link = URL(string: source) {
                        Link(destination: link) {
                            Label("Original playlist on Spotify", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                    }
                }
                .listRowBackground(ShelfTheme.surface)
                if !playlist.missingTracks.isEmpty ||
                    library.automaticDownloadProgress?.playlistID == playlistID ||
                    BackgroundAudioDownloader.shared.pendingCount(for: playlistID) > 0 {
                    Section("FIND YOUR MUSIC") {
                        let savedSourceCount = savedWishIDs.count
                        VStack(alignment: .leading, spacing: 9) {
                            PremiumEyebrow(title: "OFFLINE SOURCE MATCHING", color: ShelfTheme.mint)
                            Text("\(savedSourceCount) of \(playlist.sourceOrder.count) songs saved offline")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.white)
                            ProgressView(value: Double(savedSourceCount),
                                         total: Double(max(1, playlist.sourceOrder.count)))
                                .tint(ShelfTheme.mint)
                                .accessibilityLabel("Downloaded audio files")
                                .accessibilityValue("\(savedSourceCount) of \(playlist.sourceOrder.count) songs saved")
                            let active = transfers.pendingCount(for: playlistID)
                            if active > 0 {
                                Label("\(active) file transfer\(active == 1 ? "" : "s") underway",
                                      systemImage: "arrow.down.circle")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(ShelfTheme.accent)
                            }
                        }
                        .padding(.vertical, 8)
                        if library.isOnWiFi {
                            Label("On Wi-Fi: available songs are found and downloaded automatically.",
                                  systemImage: "wifi")
                                .font(.caption).foregroundStyle(ShelfTheme.mint)
                        } else if library.isOnCellular {
                            if library.cellularApproved(for: playlistID) {
                                Label("Cellular downloads approved for this playlist in this app session.",
                                      systemImage: "antenna.radiowaves.left.and.right")
                                    .font(.caption).foregroundStyle(ShelfTheme.accent)
                            } else {
                                Label("Waiting for Wi-Fi. No automatic song downloads over cellular.",
                                      systemImage: "wifi.slash")
                                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                Button {
                                    library.downloadUsingCellular(for: playlistID)
                                } label: {
                                    Label("Download this playlist using cellular data",
                                          systemImage: "antenna.radiowaves.left.and.right")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        } else {
                            Label("Waiting for a Wi-Fi connection to continue downloads.",
                                  systemImage: "wifi.slash")
                                .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        }
                        Text("MP3 Shelf compares recording titles, artist credits, versions and lengths. Clear matches download automatically; use Review recording matches when several recordings are similar. Public audio catalogs provide additional sources.")
                            .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        Button {
                            openMissingSourceReview()
                        } label: {
                            Label("Search the wider web for missing songs", systemImage: "globe")
                        }
                        .buttonStyle(.bordered)
                        Toggle("Use MP3 Shelf recording matching", isOn: $recordingMatchingEnabled)
                        Text("Matching and audio extraction run on this iPhone. No search key is needed for recording matching. Transfers use Wi-Fi unless you allow cellular for this playlist.")
                            .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        if let warnings = library.discoveryJob(for: playlistID)?.catalogWarnings,
                           !warnings.isEmpty {
                            Label("Search incomplete: " + warnings.joined(separator: " • ") +
                                  " Retry unmatched songs to check these catalogs again.",
                                  systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        }
                        if let job = library.discoveryJob(for: playlistID), !job.isComplete {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Recording search: \(job.nextIndex)/\(job.wishes.count) processed")
                                    .font(.caption.monospacedDigit())
                                if job.failed > 0 {
                                    Label("\(job.failed) song lookup(s) failed after retrying. The remaining songs continue automatically.",
                                          systemImage: "exclamationmark.circle")
                                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                }
                                if let issue = job.lastError {
                                    Label(issue, systemImage: "exclamationmark.circle")
                                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                }
                                if let retryAt = job.nextLookupAt, !job.isPaused {
                                    Text("Automatic retry: \(retryAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                }
                                if job.isPaused {
                                    Button("Resume Source Discovery") {
                                        library.resumeSourceDiscovery(for: playlistID)
                                    }
                                    .frame(minHeight: 44)
                                    .accessibilityHint("Continue searching for missing songs")
                                } else if (library.isOnWiFi ||
                                            (library.isOnCellular &&
                                             library.cellularApproved(for: playlistID))) &&
                                          (library.automaticDownloadProgress?.playlistID != playlistID ||
                                           library.automaticDownloadProgress?.isRunning != true) {
                                    if job.nextLookupAt == nil {
                                        Button("Resume Search") {
                                            library.resumeSourceDiscovery(for: playlistID)
                                        }
                                        .frame(minHeight: 44)
                                        .accessibilityHint("Search again for missing recordings")
                                    }
                                }
                            }
                        }
                        if let progress = library.automaticDownloadProgress,
                           progress.playlistID == playlistID {
                            Text("\(progress.processed)/\(progress.total) checked • \(progress.queued) queued • \(progress.downloaded) downloaded • \(progress.unavailable) not found • \(progress.failed) failed")
                                .font(.subheadline.monospacedDigit())
                            if progress.isRunning {
                                ProgressView(value: Double(progress.processed),
                                             total: Double(max(progress.total, 1)))
                                    .accessibilityLabel("Source discovery progress")
                                    .accessibilityValue("\(progress.processed) of \(progress.total) songs checked")
                                if !progress.currentSong.isEmpty {
                                    Text(progress.currentSong)
                                        .font(.caption)
                                        .foregroundStyle(ShelfTheme.subdued)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityLabel("Checking \(progress.currentSong)")
                                }
                                Button("Pause Source Discovery", role: .cancel) {
                                    library.pauseSourceDiscovery(for: playlistID)
                                }
                                .frame(minHeight: 44)
                                .accessibilityHint("Stops searching for new audio sources without cancelling downloads already queued")
                            } else {
                                Text(progress.wasCancelled ? "Source discovery stopped." :
                                     library.discoveryJob(for: playlistID)?.nextLookupAt != nil
                                     ? "Source lookup will retry automatically. No tap needed."
                                     : "Source lookup finished. Background downloads may still be running.")
                                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                if jobHasNoMatches {
                                    Label("No matching audio files found in the connected catalogs. Retry the search or attach a direct audio-file link to a missing song below.", systemImage: "info.circle")
                                        .font(.caption)
                                        .foregroundStyle(ShelfTheme.subdued)
                                }
                                if !playlist.missingTracks.isEmpty {
                                    Button("Retry unmatched songs") {
                                        library.startAutomaticDownloads(for: playlistID)
                                    }
                                    .frame(minHeight: 44)
                                    .accessibilityHint("Search again for recordings not yet saved offline")
                                }
                            }
                        } else {
                            Button {
                                library.startAutomaticDownloads(for: playlistID)
                            } label: {
                                Label("Find & Automatically Download Available MP3s",
                                      systemImage: "arrow.down.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(library.automaticDownloadProgress?.isRunning == true)
                        }
                        if BackgroundAudioDownloader.shared.pendingCount(for: playlistID) > 0 {
                            Label("\(BackgroundAudioDownloader.shared.pendingCount(for: playlistID)) MP3 downloads active in background", systemImage: "arrow.down.circle.fill")
                                .font(.subheadline).foregroundStyle(.green)
                            Button("Cancel background transfers", role: .destructive) {
                                library.stopBackgroundTransfers(for: playlistID)
                            }
                            .frame(minHeight: 44)
                            .accessibilityHint("Stops queued and active audio downloads for this playlist")
                            Text("Downloads can continue after you lock your iPhone. Source discovery resumes only when MP3 Shelf is open.")
                                .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        }
                        Text("Successful matches save an MP3 to this iPhone (Files → On My iPhone → MP3 Shelf → Music). Songs without a matching downloadable file stay listed for retry or a direct file link.")
                            .font(.caption2).foregroundStyle(ShelfTheme.subdued)
                    }
                    .listRowBackground(ShelfTheme.surface)
                }
                Section("AVAILABLE OFFLINE") {
                    // Resolve the playlist once for this render. Calling songs(in:)
                    // for every row repeatedly scans all playlist IDs and
                    // creates a new queue for each track in large collections.
                    let availableTracks = library.songs(in: playlist)
                    // Playlist entries are positions, not unique track IDs: a song
                    // can intentionally appear twice. Identity by track.id causes
                    // duplicate SwiftUI row IDs and unpredictable move rendering.
                    ForEach(Array(availableTracks.enumerated()), id: \.offset) { position, track in
                        MusicTrackRow(track: track, context: availableTracks, renaming: $editing)
                            .accessibilityValue("Playlist position \(position + 1) of \(availableTracks.count)")
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    // Persistence removes by ID, not occurrence. Refuse
                                    // destructive edits that would remove every duplicate.
                                    let copies = playlist.trackIDs.filter { $0 == track.id }.count
                                    guard copies == 1 else {
                                        playlistEditWarning = "This song appears \(copies) times. Removing one copy is not supported yet; no songs were changed."
                                        return
                                    }
                                    library.removeTrack(track.id, from: playlistID)
                                }
                            }
                    }
                    .onMove { from, to in
                        // The visible list excludes unresolved IDs, so its offsets
                        // cannot safely address the full persisted playlist.
                        guard availableTracks.count == playlist.trackIDs.count else {
                            playlistEditWarning = "Some saved playlist entries are unavailable. Reordering is paused to protect the original order."
                            return
                        }
                        library.moveTracks(in: playlistID, from: from, to: to)
                    }
                }
                if !playlist.sourceOrder.isEmpty {
                    Section("SONG-BY-SONG MP3 RESULTS") {
                        // One transfer snapshot per section evaluation, not an O(n)
                        // downloader lookup for every imported playlist entry.
                        let tickets = transfers.ticketsForPlaylist(playlistID)
                        let ticketsByWishID = Dictionary(grouping: tickets, by: { $0.requested.id })
                        // Snapshot the discovery job once; avoid repeatedly scanning
                        // the job list and its wish cursor for every SwiftUI row.
                        let discoveryJob = library.discoveryJob(for: playlistID)
                        let activeWishID = discoveryJob.flatMap { job in
                            job.wishes.indices.contains(job.nextIndex) ? job.wishes[job.nextIndex].id : nil
                        }
                        ForEach(playlist.sourceOrder) { wish in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(wish.title)
                                    .font(.subheadline.bold())
                                Text(wish.artist)
                                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                let isSavedOffline = savedWishIDs.contains(wish.id)
                                let status = mp3Status(for: wish, isSavedOffline: isSavedOffline,
                                                       tickets: ticketsByWishID[wish.id] ?? [],
                                                       job: discoveryJob, activeWishID: activeWishID)
                                Label(status.text, systemImage: status.symbol)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(status.text.contains("failed") ||
                                                     status.text.contains("No qualifying")
                                        ? ShelfTheme.coral : ShelfTheme.mint)
                                    .accessibilityLabel("\(wish.title): \(status.text)")
                                if let ticket = ticketsByWishID[wish.id]?.first {
                                    if ticket.status == .queued, let total = ticket.totalBytes,
                                       total > 0, let received = ticket.bytesReceived {
                                        ProgressView(value: Double(received), total: Double(total))
                                            .tint(ShelfTheme.accent)
                                            .accessibilityLabel("Download progress for \(wish.title)")
                                            .accessibilityValue("\(Int(min(100, max(0, Double(received) / Double(total) * 100)))) percent")
                                    }
                                    if ticket.status == .failed || ticket.status == .cancelled {
                                        Button(transfers.isResolvingSource(ticket.id) ? "Refreshing audio source…" : "Retry MP3 download") { transfers.retry(ticket.id) }
                                            .font(.caption.weight(.semibold))
                                            .frame(minHeight: 44)
                                            .accessibilityLabel("Retry download for \(wish.title)")
                                            .accessibilityHint("Try downloading this recording again")
                                            .disabled(!transfers.canRetry(ticket.id))
                                    }
                                    if ticket.status == .queued || ticket.status == .imported {
                                        Text("Source: \(ticket.provider)")
                                            .font(.caption2)
                                            .foregroundStyle(ShelfTheme.subdued)
                                    }
                                }
                                if let details = discoveryJob?.lookupDetails?[wish.id.uuidString],
                                   !details.isEmpty {
                                    SongSourceDiagnosticsView(wish: wish, details: details)
                                }
                                if let choices = discoveryJob?.recordingCandidates?[wish.id.uuidString],
                                   !choices.isEmpty, !isSavedOffline {
                                    Button("Review recording matches") { reviewingRecording = wish }
                                        .font(.caption.weight(.semibold))
                                        .frame(minHeight: 44)
                                        .accessibilityLabel("Review recording matches for \(wish.title)")
                                }
                                if !isSavedOffline {
                                    Button { manuallyAdding = wish } label: {
                                        Label("Attach an audio-file link",
                                              systemImage: "link.badge.plus")
                                    }
                                    .font(.caption.weight(.semibold))
                                    .frame(minHeight: 44)
                                    .accessibilityLabel("Attach audio-file link for \(wish.title)")
                                    .accessibilityHint("Download a matching audio file and attach it to this missing song.")
                                }
                                if let url = wish.spotifyURL, let link = URL(string: url) {
                                    Link(destination: link) {
                                        Label("View original on Spotify", systemImage: "arrow.up.right.square")
                                            .font(.caption.weight(.medium))
                                            .frame(minHeight: 44, alignment: .leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("View \(wish.title) by \(wish.artist) on Spotify")
                                    .accessibilityHint("Opens the original song outside MP3 Shelf")
                                }
                            }
                            .padding(.vertical, 5)
                            .listRowBackground(ShelfTheme.background)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PremiumBackdrop())
        .tint(ShelfTheme.accent)
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink { DownloadManagerView() } label: {
                    Image(systemName: "arrow.down.circle")
                }
                EditButton()
                    .disabled(playlist.map { library.songs(in: $0).count != $0.trackIDs.count } ?? true)
                    .accessibilityHint("Reordering requires every saved playlist entry to be available")
            }
        }
        .sheet(item: $editing) { track in RenameTrackView(track: track) }
        .sheet(item: $manuallyAdding) { wish in
            AuthorizedPlaylistAudioView(wish: wish, playlistID: playlistID)
        }
        .sheet(isPresented: $showWebDiscovery, onDismiss: {
            sourceReviewWishes = []
        }) {
            WebAudioDiscoveryView(wishes: sourceReviewWishes)
        }
        .sheet(item: $reviewingRecording) { wish in
            RecordingMatchReviewView(wish: wish, playlistID: playlistID,
                candidates: library.discoveryJob(for: playlistID)?.recordingCandidates?[wish.id.uuidString] ?? [])
        }
        .alert("Playlist edit protected", isPresented: Binding(
            get: { playlistEditWarning != nil },
            set: { if !$0 { playlistEditWarning = nil } }
        )) {
            Button("OK", role: .cancel) { playlistEditWarning = nil }
        } message: {
            Text(playlistEditWarning ?? "")
        }
        .alert("Playlist playback unavailable", isPresented: Binding(
            get: { playlistPlaybackError != nil },
            set: { if !$0 { dismissPlaylistPlaybackError() } }
        )) {
            // Identity conflicts are not recoverable by repeating Play. Never
            // offer an action that can only fail again against the same data.
            if playlistPlaybackCanRetry {
                Button(lastPlaylistPlaybackWasShuffled ? "Retry Shuffle" : "Retry Play") {
                    retryPlaylistPlaybackFromAlert()
                }
            }
            Button(playlistPlaybackCanRetry ? "Not now" : "OK", role: .cancel) {
                dismissPlaylistPlaybackError()
            }
        } message: {
            Text(playlistPlaybackError ?? "")
        }
        .onChange(of: playlistAudioImportBusy) { _, importing in
            if importing {
                // Never reuse an availability scan across file replacement.
                if playlistPlaybackPending { cancelPlaylistPreparation(showFeedback: true) }
                if playlistPlaybackCanRetry {
                    playlistPlaybackError = nil
                    playlistPlaybackNotice = "Audio import is updating local recordings. Wait until it finishes, then retry playback."
                }
            } else if playlistPlaybackCanRetry && !playlistPlaybackPending {
                // Completion does not imply that every recording was restored.
                // Offer an explicit fresh scan without interrupting the active queue.
                playlistPlaybackError = nil
                playlistPlaybackNotice = "Audio import finished. Retry Play or Shuffle to check the current offline recordings."
            }
        }
        .onChange(of: playlistPlaybackMetadata) { _, _ in
            // A rename, reorder, deletion or missing-source refresh invalidates
            // the snapshot being checked. Do not wait for the disk scan to finish
            // before making Play/Shuffle and Retry reflect the new revision.
            if playlistPlaybackPending {
                cancelPlaylistPreparation(showFeedback: true)
                playlistPlaybackNotice = "Playlist details changed while recordings were checked. Retry to play the latest version."
            } else if playlistPlaybackCanRetry {
                playlistPlaybackError = nil
                if let currentPlaylist = uniquePlaylist(playlistID),
                   !library.songs(in: currentPlaylist).isEmpty {
                    playlistPlaybackNotice = "Playlist details changed. Retry to check the current recordings."
                } else {
                    playlistPlaybackCanRetry = false
                    playlistPlaybackNotice = "This playlist has no songs to play. Add a recording before retrying."
                }
            }
        }
        .onChange(of: playlistRecordingLocations) { _, _ in
            // Reimports and file replacement may leave the playlist order intact.
            // Invalidate the old file scan immediately rather than waiting for I/O.
            recordingLocationsDidChange()
        }
        .onChange(of: playlist == nil) { _, isMissing in
            guard isMissing else { return }
            // A deleted or ambiguous playlist must never leave a stale Retry
            // action that could target a different restored playlist.
            cancelPlaylistPreparation(showFeedback: false)
            playlistPlaybackCanRetry = false
            playlistPlaybackNotice = nil
            playlistPlaybackError = hasAmbiguousPlaylistID
                ? "Multiple playlists now share this identity. Resolve the duplicates before playing."
                : "This playlist is no longer in the library. Return to Library to choose an available playlist."
        }
        .onChange(of: playlistScenePhase) { _, phase in
            guard phase != .active, playlistPlaybackPending else { return }
            // Keep a visible recovery path when validation is interrupted by
            // an incoming call, app switch, or device lock.
            cancelPlaylistPreparation(showFeedback: true)
            playlistPlaybackNotice = "Playback was interrupted when MP3 Shelf became inactive. Return to the app and retry; your audio was not changed."
        }
        .onDisappear { cancelPlaylistPreparation(showFeedback: false) }
    }
}

private struct RecordingMatchReviewView: View {
    let wish: PlaylistWish
    let playlistID: UUID
    let candidates: [RecordingCandidate]
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var task: Task<Void, Never>?
    @State private var working = false
    @State private var issue: String?

    // Imported playlists can be deleted, replaced, or restored while this
    // sheet is open. Never enqueue a candidate against an ambiguous identity.
    private var isCurrentRequest: Bool {
        let matches = library.playlists.filter { $0.id == playlistID }
        guard matches.count == 1 else { return false }
        return matches[0].sourceOrder.contains(where: { $0.id == wish.id && $0.title == wish.title && $0.artist == wish.artist })
    }

    private func enqueue(_ candidate: RecordingCandidate) {
        guard !working else { return }
        guard isCurrentRequest else {
            issue = "This playlist or requested song changed. Close this sheet and review the latest playlist before downloading."
            return
        }
        working = true
        issue = nil
        task = Task { @MainActor in
            defer {
                working = false
                task = nil
            }
            do {
                try Task.checkCancellation()
                guard isCurrentRequest else {
                    issue = "The requested song changed. Review the latest playlist before downloading."
                    return
                }
                try await library.queueRecording(candidate, matching: wish, playlistID: playlistID)
                if !Task.isCancelled { dismiss() }
            } catch is CancellationError {
                // Leaving the sheet is not a download failure.
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("REQUESTED RECORDING") {
                    Text(wish.title).font(.headline)
                    Text(wish.artist)
                    if let length = wish.durationSeconds { Text("Expected length: \(length.formatted(.number.precision(.fractionLength(0)))) seconds") }
                    if working {
                        ProgressView("Checking and queueing this recording…")
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    if !isCurrentRequest {
                        Label("The requested playlist or song is no longer unique and current. Close this sheet and reopen it from the library.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let issue {
                        Text(issue)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                ForEach(RecordingMatcher.rank(candidates, for: wish).prefix(8), id: \.candidate.id) { match in
                    Section {
                        Text(match.candidate.title).font(.headline)
                        Text(match.candidate.uploader).font(.subheadline)
                        Text("Match score: \(match.score) • \(match.reason)").font(.caption)
                        if let duration = match.candidate.durationSeconds { Text("\(duration.formatted(.number.precision(.fractionLength(0)))) seconds").font(.caption) }
                        Link("Open recording source", destination: match.candidate.pageURL)
                            .frame(minHeight: 44, alignment: .leading)
                        Button {
                            enqueue(match.candidate)
                        } label: {
                            Label(working ? "Queueing recording…" : "Download this recording", systemImage: "arrow.down.circle")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .disabled(working || !isCurrentRequest || match.decision == .rejected)
                        .accessibilityLabel("Download \(match.candidate.title) from \(match.candidate.uploader)")
                        .accessibilityHint(match.decision == .rejected
                            ? "This recording does not meet the matching requirements"
                            : "Verify and queue this recording for the requested playlist song")
                    }
                }
            }
            .navigationTitle("Recording matches")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(working)
        .onDisappear { task?.cancel() }
    }
}

private struct SongSourceDiagnosticsView: View {
    let wish: PlaylistWish
    let details: [String]

    var body: some View {
        DisclosureGroup("Source search details") {
            ForEach(Array(details.enumerated()), id: \.offset) { entry in
                Text(entry.element)
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ShareLink(item: "\(wish.artist) — \(wish.title)\n" + details.joined(separator: "\n")) {
                Label("Share search diagnostics", systemImage: "square.and.arrow.up")
            }
            .font(.caption)
        }
        .font(.caption.weight(.semibold))
    }
}

/// Recovery path when a catalog cannot locate a matching audio file.
/// The supplied direct HTTPS audio URL must be provided by the user, not
/// derived from Spotify streams or an unverified download search engine.
struct AuthorizedPlaylistAudioView: View {
    let wish: PlaylistWish
    var initialURL: URL? = nil
    // The discovery and inspector entry points may not have a playlist context.
    // The playlist-detail entry point does: guard it against stale requests.
    var playlistID: UUID? = nil

    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.dismiss) private var dismiss
    @FocusState private var linkFocused: Bool
    @State private var link = ""
    @State private var isDownloading = false
    @State private var errorMessage: String?

    private var trimmedLink: String {
        link.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var requestIsCurrent: Bool {
        guard let playlistID else { return true }
        let matches = library.playlists.filter { $0.id == playlistID }
        guard matches.count == 1 else { return false }
        return matches[0].sourceOrder.contains {
            $0.id == wish.id && $0.title == wish.title && $0.artist == wish.artist
        }
    }

    private func submitAudioLink() {
        guard !isDownloading else { return }
        guard requestIsCurrent else {
            errorMessage = "This playlist or requested song changed. Close this sheet and reopen it from the current playlist."
            return
        }
        guard let url = URL(string: trimmedLink),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            errorMessage = "Enter a direct HTTPS audio-file link without embedded credentials."
            linkFocused = true
            return
        }

        errorMessage = nil
        linkFocused = false
        isDownloading = true
        Task { @MainActor in
            defer { isDownloading = false }
            do {
                let result = try await library.downloadAudio(from: url, matching: wish)
                guard requestIsCurrent else {
                    // The download may already be stored. Do not claim that it
                    // attached to a playlist that changed during the operation.
                    errorMessage = "Audio was checked, but the playlist changed. Review the latest playlist before attaching a recording."
                    return
                }
                if result.imported > 0 {
                    dismiss()
                } else {
                    errorMessage = "The audio file is already stored. Check the song's title and artist in your library to match this playlist."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("MISSING SONG") {
                    Text(wish.title).font(.headline)
                    Text(wish.artist).foregroundStyle(.secondary)
                    if let duration = wish.durationSeconds {
                        Text("Expected length: \(Int(duration)) seconds")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !requestIsCurrent {
                        Label("This playlist or song changed. Close and reopen this screen from the current playlist.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("attach-audio-stale-request")
                    }
                }
                Section("DIRECT AUDIO FILE URL") {
                    TextField("https://example.org/song.mp3", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .focused($linkFocused)
                        .submitLabel(.done)
                        .onSubmit(submitAudioLink)
                        .disabled(isDownloading || !requestIsCurrent)
                        .accessibilityIdentifier("attach-audio-url")
                    Text("Paste a direct HTTPS audio-file URL. MP3 Shelf checks that the file can play and matches the song's duration when available, then attaches it to this playlist.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.updatesFrequently)
                            .accessibilityIdentifier("attach-audio-error")
                    }
                    Button(action: submitAudioLink) {
                        if isDownloading {
                            HStack {
                                ProgressView().accessibilityHidden(true)
                                Text("Downloading and checking audio…")
                            }
                        } else {
                            Label("Download and attach this song", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(isDownloading || trimmedLink.isEmpty || !requestIsCurrent)
                    .accessibilityIdentifier("attach-audio-submit")
                    .accessibilityHint("Checks the direct audio file before saving it; does not replace the current playback queue")
                }
                Section {
                    Text("Imported playlists contain song details. Use a direct audio-file link here to save the recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Attach Offline Audio")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if link.isEmpty, let initialURL { link = initialURL.absoluteString }
            }
            .onChange(of: link) { _, _ in
                if !isDownloading { errorMessage = nil }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .disabled(isDownloading)
                }
            }
        }
        // Do not let a swipe dismiss the only visible progress indicator while
        // the download is still running. Failed requests remain editable.
        .interactiveDismissDisabled(isDownloading)
    }
}

private struct WebAudioSelection: Identifiable {
    let id = UUID()
    let wish: PlaylistWish
    let url: URL
}

/// Optional broad web search for download *pages* and direct audio links.
/// Manual result browsing and setup for the bounded automatic playlist fallback.
struct WebAudioDiscoveryView: View {
    let wishes: [PlaylistWish]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var apiKey = WebAudioSearch.loadKey() ?? ""
    @AppStorage("MP3Shelf.automaticWebFallback") private var automaticWebFallback = true
    @State private var searchDepth: WebAudioSearch.SearchDepth = .quick
    @State private var inspectPagesDuringSearch = false
    @State private var inspectedDuringSearch = 0
    @State private var pageStart = 0
    @State private var results: [UUID: [WebAudioSearchResult]] = [:]
    @State private var issues: [UUID: String] = [:]
    @State private var searched = 0
    @State private var scanning = false
    @State private var scanStopReason: String?
    @State private var onlySearchIncomplete = true
    @State private var activeScanTotal = 0
    @State private var scanTask: Task<Void, Never>?
    @State private var scanID = UUID()

    // Invalidate pending callbacks before cancelling: URLSession completions can
    // arrive after cancellation and must not repopulate a closed/changed search.
    private func cancelScan() {
        scanID = UUID()
        scanTask?.cancel()
        scanTask = nil
        scanning = false
        scanStopReason = nil
        inspectionGeneration = UUID()
        for task in manualInspectionTasks.values { task.cancel() }
        manualInspectionTasks.removeAll()
        manualPageOwners.removeAll()
        wishInspectionIDs.removeAll()
        for task in directInspectionTasks.values { task.cancel() }
        directInspectionTasks.removeAll()
        directInspectionIDs.removeAll()
        inspectingPages.removeAll()
        inspectingWishes.removeAll()
    }
    // Inactive scenes must not keep user-initiated webpage requests running.
    // Preserve discovered links and per-song results for an explicit foreground retry.
    private func suspendForInactiveScene() {
        guard scanning || !manualInspectionTasks.isEmpty || !directInspectionTasks.isEmpty else { return }
        cancelScan()
        scanStopReason = "Web search and page inspections paused while MP3 Shelf is inactive. Previous results remain available; retry after returning."
    }

    // Cancelling a billable web scan must not cancel a separate, user-initiated
    // publisher inspection for another song. Preserve those task identities and
    // reconstruct only their active progress indicators.
    private func cancelWebSearch() {
        scanID = UUID()
        scanTask?.cancel()
        scanTask = nil
        scanning = false
        scanStopReason = "Web search cancelled. Completed song results are still available below."
        inspectingPages = Set(manualPageOwners.keys).union(directInspectionTasks.keys)
    }
    @State private var selectedLink: WebAudioSelection?
    @State private var inspectingWish: PlaylistWish?
    @State private var inspectingPages: Set<String> = []
    @State private var inspectingWishes: Set<UUID> = []
    @State private var manualInspectionTasks: [UUID: Task<Void, Never>] = [:]
    // A publisher hit can appear in multiple imported songs. Track ownership
    // separately so cancelling one song cannot hide another song's progress.
    @State private var manualPageOwners: [String: Set<UUID>] = [:]

    private func beginManualPage(_ hitID: String, for wishID: UUID) {
        manualPageOwners[hitID, default: []].insert(wishID)
        inspectingPages.insert(hitID)
    }

    private func endManualPage(_ hitID: String, for wishID: UUID) {
        manualPageOwners[hitID]?.remove(wishID)
        if manualPageOwners[hitID]?.isEmpty == true {
            manualPageOwners.removeValue(forKey: hitID)
        }
        // Direct inspections and automatic scans also use this indicator.
        if manualPageOwners[hitID] == nil && directInspectionTasks[hitID] == nil && !scanning {
            inspectingPages.remove(hitID)
        }
    }
    @State private var inspectionGeneration = UUID()
    @State private var wishInspectionIDs: [UUID: UUID] = [:]
    @State private var directInspectionTasks: [String: Task<Void, Never>] = [:]
    @State private var directInspectionIDs: [String: UUID] = [:]
    @State private var inspectedCount: [UUID: Int] = [:]
    @State private var extractedLinks: [String: [URL]] = [:]
    @State private var inspectionErrors: [String: String] = [:]
    @State private var message: String?

    // Publisher HTML can advertise repeated links, fragments and credential-bearing
    // URLs. Normalize before rendering to keep ForEach identities unique and prevent
    // unsafe links from reaching recording review. No network request is made here.
    private func reviewableAudioLinks(_ links: [URL]) -> [URL] {
        var seen = Set<String>()
        return links.compactMap { link in
            guard var parts = URLComponents(url: link, resolvingAgainstBaseURL: false),
                  parts.scheme?.lowercased() == "https",
                  let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil else { return nil }
            parts.fragment = nil
            guard let url = parts.url,
                  seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    // Keep every scan under 100 Brave API requests, regardless of depth.
    // Pagination makes songs beyond the first 100 accessible without silent cost.
    private var pageSize: Int { max(1, 100 / searchDepth.rawValue) }
    private var batch: [PlaylistWish] {
        Array(wishes.dropFirst(pageStart).prefix(pageSize))
    }
    // A failed, cancelled, or never-attempted song has no stored result.
    // An empty result array still represents a completed paid search.
    private var incompleteBatch: [PlaylistWish] {
        batch.filter { results[$0.id] == nil }
    }
    private var requestedBatch: [PlaylistWish] {
        onlySearchIncomplete ? incompleteBatch : batch
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("SEARCH BEYOND THE CATALOGS") {
                    Text("Search across artist sites, independent music stores, public archives, and other indexed web pages. Use multiple targeted queries to find more possible download sources.")
                        .font(.subheadline)
                    SecureField("Brave Search API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Brave offers a separate web-search API. Enter your own key once; it stays in this iPhone's Keychain and is sent only to Brave. Searches consume your account's API credits.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Get an API key from Brave Search", destination: URL(string: "https://brave.com/search/api/")!)
                    Toggle("Automatically search when catalogs find no match", isOn: $automaticWebFallback)
                    Text("With a saved key, playlist downloads can search the web and save matching files automatically. Each playlist run uses at most 20 API searches, one per unmatched song. Automatic searches use Wi-Fi unless you allow cellular for that playlist. Search limits or a rejected key stop further automatic API calls for that run.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save search key") {
                        if !WebAudioSearch.saveKey(apiKey) {
                            message = "Could not securely save the search key to Keychain."
                        } else if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            message = "Search key removed. Automatic web fallback needs a saved API key."
                        } else {
                            message = "Search key saved. Return to your playlist and choose Retry unmatched songs to use automatic fallback."
                        }
                    }
                    Picker("Search coverage", selection: $searchDepth) {
                        ForEach(WebAudioSearch.SearchDepth.allCases) { depth in
                            Text(depth.label).tag(depth)
                        }
                    }
                    .disabled(scanning)
                    Toggle("Inspect matching webpages during search", isOn: $inspectPagesDuringSearch)
                        .disabled(scanning)
                    if inspectPagesDuringSearch {
                        Text("After finding search results, inspect up to 12 relevant source pages per batch, one per song, for direct audio links. This sends additional public webpage requests but does not download audio. Longer playlists may require another batch or manual inspection.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Skip songs already searched", isOn: $onlySearchIncomplete)
                        .disabled(scanning)
                        .accessibilityHint("Preserves completed results and avoids repeating paid API searches for those songs")
                    Text("This run includes \(requestedBatch.count) of \(batch.count) songs and can make up to \(requestedBatch.count * searchDepth.rawValue) billable Brave API searches. Extensive mode combines general, store, direct-file, official and archive searches.")
                        .font(.caption).foregroundStyle(.secondary)
                    if requestedBatch.isEmpty {
                        Text("Every song in this batch already has search results. Turn off Skip songs already searched to search again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        // A stale tap can arrive after scene deactivation but before
                        // SwiftUI disables the button. Never spend API credits then.
                        guard scenePhase == .active else {
                            scanStopReason = "Return to MP3 Shelf before starting a web search. Previous results remain available."
                            return
                        }
                        guard WebAudioSearch.saveKey(apiKey) else {
                            message = "Could not securely save the search key to Keychain."
                            return
                        }
                        let currentBatch = requestedBatch
                        guard !currentBatch.isEmpty else { return }
                        // Restart only the billable search. A separately initiated
                        // publisher inspection must retain its task and progress.
                        cancelWebSearch()
                        // A full rescan applies only to the visible batch. Never erase
                        // previously searched pages or manually inspected links from
                        // other batches; the user may have spent API credits finding them.
                        // Keep existing results visible until a replacement search
                        // succeeds, so cancellation, network loss, or rate limiting
                        // cannot destroy the last usable source candidates.
                        for wish in currentBatch {
                            issues.removeValue(forKey: wish.id)
                        }
                        searched = 0
                        activeScanTotal = currentBatch.count
                        inspectedDuringSearch = 0
                        scanStopReason = nil
                        scanning = true
                        let requestID = scanID
                        let depth = searchDepth
                        let inspectPages = inspectPagesDuringSearch
                        scanTask = Task {
                            var inspectedPages = 0
                            var scannedStop = false
                            let key = apiKey
                            for wish in currentBatch {
                                if Task.isCancelled || scanID != requestID || scenePhase != .active { break }
                                do {
                                    let found = try await WebAudioSearch.search(for: wish, using: key, depth: depth)
                                    guard !Task.isCancelled, scanID == requestID, scenePhase == .active else { break }
                                    results[wish.id] = found
                                    // The new successful response supersedes any
                                    // previous error for this song, not other batches.
                                    issues.removeValue(forKey: wish.id)
                                    if inspectPages && inspectedPages < 12 {
                                        let candidates = WebAudioSearch.pagesWorthInspecting(
                                            found, for: wish, limit: 1)
                                        for hit in candidates {
                                            if Task.isCancelled || scanID != requestID || scenePhase != .active { break }
                                            inspectedPages += 1
                                            inspectingPages.insert(hit.id)
                                            do {
                                                let links = try await AudioLandingPageInspector.inspect(
                                                    hit.url, maxProbes: 2)
                                                guard !Task.isCancelled, scanID == requestID, scenePhase == .active else { break }
                                                extractedLinks[hit.id] = links
                                            } catch is CancellationError {
                                                inspectingPages.remove(hit.id)
                                                break
                                            } catch {
                                                guard !Task.isCancelled, scanID == requestID else { break }
                                                inspectionErrors[hit.id] = error.localizedDescription
                                            }
                                            guard scanID == requestID else { break }
                                            if manualPageOwners[hit.id] == nil &&
                                                directInspectionTasks[hit.id] == nil {
                                                inspectingPages.remove(hit.id)
                                            }
                                            inspectedDuringSearch = inspectedPages
                                        }
                                    }
                                } catch is CancellationError {
                                    break
                                } catch {
                                    guard !Task.isCancelled, scanID == requestID, scenePhase == .active else { break }
                                    issues[wish.id] = error.localizedDescription
                                    // Do not repeatedly hit an invalid key or exhausted API quota.
                                    if let problem = error as? WebAudioSearch.SearchFailure {
                                        switch problem {
                                        case .rejectedKey:
                                            scannedStop = true
                                            scanStopReason = "Search stopped: Brave rejected the API key. Check the key before trying again. Completed results remain available."
                                        case .rateLimited:
                                            scannedStop = true
                                            scanStopReason = "Search stopped: Brave reported a rate limit. Wait before trying again to avoid repeated API requests. Completed results remain available."
                                        default: break
                                        }
                                    }
                                }
                                guard !Task.isCancelled, scanID == requestID, scenePhase == .active else { break }
                                searched += 1
                                if scannedStop { break }
                            }
                            if scanID == requestID {
                                scanning = false
                                scanTask = nil
                                // Automatic page probes may have stopped early.
                                // Keep progress only for independently running
                                // manual/direct inspections, never stale scan hits.
                                inspectingPages = Set(manualPageOwners.keys)
                                    .union(directInspectionTasks.keys)
                            }
                        }
                    } label: {
                        Label(scanning ? "Searching web…" : "Find downloadable sources for missing songs",
                              systemImage: "magnifyingglass")
                    }
                    .disabled(scanning || scenePhase != .active || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || requestedBatch.isEmpty)
                    if scanning {
                        Button("Cancel web search") { cancelWebSearch() }
                            .frame(minHeight: 44)
                            .accessibilityHint("Stops remaining web searches and keeps results already found")
                        ProgressView(value: Double(searched), total: Double(max(1, activeScanTotal)))
                        Text("\(searched) of \(activeScanTotal) songs searched this run" +
                             (inspectPagesDuringSearch ? " · \(inspectedDuringSearch) source pages inspected" : ""))
                            .font(.caption.monospacedDigit())
                    }
                    if let scanStopReason {
                        Text(scanStopReason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    if !wishes.isEmpty {
                        HStack(spacing: 16) {
                            Text("Songs \(pageStart + 1)–\(pageStart + batch.count) of \(wishes.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if pageStart > 0 {
                                Button("Previous") {
                                    pageStart = max(0, pageStart - pageSize)
                                    searched = 0
                                }.disabled(scanning)
                            }
                            if pageStart + batch.count < wishes.count {
                                Button("Next batch") {
                                    pageStart += batch.count
                                    searched = 0
                                }.disabled(scanning)
                            }
                        }
                    }
                    Text("Web search finds pages and possible audio links. Choose a matching file to download; a search result or player page alone is not an audio file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(batch) { wish in
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(wish.title).font(.subheadline.weight(.semibold))
                                Text(wish.artist).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                ForEach(WebAudioSearch.BrowserProvider.allCases) { provider in
                                    Link(destination: WebAudioSearch.browserURL(for: wish, provider: provider)) {
                                        Text(provider.rawValue)
                                    }
                                }
                            } label: {
                                Label("10 search sites", systemImage: "globe")
                                    .font(.caption.weight(.semibold))
                            }
                            .accessibilityLabel("Choose a search website for \(wish.title)")
                        }
                        Button {
                            inspectingWish = wish
                        } label: {
                            Label("Inspect a source page URL for audio files",
                                  systemImage: "doc.text.magnifyingglass")
                                .font(.caption.weight(.semibold))
                        }
                        if let issue = issues[wish.id] {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Latest web search failed", systemImage: "exclamationmark.triangle")
                                    .font(.subheadline.weight(.semibold))
                                    .accessibilityAddTraits(.isHeader)
                                Text(issue).font(.caption)
                                if results[wish.id] != nil {
                                    Text("Previously discovered sources are still available below. Retry the search when ready.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.orange)
                            .accessibilityElement(children: .combine)
                        }
                        if let found = results[wish.id] {
                            if found.isEmpty {
                                Text("No indexed download pages returned.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !found.isEmpty {
                                let candidates = WebAudioSearch.pagesWorthInspecting(
                                    found, for: wish, limit: 5)
                                if !candidates.isEmpty {
                                    Button {
                                        guard !inspectingWishes.contains(wish.id) else { return }
                                        inspectingWishes.insert(wish.id)
                                        inspectedCount[wish.id] = 0
                                        let generation = inspectionGeneration
                                        let inspectionID = UUID()
                                        wishInspectionIDs[wish.id] = inspectionID
                                        manualInspectionTasks[wish.id] = Task {
                                            for hit in candidates {
                                                guard !Task.isCancelled, inspectionGeneration == generation,
                                                      wishInspectionIDs[wish.id] == inspectionID else { break }
                                                if extractedLinks[hit.id] != nil {
                                                    inspectedCount[wish.id, default: 0] += 1
                                                    continue
                                                }
                                                beginManualPage(hit.id, for: wish.id)
                                                inspectionErrors.removeValue(forKey: hit.id)
                                                do {
                                                    let links = try await AudioLandingPageInspector.inspect(hit.url)
                                                    guard !Task.isCancelled, inspectionGeneration == generation,
                                                          wishInspectionIDs[wish.id] == inspectionID else { break }
                                                    extractedLinks[hit.id] = links
                                                } catch is CancellationError {
                                                    break
                                                } catch {
                                                    // A cancelled song inspection can finish with a
                                                    // transport error rather than CancellationError.
                                                    // Never publish it into a newer inspection.
                                                    guard !Task.isCancelled,
                                                          inspectionGeneration == generation,
                                                          wishInspectionIDs[wish.id] == inspectionID else { break }
                                                    inspectionErrors[hit.id] = error.localizedDescription
                                                }
                                                guard !Task.isCancelled,
                                                      inspectionGeneration == generation,
                                                      wishInspectionIDs[wish.id] == inspectionID else { break }
                                                endManualPage(hit.id, for: wish.id)
                                                inspectedCount[wish.id, default: 0] += 1
                                            }
                                            guard inspectionGeneration == generation,
                                                  wishInspectionIDs[wish.id] == inspectionID else { return }
                                            wishInspectionIDs.removeValue(forKey: wish.id)
                                            inspectingWishes.remove(wish.id)
                                            manualInspectionTasks.removeValue(forKey: wish.id)
                                        }
                                    } label: {
                                        Label(inspectingWishes.contains(wish.id)
                                              ? "Checking source pages…"
                                              : "Find audio files on top \(candidates.count) pages",
                                              systemImage: "square.stack.3d.up.magnifyingglass")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .disabled(inspectingWishes.contains(wish.id))
                                    if inspectingWishes.contains(wish.id) {
                                        Button("Cancel page inspection") {
                                            manualInspectionTasks[wish.id]?.cancel()
                                            manualInspectionTasks.removeValue(forKey: wish.id)
                                            wishInspectionIDs.removeValue(forKey: wish.id)
                                            inspectingWishes.remove(wish.id)
                                            // Only cancel this song. Other songs may be inspected concurrently.
                                            for hit in candidates {
                                                endManualPage(hit.id, for: wish.id)
                                            }
                                        }
                                        .frame(minHeight: 44)
                                        .accessibilityHint("Stops outstanding page inspections without deleting completed results")
                                        ProgressView(value: Double(inspectedCount[wish.id] ?? 0),
                                                     total: Double(max(1, candidates.count)))
                                            .accessibilityLabel("Inspecting music webpages for \(wish.title) by \(wish.artist)")
                                            .accessibilityValue("\(inspectedCount[wish.id] ?? 0) of \(candidates.count) candidate pages inspected")
                                        Text("Only direct audio files advertised in page HTML are listed.")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            ForEach(found) { hit in
                                VStack(alignment: .leading, spacing: 5) {
                                    Link(destination: hit.url) {
                                        Label(hit.title, systemImage: "arrow.up.right.square")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    Text(hit.url.host ?? "")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    let score = WebAudioSearch.resultScore(hit, for: wish)
                                    if hit.isDirectAudio {
                                        Label("Direct audio file URL", systemImage: "waveform")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(ShelfTheme.mint)
                                    } else if score >= 80 {
                                        Label("Song and artist mentioned", systemImage: "text.magnifyingglass")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(ShelfTheme.accent)
                                    }
                                    if !hit.description.isEmpty {
                                        Text(hit.description)
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                    if hit.isDirectAudio {
                                        Button {
                                            selectedLink = WebAudioSelection(wish: wish, url: hit.url)
                                        } label: {
                                            Label("Check and save this audio file", systemImage: "arrow.down.circle")
                                                .font(.caption.weight(.medium))
                                        }
                                    } else {
                                        Button {
                                            guard scenePhase == .active, directInspectionTasks[hit.id] == nil else { return }
                                            let page = hit.url
                                            inspectingPages.insert(hit.id)
                                            inspectionErrors.removeValue(forKey: hit.id)
                                            let requestID = UUID()
                                            directInspectionIDs[hit.id] = requestID
                                            directInspectionTasks[hit.id] = Task {
                                                do {
                                                    let links = try await AudioLandingPageInspector.inspect(page)
                                                    guard !Task.isCancelled, directInspectionIDs[hit.id] == requestID else { return }
                                                    extractedLinks[hit.id] = links
                                                } catch {
                                                    guard !Task.isCancelled, directInspectionIDs[hit.id] == requestID else { return }
                                                    inspectionErrors[hit.id] = error.localizedDescription
                                                }
                                                guard directInspectionIDs[hit.id] == requestID else { return }
                                                directInspectionIDs.removeValue(forKey: hit.id)
                                                directInspectionTasks.removeValue(forKey: hit.id)
                                                // A separate song or automatic scan may still
                                                // own this page's progress indicator.
                                                if manualPageOwners[hit.id] == nil && !scanning {
                                                    inspectingPages.remove(hit.id)
                                                }
                                            }
                                        } label: {
                                            Label(inspectingPages.contains(hit.id)
                                                ? "Checking page for audio links…"
                                                : "Find audio files linked on this page",
                                                systemImage: "doc.text.magnifyingglass")
                                                .font(.caption.weight(.medium))
                                                .frame(minHeight: 44, alignment: .leading)
                                        }
                                        .disabled(scenePhase != .active || inspectingPages.contains(hit.id))
                                        if directInspectionTasks[hit.id] != nil {
                                            Button("Cancel this page inspection") {
                                                directInspectionTasks[hit.id]?.cancel()
                                                directInspectionTasks.removeValue(forKey: hit.id)
                                                directInspectionIDs.removeValue(forKey: hit.id)
                                                // Invalidate late callbacks without cancelling
                                                // unrelated manual or automatic inspections.
                                                if manualPageOwners[hit.id] == nil && !scanning {
                                                    inspectingPages.remove(hit.id)
                                                }
                                            }
                                            .frame(minHeight: 44)
                                            .accessibilityHint("Stops this page inspection; previously found audio links remain available")
                                        }
                                        if let discovered = extractedLinks[hit.id] {
                                            let safeLinks = reviewableAudioLinks(discovered)
                                            if safeLinks.isEmpty {
                                                Text(discovered.isEmpty
                                                     ? "No direct audio files advertised by this page."
                                                     : "No safe, unique HTTPS audio links available for review.")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            } else {
                                                if safeLinks.count < discovered.count {
                                                    Text("\(discovered.count - safeLinks.count) duplicate or unsafe links excluded.")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                                ForEach(safeLinks, id: \.absoluteString) { file in
                                                    Button {
                                                        // Recheck the current result snapshot before
                                                        // opening review; a later search may replace it.
                                                        guard reviewableAudioLinks(extractedLinks[hit.id] ?? []).contains(file) else { return }
                                                        selectedLink = WebAudioSelection(wish: wish, url: file)
                                                    } label: {
                                                        Label("Review \(file.lastPathComponent)",
                                                              systemImage: "waveform.circle")
                                                            .font(.caption.weight(.semibold))
                                                            .lineLimit(2)
                                                            .frame(maxWidth: .infinity, alignment: .leading)
                                                            .frame(minHeight: 44)
                                                    }
                                                    .accessibilityHint("Review the recording before any download begins")
                                                }
                                            }
                                        }
                                        if let error = inspectionErrors[hit.id] {
                                            Text(error).font(.caption2).foregroundStyle(.orange)
                                        }
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        } else if !scanning {
                            Text("Use Browser without an API key, or scan for in-app search results.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Web Download Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $selectedLink) { selected in
                AuthorizedPlaylistAudioView(wish: selected.wish, initialURL: selected.url)
            }
            .sheet(item: $inspectingWish) { wish in
                PublisherPageInspectorView(wish: wish)
            }
            .onChange(of: searchDepth) { _, _ in
                pageStart = 0
                searched = 0
            }
            .onDisappear { cancelScan() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { suspendForInactiveScene() }
            }
            .alert("Web Search", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }
}


/// Supports source pages found in Safari or other search providers when the
/// user has no Brave API key. All network reads are limited to public HTTPS
/// HTML and discovered audio requires a separate explicit download action.
struct PublisherPageInspectorView: View {
    let wish: PlaylistWish
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var pageText = ""
    @State private var isInspecting = false
    @State private var candidates: [URL] = []
    // Bind retained results to the exact inspected page, not merely a sheet session.
    @State private var candidatePageURL: URL?
    @State private var error: String?
    @State private var chosenAudio: WebAudioSelection?
    @State private var inspectionTask: Task<Void, Never>?
    @State private var inspectionID = UUID()
    @State private var completedInspection = false
    @State private var candidateFilter = ""
    @State private var visibleLinkLimit = 40
    @State private var excludedLinkCount = 0
    @State private var inspectionNotice: String?
    @AccessibilityFocusState private var inspectionFeedbackFocused: Bool

    private var matchingCandidates: [URL] {
        let query = candidateFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.lastPathComponent.localizedStandardContains(query) ||
            ($0.host?.localizedStandardContains(query) ?? false) ||
            $0.absoluteString.localizedStandardContains(query)
        }
    }

    // Editing the URL or leaving this sheet invalidates the in-flight response.
    // A cancelled network request may still complete; only its matching ID
    // may publish results into the current source-page review.
    private func invalidateInspection(preservingResults: Bool = false) {
        inspectionTask?.cancel()
        inspectionTask = nil
        inspectionID = UUID()
        isInspecting = false
        if !preservingResults {
            // A different URL must never inherit candidates from the old page.
            candidates = []
            candidatePageURL = nil
            candidateFilter = ""
            visibleLinkLimit = 40
            excludedLinkCount = 0
            completedInspection = false
        }
        error = nil
        inspectionFeedbackFocused = false
        // A pending review belongs to the previous inspection session.
        chosenAudio = nil
    }

    private func cancelInspection() {
        guard isInspecting else { return }
        invalidateInspection(preservingResults: true)
        inspectionNotice = candidates.isEmpty
            ? "Page inspection cancelled. You can inspect this URL again."
            : "Page inspection cancelled. Previously found audio links are still available."
        inspectionFeedbackFocused = true
    }

    private func inspectPage() {
        // A retry can be invoked from a still-visible sheet during scene
        // deactivation. Never start a network request until foregrounded.
        guard scenePhase == .active else {
            inspectionNotice = "Return to MP3 Shelf to inspect this page. Previously found audio links remain available."
            inspectionFeedbackFocused = true
            return
        }
        guard !isInspecting else { return }
        let input = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pageURL = WebAudioSearch.sanitizedResultURL(input) else {
            invalidateInspection()
            error = "Enter a public HTTPS webpage URL."
            inspectionFeedbackFocused = true
            return
        }
        // A retry may retain results only for the identical source URL. This
        // also protects against an edit/submit racing SwiftUI onChange delivery.
        // Never present another publisher’s links as results for this page.
        let isSamePage = candidatePageURL == pageURL
        invalidateInspection(preservingResults: isSamePage)
        inspectionNotice = nil
        let requestID = inspectionID
        isInspecting = true
        inspectionTask = Task {
            // The scene can deactivate after the tap but before this task runs.
            // Recheck inside the task to avoid initiating an unwanted request.
            guard !Task.isCancelled, inspectionID == requestID else { return }
            guard scenePhase == .active else {
                invalidateInspection(preservingResults: isSamePage)
                inspectionNotice = "Page inspection paused while MP3 Shelf is inactive. Return to the app to retry."
                inspectionFeedbackFocused = true
                return
            }
            do {
                let found = try await AudioLandingPageInspector.inspect(pageURL)
                // Scene notifications and network completions can be delivered in
                // either order. Never publish a result while the app is inactive.
                guard !Task.isCancelled, inspectionID == requestID, scenePhase == .active else { return }
                // Publisher pages can advertise the same URL in multiple tags,
                // including URLs with fragments or embedded credentials. Keep
                // only distinct public HTTPS links before exposing review actions.
                var seen = Set<String>()
                let safeLinks = found.compactMap { link -> URL? in
                    guard var components = URLComponents(url: link, resolvingAgainstBaseURL: false),
                          components.scheme?.lowercased() == "https",
                          components.host != nil,
                          components.user == nil, components.password == nil else { return nil }
                    components.fragment = nil
                    guard let canonical = components.url,
                          seen.insert(canonical.absoluteString).inserted else { return nil }
                    return canonical
                }
                // Keep the user's filter while refreshing the same page.
                // A late successful response must not unexpectedly reset the
                // search they entered while the network request was pending.
                let retainedFilter = candidateFilter
                candidates = safeLinks
                candidatePageURL = pageURL
                candidateFilter = isSamePage ? retainedFilter : ""
                visibleLinkLimit = 40
                excludedLinkCount = found.count - safeLinks.count
                completedInspection = true
                inspectionFeedbackFocused = safeLinks.isEmpty
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, inspectionID == requestID, scenePhase == .active else { return }
                self.error = error.localizedDescription
                inspectionFeedbackFocused = true
            }
            guard inspectionID == requestID else { return }
            isInspecting = false
            inspectionTask = nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("SOURCE PAGE") {
                    Text(wish.title).font(.headline)
                    Text(wish.artist).font(.subheadline).foregroundStyle(.secondary)
                    TextField("https://artist.example/music/song", text: Binding(
                        get: { pageText },
                        set: { newValue in
                            // Invalidate synchronously, before another tap can review
                            // results from a different publisher page.
                            if newValue != pageText {
                                invalidateInspection()
                                inspectionNotice = nil
                                pageText = newValue
                            }
                        }
                    ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Paste a music publisher's public HTTPS page URL. MP3 Shelf will look for explicitly linked MP3, M4A, AAC, WAV or AIFF files in the page's HTML and audio metadata.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        inspectPage()
                    } label: {
                        Label(isInspecting ? "Reading source page…" : "Find downloadable audio on this page",
                              systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(isInspecting || scenePhase != .active || pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if isInspecting {
                        HStack(spacing: 12) {
                            ProgressView()
                                .accessibilityHidden(true)
                            Text("Inspecting this page…")
                                .font(.subheadline)
                            Spacer(minLength: 0)
                            Button("Cancel inspection") {
                                cancelInspection()
                            }
                            .frame(minHeight: 44)
                            .accessibilityHint("Stop inspecting this page and keep previously found audio links")
                        }
                        .accessibilityElement(children: .contain)
                    }
                    if let inspectionNotice {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(inspectionNotice)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .accessibilityFocused($inspectionFeedbackFocused)
                            Button("Inspect page again") { inspectPage() }
                                .frame(minHeight: 44)
                                .disabled(isInspecting || scenePhase != .active)
                                .accessibilityHint("Restart the cancelled inspection without changing the URL")
                        }
                    }
                    if let error {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Page inspection failed")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityFocused($inspectionFeedbackFocused)
                            Text(error)
                                .font(.subheadline)
                            Button {
                                inspectPage()
                            } label: {
                                Label("Retry page inspection", systemImage: "arrow.clockwise")
                                    .frame(minHeight: 44)
                            }
                            .disabled(isInspecting || scenePhase != .active)
                            .accessibilityHint("Try the same webpage again while retaining previously found audio links")
                        }
                        .foregroundStyle(.orange)
                    } else if completedInspection && candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("No downloadable audio links found")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityFocused($inspectionFeedbackFocused)
                            Text("This page did not expose a direct audio file. Try another public publisher page or inspect this page again.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button {
                                inspectPage()
                            } label: {
                                Label("Inspect page again", systemImage: "arrow.clockwise")
                                    .frame(minHeight: 44)
                            }
                            .disabled(isInspecting || scenePhase != .active)
                            .accessibilityHint("Repeat the inspection of this webpage")
                        }
                    }
                }
                if !candidates.isEmpty {
                    Section("POSSIBLE AUDIO FILES") {
                        Text(isInspecting
                             ? "\(candidates.count) previously found audio links remain available for review while this page is inspected again."
                             : "\(candidates.count) possible audio links found. Review the recording and publisher before downloading.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if excludedLinkCount > 0 {
                            Text("\(excludedLinkCount) duplicate or unsafe links were excluded from review.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("\(excludedLinkCount) duplicate or unsafe links excluded")
                        }
                        if candidates.count > 5 {
                            TextField("Filter audio links", text: $candidateFilter)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityHint("Filter results by filename or publisher without another network request")
                            if !candidateFilter.isEmpty {
                                Button("Clear link filter") { candidateFilter = ""; visibleLinkLimit = 40 }
                                    .frame(minHeight: 44)
                            }
                        }
                        // Resolve the filtered snapshot once per render. Previously the
                        // count, empty state, page and footer each re-filtered the full
                        // discovery result, multiplying work on large publisher pages.
                        let filteredLinks = matchingCandidates
                        let displayedLinks = Array(filteredLinks.prefix(visibleLinkLimit))
                        if filteredLinks.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("No audio links match your filter")
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                Text("Try a different filename or publisher, or clear the filter to return to all discovered links.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button {
                                    candidateFilter = ""
                                    visibleLinkLimit = 40
                                } label: {
                                    Label("Show all audio links", systemImage: "line.3.horizontal.decrease.circle")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .frame(minHeight: 44)
                                }
                                .accessibilityHint("Clear the filter without inspecting the webpage again")
                            }
                        } else {
                            Text("Showing \(displayedLinks.count) of \(filteredLinks.count) matching links")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Showing \(displayedLinks.count) of \(filteredLinks.count) matching audio links")
                        }
                        ForEach(displayedLinks, id: \.absoluteString) { file in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(file.lastPathComponent.removingPercentEncoding ?? file.lastPathComponent)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(3)
                                Text(file.host ?? "Unknown publisher")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(file.absoluteString)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                Button {
                                    // Only a URL still present in the current completed
                                    // inspection may advance to recording review.
                                    guard completedInspection,
                                          candidatePageURL == WebAudioSearch.sanitizedResultURL(pageText.trimmingCharacters(in: .whitespacesAndNewlines)),
                                          candidates.contains(file),
                                          let components = URLComponents(url: file, resolvingAgainstBaseURL: false),
                                          components.scheme?.lowercased() == "https",
                                          components.host != nil,
                                          components.user == nil, components.password == nil else { return }
                                    chosenAudio = WebAudioSelection(wish: wish, url: file)
                                } label: {
                                    Label("Review this audio file", systemImage: "arrow.down.circle")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Review \(file.lastPathComponent) from \(file.host ?? "unknown publisher")")
                                .accessibilityHint("Open recording review; no download starts automatically")
                            }
                            .padding(.vertical, 4)
                        }
                        if displayedLinks.count < filteredLinks.count {
                            Button {
                                // Clamp rather than growing an unbounded page counter.
                                visibleLinkLimit = min(filteredLinks.count, visibleLinkLimit + 40)
                            } label: {
                                Label("Show more audio links", systemImage: "list.bullet")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(minHeight: 44)
                            }
                            .accessibilityHint("Show the next audio links without inspecting the webpage again")
                        }
                    }
                }
                Section {
                    Text("Inspection never guarantees that a recording matches this song or may be copied. A separate download step checks file size, playable format and expected track duration. Login, purchases, scripts and DRM are not bypassed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Inspect Music Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        invalidateInspection()
                        dismiss()
                    }
                    .accessibilityHint("Close the page inspector and cancel any active inspection")
                }
            }
            .sheet(item: $chosenAudio) { selected in
                AuthorizedPlaylistAudioView(wish: selected.wish, initialURL: selected.url)
            }
            .onChange(of: candidateFilter) { _, _ in
                visibleLinkLimit = 40
            }
            // The URL field's binding invalidates synchronously. A second
            // deferred change observer could cancel a newly started request
            // immediately after the user pastes a URL and taps Inspect.
            .onChange(of: scenePhase) { _, phase in
                // A foreground-only publisher inspection must not keep using
                // cellular data after the app becomes inactive or backgrounded.
                // Keep previously reviewed links; resumption is user initiated.
                if phase != .active && isInspecting {
                    cancelInspection()
                    inspectionNotice = "Page inspection paused when MP3 Shelf left the foreground. Previously found links remain available. Inspect again when ready."
                }
            }
            .onDisappear { invalidateInspection() }
        }
    }
}
