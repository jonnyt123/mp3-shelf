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
        // Duration can briefly remain populated after a recording is removed.
        // Never send a transport seek without a current recording identity.
        guard playback.currentTrackID != nil,
              seekableDuration > 0,
              offset.isFinite else { return }
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
        .onDisappear {
            // A dismissed Now Playing sheet may not receive the slider's
            // editing-ended callback. Do not carry an invalidated gesture
            // into a newly presented player sheet.
            clearScrub()
            sliderEditing = false
            invalidatedSliderGesture = false
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
    @State private var searchChangedAlert = false
    @State private var queueSearchText = ""
    @State private var settledQueueSearchText = ""
    @AccessibilityFocusState private var emptyQueueFocused: Bool
    @AccessibilityFocusState private var noMatchesFocused: Bool
    @AccessibilityFocusState private var playbackFailureFocused: Bool
    @State private var retryFeedback: String?
    @State private var lastRetryError: String?
    @State private var retryAttempt = 0
    @State private var retryTrackID: UUID?

    // A retry may complete asynchronously. Do not report success merely
    // because the controller has not published a new error synchronously.
    private func retryPlayback() {
        // A retry belongs to one recording and one visible error.
        guard let trackID = playback.currentTrackID,
              let error = playback.playbackError, !error.isEmpty else { return }
        retryTrackID = trackID
        lastRetryError = error
        retryFeedback = "Retrying recording…"
        retryAttempt += 1
        playback.retryFailedPlayback()
    }

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

    // Reject commands from context menus captured before the search changed.
    // A hidden result must not remain actionable after filtering updates.
    private func actionIsVisible(_ trackID: UUID) -> Bool {
        let query = queueSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queueSearchIsUpdating,
              let track = playback.queuedTracks.first(where: { $0.id == trackID }),
              matchesSearch(track, query: query) else {
            pendingQueueFocusID = nil
            pendingEmptyQueueFocus = false
            focusedQueueTrackID = nil
            searchChangedAlert = true
            return false
        }
        return true
    }

    // Keep VoiceOver on the nearest surviving queue action after a deletion.
    // The focus target must be applied after the queue has published its new rows.
    private func removeFromQueue(_ trackID: UUID) {
        guard actionIsVisible(trackID) else { return }
        // Resolve against the live queue rather than a row's captured render.
        // Playback may advance between opening a menu and choosing Remove.
        let current = playback.queuedTracks
        guard let index = current.firstIndex(where: { $0.id == trackID }) else {
            reportStaleQueueAction()
            return
        }
        let remaining = current.filter { $0.id != trackID }
        let query = queueSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = remaining.filter { matchesSearch($0, query: query) }
        let visibleIndex = current.prefix(index).filter { $0.id != trackID && matchesSearch($0, query: query) }.count
        pendingQueueFocusID = visible.isEmpty ? nil : visible[min(visibleIndex, visible.count - 1)].id
        pendingEmptyQueueFocus = remaining.isEmpty
        // Removing the final search match leaves other queued recordings
        // intact. Focus the no-results explanation rather than a vanished row.
        // The queue publication handler applies this after the mutation.
        noMatchesFocused = false
        playback.removeQueuedTrack(trackID)
    }

    // A queue mutation must leave a usable focus target, even when playback
    // advances at the same moment or a requested move is already at the edge.
    private func focusAfterQueueMutation(_ trackID: UUID) {
        pendingQueueFocusID = trackID
        pendingEmptyQueueFocus = false
    }

    private func reorder(_ trackID: UUID, earlier: Bool) {
        // An already-open menu or delayed accessibility action may fire after
        // search begins. Do not silently move hidden neighbors in that case.
        guard !queueSearchIsUpdating,
              queueSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingQueueFocusID = nil
            pendingEmptyQueueFocus = false
            return
        }
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
        guard actionIsVisible(trackID) else { return }
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
        guard actionIsVisible(trackID) else { return }
        // Resolve from the live queue; a captured MusicTrack may no longer be
        // queued when a menu action is selected after automatic advancement.
        guard let track = playback.queuedTracks.first(where: { $0.id == trackID }) else {
            reportStaleQueueAction()
            return
        }
        pendingQueueFocusID = nil
        pendingEmptyQueueFocus = false
        focusedQueueTrackID = nil
        noMatchesFocused = false
        playback.play(track)
    }

    private var queueSearchIsUpdating: Bool {
        queueSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            != settledQueueSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesSearch(_ track: MusicTrack, query: String) -> Bool {
        query.isEmpty || track.title.localizedStandardContains(query)
            || track.artist.localizedStandardContains(query)
            || track.album.localizedStandardContains(query)
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
    private func moveButton(_ track: MusicTrack, earlier: Bool, available: Bool,
                            searching: Bool) -> some View {
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
        .disabled(!available || searching)
        .accessibilityLabel(searching
            ? "Clear search to reorder: \(track.title)"
            : available ? "\(earlier ? "Move earlier" : "Move later"): \(track.title)"
                        : "\(earlier ? "Already first" : "Already last"): \(track.title)")
        .accessibilityHint(searching
            ? "Reordering is available when all queued songs are visible"
            : available ? (earlier
                ? "Move this song one position toward the start of the queue"
                : "Move this song one position toward the end of the queue")
                        : "This song cannot move any further in that direction")
    }

    // Use a vertical fallback when enlarged labels cannot fit beside two
    // minimum-size reorder targets. Both layouts invoke identical queue actions.
    @ViewBuilder
    private func queueActions(_ track: MusicTrack, index: Int,
                              upcoming: [MusicTrack], stacked: Bool,
                              searching: Bool) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    moveButton(track, earlier: true,
                               available: canMove(index: index, count: upcoming.count, earlier: true),
                               searching: searching)
                    moveButton(track, earlier: false,
                               available: canMove(index: index, count: upcoming.count, earlier: false),
                               searching: searching)
                    Spacer(minLength: 0)
                    Text("Position \(index + 1) of \(upcoming.count)")
                        .font(.caption)
                        .foregroundStyle(ShelfTheme.subdued)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 16) {
                    playNowButton(track)
                    playNextButton(track, alreadyNext: index == 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Keep transport labels on their own row at standard text sizes.
            // Four actions in one HStack can clip on narrow iPhones.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    moveButton(track, earlier: true,
                               available: canMove(index: index, count: upcoming.count, earlier: true),
                               searching: searching)
                    moveButton(track, earlier: false,
                               available: canMove(index: index, count: upcoming.count, earlier: false),
                               searching: searching)
                    Spacer(minLength: 0)
                    Text("Position \(index + 1) of \(upcoming.count)")
                        .font(.caption)
                        .foregroundStyle(ShelfTheme.subdued)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 16) {
                    playNowButton(track)
                    playNextButton(track, alreadyNext: index == 0)
                }
            }
        }
    }

    // Play now is a first-class action in search results as well as the full
    // queue. A user should not have to discover the overflow menu to play a
    // matched recording. playNow() revalidates the live queue before playback.
    private func playNowButton(_ track: MusicTrack) -> some View {
        Button {
            playNow(track.id)
        } label: {
            Label("Play now", systemImage: "play.fill")
                .font(.caption.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShelfTheme.mint)
        .accessibilityLabel("Play now: \(track.title), \(track.artist)")
        .accessibilityHint("Start this recording immediately from the upcoming queue")
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
        // Filter presentation only. Keep the original indices for move and
        // play-next operations so a search never reorders the underlying queue.
        let query = settledQueueSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never expose stale search results while a new query is settling.
        // Filtering once after typing stops avoids repeated full-queue scans.
        let visibleRows = queueSearchIsUpdating ? [] : Array(upcoming.enumerated()).filter { _, track in
            matchesSearch(track, query: query)
        }
        let visibleIDs = visibleRows.map { $0.element.id }
        return NavigationStack {
            ZStack {
                PremiumBackdrop()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        // A failed Play now request can leave the queue sheet open.
                        // Surface the existing playback failure and recovery command
                        // here, without requiring dismissal or changing saved audio.
                        if let failure = playback.playbackError ?? (retryTrackID == playback.currentTrackID ? "Waiting for playback to resume." : nil), !failure.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(playback.playbackError == nil ? "Playback recovery" : "Unable to play recording", systemImage: playback.playbackError == nil ? "clock.arrow.circlepath" : "exclamationmark.triangle.fill")
                                    .font(.headline)
                                    .foregroundStyle(ShelfTheme.coral)
                                Text(failure)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let retryFeedback {
                                    Text(retryFeedback)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(ShelfTheme.coral)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityAddTraits(.updatesFrequently)
                                }
                                // Stack at accessibility sizes so neither action
                                // truncates or drops below the minimum tap height.
                                let actionLayout = dynamicTypeSize.isAccessibilitySize
                                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                    : AnyLayout(HStackLayout(spacing: 12))
                                actionLayout {
                                    Button("Retry playback") {
                                        retryPlayback()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(ShelfTheme.accent)
                                    .frame(minHeight: 44)
                                    // Prevent repeated taps from starting overlapping attempts.
                                    // The retry becomes available again after a resolved outcome.
                                    .disabled(playback.playbackError == nil ||
                                              (retryTrackID == playback.currentTrackID &&
                                               retryFeedback == "Retrying recording…"))
                                    .accessibilityHint(retryFeedback == "Retrying recording…"
                                        ? "Waiting for the current retry to finish"
                                        : "Try playing this recording again")
                                    Button("Dismiss warning") {
                                        // Cancel the pending status check before dismissal.
                                        retryAttempt += 1
                                        retryTrackID = nil
                                        retryFeedback = nil
                                        lastRetryError = nil
                                        playback.playbackError = nil
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(minHeight: 44)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(16)
                            .premiumCard(radius: 18)
                            .accessibilityElement(children: .contain)
                            .accessibilityFocused($playbackFailureFocused)
                        }
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
                        } else if queueSearchIsUpdating {
                            ProgressView("Searching queue…")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 24)
                                .accessibilityLabel("Updating queue search results")
                        } else if visibleRows.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.largeTitle)
                                    .foregroundStyle(ShelfTheme.accent)
                                    .accessibilityHidden(true)
                                Text("No matching songs")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("Try a different title, artist, or album. Your playing queue is unchanged.")
                                    .font(.subheadline)
                                    .foregroundStyle(ShelfTheme.subdued)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(22)
                            .premiumCard()
                            .accessibilityElement(children: .combine)
                            .accessibilityFocused($noMatchesFocused)
                            Button("Clear search") { queueSearchText = "" }
                                .frame(minHeight: 44)
                                .foregroundStyle(ShelfTheme.accent)
                                .accessibilityHint("Show all queued songs without changing their order")
                        } else {
                            if !query.isEmpty {
                                HStack(alignment: .center, spacing: 12) {
                                    Text("Showing \(visibleRows.count) of \(upcoming.count) queued songs. Clear search to reorder the full queue.")
                                        .font(.caption)
                                        .foregroundStyle(ShelfTheme.subdued)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Button("Clear search") { queueSearchText = "" }
                                        .font(.subheadline.weight(.semibold))
                                        .frame(minHeight: 44)
                                        .foregroundStyle(ShelfTheme.accent)
                                        .accessibilityHint("Show the complete queue and enable reordering")
                                }
                                .accessibilityElement(children: .contain)
                            }
                            ForEach(visibleRows, id: \.element.id) { index, track in
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
                                        if query.isEmpty && canMove(index: index, count: upcoming.count, earlier: true) {
                                            Button {
                                                reorder(track.id, earlier: true)
                                            } label: {
                                                Label("Move earlier", systemImage: "arrow.up")
                                            }
                                        }
                                        if query.isEmpty && canMove(index: index, count: upcoming.count, earlier: false) {
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
                                    .accessibilityHint(query.isEmpty
                                        ? "Play, reorder, or remove this song from the upcoming queue"
                                        : "Play or remove this song. Clear search to reorder the full queue")
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
                                                     stacked: true, searching: !query.isEmpty)
                                    } else {
                                        queueActions(track, index: index, upcoming: upcoming,
                                                     stacked: false, searching: !query.isEmpty)
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
                                    if query.isEmpty && canMove(index: index, count: upcoming.count, earlier: true) {
                                        Button("Move earlier") {
                                            reorder(track.id, earlier: true)
                                        }
                                    }
                                    if query.isEmpty && canMove(index: index, count: upcoming.count, earlier: false) {
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
                guard !queueChangedAlert && !searchChangedAlert else {
                    pendingQueueFocusID = nil
                    pendingEmptyQueueFocus = false
                    return
                }
                // Search results are intentionally hidden during debounce.
                // Do not treat that temporary absence as an emptied queue or
                // move VoiceOver to a no-results state that is not rendered.
                if queueSearchIsUpdating {
                    pendingQueueFocusID = nil
                    pendingEmptyQueueFocus = false
                    focusedQueueTrackID = nil
                    noMatchesFocused = false
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
                    focusedQueueTrackID = visibleIDs.contains(target)
                        ? target : visibleIDs.first
                    noMatchesFocused = !currentIDs.isEmpty && visibleIDs.isEmpty
                } else if !currentIDs.isEmpty && visibleIDs.isEmpty &&
                            (focusedRowWasRemoved || focusedQueueTrackID != nil) {
                    // The final matching result can disappear without emptying
                    // the actual queue. Keep the search active and move focus
                    // to its explicit no-results state.
                    pendingQueueFocusID = nil
                    pendingEmptyQueueFocus = false
                    focusedQueueTrackID = nil
                    emptyQueueFocused = false
                    noMatchesFocused = true
                } else if focusedRowWasRemoved {
                    // Prefer the same visible position after removal, falling
                    // back to the last surviving row at the end of the queue.
                    let oldIndex = focusedQueueTrackID.flatMap { previousIDs.firstIndex(of: $0) } ?? 0
                    let visibleBefore = previousIDs.prefix(oldIndex).filter { visibleIDs.contains($0) }.count
                    focusedQueueTrackID = visibleIDs.isEmpty ? nil : visibleIDs[min(visibleBefore, visibleIDs.count - 1)]
                    noMatchesFocused = visibleIDs.isEmpty
                    emptyQueueFocused = false
                }
            }
            .alert("Search changed", isPresented: $searchChangedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The queue search changed before the action completed. Review the current results and try again.")
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
                let query = queueSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                focusedQueueTrackID = queueSearchIsUpdating ? nil : surviving.first(where: { matchesSearch($0, query: query) })?.id
                emptyQueueFocused = surviving.isEmpty
                noMatchesFocused = !queueSearchIsUpdating && !surviving.isEmpty && focusedQueueTrackID == nil
            }
            .task(id: retryAttempt) {
                guard retryAttempt > 0, retryTrackID != nil else { return }
                // Give an asynchronous playback attempt time to publish its
                // outcome. A repeat of the same error string does not fire
                // onChange, so a bounded check is necessary.
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                guard !Task.isCancelled, retryTrackID == playback.currentTrackID,
                      retryTrackID != nil else { return }
                // The playback controller may clear its error before audio
                // actually begins. A cleared error alone is not success.
                if playback.isPlaying && playback.playbackError == nil {
                    retryAttempt += 1
                    retryFeedback = nil
                    lastRetryError = nil
                    retryTrackID = nil
                } else if let error = playback.playbackError, !error.isEmpty {
                    retryFeedback = error == lastRetryError
                        ? "Still unable to play. Choose another queued song or try again."
                        : "Retry failed. \(error)"
                } else {
                    // No error and no playback: still pending, not a failure.
                    // Let the user retry or choose another recording.
                    retryFeedback = "Playback has not resumed yet. You can try again or choose another song."
                }
            }
            .onChange(of: playback.isPlaying) { _, playing in
                if playing && playback.playbackError == nil && retryTrackID == playback.currentTrackID {
                    retryAttempt += 1
                    retryFeedback = nil
                    lastRetryError = nil
                    retryTrackID = nil
                }
            }
            .onChange(of: playback.currentTrackID) { _, newID in
                // Never show the previous recording's retry outcome after a skip.
                if retryTrackID != nil && retryTrackID != newID {
                    retryAttempt += 1
                    retryTrackID = nil
                    retryFeedback = nil
                    lastRetryError = nil
                }
            }
            .onChange(of: playback.playbackError) { _, error in
                // A failed direct-play action must be discoverable to VoiceOver
                // even when focus was previously on the selected queue row.
                if let error, !error.isEmpty {
                    // During a retry, retain the pending message until the
                    // bounded check classifies an identical or changed error.
                    if retryTrackID == nil && error != lastRetryError {
                        retryFeedback = nil
                    }
                    focusedQueueTrackID = nil
                    playbackFailureFocused = true
                } else {
                    // A cleared error is not necessarily audible playback.
                    // Keep retry state until playback starts, the user
                    // dismisses it, or the bounded status check completes.
                    if retryTrackID == nil || playback.isPlaying {
                        if retryTrackID != nil { retryAttempt += 1 }
                        retryTrackID = nil
                        retryFeedback = nil
                        lastRetryError = nil
                    }
                    playbackFailureFocused = false
                }
            }
            .onChange(of: queueSearchText) { _, newSearch in
                // A changed filter can hide the focused options button without
                // changing the underlying queue IDs. Clear stale row focus and
                // pending mutation targets; do not steal keyboard focus while
                // the user is typing a query.
                pendingQueueFocusID = nil
                pendingEmptyQueueFocus = false
                let query = newSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                if let focused = focusedQueueTrackID,
                   !playback.queuedTracks.contains(where: {
                       $0.id == focused && matchesSearch($0, query: query)
                   }) {
                    focusedQueueTrackID = nil
                }
                noMatchesFocused = false
                emptyQueueFocused = false
            }
            .task(id: queueSearchText) {
                let requested = queueSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !requested.isEmpty {
                    do { try await Task.sleep(for: .milliseconds(220)) }
                    catch { return }
                }
                guard !Task.isCancelled,
                      queueSearchText.trimmingCharacters(in: .whitespacesAndNewlines) == requested else { return }
                settledQueueSearchText = queueSearchText
            }
            .searchable(text: $queueSearchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search queued songs")
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
