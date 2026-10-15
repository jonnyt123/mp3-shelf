import SwiftUI

struct MiniPlayer: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    let open: () -> Void

    var body: some View {
        if let track = library.song(with: playback.currentTrackID) {
            HStack(spacing: 11) {
                HStack(spacing: 11) {
                    ArtworkTile(track: track, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.subheadline.bold()).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(ShelfTheme.subdued).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
                .accessibilityAddTraits(.isButton)
                Button { playback.togglePlayback() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                Button { playback.next() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.headline).frame(width: 35, height: 44)
                }
                .accessibilityLabel("Next song")
            }
            .padding(9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(ShelfTheme.accent)
                        .frame(width: geo.size.width * (playback.duration > 0 ? min(1, playback.currentTime / playback.duration) : 0), height: 2)
                        .offset(y: geo.size.height - 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .allowsHitTesting(false)
            }
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var draggingTime: Double?
    @State private var showLyrics = false

    var body: some View {
        NavigationStack {
            Group {
                if let track = library.song(with: playback.currentTrackID) {
                    GeometryReader { proxy in
                        ScrollView {
                            VStack(spacing: 26) {
                                Spacer(minLength: 12)
                                ArtworkTile(track: track, size: min(proxy.size.width - 64, 330))
                                    .shadow(color: ShelfTheme.accent.opacity(0.2), radius: 26, y: 10)
                                    .frame(maxWidth: .infinity)
                                VStack(spacing: 6) {
                                    Text(track.title).font(.title2.bold()).multilineTextAlignment(.center)
                                    Text(track.artist).font(.subheadline).foregroundStyle(ShelfTheme.subdued)
                                    Text(track.album).font(.caption).foregroundStyle(ShelfTheme.subdued).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal)
                                VStack(spacing: 7) {
                                    Slider(value: Binding(
                                        get: { draggingTime ?? playback.currentTime },
                                        set: { draggingTime = $0 }
                                    ), in: 0...max(playback.duration, 1), onEditingChanged: { isEditing in
                                        if !isEditing, let draggingTime { playback.seek(to: draggingTime); self.draggingTime = nil }
                                    })
                                    .tint(ShelfTheme.accent)
                                    HStack {
                                        Text((draggingTime ?? playback.currentTime).shelfClock)
                                        Spacer()
                                        Text("−" + max(0, playback.duration - (draggingTime ?? playback.currentTime)).shelfClock)
                                    }
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(ShelfTheme.subdued)
                                }
                                HStack(spacing: 0) {
                                    Button { playback.isShuffled.toggle() } label: {
                                        Image(systemName: "shuffle")
                                            .foregroundStyle(playback.isShuffled ? ShelfTheme.accent : .white)
                                    }
                                    .accessibilityLabel("Shuffle")
                                    Spacer()
                                    Button { playback.previous() } label: { Image(systemName: "backward.end.fill") }
                                        .accessibilityLabel("Previous track")
                                    Spacer()
                                    Button { playback.togglePlayback() } label: {
                                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 27, weight: .bold))
                                            .foregroundStyle(.black)
                                            .frame(width: 72, height: 72)
                                            .background(.white, in: Circle())
                                    }
                                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                                    Spacer()
                                    Button { playback.next() } label: { Image(systemName: "forward.end.fill") }
                                        .accessibilityLabel("Next track")
                                    Spacer()
                                    Button { playback.cycleRepeat() } label: {
                                        Image(systemName: playback.repeatMode.systemImage)
                                            .foregroundStyle(playback.repeatMode == .off ? .white : ShelfTheme.accent)
                                    }
                                    .accessibilityLabel("Repeat: \(playback.repeatMode.rawValue)")
                                }
                                .font(.system(size: 22))
                                .buttonStyle(.plain)
                                .padding(.vertical, 8)
                                HStack {
                                    Button { library.toggleFavorite(track.id) } label: {
                                        Label(track.isFavorite ? "Favorite" : "Add favorite", systemImage: track.isFavorite ? "heart.fill" : "heart")
                                    }
                                    Spacer()
                                    Button { showLyrics = true } label: {
                                        Label("Lyrics", systemImage: "text.quote")
                                    }
                                    Spacer()
                                    ShareLink(item: library.fileURL(for: track)) {
                                        Label("Share file", systemImage: "square.and.arrow.up")
                                    }
                                }
                                .font(.subheadline)
                                .tint(ShelfTheme.accent)
                                Spacer(minLength: 24)
                            }
                            .padding(.horizontal, 26)
                        }
                    }
                } else {
                    EmptyShelfView(title: "Nothing playing", subtitle: "Choose a song in your library to get started.", symbol: "music.note")
                }
            }
            .background(ShelfTheme.background.ignoresSafeArea())
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .navigationDestination(isPresented: $showLyrics) {
                if let id = playback.currentTrackID { LyricsView(songID: id) }
            }
        }
    }
}
