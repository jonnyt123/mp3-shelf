import SwiftUI

struct DownloadManagerView: View {
    private enum TransferFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case saved = "Saved"
        case issues = "Issues"

        var id: String { rawValue }

        func includes(_ ticket: BackgroundAudioTicket) -> Bool {
            switch self {
            case .all: return true
            case .active: return ticket.status == .queued
            case .saved: return ticket.status == .imported
            case .issues: return ticket.status == .failed || ticket.status == .cancelled
            }
        }
    }

    @ObservedObject private var transfers = BackgroundAudioDownloader.shared
    @EnvironmentObject private var library: MusicLibrary
    @State private var confirmClear = false
    @State private var selectedFilter: TransferFilter = .all

    private var allTickets: [BackgroundAudioTicket] {
        transfers.ticketsForPlaylist()
    }

    private var visibleTickets: [BackgroundAudioTicket] {
        allTickets.filter { selectedFilter.includes($0) }
    }

    private var incompletePlaylists: [MusicPlaylist] {
        library.playlists.filter { !$0.missingTracks.isEmpty }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 17) {
                    PremiumIcon(symbol: "arrow.down.to.line.compact",
                                color: ShelfTheme.mint, size: 62)
                    VStack(alignment: .leading, spacing: 4) {
                        PremiumEyebrow(title: "YOUR TRANSFERS")
                        Text("\(transfers.pendingCount()) active downloads")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Keep your soundtrack with you.")
                            .font(.caption).foregroundStyle(ShelfTheme.subdued)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                LabeledContent("Music stored", value: library.totalStorageBytes == 0
                    ? "0 MB"
                    : ByteCountFormatter.string(
                        fromByteCount: library.totalStorageBytes, countStyle: .file))
                Button("Retry failed downloads") { transfers.retryFailedDownloads() }
                    .disabled(!transfers.canRetryFailedDownloads)
                Text("Retries fill available transfer slots. Cancelled downloads stay cancelled; source search stays paused if you paused it.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
                Button("Recheck saved audio") { library.recheckSavedAudio() }
                Text("Refresh playlist matches if audio files were moved or removed in Files.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
                NavigationLink {
                    MusicStorageView()
                } label: {
                    Label("Manage Music Storage", systemImage: "externaldrive")
                }
            } header: { Text("OVERVIEW") }
            .listRowBackground(ShelfTheme.surface)

            if !incompletePlaylists.isEmpty {
                Section {
                    Text("A playlist link supplies song details. An MP3 transfer starts only after a downloadable recording is found; some songs have no matching source.")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                    ForEach(incompletePlaylists) { playlist in
                        VStack(alignment: .leading, spacing: 12) {
                            NavigationLink {
                                PlaylistDetailView(playlistID: playlist.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(playlist.name).font(.headline)
                                    let total = playlist.sourceOrder.count
                                    let saved = playlist.sourceOrder.filter { library.hasOfflineRecording(matching: $0) }.count
                                    Text("\(saved) of \(total) playlist entries saved offline")
                                        .font(.caption.monospacedDigit()).foregroundStyle(ShelfTheme.subdued)
                                    ProgressView(value: Double(saved), total: Double(max(1, total)))
                                        .tint(ShelfTheme.mint)
                                        .accessibilityLabel("Offline playlist progress")
                                        .accessibilityValue("\(saved) of \(total) saved")
                                    let playlistTickets = transfers.ticketsForPlaylist(playlist.id)
                                    let activeCount = playlistTickets.filter { $0.status == .queued }.count
                                    let failedCount = playlistTickets.filter { $0.status == .failed }.count
                                    let cancelledCount = playlistTickets.filter { $0.status == .cancelled }.count
                                    Text("\(activeCount) active · \(failedCount) failed · \(cancelledCount) cancelled transfers")
                                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                    if let job = library.discoveryJob(for: playlist.id) {
                                        Text(job.isComplete ? "Source search finished" :
                                             job.isPaused ? "Source search paused" :
                                             "Source search: \(job.nextIndex)/\(job.wishes.count) checked")
                                            .font(.caption)
                                        if job.unavailable > 0 {
                                            Text("\(job.unavailable) songs had no qualifying MP3 source")
                                                .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                        }
                                        if job.failed > 0 {
                                            Text("\(job.failed) song lookups failed")
                                                .font(.caption).foregroundStyle(ShelfTheme.coral)
                                        }
                                        if let reason = job.lastError {
                                            Text(reason).font(.caption)
                                                .foregroundStyle(ShelfTheme.coral)
                                        }
                                        if !job.isComplete {
                                            if !job.isPaused, let retry = job.nextRetryAt {
                                                Text("Search retry scheduled: \(retry.formatted(date: .omitted, time: .shortened))")
                                                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                            }
                                        }
                                    } else {
                                        Text("Source search has not started")
                                            .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                    }
                                    Text("View song status and download options")
                                        .font(.caption).foregroundStyle(ShelfTheme.accent)
                                }
                                .padding(.vertical, 6)
                            }
                        PlaylistDownloadControls(playlist: playlist)
                        }
                    }
                } header: { Text("PLAYLIST SOURCE SEARCHES") }
                .listRowBackground(ShelfTheme.surface)
            }

            Section("YOUR DOWNLOADS") {
                Picker("Show transfers", selection: $selectedFilter) {
                    ForEach(TransferFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .accessibilityLabel("Filter downloads")

                if visibleTickets.isEmpty {
                    VStack(alignment: .leading, spacing: 11) {
                        PremiumIcon(symbol: selectedFilter == .issues
                                     ? "checkmark.shield"
                                     : "arrow.down.circle",
                                    color: selectedFilter == .issues
                                        ? ShelfTheme.mint : ShelfTheme.accent,
                                    size: 49)
                        Text(selectedFilter == .issues
                             ? "No failed or cancelled transfers"
                             : selectedFilter == .saved
                                ? "No saved downloads yet"
                                : selectedFilter == .active
                                    ? "No transfers in progress"
                                    : "Your downloads will appear here")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                        Text(selectedFilter == .all
                             ? "Import a playlist to find independently licensed MP3 files."
                             : "Switch to All to review your other downloads.")
                            .font(.subheadline)
                            .foregroundStyle(ShelfTheme.subdued)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                    .listRowBackground(ShelfTheme.surface)
                } else {
                    ForEach(visibleTickets) { item in
                        DownloadTicketRow(ticket: item)
                            .listRowBackground(ShelfTheme.surface)
                    }
                }
            }
            if allTickets.contains(where: { $0.status != .queued }) {
                Section {
                    Button("Clear Finished Download History", role: .destructive) {
                        confirmClear = true
                    }
                    Text("Removing history does not delete playable music. Use Manage Music Storage to delete stored MP3 files.")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PremiumBackdrop())
        .tint(ShelfTheme.accent)
        .navigationTitle("Downloads")
        .confirmationDialog("Clear completed, cancelled and failed history?",
                            isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { transfers.clearFinishedHistory() }
        } message: {
            Text("Your downloaded songs and playlists stay on the phone.")
        }
    }
}

private struct DownloadTicketRow: View {
    let ticket: BackgroundAudioTicket
    @ObservedObject private var transfers = BackgroundAudioDownloader.shared
    @EnvironmentObject private var library: MusicLibrary

    private var statusText: String {
        switch ticket.status {
        case .queued:
            if transfers.isFinalizing(ticket.id) { return "Finalizing" }
            if transfers.hasStagedAudio(ticket.id) { return "Ready to save" }
            if ticket.nextRetryAt != nil { return "Retrying" }
            return (ticket.bytesReceived ?? 0) > 0 ? "Downloading" : "Queued"
        case .imported: return "Saved Offline"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        switch ticket.status {
        case .queued: return ShelfTheme.mint
        case .imported: return ShelfTheme.accent
        case .failed: return ShelfTheme.coral
        case .cancelled: return ShelfTheme.subdued
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                PremiumIcon(symbol: ticket.status == .imported ? "checkmark" :
                            ticket.status == .queued ? "arrow.down" :
                            ticket.status == .failed ? "exclamationmark" : "xmark",
                            color: statusColor, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ticket.requested.title).font(.headline).lineLimit(2)
                    Text(ticket.requested.artist)
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                    Text(library.playlists.first(where: { $0.id == ticket.playlistID })?.name ?? "Imported Playlist")
                        .font(.caption2).foregroundStyle(ShelfTheme.subdued)
                }
                Spacer()
                Text(statusText)
                    .font(.caption.bold())
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }
            if ticket.status == .queued {
                if transfers.isFinalizing(ticket.id) {
                    Text("Checking audio format and saving to your library")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                } else if let alternatives = ticket.alternativeSources, !alternatives.isEmpty {
                    Label("\(alternatives.count) alternate verified source\(alternatives.count == 1 ? "" : "s") ready if this one fails",
                          systemImage: "arrow.triangle.branch")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ShelfTheme.mint)
                }
                if !transfers.hasStagedAudio(ticket.id), let retry = ticket.nextRetryAt {
                    Label("Temporary interruption · automatic retry \(ticket.automaticRetryCount ?? 0)/\(BackgroundTransferRetryPolicy.maxRetries)",
                          systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium)).foregroundStyle(ShelfTheme.mint)
                    Text("Scheduled no earlier than \(retry.formatted(date: .omitted, time: .shortened)) · Wi-Fi unless cellular was explicitly approved")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                }
                if transfers.isFinalizing(ticket.id) {
                    ProgressView().tint(ShelfTheme.mint)
                        .accessibilityLabel("Finalizing audio for \(ticket.requested.title)")
                } else if transfers.hasStagedAudio(ticket.id) {
                    Text("Audio is downloaded and waiting to be checked and saved.")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                    Button("Finish saving") { transfers.finishSavingStagedAudio() }
                } else if let size = ticket.totalBytes, size > 0 {
                    ProgressView(value: Double(ticket.bytesReceived ?? 0), total: Double(size))
                        .tint(ShelfTheme.mint)
                        .accessibilityLabel("Download progress for \(ticket.requested.title)")
                    Text("\(ByteCountFormatter.string(fromByteCount: ticket.bytesReceived ?? 0, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                        .font(.caption.monospacedDigit()).foregroundStyle(ShelfTheme.subdued)
                } else {
                    ProgressView().tint(ShelfTheme.mint)
                    Text((ticket.bytesReceived ?? 0) > 0
                         ? "\(ByteCountFormatter.string(fromByteCount: ticket.bytesReceived ?? 0, countStyle: .file)) received · total size unknown"
                         : "Waiting for network or starting transfer")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                }
                Button("Cancel", role: .destructive) { transfers.cancelTransfer(ticket.id) }
                    .font(.subheadline)
            } else if ticket.status == .failed || ticket.status == .cancelled {
                if let reason = ticket.failureReason {
                    Text(reason).font(.caption).foregroundStyle(ShelfTheme.subdued)
                }
                Button {
                    transfers.retry(ticket.id)
                } label: {
                    Label("Retry MP3", systemImage: "arrow.clockwise")
                }
                .font(.subheadline)
                .disabled(!transfers.canRetry(ticket.id))
                if !transfers.canRetry(ticket.id) {
                    Text("Retry becomes available when a slot opens, or in the playlist that still contains this download.")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                }
            }
            HStack(spacing: 16) {
                Link(destination: ticket.sourcePage) {
                    Label("Source", systemImage: "arrow.up.right")
                }
                Link(destination: ticket.licensePage) {
                    Label("License", systemImage: "doc.text")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(ShelfTheme.accent)
        }
        .padding(.vertical, 12)
    }
}

struct MusicStorageView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @State private var toDelete: MusicTrack?

    private var sortedTracks: [MusicTrack] {
        library.tracks.sorted { library.trackSizeBytes($0) > library.trackSizeBytes($1) }
    }

    var body: some View {
        List {
            Section("Storage Used by Audio Files") {
                HStack(spacing: 13) {
                    PremiumIcon(symbol: "externaldrive.fill", color: ShelfTheme.coral, size: 57)
                    VStack(alignment: .leading, spacing: 4) {
                        PremiumEyebrow(title: "ON THIS IPHONE", color: ShelfTheme.coral)
                        Text(library.totalStorageBytes == 0
                             ? "0 MB"
                             : ByteCountFormatter.string(fromByteCount: library.totalStorageBytes,
                                                        countStyle: .file))
                            .font(.system(.title2, design: .rounded, weight: .bold))
                    }
                }
                .padding(.vertical, 8)
                LabeledContent("Saved songs", value: "\(library.tracks.count)")
                Text("Files are stored locally and remain available offline. Deleting a song removes its copy and artwork/lyrics, and restores a missing entry in imported playlists.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
            }
            Section("LARGEST FILES FIRST") {
                ForEach(sortedTracks) { track in
                    HStack(spacing: 12) {
                        PremiumIcon(symbol: "music.note", color: ShelfTheme.accent, size: 39)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).lineLimit(1)
                            Text(track.artist).font(.caption)
                                .foregroundStyle(ShelfTheme.subdued).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(ByteCountFormatter.string(fromByteCount: library.trackSizeBytes(track),
                                                       countStyle: .file))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ShelfTheme.subdued)
                        Button(role: .destructive) { toDelete = track } label: {
                            Image(systemName: "trash").frame(width: 32, height: 36)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(track.title)")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PremiumBackdrop())
        .tint(ShelfTheme.accent)
        .navigationTitle("Music Storage")
        .confirmationDialog("Delete local audio file?", isPresented: Binding(
            get: { toDelete != nil },
            set: { if !$0 { toDelete = nil } })) {
                Button("Delete Song", role: .destructive) {
                    guard let track = toDelete else { return }
                    if playback.currentTrackID == track.id { playback.stop() }
                    library.removeTrack(track.id)
                    toDelete = nil
                }
                Button("Keep Song", role: .cancel) { toDelete = nil }
            } message: {
                Text("The MP3 copy will be deleted from this iPhone. Your imported playlist track list will be preserved.")
            }
    }
}

private struct PlaylistDownloadControls: View {
    let playlist: MusicPlaylist
    @EnvironmentObject private var library: MusicLibrary
    @ObservedObject private var transfers = BackgroundAudioDownloader.shared
    @State private var confirmCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let job = library.discoveryJob(for: playlist.id), !job.isComplete {
                Button(job.isPaused ? "Resume search" : "Pause search") {
                    if job.isPaused { library.resumeSourceDiscovery(for: playlist.id) }
                    else { library.pauseSourceDiscovery(for: playlist.id) }
                }
                .frame(minHeight: 44)
                Text("Pausing search lets already queued transfers continue.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
            } else {
                Button(library.discoveryJob(for: playlist.id) == nil ? "Find missing songs" : "Search missing songs again") {
                    library.startAutomaticDownloads(for: playlist.id)
                }
                .frame(minHeight: 44)
            }
            if transfers.pendingCount(for: playlist.id) > 0 {
                Button("Cancel transfers", role: .destructive) { confirmCancel = true }
                    .frame(minHeight: 44)
            }
        }
        .buttonStyle(.bordered)
        .confirmationDialog("Cancel transfers for \(playlist.name)?", isPresented: $confirmCancel) {
            Button("Cancel transfers", role: .destructive) {
                library.stopBackgroundTransfers(for: playlist.id)
            }
        } message: {
            Text("This also pauses source search. Songs already saved offline stay in your library.")
        }
    }
}
