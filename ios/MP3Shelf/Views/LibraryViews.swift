import SwiftUI
import UniformTypeIdentifiers

// A single cancellable SwiftUI task owns each refresh. Returning to the foreground
// triggers a fresh scan even when the library's track identifiers are unchanged.
private struct OfflineCountRefreshKey: Equatable {
    let trackIDs: [UUID]
    let scenePhase: ScenePhase
    let manualRefresh: Int
    // Reconcile existing track IDs after a file import replaces missing audio.
    let isImporting: Bool
}

// A recording ID alone is not a stable identity during restore/import:
// duplicate IDs can refer to different on-disk recordings.
private struct RecordingLocationKey: Hashable {
    let id: UUID
    let url: URL
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
    @State private var recentRetrySelection: (id: UUID, url: URL)?
    @State private var bulkPlaybackPending = false
    @State private var bulkPlaybackNotice: String?
    @State private var bulkPlaybackTask: Task<Void, Never>?
    // An older scan must never clear a newer request's busy state or feedback.
    @State private var bulkPlaybackGeneration: UUID?
    // Keep the user's original Play/Shuffle intent for a safe, explicit retry.
    @State private var bulkRetryShuffle: Bool?

    // Recently added artwork must observe the same missing-file safety rule
    // as a normal library row. Never perform coordinated file I/O on the UI actor.
    private func playRecentRecording(_ track: MusicTrack) {
        guard scenePhase == .active, recentPlaybackCheck == nil else { return }
        let generation = UUID()
        recentPlaybackGeneration = generation
        recentPlaybackCheck = track.id
        let selectedURL = library.fileURL(for: track)
        recentRetrySelection = (track.id, selectedURL)
        recentPlaybackNotice = nil
        missingRecentRecording = false
        // Snapshot the visible queue and URLs before leaving the UI actor.
        // A missing neighbor must not be queued behind an otherwise playable song.
        let recent = recentlyAdded
        let locations = recent.map { ($0.id, library.fileURL(for: $0)) }
        guard let selectedIndex = locations.firstIndex(where: { $0.0 == track.id && $0.1 == selectedURL }) else {
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
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          values.isRegularFile == true, let size = values.fileSize,
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
            guard !Task.isCancelled, scenePhase == .active,
                  recentPlaybackGeneration == generation else { return }
            recentPlaybackGeneration = nil
            recentPlaybackCheck = nil
            recentPlaybackTask = nil
            guard availability.count == recent.count,
                  recentlyAdded.map { RecordingLocationKey(id: $0.id, url: library.fileURL(for: $0)) } == locations.map { RecordingLocationKey(id: $0.0, url: $0.1) } else {
                missingRecentRecording = true
                recentPlaybackNotice = "Recently Added changed while checking local files. Retry to check the current recordings."
                return
            }
            // Never resolve duplicates through an ID-only dictionary. Match the
            // original URL as well so import/recovery cannot substitute a file.
            // Index the current library once: repeated linear searches made
            // playback preparation quadratic for large imported collections.
            // Include the URL so duplicate IDs cannot substitute recordings.
            let currentByLocation = recordingIndex()
            let queue: [MusicTrack] = recent.enumerated().compactMap { index, song in
                guard availability[index] else { return nil }
                return currentByLocation[RecordingLocationKey(id: song.id, url: locations[index].1)]
            }
            guard availability[selectedIndex],
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
    private func recordingIndex() -> [RecordingLocationKey: MusicTrack] {
        var index: [RecordingLocationKey: MusicTrack] = [:]
        index.reserveCapacity(library.tracks.count)
        for track in library.tracks {
            let key = RecordingLocationKey(id: track.id, url: library.fileURL(for: track))
            if index[key] == nil { index[key] = track }
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

    // Explicit cancellation preserves the requested mode for an intentional retry.
    // Background/navigation cancellation must not leave a stale retry affordance.
    private func cancelBulkPlaybackPreparation(showFeedback: Bool) {
        guard bulkPlaybackPending else { return }
        bulkPlaybackGeneration = nil
        bulkPlaybackTask?.cancel()
        bulkPlaybackTask = nil
        bulkPlaybackPending = false
        if showFeedback {
            bulkPlaybackNotice = "Playback preparation cancelled. Your saved recordings were not changed."
            // Retry mode is set when the request begins, before any disk I/O.
        } else {
            bulkPlaybackNotice = nil
            bulkRetryShuffle = nil
        }
    }

    // Invalidate an in-flight scan as soon as the user changes its scope.
    // Waiting for disk I/O to finish leaves the old busy indicator blocking
    // playback of the newly selected results on large libraries.
    private func browsingScopeDidChange() {
        guard bulkPlaybackPending else { return }
        cancelBulkPlaybackPreparation(showFeedback: true)
        bulkPlaybackNotice = "Your song selection changed. Retry to play the current results."
    }

    private func retryRecentRecording() {
        guard let selection = recentRetrySelection,
              let current = recentlyAdded.first(where: {
                  $0.id == selection.id && library.fileURL(for: $0) == selection.url
              }) else {
            recentPlaybackNotice = "This song is no longer in Recently Added. Choose another recording."
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
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, let size = values.fileSize,
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
        .disabled(!hasResults || isSearchUpdating || bulkPlaybackPending)
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
                    if let retryShuffle = bulkRetryShuffle, !bulkPlaybackPending {
                        Button {
                            playDisplayed(shuffled: retryShuffle)
                        } label: {
                            Label(retryShuffle ? "Retry Shuffle" : "Retry Play", systemImage: "arrow.clockwise")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Checks the current library results again without changing saved music")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Validate the whole playback queue off the main actor. A missing local
    // recording must not be selected by Play results or Shuffle results.
    private func playDisplayed(shuffled: Bool) {
        guard scenePhase == .active, !isSearchUpdating, !bulkPlaybackPending else { return }
        let songs = displayed
        guard !songs.isEmpty else { return }
        // A search, filter, sort or library edit during disk I/O invalidates
        // the requested results. Never start playback from an obsolete snapshot.
        let requestedQuery = settledSearchText
        let requestedFavorites = favoritesOnly
        let requestedSort = sortMode
        let locations = songs.map { ($0.id, library.fileURL(for: $0)) }
        let generation = UUID()
        bulkPlaybackGeneration = generation
        bulkPlaybackNotice = nil
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
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          values.isRegularFile == true, let size = values.fileSize,
                          size > 0 else {
                        availability.append(false)
                        continue
                    }
                    availability.append(true)
                }
                return availability
            }
            let availability = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard !Task.isCancelled, scenePhase == .active,
                  bulkPlaybackGeneration == generation else { return }
            bulkPlaybackGeneration = nil
            bulkPlaybackPending = false
            bulkPlaybackTask = nil
            guard !isSearchUpdating,
                  settledSearchText == requestedQuery,
                  favoritesOnly == requestedFavorites,
                  sortMode == requestedSort,
                  displayed.map { RecordingLocationKey(id: $0.id, url: library.fileURL(for: $0)) } == locations.map { RecordingLocationKey(id: $0.0, url: $0.1) },
                  availability.count == songs.count else {
                bulkPlaybackNotice = "Your library results changed while checking offline recordings. Retry to use the updated songs."
                bulkRetryShuffle = shuffled
                return
            }
            // Resolve the exact original file location, not just its ID.
            // A changed or removed recording invalidates this request; a file
            // that was already missing at scan time is simply skipped.
            let currentByLocation = recordingIndex()
            var queue: [MusicTrack] = []
            queue.reserveCapacity(songs.count)
            for (index, song) in songs.enumerated() {
                // A missing file is deliberately excluded from the queue. It must
                // not prevent otherwise playable results from starting.
                guard availability[index] else { continue }
                let originalURL = locations[index].1
                guard let match = currentByLocation[RecordingLocationKey(id: song.id, url: originalURL)] else {
                    bulkPlaybackNotice = "Some recordings changed while preparing playback. Retry to use the current library."
                    bulkRetryShuffle = shuffled
                    return
                }
                queue.append(match)
            }
            guard let first = shuffled ? queue.randomElement() : queue.first else {
                bulkPlaybackNotice = "No playable offline recordings were found in these results. Restore a recording, then retry."
                bulkRetryShuffle = shuffled
                return
            }
            playback.isShuffled = shuffled
            playback.play(first, queue: queue)
            bulkRetryShuffle = nil
            bulkPlaybackNotice = nil
            let skipped = songs.count - queue.count
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
                                ForEach(visibleTracks) { track in
                                    MusicTrackRow(track: track, context: visibleTracks,
                                                  renaming: $renaming)
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
                                .disabled(library.isImporting || offlineRecordingCount == nil)
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
                            showFilePicker = true
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
                                        .accessibilityHint("Checks the local recording before playback without using the network")
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
                                        Button {
                                            retryRecentRecording()
                                        } label: {
                                            Label("Retry Recently Added playback", systemImage: "arrow.clockwise")
                                                .frame(minHeight: 44, alignment: .leading)
                                        }
                                        .buttonStyle(.bordered)
                                        .accessibilityHint("Checks the same saved recording again without downloading audio")
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
                                ForEach(visibleTracks) { track in
                                    MusicTrackRow(track: track, context: visibleTracks,
                                                  renaming: $renaming)
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
            trackIDs: library.tracks.map(\.id),
            scenePhase: scenePhase,
            manualRefresh: offlineCountRefreshRequest,
            isImporting: library.isImporting
        )) {
            guard scenePhase == .active else { return }
            // A completed import can restore bytes for an existing track ID.
            // Do not race the import's file writes or publish partial counts.
            guard !library.isImporting else {
                offlineRecordingCount = nil
                return
            }
            offlineRecordingCount = nil
            await refreshOfflineRecordingCount()
        }
        .background(PremiumBackdrop())
        .alert("Recording unavailable", isPresented: $missingRecentRecording) {
            Button("Retry playback") { retryRecentRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected recording is unavailable or the Recently Added queue changed. Your library entry is preserved. Retry after restoring the recording.")
        }
         .onDisappear {
            cancelRecentPlaybackPreparation(showFeedback: false)
            cancelBulkPlaybackPreparation(showFeedback: false)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            cancelRecentPlaybackPreparation(showFeedback: false)
            cancelBulkPlaybackPreparation(showFeedback: false)
        }
        .navigationTitle("MP3 Shelf")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search songs, artists or albums")
        .onChange(of: searchText) { _, _ in browsingScopeDidChange() }
        .onChange(of: favoritesOnly) { _, _ in browsingScopeDidChange() }
        .onChange(of: sortMode) { _, _ in browsingScopeDidChange() }
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
                Button { showFilePicker = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ShelfTheme.accent)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Import audio files")
                .accessibilityHint("Choose audio files stored on your iPhone")
                .disabled(library.isImporting)
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { message = await library.importAudio(urls: urls).description }
            case .failure(let error):
                message = error.localizedDescription
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
    @Binding var renaming: MusicTrack?
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @State private var confirmDelete = false
    @State private var missingRecordingAlert = false
    @State private var playbackNotice: String?
    @State private var recoveryReason = "The local recording is unavailable."
    @State private var audioAvailability: Bool?
    @State private var isCheckingPlayback = false
    @State private var playbackCheckTask: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    // File metadata is checked off the main actor. A nil snapshot means the
    // row has not been scanned, not that the recording is missing.
    nonisolated private static func isUsableRecording(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else { return false }
        return size > 0
    }

    private var availabilityRefreshKey: String {
        "\(library.fileURL(for: track).path)|\(scenePhase)"
    }

    private func refreshAudioAvailability() async {
        audioAvailability = nil
        let url = library.fileURL(for: track)
        let scan = Task.detached(priority: .utility) {
            Self.isUsableRecording(at: url)
        }
        let available = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        guard !Task.isCancelled else { return }
        audioAvailability = available
    }

    private func playOrExplainMissingAudio() {
        // A duplicated track ID must not allow one usable file to make a
        // different, missing occurrence appear playable.
        guard !isCheckingPlayback, scenePhase == .active else { return }
        isCheckingPlayback = true
        playbackNotice = nil
        let selectedURL = library.fileURL(for: track)
        let queueSnapshot = context.map { ($0.id, library.fileURL(for: $0)) }
        let snapshotIDs = context.map(\.id)
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
            guard !Task.isCancelled, scenePhase == .active else { return }
            isCheckingPlayback = false
            playbackCheckTask = nil
            // A restore, deletion, or playlist edit invalidates the requested
            // queue. Validate every occurrence, not only its UUID.
            guard playable.count == queueSnapshot.count,
                  context.map(\.id) == snapshotIDs,
                  let currentTrack = library.tracks.first(where: {
                      $0.id == track.id && library.fileURL(for: $0) == selectedURL
                  }) else {
                audioAvailability = false
                recoveryReason = "The song or its location changed while checking offline audio. Retry to use the current library."
                missingRecordingAlert = true
                return
            }
            // Duplicate IDs can refer to different recordings after import/restore.
            // Resolve by both identity and exact file URL, once per validation.
            var currentByLocation: [RecordingLocationKey: MusicTrack] = [:]
            currentByLocation.reserveCapacity(library.tracks.count)
            for current in library.tracks {
                let key = RecordingLocationKey(id: current.id, url: library.fileURL(for: current))
                if currentByLocation[key] == nil { currentByLocation[key] = current }
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
            .disabled(isCheckingPlayback)
            .accessibilityLabel(isCheckingPlayback
                                ? "Checking recording: \(track.title) by \(track.artist)"
                                : audioAvailability == false
                                ? "Audio missing: \(track.title) by \(track.artist)"
                                : track.id == playback.currentTrackID
                                ? "Now playing: \(track.title) by \(track.artist)"
                                : "Play \(track.title) by \(track.artist)")
            .accessibilityValue(track.duration.shelfClock)
            .accessibilityHint(isCheckingPlayback
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
                library.toggleFavorite(track.id)
            }
            .accessibilityAction(named: "Edit song details") {
                renaming = track
            }
            .accessibilityAction(named: "Delete download") {
                confirmDelete = true
            }
            Menu {
                Button { library.toggleFavorite(track.id) } label: {
                    Label(track.isFavorite ? "Remove favorite" : "Favorite", systemImage: track.isFavorite ? "heart.slash" : "heart")
                }
                if library.playlists.isEmpty {
                    Text("Create a playlist first to add songs")
                } else {
                    Menu("Add to Playlist", systemImage: "text.badge.plus") {
                        ForEach(library.playlists) { list in
                            Button(list.name) { library.addTrack(track.id, to: list.id) }
                        }
                    }
                }
                Button("Edit Details", systemImage: "pencil") { renaming = track }
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
                Button("Delete Download", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(ShelfTheme.subdued)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More options for \(track.title) by \(track.artist)")
            .accessibilityHint("Favorite, add to playlist, edit, share or delete this download")
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
            playbackCheckTask?.cancel()
            playbackCheckTask = nil
            isCheckingPlayback = false
        }
        .onDisappear {
            playbackCheckTask?.cancel()
            playbackCheckTask = nil
            isCheckingPlayback = false
        }
        .alert("Recording unavailable", isPresented: $missingRecordingAlert) {
            Button("Retry playback") { playOrExplainMissingAudio() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(recoveryReason) Your library entry and playlists are unchanged.")
        }
        .confirmationDialog("Delete downloaded song?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Song", role: .destructive) {
                if playback.currentTrackID == track.id { playback.stop() }
                library.removeTrack(track.id)
            }
        } message: { Text("This removes the local audio file and its entries from playlists.") }
    }
}

struct RenameTrackView: View {
    let track: MusicTrack
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var editError: String?
    @FocusState private var titleFocused: Bool

    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanArtist: String { artist.trimmingCharacters(in: .whitespacesAndNewlines) }

    // A track can disappear while this sheet is open (for example after a
    // library restore). Never silently dismiss an edit that did not apply.
    private func saveEdit() {
        guard !cleanTitle.isEmpty else {
            editError = "Enter a song title before saving."
            titleFocused = true
            return
        }
        guard let current = library.tracks.first(where: { $0.id == track.id }) else {
            editError = "This song is no longer in your library. Your changes were not saved."
            return
        }
        if current.title == cleanTitle && current.artist == cleanArtist {
            dismiss()
            return
        }
        library.rename(current, title: cleanTitle, artist: cleanArtist)
        guard let updated = library.tracks.first(where: { $0.id == track.id }),
              updated.title == cleanTitle && updated.artist == cleanArtist else {
            editError = "The song could not be updated. Your edits are still here so you can retry."
            return
        }
        dismiss()
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
                            .accessibilityIdentifier("edit-song-error")
                        Button("Try saving again", action: saveEdit)
                            .disabled(cleanTitle.isEmpty)
                            .frame(minHeight: 44)
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
                    Button("Cancel") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: saveEdit)
                        .disabled(cleanTitle.isEmpty)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .onAppear { title = track.title; artist = track.artist }
            .onChange(of: title) { _, _ in editError = nil }
            .onChange(of: artist) { _, _ in editError = nil }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum FailedPlaylistEdit {
        case create
        case rename(id: UUID)
    }

    // Restore the original input when a failed write is retried instead of
    // requiring the user to reconstruct a playlist name.
    private func retryPlaylistEdit() {
        guard let failedPlaylistEdit else { return }
        playlistActionFeedback = nil
        self.failedPlaylistEdit = nil
        switch failedPlaylistEdit {
        case .create:
            showCreate = true
        case .rename(let id):
            guard let playlist = library.playlists.first(where: { $0.id == id }) else {
                playlistActionFeedback = "This playlist is no longer available to rename."
                return
            }
            pendingRename = playlist
        }
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
        let existingIDs = Set(library.playlists.map(\.id))
        library.duplicatePlaylist(playlist.id)
        if let copy = library.playlists.first(where: { !existingIDs.contains($0.id) }) {
            revealPlaylists()
            playlistActionFeedback = "Created \(copy.name)."
        } else {
            playlistActionFeedback = library.libraryStorageError
                ?? "Could not copy this playlist. Your existing playlists were preserved."
        }
    }

    private func deleteConfirmedPlaylist() {
        guard let playlist = pendingDelete else { return }
        library.deletePlaylist(playlist.id)
        pendingDelete = nil
        if library.playlists.contains(where: { $0.id == playlist.id }) {
            playlistActionFeedback = library.libraryStorageError
                ?? "Could not delete this playlist. Your existing playlists were preserved."
        } else {
            playlistResultsFocused = true
            playlistActionFeedback = "Deleted \(playlist.name). Your songs remain in your library."
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
        .overlay(alignment: .bottom) {
            if let playlistActionFeedback {
                HStack(spacing: 12) {
                    Text(playlistActionFeedback)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                    Spacer(minLength: 0)
                    if failedPlaylistEdit != nil {
                        Button("Retry", action: retryPlaylistEdit)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ShelfTheme.accent)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityHint("Reopen the playlist editor with your previous name")
                    }
                    Button {
                        self.playlistActionFeedback = nil
                        self.failedPlaylistEdit = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Dismiss playlist confirmation")
                }
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .background(ShelfTheme.background, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .accessibilityIdentifier("playlist-action-feedback")
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
                let existingIDs = Set(library.playlists.map(\.id))
                library.createPlaylist(name)
                if library.playlists.contains(where: { !existingIDs.contains($0.id) }) {
                    revealPlaylists()
                    newName = ""
                    failedPlaylistEdit = nil
                    playlistActionFeedback = "Created \(name)."
                } else {
                    failedPlaylistEdit = .create
                    playlistActionFeedback = library.libraryStorageError
                        ?? "Could not create this playlist. Your existing playlists were preserved."
                }
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                newName = ""
                failedPlaylistEdit = nil
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
                    library.renamePlaylist(playlist.id, to: name)
                    if library.playlists.first(where: { $0.id == playlist.id })?.name == name {
                        revealPlaylists()
                        failedPlaylistEdit = nil
                        playlistActionFeedback = "Renamed playlist to \(name)."
                    } else {
                        failedPlaylistEdit = .rename(id: playlist.id)
                        playlistActionFeedback = library.libraryStorageError
                            ?? "Could not rename this playlist. Its previous name was preserved."
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
        LazyVGrid(columns: columns, spacing: 13) {
            ForEach(Array(playlists.enumerated()), id: \.element.id) { index, list in
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

struct PlaylistDetailView: View {
    @ObservedObject private var transfers = BackgroundAudioDownloader.shared
    let playlistID: UUID
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @State private var editing: MusicTrack?
    @State private var manuallyAdding: PlaylistWish?
    @State private var showWebDiscovery = false
    @State private var reviewingRecording: PlaylistWish?
    @State private var playlistPlaybackTask: Task<Void, Never>?
    @State private var playlistPlaybackPending = false
    // A cancelled scan cannot publish over a subsequent Play or Shuffle request.
    @State private var playlistPlaybackGeneration: UUID?
    @State private var playlistPlaybackError: String?
    @State private var playlistPlaybackNotice: String?
    @State private var lastPlaylistPlaybackWasShuffled = false
    @State private var playlistEditWarning: String?
    @Environment(\.scenePhase) private var playlistScenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("MP3Shelf.recordingMatching") private var recordingMatchingEnabled = true

    private var playlist: MusicPlaylist? { library.playlists.first { $0.id == playlistID } }

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

    private func cancelPlaylistPreparation(showFeedback: Bool) {
        guard playlistPlaybackPending else { return }
        playlistPlaybackGeneration = nil
        playlistPlaybackTask?.cancel()
        playlistPlaybackTask = nil
        playlistPlaybackPending = false
        if showFeedback {
            playlistPlaybackNotice = "Playback preparation cancelled. Your playlist and saved audio were not changed."
        } else {
            playlistPlaybackNotice = nil
        }
    }

    // Capture file URLs on the library actor and validate them away from the UI.
    // A playlist may contain saved metadata whose audio was removed by Files.
    private func startPlaylist(_ tracks: [MusicTrack], shuffled: Bool) {
        guard playlistScenePhase == .active, !playlistPlaybackPending, !tracks.isEmpty else { return }
        let generation = UUID()
        playlistPlaybackGeneration = generation
        playlistPlaybackPending = true
        lastPlaylistPlaybackWasShuffled = shuffled
        playlistPlaybackError = nil
        playlistPlaybackNotice = nil
        let requestedPlaylistID = playlistID
        // Snapshot every occurrence, including duplicates with distinct file URLs.
        // Matching only UUIDs can incorrectly authorize a missing duplicate.
        let snapshots = tracks.map { RecordingLocationKey(id: $0.id, url: library.fileURL(for: $0)) }
        playlistPlaybackTask = Task {
            let scan = Task.detached(priority: .userInitiated) { () -> [Bool] in
                var availability: [Bool] = []
                availability.reserveCapacity(snapshots.count)
                for location in snapshots {
                    if Task.isCancelled { break }
                    let values = try? location.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    availability.append(values?.isRegularFile == true && (values?.fileSize ?? 0) > 0)
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
            guard playlistScenePhase == .active,
                  let currentPlaylist = library.playlists.first(where: { $0.id == requestedPlaylistID }) else { return }
            let currentTracks = library.songs(in: currentPlaylist)
            let currentLocations = currentTracks.map {
                RecordingLocationKey(id: $0.id, url: library.fileURL(for: $0))
            }
            guard currentLocations == snapshots, availability.count == snapshots.count else {
                playlistPlaybackError = "This playlist or its recording locations changed while files were checked. Retry playback to use the latest recordings."
                return
            }
            let queue = currentTracks.enumerated().compactMap { index, track in
                availability[index] ? track : nil
            }
            guard let first = shuffled ? queue.randomElement() : queue.first else {
                playlistPlaybackError = "No playable offline recordings are available. Check Downloads or restore the missing audio files."
                return
            }
            let skippedCount = currentTracks.count - queue.count
            if skippedCount > 0 {
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
        .accessibilityHint("Play available offline recordings in playlist order; missing files are skipped")
    }

    private func playlistShuffleButton(_ tracks: [MusicTrack]) -> some View {
        Button { startPlaylist(tracks, shuffled: true) } label: {
            Label("Shuffle", systemImage: "shuffle")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(tracks.isEmpty || playlistPlaybackPending)
        .accessibilityLabel("Shuffle playlist")
        .accessibilityHint("Shuffle available offline recordings; missing files are skipped")
    }

    var body: some View {
        List {
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
                            // A cancelled or invalidated scan must be recoverable without
                            // finding the small header Play/Shuffle controls again.
                            if !playlistPlaybackPending && playlistPlaybackNotice.contains("cancelled") ||
                                (!playlistPlaybackPending && playlistPlaybackNotice.contains("changed")) {
                                Button {
                                    if let currentPlaylist = library.playlists.first(where: { $0.id == playlistID }) {
                                        startPlaylist(library.songs(in: currentPlaylist),
                                                      shuffled: lastPlaylistPlaybackWasShuffled)
                                    }
                                } label: {
                                    Label(lastPlaylistPlaybackWasShuffled ? "Retry Shuffle" : "Retry Play",
                                          systemImage: "arrow.clockwise")
                                        .frame(minHeight: 44, alignment: .leading)
                                }
                                .accessibilityHint("Checks the current playlist again without modifying saved audio")
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
                            showWebDiscovery = true
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
            AuthorizedPlaylistAudioView(wish: wish)
        }
        .sheet(isPresented: $showWebDiscovery) {
            WebAudioDiscoveryView(wishes: playlist?.missingTracks ?? [])
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
            set: { if !$0 { playlistPlaybackError = nil } }
        )) {
            Button("Retry playback") {
                playlistPlaybackError = nil
                if let currentPlaylist = library.playlists.first(where: { $0.id == playlistID }) {
                    startPlaylist(library.songs(in: currentPlaylist), shuffled: lastPlaylistPlaybackWasShuffled)
                }
            }
            Button("Cancel", role: .cancel) { playlistPlaybackError = nil }
        } message: {
            Text(playlistPlaybackError ?? "")
        }
        .onChange(of: playlist?.trackIDs) { _, _ in
            // A reorder or removal invalidates the requested queue immediately.
            // Do not hold Play/Shuffle busy while the old filesystem scan finishes.
            if playlistPlaybackPending {
                cancelPlaylistPreparation(showFeedback: true)
                playlistPlaybackNotice = "Playlist order or contents changed. Retry to play the current playlist."
            }
        }
        .onChange(of: playlistScenePhase) { _, phase in
            if phase != .active { cancelPlaylistPreparation(showFeedback: false) }
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

    var body: some View {
        NavigationStack {
            List {
                Section("REQUESTED RECORDING") {
                    Text(wish.title).font(.headline)
                    Text(wish.artist)
                    if let length = wish.durationSeconds { Text("Expected length: \(length.formatted(.number.precision(.fractionLength(0)))) seconds") }
                    if working { ProgressView("Resolving and checking this recording…") }
                    if let issue { Text(issue).foregroundStyle(.red) }
                }
                ForEach(RecordingMatcher.rank(candidates, for: wish).prefix(8), id: \.candidate.id) { match in
                    Section {
                        Text(match.candidate.title).font(.headline)
                        Text(match.candidate.uploader).font(.subheadline)
                        Text("Match score: \(match.score) • \(match.reason)").font(.caption)
                        if let duration = match.candidate.durationSeconds { Text("\(duration.formatted(.number.precision(.fractionLength(0)))) seconds").font(.caption) }
                        Link("Open recording source", destination: match.candidate.pageURL)
                        Button("Download this recording") {
                            working = true
                            issue = nil
                            task = Task { @MainActor in
                                defer { working = false }
                                do {
                                    try await library.queueRecording(match.candidate, matching: wish, playlistID: playlistID)
                                    dismiss()
                                } catch is CancellationError { }
                                catch { issue = error.localizedDescription }
                            }
                        }
                        .disabled(working || match.decision == .rejected)
                    }
                }
            }
            .navigationTitle("Recording matches")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
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
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var isDownloading = false
    @State private var errorMessage: String?

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
                }
                Section("DIRECT AUDIO FILE URL") {
                    TextField("https://example.org/song.mp3", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Paste a direct HTTPS audio-file URL. MP3 Shelf checks that the file can play and matches the song's duration when available, then attaches it to this playlist.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
                              url.scheme?.lowercased() == "https",
                              url.host != nil else {
                            errorMessage = "Enter a direct HTTPS audio file link."
                            return
                        }
                        isDownloading = true
                        Task {
                            defer { isDownloading = false }
                            do {
                                let result = try await library.downloadAudio(from: url, matching: wish)
                                if result.imported > 0 {
                                    dismiss()
                                } else {
                                    errorMessage = "The audio file is already stored. Check the song's title and artist in your library to match this playlist."
                                }
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        if isDownloading {
                            HStack {
                                ProgressView()
                                Text("Downloading and checking audio…")
                            }
                        } else {
                            Label("Download and attach this song", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .disabled(isDownloading || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .disabled(isDownloading)
                }
            }
            .alert("Audio Download", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
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
    @State private var scanTask: Task<Void, Never>?
    @State private var selectedLink: WebAudioSelection?
    @State private var inspectingWish: PlaylistWish?
    @State private var inspectingPages: Set<String> = []
    @State private var inspectingWishes: Set<UUID> = []
    @State private var inspectedCount: [UUID: Int] = [:]
    @State private var extractedLinks: [String: [URL]] = [:]
    @State private var inspectionErrors: [String: String] = [:]
    @State private var message: String?

    // Keep every scan under 100 Brave API requests, regardless of depth.
    // Pagination makes songs beyond the first 100 accessible without silent cost.
    private var pageSize: Int { max(1, 100 / searchDepth.rawValue) }
    private var batch: [PlaylistWish] {
        Array(wishes.dropFirst(pageStart).prefix(pageSize))
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
                    Text("This batch contains \(batch.count) songs and can make up to \(batch.count * searchDepth.rawValue) billable Brave API searches. Extensive mode combines general, store, direct-file, official and archive searches.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        guard WebAudioSearch.saveKey(apiKey) else {
                            message = "Could not securely save the search key to Keychain."
                            return
                        }
                        scanTask?.cancel()
                        results = [:]
                        issues = [:]
                        searched = 0
                        inspectedDuringSearch = 0
                        scanning = true
                        let currentBatch = batch
                        let depth = searchDepth
                        let inspectPages = inspectPagesDuringSearch
                        scanTask = Task {
                            var inspectedPages = 0
                            var scannedStop = false
                            let key = apiKey
                            for wish in currentBatch {
                                if Task.isCancelled { break }
                                do {
                                    let found = try await WebAudioSearch.search(for: wish, using: key, depth: depth)
                                    results[wish.id] = found
                                    if inspectPages && inspectedPages < 12 {
                                        let candidates = WebAudioSearch.pagesWorthInspecting(
                                            found, for: wish, limit: 1)
                                        for hit in candidates {
                                            if Task.isCancelled { break }
                                            inspectedPages += 1
                                            inspectingPages.insert(hit.id)
                                            do {
                                                extractedLinks[hit.id] = try await AudioLandingPageInspector.inspect(
                                                    hit.url, maxProbes: 2)
                                            } catch is CancellationError {
                                                inspectingPages.remove(hit.id)
                                                break
                                            } catch {
                                                inspectionErrors[hit.id] = error.localizedDescription
                                            }
                                            inspectingPages.remove(hit.id)
                                            inspectedDuringSearch = inspectedPages
                                        }
                                    }
                                } catch is CancellationError {
                                    break
                                } catch {
                                    issues[wish.id] = error.localizedDescription
                                    // Do not repeatedly hit an invalid key or exhausted API quota.
                                    if let problem = error as? WebAudioSearch.SearchFailure {
                                        switch problem {
                                        case .rejectedKey, .rateLimited:
                                            scannedStop = true
                                        default: break
                                        }
                                    }
                                }
                                searched += 1
                                if scannedStop { break }
                            }
                            scanning = false
                        }
                    } label: {
                        Label(scanning ? "Searching web…" : "Find downloadable sources for missing songs",
                              systemImage: "magnifyingglass")
                    }
                    .disabled(scanning || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || batch.isEmpty)
                    if scanning {
                        ProgressView(value: Double(searched), total: Double(max(1, batch.count)))
                        Text("\(searched) of \(batch.count) songs searched" +
                             (inspectPagesDuringSearch ? " · \(inspectedDuringSearch) source pages inspected" : ""))
                            .font(.caption.monospacedDigit())
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
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        } else if let found = results[wish.id] {
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
                                        Task {
                                            defer { inspectingWishes.remove(wish.id) }
                                            for hit in candidates {
                                                if Task.isCancelled { break }
                                                if extractedLinks[hit.id] != nil {
                                                    inspectedCount[wish.id, default: 0] += 1
                                                    continue
                                                }
                                                inspectingPages.insert(hit.id)
                                                inspectionErrors.removeValue(forKey: hit.id)
                                                do {
                                                    extractedLinks[hit.id] = try await AudioLandingPageInspector.inspect(hit.url)
                                                } catch {
                                                    inspectionErrors[hit.id] = error.localizedDescription
                                                }
                                                inspectingPages.remove(hit.id)
                                                inspectedCount[wish.id, default: 0] += 1
                                            }
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
                                            let page = hit.url
                                            inspectingPages.insert(hit.id)
                                            inspectionErrors.removeValue(forKey: hit.id)
                                            Task {
                                                defer { inspectingPages.remove(hit.id) }
                                                do {
                                                    extractedLinks[hit.id] = try await AudioLandingPageInspector.inspect(page)
                                                } catch {
                                                    inspectionErrors[hit.id] = error.localizedDescription
                                                }
                                            }
                                        } label: {
                                            Label(inspectingPages.contains(hit.id)
                                                ? "Checking page for audio links…"
                                                : "Find audio files linked on this page",
                                                systemImage: "doc.text.magnifyingglass")
                                                .font(.caption.weight(.medium))
                                        }
                                        .disabled(inspectingPages.contains(hit.id))
                                        if let discovered = extractedLinks[hit.id] {
                                            if discovered.isEmpty {
                                                Text("No direct audio files advertised by this page.")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            } else {
                                                ForEach(discovered, id: \.absoluteString) { file in
                                                    Button {
                                                        selectedLink = WebAudioSelection(wish: wish, url: file)
                                                    } label: {
                                                        Label("Review \(file.lastPathComponent)",
                                                              systemImage: "waveform.circle")
                                                            .font(.caption.weight(.semibold))
                                                            .lineLimit(2)
                                                    }
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
            .onDisappear { scanTask?.cancel() }
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
    @State private var pageText = ""
    @State private var isInspecting = false
    @State private var candidates: [URL] = []
    @State private var error: String?
    @State private var chosenAudio: WebAudioSelection?
    @State private var inspectionTask: Task<Void, Never>?
    @State private var inspectionID = UUID()
    @State private var completedInspection = false
    @State private var candidateFilter = ""
    @AccessibilityFocusState private var inspectionFeedbackFocused: Bool

    private var visibleCandidates: [URL] {
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
    private func invalidateInspection() {
        inspectionTask?.cancel()
        inspectionTask = nil
        inspectionID = UUID()
        isInspecting = false
        candidates = []
        candidateFilter = ""
        error = nil
        completedInspection = false
        inspectionFeedbackFocused = false
    }

    private func inspectPage() {
        let input = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pageURL = WebAudioSearch.sanitizedResultURL(input) else {
            invalidateInspection()
            error = "Enter a public HTTPS webpage URL."
            inspectionFeedbackFocused = true
            return
        }
        invalidateInspection()
        let requestID = inspectionID
        isInspecting = true
        inspectionTask = Task {
            do {
                let found = try await AudioLandingPageInspector.inspect(pageURL)
                guard !Task.isCancelled, inspectionID == requestID else { return }
                candidates = found
                completedInspection = true
                inspectionFeedbackFocused = found.isEmpty
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, inspectionID == requestID else { return }
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
                    TextField("https://artist.example/music/song", text: $pageText)
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
                    .disabled(isInspecting || pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if isInspecting {
                        HStack(spacing: 12) {
                            ProgressView()
                                .accessibilityHidden(true)
                            Text("Inspecting this page…")
                                .font(.subheadline)
                            Spacer(minLength: 0)
                            Button("Cancel inspection") {
                                invalidateInspection()
                            }
                            .frame(minHeight: 44)
                            .accessibilityHint("Stop inspecting this page without changing the URL")
                        }
                        .accessibilityElement(children: .contain)
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
                            .disabled(isInspecting)
                            .accessibilityHint("Try the same webpage again without losing its address")
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
                            .accessibilityHint("Repeat the inspection of this webpage")
                        }
                    }
                }
                if !candidates.isEmpty {
                    Section("POSSIBLE AUDIO FILES") {
                        Text("\(candidates.count) possible audio links found. Review the recording and publisher before downloading.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if candidates.count > 5 {
                            TextField("Filter audio links", text: $candidateFilter)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityHint("Filter results by filename or publisher without another network request")
                            if !candidateFilter.isEmpty {
                                Button("Clear link filter") { candidateFilter = "" }
                                    .frame(minHeight: 44)
                            }
                        }
                        if visibleCandidates.isEmpty {
                            Text("No links match this filter. Clear it to see all discovered files.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(visibleCandidates, id: \.absoluteString) { file in
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
            .onChange(of: pageText) { _, _ in invalidateInspection() }
            .onDisappear { invalidateInspection() }
        }
    }
}
