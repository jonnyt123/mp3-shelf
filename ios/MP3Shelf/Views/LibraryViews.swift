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
                [track.title, track.artist, track.album].contains(where: { $0.localizedCaseInsensitiveContains(searchText) }))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "iphone")
                        .font(.title2)
                        .foregroundStyle(ShelfTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your music, on your iPhone").font(.headline)
                        Text("\(library.tracks.count) offline songs · No connection required")
                            .font(.caption).foregroundStyle(ShelfTheme.subdued)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .listRowBackground(ShelfTheme.surface)
            }
            Section {
                Picker("Library view", selection: $favoritesOnly) {
                    Text("All Songs").tag(false)
                    Text("Favorites").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(ShelfTheme.background)
            }
            if displayed.isEmpty {
                EmptyShelfView(title: favoritesOnly ? "No favorites yet" : "Your library is ready",
                               subtitle: favoritesOnly ? "Tap the heart on a song to save it here." :
                                "Import MP3s or other supported audio files from Files to listen offline.",
                               symbol: "music.note.list")
                    .listRowBackground(ShelfTheme.background)
            } else {
                Section("Songs") {
                    ForEach(displayed) { track in
                        MusicTrackRow(track: track, context: displayed, renaming: $renaming)
                            .listRowBackground(ShelfTheme.background)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ShelfTheme.background)
        .navigationTitle("MP3 Shelf")
        .searchable(text: $searchText, prompt: "Song, artist or album")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilePicker = true } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .accessibilityLabel("Import audio files")
                .disabled(library.isImporting)
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { message = await library.importAudio(urls: urls).description }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .alert("Import Result", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .sheet(item: $renaming) { track in RenameTrackView(track: track) }
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
                    Text(track.duration.shelfClock)
                        .font(.caption.monospacedDigit()).foregroundStyle(ShelfTheme.subdued)
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
                Divider()
                Button("Delete Download", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(ShelfTheme.subdued)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
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
    @State private var showSpotifyImport = false

    var body: some View {
        List {
            Section {
                NavigationLink { SpotifyConnectView() } label: {
                    Label("Connect Spotify / Import Playlists", systemImage: "square.and.arrow.down.on.square")
                        .foregroundStyle(ShelfTheme.accent)
                }
                .listRowBackground(ShelfTheme.surface)
            }
            if library.playlists.isEmpty {
                EmptyShelfView(title: "Make it yours",
                               subtitle: "Create playlists or import a Spotify playlist track list to match your offline files.",
                               symbol: "square.stack")
                    .listRowBackground(ShelfTheme.background)
            } else {
                Section("Your Playlists") {
                    ForEach(library.playlists) { list in
                        NavigationLink { PlaylistDetailView(playlistID: list.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list")
                                    .font(.title2).foregroundStyle(ShelfTheme.accent)
                                    .frame(width: 46, height: 46)
                                    .background(ShelfTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(list.name).font(.headline)
                                    Text("\(list.trackIDs.count) ready · \(list.missingTracks.count) unmatched")
                                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowBackground(ShelfTheme.background)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { library.playlists[$0].id }
                        ids.forEach(library.deletePlaylist)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .alert("New Playlist", isPresented: $showCreate) {
            TextField("Playlist name", text: $newName)
            Button("Create") { library.createPlaylist(newName); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: { Text("Songs stay on your device.") }
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @State private var editing: MusicTrack?

    private var playlist: MusicPlaylist? { library.playlists.first { $0.id == playlistID } }

    var body: some View {
        List {
            if let playlist {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.largeTitle).foregroundStyle(ShelfTheme.accent)
                            .frame(width: 70, height: 70)
                            .background(ShelfTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(playlist.name).font(.title3.bold())
                            Text("\(playlist.trackIDs.count) downloaded · \(playlist.missingTracks.count) unmatched")
                                .font(.caption).foregroundStyle(ShelfTheme.subdued)
                        }
                    }
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
                .listRowBackground(ShelfTheme.background)
                Section("Available Offline") {
                    ForEach(library.songs(in: playlist)) { track in
                        MusicTrackRow(track: track, context: library.songs(in: playlist), renaming: $editing)
                            .listRowBackground(ShelfTheme.background)
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    library.removeTrack(track.id, from: playlistID)
                                }
                            }
                    }
                    .onMove { from, to in library.moveTracks(in: playlistID, from: from, to: to) }
                }
                if !playlist.missingTracks.isEmpty {
                    Section("Not Found in Your Files") {
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
        .background(ShelfTheme.background)
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(item: $editing) { track in RenameTrackView(track: track) }
    }
}
