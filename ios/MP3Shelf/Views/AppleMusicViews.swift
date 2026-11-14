import SwiftUI
import UIKit

@MainActor
struct AppleMusicImportView: View {
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appleMusic = AppleMusicService()
    @State private var importTask: Task<Void, Never>?
    @State private var importingID: UInt64?
    @State private var notice: String?
    @State private var selectedPlaylistID: UUID?
    @State private var showDownloadDashboard = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 13) {
                    PremiumIcon(symbol: "music.note.list", color: ShelfTheme.coral, size: 54)
                    VStack(alignment: .leading, spacing: 5) {
                        PremiumEyebrow(title: "YOUR PLAYLISTS", color: ShelfTheme.coral)
                        Text("Bring your Apple Music playlists")
                            .font(.headline).foregroundStyle(.white)
                    }
                }
                Text("Choose a playlist from your iPhone's Music library. MP3 Shelf reads its song list, then finds matching recordings and saves MP3 files for offline listening.")
                    .foregroundStyle(ShelfTheme.subdued)
                if appleMusic.isAuthorized {
                    Label("Music library access enabled", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(ShelfTheme.mint)
                    Button("Refresh Apple Music playlists") { startRefresh() }
                        .disabled(appleMusic.isBusy || importingID != nil)
                } else if appleMusic.needsSettings {
                    Text("Enable Media & Apple Music access for MP3 Shelf in Settings.")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                    Button("Open app settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } else {
                    Button("Read my Apple Music playlists") { startRefresh(requestAccess: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(appleMusic.isBusy)
                }
                if appleMusic.isBusy { ProgressView(importingID == nil ? "Reading your playlists…" : "Reading playlist songs…") }
            } header: { Text("APPLE MUSIC LIBRARY") }
            .listRowBackground(ShelfTheme.surface)

            if appleMusic.isAuthorized {
                Section("CHOOSE A PLAYLIST") {
                    if appleMusic.playlists.isEmpty && !appleMusic.isBusy {
                        Text("No playlists are visible yet. Add the playlist to your library in Music, allow it to sync, then refresh here.")
                            .foregroundStyle(ShelfTheme.subdued)
                    }
                    ForEach(appleMusic.playlists) { playlist in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(playlist.name).font(.headline)
                            Text("\(playlist.itemCount) items").font(.caption).foregroundStyle(ShelfTheme.subdued)
                            Button(importingID == playlist.id ? "Preparing songs…" : "Find & Save Offline MP3s") {
                                startImport(playlist)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(appleMusic.isBusy || importingID != nil || playlist.itemCount == 0)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listRowBackground(ShelfTheme.surface)
            }
            Section("HOW IT WORKS") {
                Text("Playlist order and repeated songs are preserved. Reimporting updates the same playlist. Matching uses the existing recording engine, with Wi-Fi downloads by default and review choices when a match is uncertain.")
                Text("This reads playlist details from Music. Audio files come from the recording sources found by MP3 Shelf.")
                NavigationLink("Import CSV / TSV instead") { SpotifyImportView() }
            }
            .font(.caption).foregroundStyle(ShelfTheme.subdued)
            .listRowBackground(ShelfTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(PremiumBackdrop())
        .tint(ShelfTheme.accent)
        .navigationTitle("Apple Music Playlists")
        .task {
            appleMusic.checkAuthorization()
            if appleMusic.isAuthorized { await refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { appleMusic.checkAuthorization() }
        }
        .onDisappear { importTask?.cancel() }
        .navigationDestination(isPresented: $showDownloadDashboard) {
            if let selectedPlaylistID { PlaylistDetailView(playlistID: selectedPlaylistID) }
        }
        .alert("Apple Music Import", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func startRefresh(requestAccess: Bool = false) {
        guard importingID == nil else { return }
        importTask?.cancel()
        importTask = Task { await refresh(requestAccess: requestAccess) }
    }

    private func refresh(requestAccess: Bool = false) async {
        do { try await appleMusic.refresh(requestAccess: requestAccess) }
        catch is CancellationError { }
        catch { notice = error.localizedDescription }
    }

    private func startImport(_ playlist: AppleMusicPlaylistSummary) {
        guard importingID == nil, !appleMusic.isBusy else { return }
        importTask?.cancel()
        importingID = playlist.id
        importTask = Task { @MainActor in
            defer { importingID = nil }
            do {
                let snapshot = try await appleMusic.snapshot(for: playlist.id)
                let wishes = try snapshot.wishes(namespace: appleMusic.namespace)
                try Task.checkCancellation()
                let report = library.importPlaylist(wishes: wishes, name: snapshot.name,
                    appleMusicLibraryID: AppleMusicLibraryIdentity.key(namespace: appleMusic.namespace, persistentID: snapshot.id))
                if report.missing > 0 && library.discoveryJob(for: report.playlistID) == nil {
                    library.startAutomaticDownloads(for: report.playlistID)
                }
                selectedPlaylistID = report.playlistID
                showDownloadDashboard = true
            } catch is CancellationError { }
            catch { notice = error.localizedDescription }
        }
    }
}

@MainActor
struct PlaylistSourcesView: View {
    var body: some View {
        Form {
            Section("CHOOSE A PLAYLIST SOURCE") {
                NavigationLink { AppleMusicImportView() } label: {
                    Label("Apple Music library", systemImage: "music.note.list")
                }
                NavigationLink { SpotifyConnectView() } label: {
                    Label("Spotify playlists", systemImage: "square.stack.3d.up")
                }
                NavigationLink { SpotifyImportView() } label: {
                    Label("CSV / TSV track list", systemImage: "doc.text")
                }
            }
            .listRowBackground(ShelfTheme.surface)
        }
        .navigationTitle("Import a playlist")
        .scrollContentBackground(.hidden)
        .background(PremiumBackdrop())
        .tint(ShelfTheme.accent)
    }
}
