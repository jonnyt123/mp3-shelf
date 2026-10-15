import SwiftUI

struct MiniPlayer: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let open: () -> Void

    var body: some View {
        if let track = library.song(with: playback.currentTrackID) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    ArtworkTile(track: track, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(ShelfTheme.subdued)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Open Now Playing for \(track.title)")
                Button { playback.togglePlayback() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ShelfTheme.background)
                        .frame(width: 44, height: 44)
                        .background(ShelfTheme.accent, in: Circle())
                }
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                Button { playback.next() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next song")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 22)
                    .fill(ShelfTheme.elevated)
                    .overlay {
                        if !reduceTransparency {
                            RoundedRectangle(cornerRadius: 22)
                                .fill(.ultraThinMaterial)
                        }
                    }
            }
            .overlay(RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(LinearGradient(colors: [ShelfTheme.accent, ShelfTheme.mint],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * (playback.duration > 0
                            ? max(0, min(1, playback.currentTime / playback.duration)) : 0),
                               height: 3)
                        .offset(y: geo.size.height - 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var draggingTime: Double?
    @State private var showLyrics = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Group {
                if let track = library.song(with: playback.currentTrackID) {
                    GeometryReader { proxy in
                        let coverSize = min(proxy.size.width - 64,
                                            dynamicTypeSize.isAccessibilitySize
                                                ? max(156, proxy.size.height * 0.26)
                                                : max(190, proxy.size.height * 0.39),
                                            330)
                        ScrollView {
                            VStack(spacing: 0) {
                                HStack {
                                    Spacer()
                                    VStack(spacing: 5) {
                                        PremiumEyebrow(title: "NOW PLAYING")
                                        Text("MP3 Shelf")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(ShelfTheme.subdued)
                                    }
                                    Spacer()
                                }
                                .padding(.top, 5)
                                .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 15 : 25)

                                ArtworkTile(track: track, size: coverSize)
                                    .shadow(color: ShelfTheme.artworkColors(for: track.title)[0].opacity(0.16),
                                            radius: 38, y: 17)
                                    .shadow(color: .black.opacity(0.3), radius: 14, y: 10)
                                    .frame(maxWidth: .infinity)
                                    .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 17 : 29)

                                HStack(alignment: .center, spacing: 18) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(track.title)
                                            .font(.system(.title2, design: .rounded, weight: .bold))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                            .minimumScaleFactor(0.8)
                                        Text(track.artist)
                                            .font(.headline.weight(.regular))
                                            .foregroundStyle(ShelfTheme.subdued)
                                            .lineLimit(1)
                                        Text(track.album)
                                            .font(.caption)
                                            .foregroundStyle(ShelfTheme.subdued.opacity(0.75))
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Button { library.toggleFavorite(track.id) } label: {
                                        Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                                            .font(.system(size: 21, weight: .medium))
                                            .foregroundStyle(track.isFavorite ? ShelfTheme.coral : .white)
                                            .frame(width: 50, height: 50)
                                            .background(ShelfTheme.elevated, in: Circle())
                                            .overlay(Circle().strokeBorder(ShelfTheme.border, lineWidth: 1))
                                    }
                                    .accessibilityLabel(track.isFavorite ? "Remove favorite" : "Add favorite")
                                }
                                .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 15 : 25)

                                VStack(spacing: 7) {
                                    Slider(value: Binding(
                                        get: { draggingTime ?? playback.currentTime },
                                        set: { draggingTime = $0 }
                                    ), in: 0...max(playback.duration, 1), onEditingChanged: { editing in
                                        if !editing, let draggingTime {
                                            playback.seek(to: draggingTime)
                                            self.draggingTime = nil
                                        }
                                    })
                                    .tint(ShelfTheme.mint)
                                    .accessibilityLabel("Track progress")
                                    .accessibilityValue("\((draggingTime ?? playback.currentTime).shelfClock) of \(playback.duration.shelfClock)")
                                    HStack {
                                        Text((draggingTime ?? playback.currentTime).shelfClock)
                                        Spacer()
                                        Text("−" + max(0, playback.duration -
                                            (draggingTime ?? playback.currentTime)).shelfClock)
                                    }
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(ShelfTheme.subdued)
                                }
                                .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 15 : 25)

                                HStack(spacing: 0) {
                                    playerButton("shuffle", active: playback.isShuffled,
                                                 action: { playback.isShuffled.toggle() })
                                        .accessibilityLabel("Shuffle")
                                        .accessibilityValue(playback.isShuffled ? "On" : "Off")
                                    Spacer()
                                    Button { playback.previous() } label: {
                                        Image(systemName: "backward.end.fill")
                                            .font(.system(size: 25, weight: .medium))
                                            .frame(width: 44, height: 56)
                                    }
                                    .accessibilityLabel("Previous track")
                                    Spacer()
                                    Button { playback.togglePlayback() } label: {
                                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 29, weight: .bold))
                                            .foregroundStyle(ShelfTheme.background)
                                            .frame(width: 76, height: 76)
                                            .background(ShelfTheme.accent, in: Circle())
                                            .shadow(color: ShelfTheme.accent.opacity(0.24),
                                                    radius: 20, y: 8)
                                    }
                                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                                    Spacer()
                                    Button { playback.next() } label: {
                                        Image(systemName: "forward.end.fill")
                                            .font(.system(size: 25, weight: .medium))
                                            .frame(width: 44, height: 56)
                                    }
                                    .accessibilityLabel("Next track")
                                    Spacer()
                                    playerButton(playback.repeatMode.systemImage,
                                                 active: playback.repeatMode != .off,
                                                 action: { playback.cycleRepeat() })
                                        .accessibilityLabel("Repeat")
                                        .accessibilityValue(playback.repeatMode.rawValue)
                                }
                                .foregroundStyle(.white)
                                .buttonStyle(.plain)
                                .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 18 : 30)

                                HStack(spacing: 12) {
                                    Button { showLyrics = true } label: {
                                        Label("Lyrics", systemImage: "text.quote")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 15)
                                    }
                                    .buttonStyle(.plain)
                                    .premiumCard(radius: 16)
                                    ShareLink(item: library.fileURL(for: track)) {
                                        Label("Share song", systemImage: "square.and.arrow.up")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 15)
                                    }
                                    .buttonStyle(.plain)
                                    .premiumCard(radius: 16)
                                }
                                .foregroundStyle(.white)
                                HStack(spacing: 7) {
                                    Image(systemName: "iphone.gen3")
                                        .font(.caption)
                                    Text("SAVED ON THIS IPHONE")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .tracking(1.4)
                                }
                                .foregroundStyle(ShelfTheme.subdued)
                                .padding(.top, 21)
                                Spacer(minLength: 24)
                            }
                            .padding(.horizontal, 27)
                        }
                        .scrollIndicators(.hidden)
                    }
                } else {
                    EmptyShelfView(title: "Nothing playing",
                                   subtitle: "Pick something from your library.",
                                   symbol: "music.note")
                        .padding(24)
                }
            }
            .background {
                ZStack {
                    PremiumBackdrop()
                    RadialGradient(colors: [
                                       ShelfTheme.artworkColors(
                                         for: library.song(with: playback.currentTrackID)?.title ?? "MP3 Shelf"
                                       )[0].opacity(0.12), .clear
                                   ],
                                   center: .center, startRadius: 40, endRadius: 430)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(ShelfTheme.elevated, in: Circle())
                    }
                    .accessibilityLabel("Close player")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showLyrics) {
                if let id = playback.currentTrackID { LyricsView(songID: id) }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func playerButton(_ symbol: String, active: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(active ? ShelfTheme.mint : ShelfTheme.subdued)
                .frame(width: 44, height: 48)
        }
    }
}
