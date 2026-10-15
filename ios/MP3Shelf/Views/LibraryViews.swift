import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @State private var showFilePicker = false
    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var message: String?
    @State private var renaming: MusicTrack?

    private var displayed: [MusicTrack] {
        library.tracks.filter { track in
            (!favoritesOnly || track.isFavorite) && (searchText.isEmpty ||
                [track.title, track.artist, track.album].contains(where: {
                    $0.localizedCaseInsensitiveContains(searchText)
                }))
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
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

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            Circle().fill(ShelfTheme.mint).frame(width: 7, height: 7)
                            Text("ALWAYS OFFLINE")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .tracking(1.6)
                                .foregroundStyle(ShelfTheme.mint)
                        }
                        Text("All yours.\nAlways playing.")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(library.tracks.count) songs ready wherever life takes you.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.77))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    ArtworkTile(track: library.tracks.last, size: 110)
                        .rotationEffect(.degrees(7))
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 9)
                        .accessibilityHidden(true)
                }
                .padding(22)
                .frame(maxWidth: .infinity, minHeight: 198, alignment: .leading)
                .background(ShelfTheme.heroGradient,
                            in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1))

                HStack(spacing: 10) {
                    filterButton("All music", selected: !favoritesOnly) { favoritesOnly = false }
                    filterButton("Favorites", symbol: "heart.fill", selected: favoritesOnly) { favoritesOnly = true }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .contain)

                VStack(alignment: .leading, spacing: 13) {
                    PremiumSectionHeading(title: favoritesOnly ? "Loved tracks" : "Your library",
                                          detail: "\(displayed.count) songs")
                    if displayed.isEmpty {
                        VStack(spacing: 15) {
                            EmptyShelfView(
                                title: favoritesOnly ? "Nothing here just yet" : "Your soundtrack starts here",
                                subtitle: favoritesOnly ? "Tap the heart on a song you love." :
                                    "Bring your favorite MP3 files and take your music everywhere.",
                                symbol: favoritesOnly ? "heart" : "music.note")
                            if !favoritesOnly {
                                Button { showFilePicker = true } label: {
                                    Label("Add your first songs", systemImage: "plus")
                                        .font(.subheadline.bold())
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(ShelfTheme.accent)
                            }
                        }
                    } else {
                        LazyVStack(spacing: 9) {
                            ForEach(displayed) { track in
                                MusicTrackRow(track: track, context: displayed, renaming: $renaming)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(PremiumBackdrop())
        .navigationTitle("MP3 Shelf")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search songs, artists or albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilePicker = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ShelfTheme.accent)
                }
                .accessibilityLabel("Import audio files")
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
            .padding(.vertical, 11)
            .background(selected ? ShelfTheme.accent : ShelfTheme.elevated,
                        in: Capsule())
            .overlay(Capsule().strokeBorder(
                selected ? ShelfTheme.accent : ShelfTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MusicTrackRow: View {
    let track: MusicTrack
    let context: [MusicTrack]
    @Binding var renaming: MusicTrack?
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Button { playback.play(track, queue: context) } label: {
                HStack(spacing: 12) {
                    ArtworkTile(track: track)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(ShelfTheme.subdued).lineLimit(1)
                    }
                    Spacer(minLength: 0)
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
                ShareLink(item: library.fileURL(for: track)) { Label("Share Audio File", systemImage: "square.and.arrow.up") }
                if let attribution = track.sourceAttribution {
                    if let sourceURL = URL(string: attribution.pageURL) {
                        Link(destination: sourceURL) {
                            Label("View Audio Source", systemImage: "link")
                        }
                    }
                    if let licenseURL = URL(string: attribution.licenseURL) {
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
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
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

    var body: some View {
        NavigationStack {
            Form {
                TextField("Song title", text: $title)
                TextField("Artist", text: $artist)
                Text("Changes affect your local library only, not the audio file's ID3 tags.")
                    .foregroundStyle(ShelfTheme.subdued).font(.caption)
            }
            .navigationTitle("Edit Song")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { library.rename(track, title: title, artist: artist); dismiss() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { title = track.title; artist = track.artist }
        }
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var showCreate = false
    @State private var newName = ""

    private let columns = [GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    PremiumEyebrow(title: "CURATED BY YOU", color: ShelfTheme.coral)
                    Text("Made for every mood.")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Your music, exactly how you like it.")
                        .font(.subheadline).foregroundStyle(ShelfTheme.subdued)
                }
                .padding(.top, 10)

                NavigationLink { SpotifyConnectView() } label: {
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

                VStack(alignment: .leading, spacing: 14) {
                    PremiumSectionHeading(title: "Your playlists",
                                          detail: "\(library.playlists.count) collections")
                    if library.playlists.isEmpty {
                        EmptyShelfView(title: "Make something personal",
                                       subtitle: "Mix the songs you love into playlists for any occasion.",
                                       symbol: "square.stack")
                    } else {
                        LazyVGrid(columns: columns, spacing: 13) {
                            ForEach(library.playlists.indices, id: \.self) { index in
                                let list = library.playlists[index]
                                NavigationLink { PlaylistDetailView(playlistID: list.id) } label: {
                                    playlistCard(list, index: index)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        library.deletePlaylist(list.id)
                                    } label: { Label("Delete Playlist", systemImage: "trash") }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(PremiumBackdrop())
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus").foregroundStyle(ShelfTheme.accent)
                        .font(.system(size: 16, weight: .bold))
                }
                .accessibilityLabel("Create a playlist")
            }
        }
        .alert("New Playlist", isPresented: $showCreate) {
            TextField("Playlist name", text: $newName)
            Button("Create") { library.createPlaylist(newName); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: { Text("Songs stay on your device.") }
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
                Image(systemName: ["waveform", "music.mic", "headphones", "record.circle"][index % 4])
                    .font(.system(size: 39, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .frame(height: 125)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 17))
            Text(list.name)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(list.trackIDs.count) offline · \(list.missingTracks.count) missing")
                .font(.caption2)
                .foregroundStyle(ShelfTheme.subdued)
                .lineLimit(1)
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

    private var playlist: MusicPlaylist? { library.playlists.first { $0.id == playlistID } }

    var body: some View {
        List {
            if let playlist {
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(LinearGradient(
                                    colors: ShelfTheme.artworkColors(for: playlist.name),
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                            Image(systemName: "waveform")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 82, height: 82)
                        VStack(alignment: .leading, spacing: 6) {
                            PremiumEyebrow(title: "YOUR PLAYLIST", color: ShelfTheme.coral)
                            Text(playlist.name)
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Text("\(playlist.trackIDs.count) offline · \(playlist.missingTracks.count) missing")
                                .font(.caption)
                                .foregroundStyle(ShelfTheme.subdued)
                        }
                    }
                    .padding(.vertical, 12)
                    HStack(spacing: 12) {
                        Button { if let first = library.songs(in: playlist).first { playback.play(first, queue: library.songs(in: playlist)) } } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(ShelfTheme.accent)
                        Button {
                            let all = library.songs(in: playlist)
                            if let track = all.randomElement() {
                                playback.isShuffled = true
                                playback.play(track, queue: all)
                            }
                        } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                    .disabled(playlist.trackIDs.isEmpty)
                    if let source = playlist.sourceURL, let link = URL(string: source) {
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
                        Text("Searches Internet Archive and eligible Openverse catalogs for exact artist/title matches, MP3 files, and declared Creative Commons/public-domain licenses. Verified download URLs transfer through iOS even while the screen is locked. Popular commercial songs are unlikely to qualify.")
                            .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        if let job = library.discoveryJob(for: playlistID), !job.isComplete {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Catalog search: \(job.nextIndex)/\(job.wishes.count) processed")
                                    .font(.caption.monospacedDigit())
                                if let issue = job.lastError {
                                    Label("Paused by network error: \(issue)", systemImage: "wifi.exclamationmark")
                                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                }
                                if job.isPaused {
                                    Button("Resume Source Discovery") {
                                        library.resumeSourceDiscovery(for: playlistID)
                                    }
                                } else if library.automaticDownloadProgress?.playlistID != playlistID ||
                                            library.automaticDownloadProgress?.isRunning != true {
                                    Button("Resume Search") {
                                        library.resumeSourceDiscovery(for: playlistID)
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
                                Text(progress.currentSong)
                                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                Button("Pause Source Discovery", role: .cancel) {
                                    library.pauseSourceDiscovery(for: playlistID)
                                }
                            } else {
                                Text(progress.wasCancelled ? "Source discovery stopped." : "Source lookup finished. Background downloads may still be running.")
                                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                if !playlist.missingTracks.isEmpty {
                                    Button("Retry unmatched songs") {
                                        library.startAutomaticDownloads(for: playlistID)
                                    }
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
                            Text("Downloads can continue after you lock your iPhone. Source discovery resumes only when MP3 Shelf is open.")
                                .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        }
                        Text("Catalog licenses are uploader-declared and not independently certified. Songs with no authorized download stay unmatched.")
                            .font(.caption2).foregroundStyle(ShelfTheme.subdued)
                    }
                    .listRowBackground(ShelfTheme.surface)
                }
                Section("AVAILABLE OFFLINE") {
                    ForEach(library.songs(in: playlist)) { track in
                        MusicTrackRow(track: track, context: library.songs(in: playlist), renaming: $editing)
                            .listRowBackground(.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    library.removeTrack(track.id, from: playlistID)
                                }
                            }
                    }
                    .onMove { from, to in library.moveTracks(in: playlistID, from: from, to: to) }
                }
                if !playlist.missingTracks.isEmpty {
                    Section("STILL MISSING") {
                        ForEach(playlist.missingTracks) { wish in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(wish.title).font(.subheadline.bold())
                                Text(wish.artist).font(.caption).foregroundStyle(ShelfTheme.subdued)
                                if let url = wish.spotifyURL, let link = URL(string: url) {
                                    Link("View on Spotify", destination: link).font(.caption)
                                }
                            }
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
            }
        }
        .sheet(item: $editing) { track in RenameTrackView(track: track) }
    }
}
