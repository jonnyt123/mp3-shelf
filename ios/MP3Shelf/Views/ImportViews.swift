import SwiftUI
import UniformTypeIdentifiers

struct DownloadView: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var remoteURL = ""
    @State private var notice: String?
    @State private var isDownloading = false
    @State private var showImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    PremiumEyebrow(title: "BUILD YOUR COLLECTION", color: ShelfTheme.mint)
                    Text("Bring the music.")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Everything you love, ready to play offline.")
                        .font(.subheadline).foregroundStyle(ShelfTheme.subdued)
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        PremiumIcon(symbol: "folder.fill", color: ShelfTheme.mint, size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("From your iPhone")
                                .font(.system(.headline, design: .rounded, weight: .bold))
                            Text("MP3, M4A, AAC, WAV and more")
                                .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        }
                        Spacer()
                    }
                    Text("Import your files once. We keep a local copy, so your music plays even without a connection.")
                        .font(.subheadline)
                        .foregroundStyle(ShelfTheme.subdued)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { showImporter = true } label: {
                        Label(library.isImporting ? "Adding your music…" : "Choose audio files",
                              systemImage: "plus")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShelfTheme.accent)
                    .disabled(library.isImporting)
                }
                .padding(19)
                .premiumCard(radius: 25)

                NavigationLink { SpotifyConnectView() } label: {
                    HStack(spacing: 14) {
                        PremiumIcon(symbol: "square.stack.3d.up", color: ShelfTheme.coral, size: 55)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Your Spotify playlists")
                                .font(.system(.headline, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Import song lists and find eligible offline recordings")
                                .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(ShelfTheme.coral)
                    }
                    .padding(19)
                    .premiumCard(radius: 25)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 12) {
                        PremiumIcon(symbol: "link", color: ShelfTheme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Have a direct download link?")
                                .font(.system(.headline, design: .rounded, weight: .bold))
                            Text("Save authorized audio straight to your shelf")
                                .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        }
                    }
                    TextField("Paste a direct MP3 file URL", text: $remoteURL,
                              axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(2...3)
                        .font(.subheadline)
                        .padding(14)
                        .background(ShelfTheme.background,
                                    in: RoundedRectangle(cornerRadius: 15))
                        .overlay(RoundedRectangle(cornerRadius: 15)
                            .strokeBorder(ShelfTheme.border, lineWidth: 1))
                    Button {
                        guard let url = URL(string: remoteURL.trimmingCharacters(
                            in: .whitespacesAndNewlines)) else {
                            notice = "Enter a valid HTTPS URL to an audio file."
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
                            Label(isDownloading ? "Downloading…" : "Download audio file",
                                  systemImage: "arrow.down.circle")
                        }
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.bordered)
                    .tint(ShelfTheme.mint)
                    .disabled(isDownloading || library.isImporting || remoteURL.isEmpty)
                    Text("Only files you have permission to download. Streaming links are not MP3 files.")
                        .font(.caption2)
                        .foregroundStyle(ShelfTheme.subdued)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(19)
                .premiumCard(radius: 25)

                NavigationLink { DownloadManagerView() } label: {
                    HStack(spacing: 12) {
                        PremiumIcon(symbol: "arrow.down.circle",
                                    color: ShelfTheme.mint, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Your downloads")
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                            Text(library.pendingBackgroundDownloads == 0
                                 ? "See transfer history and saved files"
                                 : "\(library.pendingBackgroundDownloads) transfers in progress")
                                .font(.caption)
                                .foregroundStyle(ShelfTheme.subdued)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(ShelfTheme.subdued)
                    }
                    .padding(15)
                    .premiumCard(radius: 19)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Download Manager")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(PremiumBackdrop())
        .navigationTitle("Add Music")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { notice = await library.importAudio(urls: urls).description }
            case .failure(let error): notice = error.localizedDescription
            }
        }
        .alert("Import", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } })) {
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
                    HStack(spacing: 13) {
                        PremiumIcon(symbol: "square.stack.3d.up", color: ShelfTheme.mint, size: 49)
                        VStack(alignment: .leading, spacing: 5) {
                            PremiumEyebrow(title: "PLAYLIST IMPORT")
                            Text("A playlist that travels.")
                                .font(.system(.headline, design: .rounded, weight: .bold))
                        }
                    }
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
        .scrollContentBackground(.hidden)
        .background(PremiumBackdrop())
        .tint(ShelfTheme.accent)
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
    @State private var portableBackupURL: URL?
    @State private var showPortableImporter = false
    @State private var portableStatus: String?
    @State private var portableBusy = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 15) {
                    PremiumIcon(symbol: "internaldrive.fill", color: ShelfTheme.mint, size: 58)
                    VStack(alignment: .leading, spacing: 6) {
                        PremiumEyebrow(title: "STORED LOCALLY")
                        Text(library.totalStorageBytes == 0
                             ? "0 MB"
                             : ByteCountFormatter.string(
                                 fromByteCount: library.totalStorageBytes, countStyle: .file))
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text("Ready even in airplane mode")
                            .font(.caption).foregroundStyle(ShelfTheme.subdued)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
                LabeledContent("Songs in library", value: "\(library.tracks.count)")
                LabeledContent("Your playlists", value: "\(library.playlists.count)")
            } header: { Text("YOUR MUSIC") }
            .listRowBackground(ShelfTheme.surface)

            Section {
                NavigationLink { DownloadManagerView() } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Download Manager")
                            Text("Track every song")
                                .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        }
                    } icon: {
                        PremiumIcon(symbol: "arrow.down.circle", color: ShelfTheme.accent, size: 40)
                    }
                }
                NavigationLink { MusicStorageView() } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Manage storage")
                            Text("Review and remove local files")
                                .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        }
                    } icon: {
                        PremiumIcon(symbol: "externaldrive", color: ShelfTheme.coral, size: 40)
                    }
                }
                LabeledContent("Background transfers", value: "\(library.pendingBackgroundDownloads)")
            } header: { Text("DOWNLOADS & STORAGE") }
            .listRowBackground(ShelfTheme.surface)

            Section {
                HStack(spacing: 12) {
                    PremiumIcon(symbol: "externaldrive.badge.icloud", color: ShelfTheme.mint, size: 48)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your music, wherever you go")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                        Text("Save songs, artwork, lyrics and playlists in one portable file.")
                            .font(.caption)
                            .foregroundStyle(ShelfTheme.subdued)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 7)
                Button {
                    portableBusy = true
                    portableStatus = nil
                    portableBackupURL = nil
                    Task {
                        do {
                            portableBackupURL = try await library.exportPortableBackup()
                            portableStatus = "Your backup is ready. Share it to Files or another device to keep a copy."
                        } catch {
                            portableStatus = error.localizedDescription
                        }
                        portableBusy = false
                    }
                } label: {
                    Label("Prepare portable backup", systemImage: "archivebox")
                }
                .disabled(portableBusy)

                if let url = portableBackupURL {
                    ShareLink(item: url) {
                        Label("Share Backup to Files or another device",
                              systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    showPortableImporter = true
                } label: {
                    Label("Restore .mp3shelf backup", systemImage: "square.and.arrow.down")
                }
                .disabled(portableBusy)
                if portableBusy {
                    ProgressView("Working with your music library…")
                        .tint(ShelfTheme.mint)
                        .accessibilityLabel("Processing portable backup")
                }
                if let portableStatus {
                    Text(portableStatus)
                        .font(.caption)
                        .foregroundStyle(ShelfTheme.subdued)
                }
                Text("Works with web MP3 Shelf archives. Restore adds missing music and playlists without deleting existing songs.")
                    .font(.caption)
                    .foregroundStyle(ShelfTheme.subdued)
            } header: { Text("PORTABLE BACKUP & RESTORE") }
            .listRowBackground(ShelfTheme.surface)

            Section {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label("Song crossfade", systemImage: "waveform.path")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(playback.crossfadeSeconds))s")
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(ShelfTheme.mint)
                    }
                    Slider(value: $playback.crossfadeSeconds, in: 0...10, step: 1)
                        .tint(ShelfTheme.accent)
                    Text("Blend the end of one track into the start of the next.")
                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                }
                .padding(.vertical, 7)
                Label("Offline synced lyrics supported", systemImage: "text.quote")
                Label("Lock Screen & headphone controls", systemImage: "headphones")
            } header: { Text("LISTENING EXPERIENCE") }
            .listRowBackground(ShelfTheme.surface)

            Section {
                Label("Your tracks are stored on your iPhone", systemImage: "lock.shield")
                Text("Find imported files in Files → On My iPhone → MP3 Shelf when file sharing is available. Back up your device to preserve playlist metadata.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
                Text("Spotify is used for playlist information, not downloading protected streams. Only eligible independent audio downloads are supported.")
                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
            } header: { Text("PRIVACY & FILES") }
            .listRowBackground(ShelfTheme.surface)

            Section {
                HStack {
                    Spacer()
                    Text("MP3 SHELF  ·  MADE FOR OFFLINE")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(1.7)
                        .foregroundStyle(ShelfTheme.subdued)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PremiumBackdrop())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .tint(ShelfTheme.accent)
        .fileImporter(isPresented: $showPortableImporter,
                      allowedContentTypes: [UTType(filenameExtension: "mp3shelf", conformingTo: .data) ?? .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                portableBusy = true
                portableStatus = nil
                Task {
                    do {
                        let report = try await library.importPortableBackup(from: url)
                        portableStatus = report.description
                    } catch {
                        portableStatus = error.localizedDescription
                    }
                    portableBusy = false
                }
            case .failure(let error):
                portableStatus = error.localizedDescription
            }
        }
    }
}
