import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    private enum SortMode: String, CaseIterable, Identifiable {
        case title = "Title"
        case recent = "Recently added"
        case artist = "Artist"

        var id: String { rawValue }
    }

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
    @State private var sortMode: SortMode = .title
    @State private var message: String?
    @State private var renaming: MusicTrack?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var recentlyAdded: [MusicTrack] {
        Array(library.tracks.sorted { $0.addedAt > $1.addedAt }.prefix(8))
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayed: [MusicTrack] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.tracks.filter { track in
            (!favoritesOnly || track.isFavorite) && (query.isEmpty ||
                [track.title, track.artist, track.album].contains(where: {
                    $0.localizedCaseInsensitiveContains(query)
                }))
        }
        .sorted { lhs, rhs in
            switch sortMode {
            case .title:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .recent:
                return lhs.addedAt == rhs.addedAt
                    ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    : lhs.addedAt > rhs.addedAt
            case .artist:
                let order = lhs.artist.localizedStandardCompare(rhs.artist)
                return order == .orderedSame
                    ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    : order == .orderedAscending
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort songs", selection: $sortMode) {
                ForEach(SortMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ShelfTheme.accent)
        }
        .accessibilityLabel("Sort songs by \(sortMode.rawValue)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if isSearching {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 5) {
                                PremiumEyebrow(title: "SEARCH YOUR LIBRARY")
                                Text("Search results")
                                    .font(.system(.title2, design: .rounded, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 9) {
                                Text("\(displayed.count) found")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(ShelfTheme.subdued)
                                sortMenu
                            }
                        }
                        HStack(spacing: 10) {
                            filterButton("All music", selected: !favoritesOnly) {
                                favoritesOnly = false
                            }
                            filterButton("Favorites", symbol: "heart.fill",
                                         selected: favoritesOnly) {
                                favoritesOnly = true
                            }
                            Spacer()
                        }
                        if displayed.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                PremiumIcon(symbol: "magnifyingglass", color: ShelfTheme.accent,
                                            size: 56)
                                Text("No matching songs")
                                    .font(.system(.headline, design: .rounded, weight: .bold))
                                    .foregroundStyle(.white)
                                Text(favoritesOnly
                                     ? "Try All music or a different song, artist or album."
                                     : "Try a different song, artist or album.")
                                    .font(.subheadline)
                                    .foregroundStyle(ShelfTheme.subdued)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(22)
                            .premiumCard()
                        } else {
                            LazyVStack(spacing: 9) {
                                ForEach(displayed) { track in
                                    MusicTrackRow(track: track, context: displayed,
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
                                Text("ALWAYS OFFLINE")
                                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                                    .tracking(1.6)
                                    .foregroundStyle(ShelfTheme.mint)
                            }
                            Text(library.tracks.isEmpty
                                 ? "Start your\nsoundtrack."
                                 : "All yours.\nAlways playing.")
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(library.tracks.isEmpty
                                 ? "Your favorite songs, right on your iPhone."
                                 : "\(library.tracks.count) songs ready wherever life takes you.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
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
                        NavigationLink { SpotifyConnectView() } label: {
                            HStack(spacing: 14) {
                                PremiumIcon(symbol: "square.stack.3d.up",
                                            color: ShelfTheme.coral, size: 46)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Import a Spotify playlist")
                                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                                        .foregroundStyle(.white)
                                    Text("Find eligible MP3s for your song list")
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
                                    ForEach(recentlyAdded) { track in
                                        Button {
                                            playback.play(track, queue: recentlyAdded)
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
                                                    .lineLimit(1)
                                                Text(track.artist)
                                                    .font(.caption)
                                                    .foregroundStyle(ShelfTheme.subdued)
                                                    .lineLimit(1)
                                            }
                                            .frame(width: 122, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Play \(track.title) by \(track.artist)")
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .scrollIndicators(.hidden)
                        }
                    }
                    HStack(spacing: 10) {
                        filterButton("All music", selected: !favoritesOnly) { favoritesOnly = false }
                        filterButton("Favorites", symbol: "heart.fill",
                                     selected: favoritesOnly) { favoritesOnly = true }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .contain)

                    VStack(alignment: .leading, spacing: 13) {
                        HStack(spacing: 12) {
                            PremiumSectionHeading(title: favoritesOnly ? "Loved tracks" : "Your library",
                                                  detail: "\(displayed.count) songs")
                            sortMenu
                        }
                        if displayed.isEmpty {
                            EmptyShelfView(
                                title: "No favorites yet",
                                subtitle: "Tap the heart on a song to collect it here.",
                                symbol: "heart")
                        } else {
                            LazyVStack(spacing: 9) {
                                ForEach(displayed) { track in
                                    MusicTrackRow(track: track, context: displayed,
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
    @State private var pendingDelete: MusicPlaylist?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Accessibility text sizes get a full-width playlist card instead of
    // squeezing large text into two narrow columns.
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 13)]
            : [GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13)]
    }

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
                    } else {
                        LazyVGrid(columns: columns, spacing: 13) {
                            ForEach(library.playlists.indices, id: \.self) { index in
                                let list = library.playlists[index]
                                NavigationLink { PlaylistDetailView(playlistID: list.id) } label: {
                                    playlistCard(list, index: index)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(list.name), \(list.trackIDs.count) songs offline, \(list.missingTracks.count) still to find")
                                .contextMenu {
                                    Button(role: .destructive) {
                                        pendingDelete = list
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
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "playlist")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete playlist", role: .destructive) {
                if let playlist = pendingDelete { library.deletePlaylist(playlist.id) }
                pendingDelete = nil
            }
            Button("Keep playlist", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Only this playlist will be removed. Your offline songs will remain on this iPhone.")
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
                if let cover = library.songs(in: list).first {
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
                .lineLimit(1)
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ShelfTheme.mint)
                Text("\(list.trackIDs.count) offline")
                    .foregroundStyle(ShelfTheme.subdued)
                if !list.missingTracks.isEmpty {
                    Text("· \(list.missingTracks.count) to find")
                        .foregroundStyle(ShelfTheme.coral)
                }
            }
            .font(.caption2.weight(.medium))
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
    @State private var manuallyAdding: PlaylistWish?
    @State private var showWebDiscovery = false

    private var playlist: MusicPlaylist? { library.playlists.first { $0.id == playlistID } }

    private var jobHasNoMatches: Bool {
        guard let job = library.discoveryJob(for: playlistID) else { return false }
        return job.isComplete && job.queued == 0 && job.unavailable > 0
    }

    private var offlineSourceCount: Int {
        guard let playlist else { return 0 }
        return playlist.sourceOrder.filter {
            MusicMatching.matchingTrack(for: $0, in: library.tracks) != nil
        }.count
    }

    /// Report the real, persisted outcome for each song in the imported
    /// Spotify playlist. Downloading is not the same as already saved offline.
    private func mp3Status(for wish: PlaylistWish) -> (text: String, symbol: String) {
        if MusicMatching.matchingTrack(for: wish, in: library.tracks) != nil {
            return ("Saved offline as an audio file", "checkmark.circle.fill")
        }
        if let ticket = transfers.ticketsForPlaylist(playlistID).first(where: {
            $0.requested.id == wish.id
        }) {
            switch ticket.status {
            case .queued:
                return (ticket.bytesReceived ?? 0) > 0
                    ? ("Downloading MP3…", "arrow.down.circle.fill")
                    : ("MP3 download queued", "clock.arrow.circlepath")
            case .imported:
                return ("MP3 saved offline", "checkmark.circle.fill")
            case .failed:
                return ("MP3 download failed — retry in Downloads", "exclamationmark.triangle")
            case .cancelled:
                return ("MP3 download cancelled", "xmark.circle")
            }
        }
        if let job = library.discoveryJob(for: playlistID) {
            if let index = job.wishes.firstIndex(where: { $0.id == wish.id }),
               index == job.nextIndex && !job.isPaused && !job.isComplete {
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
            case .previous:
                return ("Previously checked — try search again", "clock.arrow.circlepath")
            case nil:
                break
            }
        }
        return ("Awaiting MP3 source search", "magnifyingglass")
    }

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
                        VStack(alignment: .leading, spacing: 9) {
                            PremiumEyebrow(title: "OFFLINE SOURCE MATCHING", color: ShelfTheme.mint)
                            Text("\(offlineSourceCount) of \(playlist.sourceOrder.count) songs saved offline")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.white)
                            ProgressView(value: Double(offlineSourceCount),
                                         total: Double(max(1, playlist.sourceOrder.count)))
                                .tint(ShelfTheme.mint)
                                .accessibilityLabel("Downloaded audio files")
                                .accessibilityValue("\(offlineSourceCount) of \(playlist.sourceOrder.count) songs saved")
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
                        Text("Automatic matching checks three openly licensed catalogs. Other web download pages are suggestions requiring review; the app cannot guarantee every Spotify recording is independently downloadable.")
                            .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        Button {
                            showWebDiscovery = true
                        } label: {
                            Label("Search the wider web for missing songs", systemImage: "globe")
                        }
                        .buttonStyle(.bordered)
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
                                } else if (library.isOnWiFi ||
                                            (library.isOnCellular &&
                                             library.cellularApproved(for: playlistID))) &&
                                          (library.automaticDownloadProgress?.playlistID != playlistID ||
                                           library.automaticDownloadProgress?.isRunning != true) {
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
                                if jobHasNoMatches {
                                    Label("No authorized matching MP3s found in the connected catalogs. You can attach a legally obtained file link to each missing song below.", systemImage: "info.circle")
                                        .font(.caption)
                                        .foregroundStyle(ShelfTheme.subdued)
                                }
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
                        Text("Every successful match downloads an actual .mp3 to this iPhone (Files → On My iPhone → MP3 Shelf → Music). If a recording has no qualifying source, it stays missing instead of being replaced with a different version. Source licenses are uploader-declared.")
                            .font(.caption2).foregroundStyle(ShelfTheme.subdued)
                    }
                    .listRowBackground(ShelfTheme.surface)
                }
                Section("AVAILABLE OFFLINE") {
                    ForEach(library.songs(in: playlist)) { track in
                        MusicTrackRow(track: track, context: library.songs(in: playlist), renaming: $editing)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    library.removeTrack(track.id, from: playlistID)
                                }
                            }
                    }
                    .onMove { from, to in library.moveTracks(in: playlistID, from: from, to: to) }
                }
                if !playlist.sourceOrder.isEmpty {
                    Section("SONG-BY-SONG MP3 RESULTS") {
                        ForEach(playlist.sourceOrder) { wish in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(wish.title)
                                    .font(.subheadline.bold())
                                Text(wish.artist)
                                    .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                let status = mp3Status(for: wish)
                                Label(status.text, systemImage: status.symbol)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(status.text.contains("failed") ||
                                                     status.text.contains("No qualifying")
                                        ? ShelfTheme.coral : ShelfTheme.mint)
                                    .accessibilityLabel("\(wish.title): \(status.text)")
                                if let ticket = transfers.ticketsForPlaylist(playlistID)
                                    .first(where: { $0.requested.id == wish.id }) {
                                    if ticket.status == .queued, let total = ticket.totalBytes,
                                       total > 0, let received = ticket.bytesReceived {
                                        ProgressView(value: Double(received), total: Double(total))
                                            .tint(ShelfTheme.accent)
                                            .accessibilityLabel("Download progress for \(wish.title)")
                                    }
                                    if ticket.status == .failed || ticket.status == .cancelled {
                                        Button("Retry MP3 download") { transfers.retry(ticket.id) }
                                            .font(.caption.weight(.semibold))
                                    }
                                    if ticket.status == .queued || ticket.status == .imported {
                                        Text("Source: \(ticket.provider)")
                                            .font(.caption2)
                                            .foregroundStyle(ShelfTheme.subdued)
                                    }
                                }
                                if MusicMatching.matchingTrack(for: wish, in: library.tracks) == nil {
                                    Button { manuallyAdding = wish } label: {
                                        Label("I have an authorized audio link",
                                              systemImage: "link.badge.plus")
                                    }
                                    .font(.caption.weight(.semibold))
                                    .accessibilityHint("Download a recording you have permission to save and attach it to this missing song.")
                                }
                                if let url = wish.spotifyURL, let link = URL(string: url) {
                                    Link("View original on Spotify", destination: link)
                                        .font(.caption)
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
            }
        }
        .sheet(item: $editing) { track in RenameTrackView(track: track) }
        .sheet(item: $manuallyAdding) { wish in
            AuthorizedPlaylistAudioView(wish: wish)
        }
        .sheet(isPresented: $showWebDiscovery) {
            WebAudioDiscoveryView(wishes: playlist?.missingTracks ?? [])
        }
    }
}

/// Recovery path when an independent catalog cannot locate a licensed recording.
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
                    Text("Paste a direct HTTPS file URL only when the rights holder permits downloading. MP3 Shelf checks that the file can play and matches Spotify's duration when available. It will then link the saved recording to this playlist.")
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
                    Text("A Spotify playlist link is not a direct MP3 file. Commercial music usually requires a separate legal purchase or download from the rightsholder.")
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
/// Only a URL explicitly chosen by the user is submitted to the local
/// audio importer; a search result is never silently treated as an MP3.
struct WebAudioDiscoveryView: View {
    let wishes: [PlaylistWish]
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = WebAudioSearch.loadKey() ?? ""
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
                    Text("Web results may be unrelated, behind a purchase, or unauthorized. This feature does not extract Spotify streams, bypass DRM, or automatically download unverified search hits.")
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
                                                     total: Double(candidates.count))
                                            .accessibilityLabel("Inspecting music webpages")
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
                        guard let pageURL = WebAudioSearch.sanitizedResultURL(
                            pageText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                            error = "Enter a public HTTPS webpage URL."
                            return
                        }
                        isInspecting = true
                        candidates = []
                        error = nil
                        Task {
                            defer { isInspecting = false }
                            do {
                                candidates = try await AudioLandingPageInspector.inspect(pageURL)
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    } label: {
                        Label(isInspecting ? "Reading source page…" : "Find downloadable audio on this page",
                              systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(isInspecting || pageText.isEmpty)
                    if isInspecting { ProgressView() }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    if !isInspecting, candidates.isEmpty, error == nil {
                        Text("Not all publishers advertise downloadable files in page HTML. A purchase page or streaming player may not expose a direct download URL.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !candidates.isEmpty {
                    Section("POSSIBLE AUDIO FILES") {
                        ForEach(candidates, id: \.absoluteString) { file in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(file.lastPathComponent)
                                    .font(.subheadline.weight(.semibold))
                                Text(file.host ?? "")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Button {
                                    chosenAudio = WebAudioSelection(wish: wish, url: file)
                                } label: {
                                    Label("Review and download this file", systemImage: "arrow.down.circle")
                                        .font(.caption.weight(.semibold))
                                }
                            }
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
                    Button("Close") { dismiss() }
                        .disabled(isInspecting)
                }
            }
            .sheet(item: $chosenAudio) { selected in
                AuthorizedPlaylistAudioView(wish: selected.wish, initialURL: selected.url)
            }
        }
    }
}
