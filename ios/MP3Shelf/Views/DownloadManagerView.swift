import SwiftUI

struct DownloadManagerView: View {
    @ObservedObject private var transfers = BackgroundAudioDownloader.shared
    @EnvironmentObject private var library: MusicLibrary
    @State private var confirmClear = false

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
                LabeledContent("In progress", value: "\(transfers.pendingCount())")
                LabeledContent("Music stored", value: ByteCountFormatter.string(
                    fromByteCount: library.totalStorageBytes, countStyle: .file))
                NavigationLink {
                    MusicStorageView()
                } label: {
                    Label("Manage Music Storage", systemImage: "externaldrive")
                }
            } header: { Text("OVERVIEW") }
            .listRowBackground(ShelfTheme.surface)

            Section("YOUR DOWNLOADS") {
                let items = transfers.ticketsForPlaylist()
                if items.isEmpty {
                    ContentUnavailableView("No transfers yet",
                                           systemImage: "arrow.down.circle",
                                           description: Text("Import a playlist to discover authorized MP3 downloads."))
                } else {
                    ForEach(items) { item in
                        DownloadTicketRow(ticket: item)
                            .listRowBackground(ShelfTheme.surface)
                    }
                }
            }
            Section {
                Button("Clear Finished Download History", role: .destructive) {
                    confirmClear = true
                }
                .disabled(transfers.ticketsForPlaylist().allSatisfy { $0.status == .queued })
                Text("Removing history does not delete playable music. Use Manage Music Storage to delete stored MP3 files.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
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
        case .queued: return "Downloading"
        case .imported: return "Saved Offline"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
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
                    .foregroundStyle(ticket.status == .imported ? .green : ShelfTheme.subdued)
            }
            if ticket.status == .queued {
                if let size = ticket.totalBytes, size > 0 {
                    ProgressView(value: Double(ticket.bytesReceived ?? 0), total: Double(size))
                    Text("\(ByteCountFormatter.string(fromByteCount: ticket.bytesReceived ?? 0, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                        .font(.caption.monospacedDigit()).foregroundStyle(ShelfTheme.subdued)
                } else {
                    ProgressView()
                    Text("Queued or receiving data")
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
            }
            HStack(spacing: 16) {
                Link("Source", destination: ticket.sourcePage)
                Link("Declared License", destination: ticket.licensePage)
            }
            .font(.caption)
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
                        Text(ByteCountFormatter.string(fromByteCount: library.totalStorageBytes,
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
