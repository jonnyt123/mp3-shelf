import SwiftUI

struct MiniPlayer: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let open: () -> Void

    // Audio metadata can briefly be unknown or nonfinite during a track switch.
    // Never feed NaN or infinity into SwiftUI's layout system.
    private var playbackProgress: Double {
        guard playback.duration.isFinite, playback.duration > 0,
              playback.currentTime.isFinite else { return 0 }
        return min(max(playback.currentTime / playback.duration, 0), 1)
    }

    var body: some View {
        if let track = library.song(with: playback.currentTrackID) {
            // An iPhone in Split View or with larger text can be narrower
            // than its nominal size class. Fit the controls below metadata
            // before compressing the title into an unusable tap target.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    openNowPlaying(track)
                        .frame(minWidth: 155)
                    transportControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    openNowPlaying(track)
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
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
                        .frame(width: max(0, geo.size.width) * playbackProgress, height: 3)
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

    // An in-progress scrub belongs to exactly one recording. A new recording
    // must never inherit the previous recording's pending slider value.
    private func clearScrub() {
        draggingTime = nil
        scrubbingTrackID = nil
    }

    private var seekableDuration: Double {
        playback.duration.isFinite && playback.duration > 0 ? playback.duration : 0
    }

    // Transport buttons operate on the live playback clock, not a pending
    // slider drag. A scrub is only committed when its editing gesture ends.
    private var livePlaybackTime: Double {
        guard playback.currentTime.isFinite else { return 0 }
        return min(max(playback.currentTime, 0), seekableDuration)
    }

    private func seekBy(_ offset: TimeInterval) {
        guard seekableDuration > 0 else { return }
        let destination = min(max(livePlaybackTime + offset, 0), seekableDuration)
        clearScrub()
        playback.seek(to: destination)
    }

    private var displayedTime: Double {
        let raw = (scrubbingTrackID == playback.currentTrackID ? draggingTime : nil)
            ?? playback.currentTime
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), seekableDuration)
    }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Snapshot the queue once for this render so playback ticks do not
        // repeatedly rebuild it for the preview and its visibility check.
        let upcomingPreview = playback.upcomingTracks
        return NavigationStack {
            Group {
                if let track = library.song(with: playback.currentTrackID) {
                    GeometryReader { proxy in
                        // Never pass negative or nonfinite dimensions to ArtworkTile
                        // when the player is temporarily given zero layout space.
                        let availableWidth = proxy.size.width.isFinite
                            ? max(0, proxy.size.width - 64) : 0
                        let availableHeight = proxy.size.height.isFinite
                            ? max(0, proxy.size.height) : 0
                        let preferredCoverHeight = dynamicTypeSize.isAccessibilitySize
                            ? max(156, availableHeight * 0.26)
                            : max(190, availableHeight * 0.39)
                        let coverSize = min(availableWidth, preferredCoverHeight, 330)
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
                                    // A zero/unknown duration is not a seekable timeline.
                                    // Keep the slider in a finite range while preventing
                                    // phantom scrubs before media metadata is available.
                                    Slider(value: Binding(
                                        get: {
                                            min(displayedTime, max(seekableDuration, 1))
                                        },
                                        set: { draggingTime = $0.isFinite ? $0 : nil }
                                    ), in: 0...max(seekableDuration, 1), onEditingChanged: { editing in
                                        if editing {
                                            scrubbingTrackID = playback.currentTrackID
                                        } else {
                                            if scrubbingTrackID == playback.currentTrackID,
                                               seekableDuration > 0,
                                               let draggingTime, draggingTime.isFinite {
                                                playback.seek(to: min(max(draggingTime, 0), seekableDuration))
                                            }
                                            clearScrub()
                                        }
                                    })
                                    .tint(ShelfTheme.mint)
                                    .disabled(seekableDuration == 0)
                                    .accessibilityLabel("Track progress")
                                    .accessibilityValue(seekableDuration > 0
                                        ? "\(displayedTime.shelfClock) of \(seekableDuration.shelfClock)"
                                        : "Duration unavailable")
                                    .accessibilityHint(seekableDuration > 0
                                        ? "Swipe up or down to seek by 15 seconds"
                                        : "Seeking is unavailable until the recording duration is known")
                                     // VoiceOver increments do not necessarily invoke
                                     // Slider drag lifecycle callbacks. Use live time.
                                     .accessibilityAdjustableAction { direction in
                                         guard seekableDuration > 0 else { return }
                                         switch direction {
                                         case .increment:
                                             seekBy(seekStep)
                                         case .decrement:
                                             seekBy(-seekStep)
                                         @unknown default:
                                             break
                                         }
                                     }
                                    HStack {
                                        Text(displayedTime.shelfClock)
                                            .accessibilityLabel("Elapsed time")
                                            .accessibilityValue(displayedTime.shelfClock)
                                        Spacer()
                                        Text("−" + max(0, seekableDuration - displayedTime).shelfClock)
                                            .accessibilityLabel("Time remaining")
                                            .accessibilityValue(max(0, seekableDuration - displayedTime).shelfClock)
                                    }
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(ShelfTheme.subdued)
                                }
                                .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 15 : 25)

                                HStack {
                                    Button {
                                        seekBy(-seekStep)
                                    } label: {
                                        Label("Back 15 seconds", systemImage: "gobackward.15")
                                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                    }
                                    .disabled(seekableDuration == 0 || livePlaybackTime <= 0)
                                    .accessibilityHint("Seek toward the beginning of the current recording")
                                    Spacer()
                                    Text(playback.isPlaying ? "Playing" : "Paused")
                                        .font(.caption).foregroundStyle(ShelfTheme.subdued)
                                    Spacer()
                                    Button {
                                        seekBy(seekStep)
                                    } label: {
                                        Label("Forward 15 seconds", systemImage: "goforward.15")
                                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                    }
                                    .disabled(seekableDuration == 0 || livePlaybackTime >= seekableDuration)
                                    .accessibilityHint("Seek toward the end of the current recording")
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
        .onChange(of: playback.currentTrackID) { _, _ in
            clearScrub()
        }
        .onChange(of: playback.duration) { _, duration in
            // Duration can reset during a source transition without an ID change.
            if !duration.isFinite || duration <= 0 {
                clearScrub()
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
        guard earlier ? index > 0 : index < current.count - 1 else {
            // An obsolete context-menu action must not leave focus pending.
            pendingQueueFocusID = nil
            return
        }
        focusAfterQueueMutation(trackID)
        playback.moveQueuedTrack(trackID, earlier: earlier)
    }

    private func playNext(_ trackID: UUID) {
        // A context menu can stay open after playback advances or a queue edit.
        // Do not issue a mutation or retain a focus request for a vanished row.
        let current = playback.queuedTracks
        guard let index = current.firstIndex(where: { $0.id == trackID }) else { return }
        // Already next: no queue publication will follow, so avoid leaving a
        // pending focus request that could hijack a later unrelated queue edit.
        guard index > 0 else {
            pendingQueueFocusID = nil
            pendingEmptyQueueFocus = false
            focusedQueueTrackID = trackID
            return
        }
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

    // A row's captured index can become stale as playback advances.
    // All queue controls must use live boundaries before enabling an action.
    private func canMove(_ trackID: UUID, earlier: Bool) -> Bool {
        let current = playback.queuedTracks
        guard let index = current.firstIndex(where: { $0.id == trackID }) else { return false }
        return earlier ? index > 0 : index < current.count - 1
    }

    // Large-text users should not have to open a context menu for every
    // reorder. The same bounded operations back the menu and VoiceOver.
    private func moveButton(_ track: MusicTrack, earlier: Bool) -> some View {
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
                    moveButton(track, earlier: true)
                        .disabled(!canMove(track.id, earlier: true))
                    moveButton(track, earlier: false)
                        .disabled(!canMove(track.id, earlier: false))
                    Spacer(minLength: 0)
                    Text("Position \(index + 1) of \(upcoming.count)")
                        .font(.caption)
                        .foregroundStyle(ShelfTheme.subdued)
                        .accessibilityHidden(true)
                }
                playNextButton(track)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 8) {
                moveButton(track, earlier: true)
                    .disabled(!canMove(track.id, earlier: true))
                moveButton(track, earlier: false)
                    .disabled(!canMove(track.id, earlier: false))
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
        .accessibilityLabel("Play next: \(track.title)")
        .accessibilityHint("Make this song the next recording to play")
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
                                        if canMove(track.id, earlier: true) {
                                            Button {
                                                reorder(track.id, earlier: true)
                                            } label: {
                                                Label("Move earlier", systemImage: "arrow.up")
                                            }
                                        }
                                        if canMove(track.id, earlier: false) {
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
                                    // Expose the primary queue actions at every text size.
                                    // Previously only accessibility sizes showed these controls,
                                    // forcing standard-size users into an overflow menu to reorder.
                                    // The stacked fallback also protects narrow iPhones and
                                    // long localized labels without shrinking 44-point targets.
                                    ViewThatFits(in: .horizontal) {
                                        queueActions(track, index: index, upcoming: upcoming,
                                                     stacked: false)
                                        queueActions(track, index: index, upcoming: upcoming,
                                                     stacked: true)
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
                                    reorder(track.id, earlier: true)
                                }
                                .accessibilityAction(named: "Move later") {
                                    reorder(track.id, earlier: false)
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
            .onChange(of: playback.currentTrackID) { _, _ in
                // An automatic track transition can invalidate VoiceOver focus
                // even when the queue editor remains presented.
                let liveIDs = playback.queuedTracks.map(\.id)
                if let focused = focusedQueueTrackID, !liveIDs.contains(focused) {
                    focusedQueueTrackID = liveIDs.first
                    emptyQueueFocused = liveIDs.isEmpty
                }
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
