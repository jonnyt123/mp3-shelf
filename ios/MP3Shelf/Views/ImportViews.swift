import SwiftUI
import UniformTypeIdentifiers

struct DownloadView: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var remoteURL = ""
    @State private var notice: String?
    @State private var isDownloading = false
    @State private var showImporter = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Offline means offline", systemImage: "wifi.slash")
                        .font(.headline)
                    Text("Imported files are copied onto your iPhone. Play them with airplane mode on, even when the original file is no longer available.")
                        .font(.subheadline).foregroundStyle(ShelfTheme.subdued)
                }
                .padding(.vertical, 8)
                Button { showImporter = true } label: {
                    Label(library.isImporting ? "Importing…" : "Choose Audio from Files", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(library.isImporting)
            } header: { Text("Import from Files") }
            Section {
                TextField("https://example.com/your-song.mp3", text: $remoteURL, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(2...3)
                Button {
                    guard let url = URL(string: remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        notice = "Enter a valid HTTPS address to an audio file."
                        return
                    }
                    isDownloading = true
                    Task {
                        defer { isDownloading = false }
                        do { notice = try await library.downloadAudio(from: url).description }
                        catch { notice = error.localizedDescription }
                    }
                } label: {
                    HStack {
                        if isDownloading { ProgressView().tint(.white) }
                        Label(isDownloading ? "Downloading Audio…" : "Download Audio File", systemImage: "arrow.down.to.line")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ShelfTheme.accent)
                .disabled(isDownloading || library.isImporting || remoteURL.isEmpty)
                Text("Only direct links to audio you are authorized to download. Spotify playlist and streaming links are not downloadable MP3 files.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
            } header: { Text("Download From a Direct Link") }
            Section {
                NavigationLink { SpotifyConnectView() } label: {
                    Label("Connect Spotify Account", systemImage: "person.crop.circle.badge.checkmark")
                }
                Text("Connect Spotify to import supported playlists, or import a CSV track list. Neither method downloads Spotify audio.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
            } header: { Text("Spotify Playlist Matching") }
        }
        .navigationTitle("Import Music")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { notice = await library.importAudio(urls: urls).description }
            case .failure(let error): notice = error.localizedDescription
            }
        }
        .alert("Import", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }
}

struct SpotifyImportView: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var showDocumentPicker = false
    @State private var optionalSpotifyURL = ""
    @State private var notice: String?
    @State private var latest: PlaylistImportReport?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Spotify playlist → offline collection", systemImage: "square.stack.3d.up.fill")
                        .font(.headline)
                    Text("Import a CSV or TSV list of your playlist's tracks. MP3 Shelf matches your local music, then automatically searches for independently licensed MP3 downloads for missing songs.")
                        .foregroundStyle(ShelfTheme.subdued).font(.subheadline)
                    Text("This does not turn Spotify streams into MP3s. Commercial recordings usually have no qualifying free download source.")
                        .font(.caption).foregroundStyle(.orange)
                }
                .padding(.vertical, 8)
            }
            Section("Optional Spotify Source Link") {
                TextField("https://open.spotify.com/playlist/…", text: $optionalSpotifyURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Text("Keeps a link back to the original playlist. Importing the link alone cannot retrieve its songs.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
            }
            Section("Playlist Track List") {
                Button { showDocumentPicker = true } label: {
                    Label("Choose CSV or TSV Playlist", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Recognized columns: Track Name, Artist Name, Album Name, and optional Track URI. Commas inside quoted song titles are supported.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
            }
            if let latest {
                Section("Import Complete") {
                    Label(latest.playlistName, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(latest.matched) songs are ready to play offline.")
                    Text("\(latest.missing) songs queued for automatic license-declared source lookup.")
                        .foregroundStyle(ShelfTheme.subdued)
                    Text("Open the imported playlist for download progress, results, and retry controls.")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                }
            }
        }
        .navigationTitle("Import Playlist")
        .fileImporter(isPresented: $showDocumentPicker,
                      allowedContentTypes: [.commaSeparatedText, .plainText],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let baseName = url.deletingPathExtension().lastPathComponent
                    latest = try library.importPlaylistCSV(data: data, name: baseName, spotifyURL: optionalSpotifyURL)
                    if let latest, latest.missing > 0, let imported = library.playlists.last {
                        library.startAutomaticDownloads(for: imported.id)
                    }
                } catch { notice = error.localizedDescription }
            case .failure(let error): notice = error.localizedDescription
            }
        }
        .alert("Could Not Import Playlist", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "internaldrive.fill")
                        .font(.title2).foregroundStyle(ShelfTheme.accent)
                    VStack(alignment: .leading) {
                        Text("Stored on this iPhone").font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: library.totalStorageBytes, countStyle: .file))
                            .foregroundStyle(ShelfTheme.subdued)
                    }
                    Spacer()
                }
                LabeledContent("Downloaded songs", value: "\(library.tracks.count)")
                LabeledContent("Playlists", value: "\(library.playlists.count)")
            } header: { Text("Offline Storage") }
            Section("Downloads") {
                NavigationLink { DownloadManagerView() } label: {
                    Label("Download Manager", systemImage: "arrow.down.circle")
                }
                NavigationLink { MusicStorageView() } label: {
                    Label("Manage Music Storage", systemImage: "externaldrive")
                }
                LabeledContent("Active MP3 Transfers", value: "\(library.pendingBackgroundDownloads)")
            }
            Section("Backup & Files") {
                Label("Imported songs are saved in Files → On My iPhone → MP3 Shelf → Music (when file sharing is available).", systemImage: "folder")
                    .font(.subheadline)
                Text("For a backup, copy the Music folder to a Mac or other storage. Back up the whole iPhone to preserve playlist metadata too. The web MP3 Shelf .mp3shelf backup format is not yet supported by this native app.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
            }
            Section("Playback") {
                VStack(alignment: .leading) {
                    HStack { Text("Song crossfade"); Spacer(); Text("\(Int(playback.crossfadeSeconds)) sec") }
                    Slider(value: $playback.crossfadeSeconds, in: 0...10, step: 1)
                        .tint(ShelfTheme.accent)
                    Text("Overlaps the end of one local audio file with the beginning of the next. Set to zero for normal playback.")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                }
                Text("Offline synchronized lyrics can be imported from the Now Playing screen (.lrc). Embedded file artwork is shown automatically.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
            }
            Section("How Playback Works") {
                Label("No account required", systemImage: "person.crop.circle.badge.checkmark")
                Label("Music is playable in airplane mode", systemImage: "airplane")
                Label("Lock Screen / Control Center controls", systemImage: "lock.iphone")
                Label("Background and headphone playback", systemImage: "headphones")
                Text("Spotify streaming audio remains inside Spotify. Importing a playlist track list only matches your existing files.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
            }
            Section {
                Text("MP3 Shelf · iOS Edition · 1.0")
                    .foregroundStyle(ShelfTheme.subdued)
            }
        }
        .navigationTitle("Settings")
    }
}
