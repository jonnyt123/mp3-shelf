import SwiftUI

struct MiniPlayer: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let open: () -> Void

    var body: some View {
        if let track = library.song(with: playback.currentTrackID) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        openNowPlaying(track)
                        HStack(spacing: 12) {
                            Spacer(minLength: 0)
                            transportControls
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        openNowPlaying(track)
                        transportControls
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 8 : 11)
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
    // At accessibility text sizes, give the song metadata the full width and
    // move transport actions below it instead of squeezing text between buttons.
    private func openNowPlaying(_ track: MusicTrack) -> some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ArtworkTile(track: track, size: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(ShelfTheme.subdued)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Now Playing for \(track.title) by \(track.artist)")
        .accessibilityHint("Show playback controls, lyrics and the queue")
    }

    private var transportControls: some View {
        HStack(spacing: 12) {
            Button { playback.togglePlayback() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ShelfTheme.background)
                    .frame(width: 44, height: 44)
                    .background(ShelfTheme.accent, in: Circle())
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            .accessibilityHint("Toggle playback of the current song")
            Button { playback.next() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next song")
            .accessibilityHint("Skip to the next song in the queue")
        }
        .buttonStyle(.plain)
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var draggingTime: Double?
    @State private var scrubbingTrackID: UUID?
    @State private var showLyrics = false
    @State private var showQueue = false
    @AccessibilityFocusState private var queueButtonFocused: Bool
    private let seekStep: TimeInterval = 15
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Snapshot the queue once for this render so playback ticks do not
        // repeatedly rebuild it for the preview and its visibility check.
        let upcomingPreview = playback.upcomingTracks
        return NavigationStack {
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
                                PlaybackErrorBanner()
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
                                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(track.artist)
                                            .font(.headline.weight(.regular))
                                            .foregroundStyle(ShelfTheme.subdued)
                                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if !track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                            track.album.localizedCaseInsensitiveCompare("Unknown Album") != .orderedSame {
                                            Text(track.album)
                                                .font(.caption)
                                                .foregroundStyle(ShelfTheme.subdued.opacity(0.75))
                                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
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
                                        if editing {
                                            scrubbingTrackID = playback.currentTrackID
                                        } else {
                                            if scrubbingTrackID == playback.currentTrackID, let draggingTime {
                                                playback.seek(to: draggingTime)
                                            }
                                            self.draggingTime = nil
                                            scrubbingTrackID = nil
                                        }
                                    })
                                    .tint(ShelfTheme.mint)
                                    .accessibilityLabel("Track progress")
                                    .accessibilityValue("\((draggingTime ?? playback.currentTime).shelfClock) of \(playback.duration.shelfClock)")
                                    HStack {
                                        Text((draggingTime ?? playback.currentTime).shelfClock)
                                            .accessibilityLabel("Elapsed time")
                                            .accessibilityValue((draggingTime ?? playback.currentTime).shelfClock)
                                        Spacer()
                                        Text("−" + max(0, playback.duration -
                                            (draggingTime ?? playback.currentTime)).shelfClock)
                                            .accessibilityLabel("Time remaining")
                                            .accessibilityValue(max(0, playback.duration - (draggingTime ?? playback.currentTime)).shelfClock)
                                    }
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(ShelfTheme.subdued)
                                }
                                .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 15 : 25)

                                HStack {
                                    Button {
                                        draggingTime = nil
                                        scrubbingTrackID = nil
                                        playback.seek(to: playback.currentTime - seekStep)
                                    } label: {
                                        Label("Back 15 seconds", systemImage: "gobackward.15")
                                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                    }
                                    Spacer()
                                    Text(playback.isPlaying ? "Playing" : "Paused")
                                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                    Spacer()
                                    Button {
                                        draggingTime = nil
                                        scrubbingTrackID = nil
                                        playback.seek(to: playback.currentTime + seekStep)
                                    } label: {
                                        Label("Forward 15 seconds", systemImage: "goforward.15")
                                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                    }
                                }
                                .tint(ShelfTheme.mint)
                                .padding(.bottom, 8)

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

                                Button { showQueue = true } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "list.bullet.rectangle.portrait")
                                            .font(.system(size: 19, weight: .semibold))
                                            .foregroundStyle(ShelfTheme.mint)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Manage playing queue")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.white)
                                            Text("\(playback.queuedTracks.count) songs lined up")
                                                .font(.caption)
                                                .foregroundStyle(ShelfTheme.subdued)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(ShelfTheme.subdued)
                                    }
                                    .padding(15)
                                    .premiumCard(radius: 17)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Manage playing queue")
                                 .accessibilityHint("Review and reorder upcoming songs")
                                 .accessibilityFocused($queueButtonFocused)

                                if !upcomingPreview.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        PremiumSectionHeading(title: "Up next",
                                                              detail: "YOUR QUEUE")
                                        ForEach(upcomingPreview) { next in
                                            Button {
                                                playback.play(next)
                                            } label: {
                                                HStack(spacing: 12) {
                                                    ArtworkTile(track: next, size: 46)
                                                    VStack(alignment: .leading, spacing: 3) {
                                                        Text(next.title)
                                                            .font(.subheadline.weight(.semibold))
                                                            .foregroundStyle(.white)
                                                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                                                        Text(next.artist)
                                                            .font(.caption)
                                                            .foregroundStyle(ShelfTheme.subdued)
                                                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                                                    }
                                                    Spacer(minLength: 0)
                                                    Image(systemName: "play.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(ShelfTheme.accent)
                                                }
                                                .padding(10)
                                                .premiumCard(radius: 17)
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Play next: \(next.title) by \(next.artist)")
                                             .accessibilityHint("Start this queued recording now")
                                        }
                                    }
                                    .padding(.top, 24)
                                }

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
                            .frame(width: 44, height: 44)
                            .background(ShelfTheme.elevated, in: Circle())
                    }
                    .accessibilityLabel("Close player")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showLyrics) {
                if let id = playback.currentTrackID { LyricsView(songID: id) }
            }
            .onChange(of: playback.currentTrackID) { _, _ in draggingTime = nil }
             .onChange(of: showQueue) { _, presented in
                 if !presented { queueButtonFocused = true }
             }
            .sheet(isPresented: $showQueue) {
                PlaybackQueueSheet()
                    .environmentObject(library)
                    .environmentObject(playback)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
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


/// A separate, bounded and lazy queue editor. All controls affect only the
/// current in-memory play order; they never delete files or modify playlists.
struct PlaybackQueueSheet: View {
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var focusedQueueTrackID: UUID?
    @State private var pendingQueueFocusID: UUID?
    @State private var pendingEmptyQueueFocus = false
    @AccessibilityFocusState private var emptyQueueFocused: Bool

    // Keep VoiceOver on the nearest surviving queue action after a deletion.
    // The focus target must be applied after the queue has published its new rows.
    private func removeFromQueue(_ trackID: UUID) {
        // Resolve against the live queue rather than a row's captured render.
        // Playback may advance between opening a menu and choosing Remove.
        let current = playback.queuedTracks
        guard let index = current.firstIndex(where: { $0.id == trackID }) else { return }
        let remaining = current.filter { $0.id != trackID }
        pendingQueueFocusID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        pendingEmptyQueueFocus = remaining.isEmpty
        playback.removeQueuedTrack(trackID)
    }

    // A queue mutation must leave a usable focus target, even when playback
    // advances at the same moment or a requested move is already at the edge.
    private func focusAfterQueueMutation(_ trackID: UUID) {
        pendingQueueFocusID = trackID
        pendingEmptyQueueFocus = false
    }

    private func reorder(_ trackID: UUID, earlier: Bool) {
        // A queued row can outlive the snapshot it rendered from. Always
        // recheck live boundaries before changing the play order.
        let current = playback.queuedTracks
        guard let index = current.firstIndex(where: { $0.id == trackID }) else { return }
        guard earlier ? index > 0 : index < current.count - 1 else { return }
        focusAfterQueueMutation(trackID)
        playback.moveQueuedTrack(trackID, earlier: earlier)
    }

    private func playNext(_ trackID: UUID) {
        // A context menu can stay open after playback advances or a queue edit.
        // Do not issue a mutation or retain a focus request for a vanished row.
        guard playback.queuedTracks.contains(where: { $0.id == trackID }) else { return }
        focusAfterQueueMutation(trackID)
        playback.playQueuedTrackNext(trackID)
    }

    private func playNow(_ trackID: UUID) {
        // Resolve from the live queue; a captured MusicTrack may no longer be
        // queued when a menu action is selected after automatic advancement.
        guard let track = playback.queuedTracks.first(where: { $0.id == trackID }) else { return }
        pendingQueueFocusID = nil
        pendingEmptyQueueFocus = false
        playback.play(track)
    }

    // Large-text users should not have to open a context menu for every
    // reorder. The same bounded operations back the menu and VoiceOver.
    private func moveButton(_ track: MusicTrack, earlier: Bool,
                            in upcoming: [MusicTrack]) -> some View {
        Button {
            reorder(track.id, earlier: earlier)
        } label: {
            Image(systemName: earlier ? "arrow.up" : "arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(ShelfTheme.accent)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(earlier ? "Move earlier" : "Move later"): \(track.title)")
        .accessibilityHint(earlier
            ? "Move this song one position toward the start of the queue"
            : "Move this song one position toward the end of the queue")
    }

    // Use a vertical fallback when enlarged labels cannot fit beside two
    // minimum-size reorder targets. Both layouts invoke identical queue actions.
    @ViewBuilder
    private func queueActions(_ track: MusicTrack, index: Int,
                              upcoming: [MusicTrack], stacked: Bool) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    moveButton(track, earlier: true, in: upcoming)
                        .disabled(index == 0)
                    moveButton(track, earlier: false, in: upcoming)
                        .disabled(index == upcoming.count - 1)
                    Spacer(minLength: 0)
                    Text("Position \\(index + 1) of \\(upcoming.count)")
                        .font(.caption)
                        .foregroundStyle(ShelfTheme.subdued)
                        .accessibilityHidden(true)
                }
                playNextButton(track)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 8) {
                moveButton(track, earlier: true, in: upcoming)
                    .disabled(index == 0)
                moveButton(track, earlier: false, in: upcoming)
                    .disabled(index == upcoming.count - 1)
                Spacer(minLength: 0)
                playNextButton(track)
            }
        }
    }

    private func playNextButton(_ track: MusicTrack) -> some View {
        Button {
            playNext(track.id)
        } label: {
            Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShelfTheme.accent)
        .accessibilityLabel("Play next: \\(track.title)")
        .accessibilityHint("Move this song to the next position in the playback queue")
    }

    var body: some View {
        let upcoming = playback.queuedTracks
        return NavigationStack {
            ZStack {
                PremiumBackdrop()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let playing = library.song(with: playback.currentTrackID) {
                            PremiumEyebrow(title: "PLAYING NOW")
                            HStack(spacing: 13) {
                                ArtworkTile(track: playing, size: 58)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playing.title)
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                                    Text(playing.artist)
                                        .font(.subheadline)
                                        .foregroundStyle(ShelfTheme.subdued)
                                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                                }
                                Spacer()
                                Image(systemName: "waveform")
                                    .foregroundStyle(ShelfTheme.mint)
                                    .accessibilityHidden(true)
                            }
                            .padding(14)
                            .premiumCard(radius: 18)
                        }

                        PremiumSectionHeading(
                            title: "Up next",
                            detail: "\(upcoming.count) in queue"
                        )
                        .padding(.top, 14)

                        if upcoming.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: "music.note.list")
                                    .font(.largeTitle)
                                    .foregroundStyle(ShelfTheme.accent)
                                Text("You're all caught up")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("Pick more songs from Listen to build your queue.")
                                    .font(.subheadline)
                                    .foregroundStyle(ShelfTheme.subdued)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(22)
                            .premiumCard()
                            .accessibilityElement(children: .combine)
                            .accessibilityFocused($emptyQueueFocused)
                        } else {
                            ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, track in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 12) {
                                    ArtworkTile(track: track, size: dynamicTypeSize.isAccessibilitySize ? 40 : 48)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                                        Text(track.artist)
                                            .font(.caption)
                                            .foregroundStyle(ShelfTheme.subdued)
                                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .layoutPriority(1)
                                    Menu {
                                        Button {
                                            playNow(track.id)
                                        } label: {
                                            Label("Play now", systemImage: "play.fill")
                                        }
                                        Button {
                                            playNext(track.id)
                                        } label: {
                                            Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                        }
                                        if index > 0 {
                                            Button {
                                                reorder(track.id, earlier: true)
                                            } label: {
                                                Label("Move earlier", systemImage: "arrow.up")
                                            }
                                        }
                                        if index < upcoming.count - 1 {
                                            Button {
                                                reorder(track.id, earlier: false)
                                            } label: {
                                                Label("Move later", systemImage: "arrow.down")
                                            }
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            removeFromQueue(track.id)
                                        } label: {
                                            Label("Remove from queue", systemImage: "minus.circle")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.body.weight(.bold))
                                            .foregroundStyle(ShelfTheme.accent)
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("Queue options for \(track.title)")
                                    .accessibilityHint("Play, reorder, or remove this song from the upcoming queue")
                                    .accessibilityFocused($focusedQueueTrackID, equals: track.id)
                                    }
                                    if dynamicTypeSize.isAccessibilitySize {
                                        // Separate transport actions from metadata so the largest
                                        // text sizes never compete with three 44-point targets.
                                        // At the largest text sizes, keep all three actions
                                        // independently reachable without compressing labels.
                                        ViewThatFits(in: .horizontal) {
                                            queueActions(track, index: index, upcoming: upcoming,
                                                         stacked: false)
                                            queueActions(track, index: index, upcoming: upcoming,
                                                         stacked: true)
                                        }
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .premiumCard(radius: 17)
                                .accessibilityElement(children: .contain)
                                .accessibilityAction(named: "Play now") {
                                    playNow(track.id)
                                }
                                .accessibilityAction(named: "Play next") {
                                    playNext(track.id)
                                }
                                .accessibilityAction(named: "Move earlier") {
                                    if index > 0 { reorder(track.id, earlier: true) }
                                }
                                .accessibilityAction(named: "Move later") {
                                    if index < upcoming.count - 1 { reorder(track.id, earlier: false) }
                                }
                                .accessibilityAction(named: "Remove from queue") {
                                    removeFromQueue(track.id)
                                }
                            }
                        }

                        Text("Queue edits do not change your saved playlists or remove music.")
                            .font(.caption)
                            .foregroundStyle(ShelfTheme.subdued)
                            .padding(.top, 12)
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .onChange(of: upcoming.map(\.id)) { _, currentIDs in
                // An empty queue has no track ID to focus; retain that intent
                // separately so removing the final song still announces the state.
                if pendingEmptyQueueFocus && currentIDs.isEmpty {
                    pendingEmptyQueueFocus = false
                    pendingQueueFocusID = nil
                    emptyQueueFocused = true
                } else if currentIDs.isEmpty {
                    // Automatic playback advancement can drain the queue without
                    // a removal action. A focused row must never remain orphaned.
                    pendingQueueFocusID = nil
                    pendingEmptyQueueFocus = false
                    focusedQueueTrackID = nil
                    emptyQueueFocused = true
                } else if let target = pendingQueueFocusID {
                    pendingQueueFocusID = nil
                    pendingEmptyQueueFocus = false
                    if currentIDs.contains(target) {
                        focusedQueueTrackID = target
                    } else if currentIDs.isEmpty {
                        emptyQueueFocused = true
                    } else if let first = currentIDs.first {
                        // Playback can advance while the user is editing.
                        // Never leave focus pointing at a vanished queue row.
                        focusedQueueTrackID = first
                    }
                }
            }
            .navigationTitle("Your queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(ShelfTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
