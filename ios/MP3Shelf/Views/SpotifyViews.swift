import SwiftUI

struct SpotifyConnectView: View {
    @EnvironmentObject private var spotify: SpotifyService
    @EnvironmentObject private var library: MusicLibrary
    @State private var importingID: String?
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 13) {
                    PremiumIcon(symbol: "square.stack.3d.up", color: ShelfTheme.coral, size: 54)
                    VStack(alignment: .leading, spacing: 5) {
                        PremiumEyebrow(title: "YOUR PLAYLISTS", color: ShelfTheme.coral)
                        Text("Connect your Spotify")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.vertical, 6)
                Text("Browse supported Spotify playlists and build an offline playlist using audio files you already own. Spotify does not allow this app to download its streams as MP3 files.")
                    .font(.subheadline).foregroundStyle(ShelfTheme.subdued)
                if !spotify.isConnected {
                    TextField("Spotify Developer Client ID", text: $spotify.clientID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { Task { await spotify.signIn() } } label: {
                        Label(spotify.isBusy ? "Connecting…" : "Sign in with Spotify", systemImage: "person.crop.circle")
                    }
                    .disabled(spotify.isBusy || spotify.clientID.isEmpty)
                    Text("For personal builds, create a Spotify developer app and register mp3shelf-auth://callback exactly. Spotify requires a Premium account and allowlisted testers in development mode.")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                } else {
                    Label("Connected", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                    Button("Refresh Spotify Playlists") { Task { await reload() } }
                    Button("Disconnect", role: .destructive) { spotify.disconnect() }
                }
            } header: { Text("ACCOUNT CONNECTION") }
            .listRowBackground(ShelfTheme.surface)
            if spotify.isConnected {
                Section("YOUR AVAILABLE PLAYLISTS") {
                    if spotify.playlists.isEmpty {
                        Text("No accessible playlists returned. Spotify may restrict playlists you follow but do not own or collaborate on.")
                            .foregroundStyle(ShelfTheme.subdued)
                    }
                    ForEach(spotify.playlists) { playlist in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(playlist.name).font(.headline)
                            HStack {
                                Button(importingID == playlist.id ? "Importing…" : "Import Track List") {
                                    Task { await importPlaylist(playlist) }
                                }
                                .buttonStyle(.borderedProminent).tint(ShelfTheme.accent)
                                .disabled(importingID != nil)
                                if let link = playlist.external_urls?.spotify, let url = URL(string: link) {
                                    Link("Open in Spotify", destination: url).font(.caption)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section("IMPORT WITHOUT LOGIN") {
                NavigationLink("Import CSV / TSV Playlist") { SpotifyImportView() }
                Text("CSV import remains available without Spotify sign-in or API access.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
            }
            Section("HOW IT WORKS") {
                Text("Spotify authentication and playlist lookup require internet access. MP3 Shelf's previously imported audio and playlists work offline.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PremiumBackdrop())
        .tint(ShelfTheme.accent)
        .navigationTitle("Spotify Playlists")
        .onChange(of: spotify.message) { _, new in
            if let new { notice = new; spotify.message = nil }
        }
        .alert("Spotify Import", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func reload() async {
        do { try await spotify.refreshPlaylists() }
        catch { notice = error.localizedDescription }
    }

    private func importPlaylist(_ list: SpotifyPlaylist) async {
        importingID = list.id
        defer { importingID = nil }
        do {
            let wishes = try await spotify.getTrackList(for: list)
            let report = library.importPlaylist(wishes: wishes, name: list.name,
                sourceURL: list.external_urls?.spotify)
            if report.missing > 0, let imported = library.playlists.last {
                library.startAutomaticDownloads(for: imported.id)
            }
            notice = "\(report.playlistName): \(report.matched) ready now, \(report.missing) queued for automatic licensed-source lookup. Open the imported playlist to view progress."
        } catch { notice = error.localizedDescription }
    }
}
