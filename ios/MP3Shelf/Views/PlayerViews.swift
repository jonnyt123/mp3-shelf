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
            Group {
                // ViewThatFits can accept a compressed HStack even when the
                // metadata becomes unreadable. At accessibility sizes, give
                // the song details their own row and preserve full-size
                // transport targets below them.
                if dynamicTypeSize >= .xxxLarge {
                    VStack(alignment: .leading, spacing: 8) {
                        openNowPlaying(track)
                        HStack(spacing: 12) {
                            Spacer(minLength: 0)
                            transportControls
                        }
                    }
                } else {
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
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, dynamicTypeSize >= .xxxLarge ? 8 : 11)
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
                .accessibilityHidden(true)
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
                        .lineLimit(dynamicTypeSize >= .xxxLarge ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(ShelfTheme.subdued)
                        .lineLimit(dynamicTypeSize >= .xxxLarge ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: true)
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
            .accessibilityHint(playback.isPlaying ? "Pause the current recording" : "Resume the current recording")
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
    @State private var sliderEditing = false
    @State private var invalidatedSliderGesture = false
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var previewQueueChanged = false
    @State private var openQueueAfterPreviewAlert = false
    @AccessibilityFocusState private var queueButtonFocused: Bool
    private let seekStep: TimeInterval = 15

    // An in-progress scrub belongs to exactly one recording. A new recording
    // must never inherit the previous recording's pending slider value.
    private func clearScrub() {
        draggingTime = nil
        scrubbingTrackID = nil
    }

    // A track transition can occur while UIKit/SwiftUI is still delivering
    // drag updates. Reject the remainder of that gesture, even after the
    // pending track identity is cleared, until editing ends explicitly.
    private func invalidateActiveScrub() {
        if sliderEditing || scrubbingTrackID != nil {
            invalidatedSliderGesture = true
        }
        clearScrub()
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
        // A transport seek can occur while a finger is still dragging the
        // timeline. End that gesture's authority before moving the playhead;
        // otherwise its next binding update can overwrite the button seek.
        if sliderEditing {
            invalidateActiveScrub()
        } else {
            clearScrub()
        }
        playback.seek(to: destination)
    }

    // Playback navigation can publish a replacement recording after this
    // action returns. Revoke the old gesture before invoking the command.
    private func navigatePlayback(_ action: () -> Void) {
        invalidateActiveScrub()
        action()
    }

    private var displayedTime: Double {
        let raw = (scrubbingTrackID == playback.currentTrackID ? draggingTime : nil)
            ?? playback.currentTime
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), seekableDuration)
    }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private func trackMetadata(_ track: MusicTrack) -> some View {
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
    }

    private func favoriteButton(_ track: MusicTrack) -> some View {
        Button { library.toggleFavorite(track.id) } label: {
            Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(track.isFavorite ? ShelfTheme.coral : .white)
                .frame(width: 50, height: 50)
                .background(ShelfTheme.elevated, in: Circle())
                .overlay(Circle().strokeBorder(ShelfTheme.border, lineWidth: 1))
        }
        .accessibilityLabel(track.isFavorite ? "Remove favorite" : "Add favorite")
        .accessibilityHint("Double tap to update this song in your favorites")
    }

    // Accessibility text must not force the Lyrics and Share actions into
    // two clipped columns. Keep their hit areas and behavior identical when
    // switching to a vertical layout.
    private func secondaryActions(for track: MusicTrack) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button { showLyrics = true } label: {
                Label("Lyrics", systemImage: "text.quote")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .premiumCard(radius: 16)
            ShareLink(item: library.fileURL(for: track)) {
                Label("Share song", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .premiumCard(radius: 16)
        }
        .foregroundStyle(.white)
    }

    var body: some View {
        // Snapshot the queue once for this render so playback ticks do not
        // repeatedly rebuild it for the preview and its visibility check.
        // Now Playing is an overview, not a second full queue editor. Keep
        // this eager ScrollView bounded even for imported 1,000-song playlists.
        let upcoming = playback.upcomingTracks
        let upcomingPreview = Array(upcoming.prefix(5))
        let hiddenUpcomingCount = max(0, upcoming.count - upcomingPreview.count)
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

                                Group {
                                    if dynamicTypeSize.isAccessibilitySize {
                                        VStack(alignment: .leading, spacing: 10) {
                                            trackMetadata(track)
                                            HStack {
                                                Spacer(minLength: 0)
                                                favoriteButton(track)
                                            }
                                        }
                                    } else {
                                        HStack(alignment: .center, spacing: 18) {
                                            trackMetadata(track)
                                            Spacer(minLength: 0)
                                            favoriteButton(track)
                                        }
                                    }
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
                                        set: { proposedTime in
                                            // The slider binding may receive updates before
                                            // onEditingChanged(true), especially with assistive
                                            // input. Bind the pending value to the recording
                                            // that actually received the interaction.
                                            // A transport action or track transition can
                                            // invalidate an active drag. Ignore every
                                            // remaining update until editing ends.
                                            guard !invalidatedSliderGesture,
                                                  seekableDuration > 0, proposedTime.isFinite,
                                                  let currentID = playback.currentTrackID else {
                                                clearScrub()
                                                return
                                            }
                                            if scrubbingTrackID == nil {
                                                scrubbingTrackID = currentID
                                            }
                                            // Never transfer a drag from a previous song to
                                            // a newly advanced recording.
                                            guard scrubbingTrackID == currentID else { return }
                                            draggingTime = min(max(proposedTime, 0), seekableDuration)
                                        }
                                    ), in: 0...max(seekableDuration, 1), onEditingChanged: { editing in
                                        if editing {
                                            sliderEditing = true
                                            // Do not overwrite the identity captured by the
                                            // binding if a track switched mid-interaction.
                                            if !invalidatedSliderGesture && scrubbingTrackID == nil {
                                                scrubbingTrackID = playback.currentTrackID
                                            }
                                        } else {
                                            if !invalidatedSliderGesture,
                                               scrubbingTrackID == playback.currentTrackID,
                                               seekableDuration > 0,
                                               let draggingTime, draggingTime.isFinite {
                                                playback.seek(to: min(max(draggingTime, 0), seekableDuration))
                                            }
                                            clearScrub()
                                            sliderEditing = false
                                            invalidatedSliderGesture = false
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
                                        .accessibilityHint("Double tap to \(playback.isShuffled ? "disable" : "enable") shuffled playback")
                                    Spacer()
                                    Button { navigatePlayback { playback.previous() } } label: {
                                        Image(systemName: "backward.end.fill")
                                            .font(.system(size: 25, weight: .medium))
                                            .frame(width: 44, height: 56)
                                    }
                                    .accessibilityLabel("Previous track")
                                    .accessibilityHint("Restart the current recording or play the previous recording")
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
                                    .accessibilityHint(playback.isPlaying ? "Pause the current recording" : "Resume the current recording")
                                    Spacer()
                                    Button { navigatePlayback { playback.next() } } label: {
                                        Image(systemName: "forward.end.fill")
                                            .font(.system(size: 25, weight: .medium))
                                            .frame(width: 44, height: 56)
                                    }
                                    .accessibilityLabel("Next track")
                                    .accessibilityHint("Skip to the next recording in playback order")
                                    Spacer()
                                    playerButton(playback.repeatMode.systemImage,
                                                 active: playback.repeatMode != .off,
                                                 action: { playback.cycleRepeat() })
                                        .accessibilityLabel("Repeat")
                                        .accessibilityValue(playback.repeatMode.rawValue)
                                        .accessibilityHint("Double tap to change repeat mode")
                                }
                                .foregroundStyle(.white)
                                .buttonStyle(.plain)
                                .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 18 : 30)

                                secondaryActions(for: track)

                                Button { showQueue = true } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "list.bullet.rectangle.portrait")
                                            .font(.system(size: 19, weight: .semibold))
                                            .foregroundStyle(ShelfTheme.mint)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Manage playing queue")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.white)
                                            Text("\(upcoming.count) upcoming \(upcoming.count == 1 ? "song" : "songs")")
                                                .font(.caption)
                                                .foregroundStyle(ShelfTheme.subdued)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(ShelfTheme.subdued)
                                            .accessibilityHidden(true)
                                    }
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                    .padding(15)
                                    .premiumCard(radius: 17)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Manage playing queue")
                                 .accessibilityValue("\(upcoming.count) upcoming \(upcoming.count == 1 ? "song" : "songs")")
                                 .accessibilityHint(upcoming.isEmpty
                                     ? "The queue is empty. Open to review playback order"
                                     : "Open the full queue to play, reorder or remove recordings")
                                 .accessibilityFocused($queueButtonFocused)

                                if !upcomingPreview.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        PremiumSectionHeading(title: "Up next",
                                                              detail: "YOUR QUEUE")
                                        ForEach(upcomingPreview) { next in
                                            Button {
                                                // A track can advance while this preview is displayed.
                                                // Resolve the live queue before changing playback.
                                                guard let queued = playback.queuedTracks.first(where: { $0.id == next.id }) else {
                                                    // A preview can become stale when playback advances
                                                    // before a VoiceOver user activates its button.
                                                    // Never start a track that is no longer queued.
                                                    openQueueAfterPreviewAlert = false
                                                    queueButtonFocused = false
                                                    previewQueueChanged = true
                                                    return
                                                }
                                                navigatePlayback { playback.play(queued) }
                                            } label: {
                                                HStack(spacing: 12) {
                                                    ArtworkTile(track: next, size: 46)
                                                        .accessibilityHidden(true)
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
                                            .accessibilityLabel("Play now: \(next.title) by \(next.artist)")
                                            .accessibilityHint("Start this queued recording immediately, replacing the current song")
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
                // A modal alert owns VoiceOver focus until it is dismissed.
                queueButtonFocused = !presented && !previewQueueChanged
            }
            .onChange(of: previewQueueChanged) { _, presented in
                guard !presented else {
                    queueButtonFocused = false
                    return
                }
                if openQueueAfterPreviewAlert {
                    // Avoid asking SwiftUI to present a sheet from inside an
                    // alert action while the alert presentation is still active.
                    openQueueAfterPreviewAlert = false
                    showQueue = true
                } else if !showQueue {
                    queueButtonFocused = true
                }
            }
            .alert("Queue changed", isPresented: $previewQueueChanged) {
                Button("Review queue") {
                    // Defer navigation until the alert binding dismisses.
                    openQueueAfterPreviewAlert = true
                }
                Button("OK", role: .cancel) {
                    openQueueAfterPreviewAlert = false
                }
            } message: {
                Text("That song is no longer upcoming. Review the updated queue to choose what plays next.")
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
            invalidateActiveScrub()
        }
        .onChange(of: playback.duration) { _, duration in
            // Duration can reset during a source transition without an ID change.
            if !duration.isFinite || duration <= 0 {
                invalidateActiveScrub()
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
    @State private var queueChangedAlert = false
    @AccessibilityFocusState private var emptyQueueFocused: Bool

    // Context menus can outlive their row after automatic playback advancement.
    // Explain rejected actions instead of silently ignoring the tap, and give
    // VoiceOver a surviving focus target in the refreshed queue.
    private func reportStaleQueueAction() {
        // An alert temporarily owns accessibility focus. Do not focus a queue
        // row underneath it: VoiceOver may lose the alert or jump unexpectedly.
        // Restore a live target only after the user dismisses the alert.
        pendingQueueFocusID = nil
        pendingEmptyQueueFocus = false
        focusedQueueTrackID = nil
        emptyQueueFocused = false
        queueChangedAlert = true
    }

    // Keep VoiceOver on the nearest surviving queue action after a deletion.
    // The focus target must be applied after the queue has published its new rows.
    private func removeFromQueue(_ trackID: UUID) {
        // Resolve against the live queue rather than a row's captured render.
        // Playback may advance between opening a menu and choosing Remove.
        let current = playback.queuedTracks
        guard let index = current.firstIndex(where: { $0.id == trackID }) else {
            reportStaleQueueAction()
            return
        }
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
        guard let index = current.firstIndex(where: { $0.id == trackID }) else {
            reportStaleQueueAction()
            return
        }
        guard earlier ? index > 0 : index < current.count - 1 else {
            // The menu was created for an older queue ordering. An action
            // that has become impossible must explain the change rather than
            // silently doing nothing or leaving a stale focus request.
            reportStaleQueueAction()
            return
        }
        focusAfterQueueMutation(trackID)
        playback.moveQueuedTrack(trackID, earlier: earlier)
    }

    private func playNext(_ trackID: UUID) {
        // A context menu can stay open after playback advances or a queue edit.
        // Do not issue a mutation or retain a focus request for a vanished row.
        let current = playback.queuedTracks
        guard let index = current.firstIndex(where: { $0.id == trackID }) else {
            reportStaleQueueAction()
            return
        }
        // Already next: no queue publication will follow, so avoid leaving a
        // pending focus request that could hijack a later unrelated queue edit.
        guard index > 0 else {
            // The row may have moved to first while an old context menu
            // remained open. The command is now redundant, but the recording
            // is still present; restore focus to its surviving options.
            pendingQueueFocusID = nil
            pendingEmptyQueueFocus = false
            emptyQueueFocused = false
            focusedQueueTrackID = trackID
            return
        }
        focusAfterQueueMutation(trackID)
        playback.playQueuedTrackNext(trackID)
    }

    private func playNow(_ trackID: UUID) {
        // Resolve from the live queue; a captured MusicTrack may no longer be
        // queued when a menu action is selected after automatic advancement.
        guard let track = playback.queuedTracks.first(where: { $0.id == trackID }) else {
            reportStaleQueueAction()
            return
        }
        pendingQueueFocusID = nil
        pendingEmptyQueueFocus = false
        playback.play(track)
    }

    // The queue is snapshotted once per render. Recomputing queuedTracks and
    // searching for every row's buttons makes long queues quadratic in size.
    // These flags are presentation-only: reorder() still checks the live queue
    // immediately before mutating it, so an old menu cannot move a stale row.
    private func canMove(index: Int, count: Int, earlier: Bool) -> Bool {
        earlier ? index > 0 : index < count - 1
    }

    // Large-text users should not have to open a context menu for every
    // reorder. The same bounded operations back the menu and VoiceOver.
    private func moveButton(_ track: MusicTrack, earlier: Bool, available: Bool) -> some View {
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
        .disabled(!available)
        .accessibilityLabel(available
            ? "\(earlier ? "Move earlier" : "Move later"): \(track.title)"
            : "\(earlier ? "Already first" : "Already last"): \(track.title)")
        .accessibilityHint(available
            ? (earlier
                ? "Move this song one position toward the start of the queue"
                : "Move this song one position toward the end of the queue")
            : "This song cannot move any further in that direction")
    }

    // Use a vertical fallback when enlarged labels cannot fit beside two
    // minimum-size reorder targets. Both layouts invoke identical queue actions.
    @ViewBuilder
    private func queueActions(_ track: MusicTrack, index: Int,
                              upcoming: [MusicTrack], stacked: Bool) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    moveButton(track, earlier: true,
                               available: canMove(index: index, count: upcoming.count, earlier: true))
                    moveButton(track, earlier: false,
                               available: canMove(index: index, count: upcoming.count, earlier: false))
                    Spacer(minLength: 0)
                    Text("Position \(index + 1) of \(upcoming.count)")
                        .font(.caption)
                        .foregroundStyle(ShelfTheme.subdued)
                        .accessibilityHidden(true)
                }
                playNextButton(track, alreadyNext: index == 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 8) {
                moveButton(track, earlier: true,
                           available: canMove(index: index, count: upcoming.count, earlier: true))
                moveButton(track, earlier: false,
                           available: canMove(index: index, count: upcoming.count, earlier: false))
                Spacer(minLength: 0)
                playNextButton(track, alreadyNext: index == 0)
            }
        }
    }

    private func playNextButton(_ track: MusicTrack, alreadyNext: Bool) -> some View {
        Button {
            playNext(track.id)
        } label: {
            Label(alreadyNext ? "Already next" : "Play next",
                      systemImage: alreadyNext ? "checkmark.circle" : "text.line.first.and.arrowtriangle.forward")
                .font(.caption.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(alreadyNext ? ShelfTheme.subdued : ShelfTheme.accent)
        .disabled(alreadyNext)
        .accessibilityLabel(alreadyNext ? "Already next: \(track.title)" : "Play next: \(track.title)")
        .accessibilityHint(alreadyNext ? "This song is already first in the upcoming queue" : "Make this song the next recording to play")
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
                                    .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
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
                                        if index > 0 {
                                            Button {
                                                playNext(track.id)
                                            } label: {
                                                Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                            }
                                        }
                                        if canMove(index: index, count: upcoming.count, earlier: true) {
                                            Button {
                                                reorder(track.id, earlier: true)
                                            } label: {
                                                Label("Move earlier", systemImage: "arrow.up")
                                            }
                                        }
                                        if canMove(index: index, count: upcoming.count, earlier: false) {
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
                                    // The horizontal variant contains a Spacer, so
                                    // ViewThatFits cannot reliably detect cramped text.
                                    // Select the vertical action layout explicitly at
                                    // accessibility sizes to preserve 44-point controls.
                                    if dynamicTypeSize.isAccessibilitySize {
                                        queueActions(track, index: index, upcoming: upcoming,
                                                     stacked: true)
                                    } else {
                                        queueActions(track, index: index, upcoming: upcoming,
                                                     stacked: false)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .premiumCard(radius: 17)
                                .accessibilityElement(children: .contain)
                                .accessibilityValue("Position \(index + 1) of \(upcoming.count) in queue")
                                .accessibilityAction(named: "Play now") {
                                    playNow(track.id)
                                }
                                // Only advertise reorder actions that can actually
                                // succeed. The live reorder handler still validates
                                // bounds if playback changes before activation.
                                .accessibilityActions {
                                    if index > 0 {
                                        Button("Play next") { playNext(track.id) }
                                    }
                                    if canMove(index: index, count: upcoming.count, earlier: true) {
                                        Button("Move earlier") {
                                            reorder(track.id, earlier: true)
                                        }
                                    }
                                    if canMove(index: index, count: upcoming.count, earlier: false) {
                                        Button("Move later") {
                                            reorder(track.id, earlier: false)
                                        }
                                    }
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
            .onChange(of: upcoming.map(\.id)) { previousIDs, currentIDs in
                // A presented alert owns accessibility focus. Playback can
                // advance while it is open; defer all row/empty-state focus
                // recovery until dismissal rather than moving VoiceOver behind
                // the alert.
                guard !queueChangedAlert else {
                    pendingQueueFocusID = nil
                    pendingEmptyQueueFocus = false
                    return
                }
                // Queue changes can also originate outside this sheet (playback
                // advancement, shuffle, or another queue control). Recover only
                // focus that was actually on a row that disappeared; otherwise
                // leave the user's current VoiceOver position untouched.
                let focusedRowWasRemoved = focusedQueueTrackID.map {
                    previousIDs.contains($0) && !currentIDs.contains($0)
                } ?? false
                if pendingEmptyQueueFocus && currentIDs.isEmpty {
                    pendingEmptyQueueFocus = false
                    pendingQueueFocusID = nil
                    focusedQueueTrackID = nil
                    emptyQueueFocused = true
                } else if currentIDs.isEmpty {
                    pendingQueueFocusID = nil
                    pendingEmptyQueueFocus = false
                    if focusedRowWasRemoved {
                        focusedQueueTrackID = nil
                        emptyQueueFocused = true
                    }
                } else if let target = pendingQueueFocusID {
                    pendingQueueFocusID = nil
                    pendingEmptyQueueFocus = false
                    emptyQueueFocused = false
                    // A simultaneous playback transition can consume the
                    // requested target before the queue update is observed.
                    focusedQueueTrackID = currentIDs.contains(target)
                        ? target : currentIDs.first
                } else if focusedRowWasRemoved {
                    // Prefer the same visible position after removal, falling
                    // back to the last surviving row at the end of the queue.
                    let oldIndex = focusedQueueTrackID.flatMap { previousIDs.firstIndex(of: $0) } ?? 0
                    focusedQueueTrackID = currentIDs[min(oldIndex, currentIDs.count - 1)]
                    emptyQueueFocused = false
                }
            }
            .alert("Queue changed", isPresented: $queueChangedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("That song is no longer in the upcoming queue. The list has been updated.")
            }
            .onChange(of: queueChangedAlert) { _, presented in
                guard !presented else { return }
                // Dismissal, not the OK tap, is the point when the alert
                // relinquishes VoiceOver focus. This also covers system-driven
                // dismissal and uses the latest queue after further advancement.
                let surviving = playback.queuedTracks
                pendingQueueFocusID = nil
                pendingEmptyQueueFocus = false
                focusedQueueTrackID = surviving.first?.id
                emptyQueueFocused = surviving.isEmpty
            }
            .navigationTitle("Your queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .foregroundStyle(ShelfTheme.accent)
                        .accessibilityHint("Close the queue and return to Now Playing")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
