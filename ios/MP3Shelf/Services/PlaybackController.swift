import AVFoundation
import MediaPlayer
import UIKit
import Foundation
import Combine

private final class AudioCompletionRelay: NSObject, AVAudioPlayerDelegate {
    // Capture the playback generation synchronously with the delegate event.
    // A callback queued before pause/resume must not advance the resumed player.
    private let generationLock = NSLock()
    private var generation: UInt64 = 0
    var finished: ((AVAudioPlayer, Bool, UInt64) -> Void)?

    func invalidatePendingCompletions() {
        generationLock.lock()
        generation &+= 1
        generationLock.unlock()
    }

    func completionGeneration() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finished?(player, flag, completionGeneration())
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finished?(player, false, completionGeneration())
    }
}

@MainActor
final class PlaybackController: NSObject, ObservableObject {
    @Published private(set) var currentTrackID: UUID?
    @Published var playbackError: String?
    private var failedTrackID: UUID?
    private var failedPlaybackOrder: PlaybackOrder?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var isShuffled = false {
        didSet {
            playbackOrder.setShuffle(isShuffled)
            // A shuffle change can select a different successor. A failed
            // crossfade attempt against the old queue must not block it.
            attemptedCrossfadePlayer = nil
        }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet {
            // Repeat-all can expose a successor that was not eligible under
            // repeat-off; permit a fresh attempt without seeking the song.
            attemptedCrossfadePlayer = nil
        }
    }
    @Published var crossfadeSeconds: Double = UserDefaults.standard.double(forKey: "mp3shelf.crossfadeSeconds") {
        didSet {
            UserDefaults.standard.set(crossfadeSeconds, forKey: "mp3shelf.crossfadeSeconds")
            // A user-adjusted transition window is a new explicit attempt.
            attemptedCrossfadePlayer = nil
        }
    }

    private weak var library: MusicLibrary?
    private var audioPlayer: AVAudioPlayer?
    // AVAudioPlayer can keep decoding stale bytes after either an atomic
    // replacement (new inode) or an in-place overwrite (same inode).
    private var openedAudioFileIdentity: LocalAudioFileIdentity?

    private struct LocalAudioFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init?(url: URL) {
            // Inspect the directory entry itself. Foundation file attributes
            // can follow a symlink installed after ownedPlaybackURL validation.
            // POSIX change time also catches same-size rewrites whose mtime was
            // restored, without hashing a potentially large recording on each
            // 200 ms playback clock tick.
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_size > 0 else { return nil }
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
            byteCount = UInt64(info.st_size)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }
    private var positionTimer: Timer?
    private var fadeTimer: Timer?
    private var outgoingPlayer: AVAudioPlayer?
    // A damaged successor must not be reopened on every 200 ms clock tick.
    // Retry crossfade only after the user changes the queue or playback position.
    private weak var attemptedCrossfadePlayer: AVAudioPlayer?
    @Published private var playbackOrder = PlaybackOrder()

    #if DEBUG
    /// Read the real local player's clock without depending on UI timer cadence.
    func localFilePlaybackProof() -> (url: URL?, currentTime: TimeInterval, isPlaying: Bool) {
        (audioPlayer?.url, audioPlayer?.currentTime ?? 0, audioPlayer?.isPlaying ?? false)
    }
    #endif

    private var loopMode: PlaybackLoopMode {
        switch repeatMode {
        case .off: return .off
        case .all: return .all
        case .one: return .one
        }
    }

    /// Read-only queue preview for the native Now Playing screen.
    /// Uses the active playback order and never mutates the playlist.
    var upcomingTracks: [MusicTrack] {
        guard let library else { return [] }
        return playbackOrder.upcomingIDs(limit: 3, loop: loopMode)
            .compactMap { library.song(with: $0) }
    }

    /// Bounded, distinct current-cycle queue for a responsive edit sheet.
    /// This is playback-only state and never rewrites a saved playlist.
    var queuedTracks: [MusicTrack] {
        guard let library else { return [] }
        return playbackOrder.editableUpcomingIDs()
            .compactMap { library.song(with: $0) }
    }

    func moveQueuedTrack(_ id: UUID, earlier: Bool) {
        _ = playbackOrder.moveUpcoming(id, earlier: earlier)
        attemptedCrossfadePlayer = nil
    }

    func playQueuedTrackNext(_ id: UUID) {
        _ = playbackOrder.playNext(id)
        attemptedCrossfadePlayer = nil
    }

    func removeQueuedTrack(_ id: UUID) {
        _ = playbackOrder.removeUpcoming(id)
        attemptedCrossfadePlayer = nil
    }

    private let relay = AudioCompletionRelay()
    private var remoteControlsConfigured = false
    private var interruptionState = PlaybackInterruptionState()
    private var audioSessionObservers: [NSObjectProtocol] = []

    deinit {
        for observer in audioSessionObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func connect(to library: MusicLibrary) {
        self.library = library
        guard !remoteControlsConfigured else { return }
        remoteControlsConfigured = true
        relay.finished = { [weak self] player, succeeded, generation in
            Task { @MainActor [weak player] in
                guard let self, let player, self.audioPlayer === player,
                      self.relay.completionGeneration() == generation else { return }
                // Delegate completion can be queued before a user pause or an
                // audio-session interruption. Never start the next recording
                // or overwrite a deliberately paused player's retry state.
                guard self.isPlaying else { return }
                if succeeded { self.advance(automatically: true) }
                else {
                    // A decode failure can arrive while an outgoing player is
                    // still audible during a crossfade. Stop both players and
                    // polling before exposing the retry state; otherwise the
                    // library reports stopped playback while audio continues.
                    self.positionTimer?.invalidate()
                    self.positionTimer = nil
                    self.cancelFade()
                    player.stop()
                    self.isPlaying = false
                    self.interruptionState.cancelResume()
                    self.playbackError = "Audio playback stopped unexpectedly. Choose another song or try playing again."
                    self.failedTrackID = self.currentTrackID
                    self.failedPlaybackOrder = self.playbackOrder
                    self.updateNowPlaying()
                }
            }
        }
        configureRemoteControls()
        observeAudioSession()
    }

    private func activateAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    func play(_ track: MusicTrack, queue songs: [MusicTrack]? = nil, transition: TimeInterval = 0) {
        guard let library else { return }
        // A delayed Now Playing or playlist action may retain a MusicTrack
        // value after library reconciliation deleted its catalog entry.
        // Do not open an orphaned recording or reset a healthy playback queue.
        guard let catalogTrack = library.song(with: track.id) else {
            // A stale Now Playing selection must not leave a deleted current
            // recording audible behind the error. Recover only when the
            // selected decoder itself has lost catalog ownership.
            _ = recoverDeletedCurrentTrack()
            playbackError = "This song is no longer in your library. Choose another song."
            updateNowPlaying()
            return
        }
        var nextOrder = playbackOrder
        if let songs {
            // UI snapshots may contain tracks removed by a concurrent import
            // or library repair. Queue only identities still owned by the
            // current catalog, while keeping the requested selection present.
            let available = Set(library.tracks.map(\.id))
            nextOrder.reset(queue: songs.map(\.id).filter { available.contains($0) },
                            current: catalogTrack.id, shuffled: isShuffled)
        } else if nextOrder.queueIDs.isEmpty || !nextOrder.queueIDs.contains(track.id) {
            nextOrder.reset(queue: library.tracks.map(\.id), current: track.id, shuffled: isShuffled)
        } else {
            nextOrder.retainAvailable(Set(library.tracks.map(\.id)))
            nextOrder.select(track.id)
        }
        // The caller's MusicTrack may predate a restored filename or metadata
        // repair. Always open the current catalog value, never stale file paths.
        beginPlayback(catalogTrack, using: nextOrder, transition: transition)
    }

    /// Playback order commits only after AVAudioPlayer successfully starts.
    /// A corrupted or missing file cannot consume shuffle history.
    private func beginPlayback(_ track: MusicTrack, using nextOrder: PlaybackOrder,
                               transition: TimeInterval = 0,
                               preserveExistingOnFailure: Bool = true,
                               startPaused: Bool = false) -> Bool {
        guard let library else { return false }
        // Every entry point (manual selection, queue advance, retry, crossfade)
        // must obey the same catalog ownership check. An open audio file can
        // survive deletion, but a new player must not resurrect that entry.
        guard let catalogTrack = library.song(with: track.id) else {
            playbackError = "This song is no longer in your library. Choose another song."
            return false
        }
        do {
            // A persisted catalog is not a trusted filesystem path. Reject
            // traversal, symlinks, directories and missing recordings before
            // activating the audio session or changing the current decoder.
            // Failed selections preserve the previous audible/paused player.
            guard let ownedAudioURL = library.ownedPlaybackURL(for: catalogTrack) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            // Selecting another recording while paused must not activate the
            // audio session or interrupt another app. Decoder preparation does
            // not require an active session; explicit Play/Resume activates it.
            // Keep activation before every audible transition, including
            // crossfades and automatic queue advancement.
            // Re-resolve at the shared open boundary as well: queued playback,
            // retries and crossfade can all carry older MusicTrack snapshots.
            // Validate the decoder before taking the system audio session.
            // A corrupt/missing queued recording must not interrupt another
            // app's audio when playback will never begin.
            let identityBeforeOpen = LocalAudioFileIdentity(url: ownedAudioURL)
            let player = try AVAudioPlayer(contentsOf: ownedAudioURL)
            let identityAfterOpen = LocalAudioFileIdentity(url: ownedAudioURL)
            // A replacement between path validation and decoder creation must
            // not be accepted as the selected catalog-owned recording.
            guard identityBeforeOpen != nil, identityBeforeOpen == identityAfterOpen,
                  library.ownedPlaybackURL(for: catalogTrack) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            player.delegate = relay
            guard player.prepareToPlay(), player.duration.isFinite, player.duration > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Decoder preparation may read the file while an importer or another
            // process overwrites it. Never commit a decoder for changed bytes.
            guard LocalAudioFileIdentity(url: ownedAudioURL) == identityAfterOpen,
                  library.ownedPlaybackURL(for: catalogTrack) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Paused selection only prepares a decoder. Audible playback,
            // including retries, crossfades and automatic transitions, still
            // activates the session immediately before starting the player.
            if !startPaused {
                try activateAudio()
            }
            // Audio-session activation can yield to other work; reject any
            // recording changed since decoder preparation before audible play.
            guard LocalAudioFileIdentity(url: ownedAudioURL) == identityAfterOpen,
                  library.ownedPlaybackURL(for: catalogTrack) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // The outgoing decoder must still represent the catalog-owned bytes
            // before it is allowed to overlap the incoming recording. A file
            // replaced during decoder preparation could otherwise remain audible
            // until the first fade timer tick, even when the incoming file is valid.
            let outgoingIsOwned: Bool = {
                guard let currentTrackID, let openedAudioFileIdentity,
                      let outgoingSong = library.song(with: currentTrackID),
                      let outgoingURL = library.ownedPlaybackURL(for: outgoingSong) else {
                    return false
                }
                return LocalAudioFileIdentity(url: outgoingURL) == openedAudioFileIdentity
            }()
            // A newly prepared recording must never overlap a decoder whose
            // catalog entry disappeared or whose backing file was replaced.
            // Previously the immediate-transition branch called player.play()
            // before stopping that decoder, briefly exposing stale audio.
            // Retire it before any incoming audible start, even when the new
            // decoder subsequently fails to play. The existing queue remains
            // available for retry and no recording bytes are touched.
            if audioPlayer != nil && !outgoingIsOwned {
                relay.invalidatePendingCompletions()
                positionTimer?.invalidate()
                positionTimer = nil
                cancelFade()
                audioPlayer?.stop()
                audioPlayer = nil
                openedAudioFileIdentity = nil
                isPlaying = false
                interruptionState.cancelResume()
            }
            if !startPaused, transition > 0, outgoingIsOwned,
               let previous = audioPlayer, previous.isPlaying {
                player.volume = 0
                guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
                // The previous decoder remains audible during the fade. Keep its
                // original file identity so replacing that file cannot leave an
                // orphaned recording playing behind the newly selected track.
                let outgoingIdentity = openedAudioFileIdentity
                let outgoingTrackID = currentTrackID
                cancelFade()
                outgoingPlayer = previous
                previous.delegate = nil
                audioPlayer = player
                startFade(duration: transition, from: previous, to: player,
                          outgoingTrackID: outgoingTrackID, outgoingIdentity: outgoingIdentity)
            } else {
                player.volume = 1
                if !startPaused {
                    guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
                }
                cancelFade()
                audioPlayer?.stop()
                audioPlayer = player
            }
            openedAudioFileIdentity = identityAfterOpen
            relay.invalidatePendingCompletions()
            playbackError = nil
            failedTrackID = nil
            failedPlaybackOrder = nil
            interruptionState.cancelResume()
            playbackOrder = nextOrder
            attemptedCrossfadePlayer = nil
            currentTrackID = track.id
            duration = player.duration
            currentTime = 0
            isPlaying = !startPaused
            if startPaused {
                positionTimer?.invalidate()
                positionTimer = nil
            } else {
                startTimer()
            }
            updateNowPlaying()
            return true
        } catch {
            // Keep an already-playing recording audible when a manually selected
            // replacement cannot open. If automatic advance failed after the
            // outgoing recording finished, however, no audio remains: retire
            // polling and any overlapping fade rather than leaving an idle
            // 200 ms timer alive indefinitely.
            // A failed manual selection must not destroy a paused recording:
            // the listener may resume it after dismissing the error. Automatic
            // advancement has no such fallback because its predecessor ended.
            // A replacement may fail after the previous recording was removed,
            // overwritten or replaced in place. Never preserve that stale
            // decoder as a fallback merely because it still reports isPlaying.
            // Retirement preserves queue identity and never deletes audio bytes.
            let retiredUnsafePredecessor = retireUnsafeCurrentDecoder()
            let previousIsAudible = !retiredUnsafePredecessor && audioPlayer?.isPlaying == true
            if !preserveExistingOnFailure || audioPlayer == nil {
                positionTimer?.invalidate()
                positionTimer = nil
                cancelFade()
                audioPlayer?.stop()
                if !preserveExistingOnFailure { audioPlayer = nil }
            }
            failedTrackID = track.id
            failedPlaybackOrder = nextOrder
            playbackError = "Could not play \(track.title). Check that its audio file is still available, then retry or choose another song."
            isPlaying = preserveExistingOnFailure && previousIsAudible
            if !preserveExistingOnFailure { interruptionState.cancelResume() }
            updateNowPlaying()
            return false
        }
    }

    /// Explicit retry starts audio; a seek-only decoder repair must not turn
    /// a paused selection into audible playback. Both paths reopen the same
    /// catalog-owned recording without discarding its saved queue position.
    func retryFailedPlayback(startPaused: Bool = false) {
        guard let library, let failedTrackID,
              let track = library.song(with: failedTrackID) else {
            playbackError = "This song is no longer in your library. Choose another song."
            return
        }
        var order = failedPlaybackOrder ?? playbackOrder
        order.retainAvailable(Set(library.tracks.map(\.id)))
        order.setShuffle(isShuffled)
        if !order.queueIDs.contains(track.id) {
            // Legacy/empty retry state: rebuild only from currently owned IDs.
            order.reset(queue: library.tracks.map(\.id),
                        current: track.id, shuffled: isShuffled)
        } else {
            order.select(track.id)
        }
        _ = beginPlayback(track, using: order, startPaused: startPaused)
    }

    func togglePlayback() { isPlaying ? pause() : resume() }

    func pause() {
        // A deleted recording can remain audible through its open decoder.
        // A Pause command must retire it, not leave an orphaned player ready
        // to resume after the library has removed its catalog identity.
        // Preserve the listener's pause intent while selecting a surviving
        // queued recording; never delete or rewrite audio bytes here.
        if recoverDeletedCurrentTrack(forcePause: true) { return }
        // Pause is also a transport boundary: an open decoder may still point
        // at a replaced recording even though the catalog path looks valid.
        // Retire it now, rather than leaving stale bytes allocated until a
        // later Resume/Seek. Preserve the selected ID and queue for reimport.
        if retireUnsafeCurrentDecoder() { return }
        relay.invalidatePendingCompletions()
        interruptionState.cancelResume()
        if outgoingPlayer != nil { cancelFade(); audioPlayer?.volume = 1 }
        audioPlayer?.pause()
        isPlaying = false
        // A paused player needs no 200 ms polling. Keeping the timer alive
        // wastes wakeups while the app is backgrounded or the phone is locked.
        positionTimer?.invalidate()
        positionTimer = nil
        currentTime = audioPlayer?.currentTime ?? currentTime
        updateNowPlaying()
    }

    /// Retire an open decoder whose selected track has been removed from the
    /// catalog. AVAudioPlayer may keep playing an unlinked file descriptor.
    /// The queue is advanced only after retiring the orphan, so lock-screen
    /// state and the playback clock cannot continue advertising deleted audio.
    /// Returns true when the caller must stop using its previous player.
    @discardableResult
    private func recoverDeletedCurrentTrack(allowAutoplay: Bool = false,
                                            forcePause: Bool = false) -> Bool {
        guard let currentTrackID, let library,
              library.song(with: currentTrackID) == nil else { return false }
        // Library deletion can be discovered from a paused seek or a lock-screen
        // transport command. Recover the queue without unexpectedly starting
        // audio when the listener deliberately paused playback.
        let shouldRemainPaused = forcePause || (!isPlaying && !allowAutoplay)
        relay.invalidatePendingCompletions()
        positionTimer?.invalidate()
        positionTimer = nil
        cancelFade()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        failedTrackID = nil
        failedPlaybackOrder = nil
        interruptionState.cancelResume()
        advance(automatically: true, startPaused: shouldRemainPaused)
        return true
    }

    /// Recheck file ownership before transport operations use a retained decoder.
    /// A paused AVAudioPlayer can keep an unlinked or symlink-replaced file open;
    /// neither Resume nor Seek may reuse it after library validation fails.
    /// Keep queue and track IDs for an explicit repair/reimport retry.
    @discardableResult
    private func retireUnsafeCurrentDecoder() -> Bool {
        guard let player = audioPlayer, let currentTrackID, let library,
              let selected = library.song(with: currentTrackID) else { return false }
        let ownedURL = library.ownedPlaybackURL(for: selected)
        let identityChanged = openedAudioFileIdentity != nil &&
            ownedURL.flatMap { LocalAudioFileIdentity(url: $0) } != openedAudioFileIdentity
        guard ownedURL == nil || identityChanged else { return false }
        relay.invalidatePendingCompletions()
        positionTimer?.invalidate()
        positionTimer = nil
        cancelFade()
        player.stop()
        audioPlayer = nil
        openedAudioFileIdentity = nil
        isPlaying = false
        interruptionState.cancelResume()
        failedTrackID = currentTrackID
        failedPlaybackOrder = playbackOrder
        playbackError = "This recording is unavailable or unsafe. Reimport it, then retry playback."
        updateNowPlaying()
        return true
    }

    func resume() {
        relay.invalidatePendingCompletions()
        interruptionState.cancelResume()
        // Automatic advancement retires the finished player when the next
        // recording cannot be opened. Lock-screen Play must retry that failed
        // selection rather than silently succeeding with no audio player.
        // A deleted selection can have no decoder after failed advancement.
        // Reconcile it before the nil-player retry branch so lock-screen Play
        // cannot repeatedly retry an ID absent from the current catalog.
        if recoverDeletedCurrentTrack(allowAutoplay: true) { return }
        guard let audioPlayer else {
            if failedTrackID != nil { retryFailedPlayback() }
            return
        }
        // An AVAudioPlayer can retain an open descriptor after its cataloged
        // recording disappears or is replaced by an unsafe filesystem entry.
        // Resume must not play that orphan merely because the track ID still
        // exists. Retire the decoder and keep the selection/retry identity;
        // a later reimport can then be reopened through the owned-file check.
        if retireUnsafeCurrentDecoder() { return }
        // A decode-error delegate leaves the old AVAudioPlayer allocated but
        // unusable. Reopen the recording on retry so a repaired/reimported file
        // is actually read. A failed manual selection is different: its ID is
        // not the current track, and Resume must preserve the paused source.
        if !isPlaying, failedTrackID == currentTrackID, failedTrackID != nil {
            retryFailedPlayback()
            return
        }
        do {
            try activateAudio()
            // Audio-session activation can yield while a background import or
            // filesystem provider replaces the selected file. Recheck both
            // catalog ownership and the exact decoder-backed file identity
            // immediately before audible Resume; the earlier transport check
            // alone cannot close this race.
            if retireUnsafeCurrentDecoder() { return }
            guard audioPlayer.play() else { throw CocoaError(.fileReadCorruptFile) }
            isPlaying = true
            playbackError = nil
            failedTrackID = nil
            failedPlaybackOrder = nil
            startTimer()
            updateNowPlaying()
        } catch {
            isPlaying = audioPlayer.isPlaying
            failedTrackID = currentTrackID
            failedPlaybackOrder = playbackOrder
            playbackError = "Could not resume this song. Retry playback or choose another song."
            updateNowPlaying()
        }
    }

    func stop() {
        relay.invalidatePendingCompletions()
        playbackError = nil
        failedTrackID = nil
        failedPlaybackOrder = nil
        interruptionState.cancelResume()
        audioPlayer?.stop()
        audioPlayer = nil
        openedAudioFileIdentity = nil
        cancelFade()
        positionTimer?.invalidate()
        positionTimer = nil
        currentTrackID = nil
        attemptedCrossfadePlayer = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        playbackOrder = PlaybackOrder()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        // A queued track can be removed while its AVAudioPlayer still owns an
        // open descriptor. Scrubbing must not revive or continue publishing
        // progress for that orphaned recording. Reconcile through the same
        // bounded queue recovery used by lock-screen Resume; do not seek the
        // stale player or mutate a user-owned audio file.
        if recoverDeletedCurrentTrack() { return }
        // A scrub must not seek an open descriptor whose catalog path became
        // unsafe while paused or playing. Preserve the queue for reimport.
        if retireUnsafeCurrentDecoder() { return }
        // A decode failure can leave an AVAudioPlayer allocated but unable to
        // decode any more frames. Seeking its clock would appear successful
        // while the listener still hears silence. Reopen the catalog-owned
        // recording first; never seek a retired decoder or a missing file.
        // retryFailedPlayback clears failedTrackID only after a real play()
        // succeeds, so a failed reopen leaves the retry identity intact.
        if failedTrackID != nil, failedTrackID == currentTrackID {
            // Scrubbing is not a Play command. Reopen a repaired decoder in
            // the paused state, then apply the requested position atomically.
            // The explicit Retry/Play actions still start playback normally.
            retryFailedPlayback(startPaused: !isPlaying)
            guard failedTrackID == nil, audioPlayer != nil else { return }
        }
        guard let audioPlayer else { return }
        // AVAudioPlayer can enqueue a completion before a seek, particularly
        // when scrubbing backwards at the end of a recording. That completion
        // belongs to the old playback position, not the newly sought position.
        // Invalidate it before changing the player's clock so it cannot
        // advance the queue or report a spurious decode failure after scrubbing.
        relay.invalidatePendingCompletions()
        attemptedCrossfadePlayer = nil
        cancelFade()
        audioPlayer.volume = 1
        let position = max(0, min(seconds, audioPlayer.duration))
        audioPlayer.currentTime = position
        currentTime = position
        updateNowPlaying()
    }

    func next() {
        // Manual Next at the end of a finite queue is otherwise a no-op.
        // Never leave an orphaned decoder audible after catalog deletion.
        if recoverDeletedCurrentTrack() { return }
        // Retire an unsafe open decoder even when there is no next track.
        // Capture playback intent before retirement so a valid successor
        // remains audible after Next, while a paused queue stays paused.
        let wasPlaying = isPlaying
        _ = retireUnsafeCurrentDecoder()
        advance(automatically: false, startPaused: !wasPlaying)
    }

    func previous() {
        // Previous can resolve to no candidate after catalog deletion.
        // Never seek or preserve a decoder whose selected ID is unowned.
        if recoverDeletedCurrentTrack() { return }
        // Previous must not restart an unlinked decoder when the queue has
        // no earlier entry. Keep the original pause/play intent for a safely
        // reopened predecessor, and retire the stale decoder first.
        let wasPlaying = isPlaying
        _ = retireUnsafeCurrentDecoder()
        guard let library else { return }
        // An open player is not evidence that its recording still belongs to
        // the library. Never restart an orphaned track when pressing Previous
        // after a deletion; resolve the surviving queue first.
        if currentTime > 3, audioPlayer != nil, let currentTrackID,
           library.song(with: currentTrackID) != nil,
           failedTrackID != currentTrackID {
            // A decode failure leaves an allocated but unusable AVAudioPlayer.
            // Seeking that retired player reports success without reopening
            // repaired audio. Only a healthy paused/playing player can seek.
            seek(to: 0)
            return
        }
        var nextOrder = playbackOrder
        nextOrder.retainAvailable(Set(library.tracks.map(\.id)))
        // A stale queue entry or a damaged local recording must not strand
        // Previous. Probe at most one cycle, committing order only when audio
        // starts; a failed candidate cannot consume shuffle history or stop
        // the currently audible recording.
        // Failed candidates must not replace the retry identity or error of
        // an already audible recording. Preserve the original state until a
        // candidate actually starts; successful beginPlayback clears it.
        let originalError = playbackError
        let originalFailedTrackID = failedTrackID
        let originalFailedOrder = failedPlaybackOrder
        // Previous is speculative for both audible and paused playback. A
        // failed candidate must not replace the retry target of a paused song
        // or erase a pre-existing error. The selected track and player remain
        // unchanged until beginPlayback succeeds.
        let originalPlayer = audioPlayer
        let originalTrackID = currentTrackID
        let originalIsPlaying = wasPlaying
        func restoreSelectionState() {
            guard audioPlayer === originalPlayer,
                  currentTrackID == originalTrackID else { return }
            playbackError = originalError
            failedTrackID = originalFailedTrackID
            failedPlaybackOrder = originalFailedOrder
            isPlaying = originalIsPlaying && audioPlayer?.isPlaying == true
            updateNowPlaying()
        }
        var attempted: Set<UUID> = []
        while attempted.count < nextOrder.queueIDs.count {
            guard let id = nextOrder.previous(loop: loopMode),
                  attempted.insert(id).inserted else {
                restoreSelectionState()
                return
            }
            if id == currentTrackID {
                // No earlier playable entry: restart the current recording
                // without altering its queue position.
                if audioPlayer != nil, failedTrackID != currentTrackID {
                    restoreSelectionState()
                    seek(to: 0)
                    return
                }
                // Automatic advancement may retire the player after a failed
                // successor. Previous must reopen the still-cataloged track
                // instead of seeking a nil player and doing nothing.
                guard let target = library.song(with: id) else { continue }
                if beginPlayback(target, using: nextOrder,
                                 startPaused: !originalIsPlaying) { return }
                continue
            }
            guard let target = library.song(with: id) else { continue }
            if beginPlayback(target, using: nextOrder,
                             startPaused: !originalIsPlaying) { return }
        }
        // Leave the current recording and its playback order intact when
        // every previous candidate is unavailable.
        restoreSelectionState()
    }

    private func advance(automatically: Bool, crossfading: Bool = false,
                         startPaused: Bool = false) {
        guard let library else { return }
        // Repeat One is only valid while the selected recording still exists
        // in the library. An already-open audio player can outlive catalog
        // deletion; replaying it here would strand surviving queued songs.
        // Fall through to PlaybackOrder's deleted-current recovery instead.
        if automatically && repeatMode == .one,
           let currentTrackID,
           library.song(with: currentTrackID) != nil {
            seek(to: 0)
            resume()
            return
        }
        if crossfading {
            guard let activePlayer = audioPlayer,
                  attemptedCrossfadePlayer !== activePlayer else { return }
            attemptedCrossfadePlayer = activePlayer
        }
        var nextOrder = playbackOrder
        nextOrder.retainAvailable(Set(library.tracks.map(\.id)))
        // Repeat One must not pin recovery to a catalog entry that was
        // deleted while its decoder was open. Traverse surviving entries
        // instead, without changing the listener's repeat preference.
        // This also applies to paused recovery and explicit Play after deletion.
        let selectedIsMissing = currentTrackID.map { library.song(with: $0) == nil } ?? false
        // Recovery is not ordinary end-of-queue playback: when the selected
        // recording was removed, search surviving queue entries even if the
        // deleted ID was last and Repeat is Off. Do not change the user's
        // repeat preference; the override applies only to this recovery.
        let effectiveLoop: PlaybackLoopMode = selectedIsMissing ? .all : loopMode
        guard let nextID = nextOrder.next(automatic: automatically, loop: effectiveLoop) else {
            // A manual Next at the end of a finite queue is a no-op. Do not
            // discard the current paused position, retry state, or queue.
            // Natural completion still ends playback when repeat is off.
            if automatically && !crossfading { stop() }
            return
        }
        // Automatic completion has no audible predecessor to preserve. Probe
        // each remaining queue entry at most once, including catalog entries
        // removed after the queue snapshot. A failed file may be repaired and
        // retried from the lock screen; a wholly missing queue must stop.
        // Manual Next and pre-end crossfade are speculative: a corrupt next
        // file must not replace the retry identity of the still-selected song.
        // Automatic end-of-track advancement intentionally retains failures
        // for explicit retry, because the predecessor has already finished.
        let originalError = playbackError
        let originalFailedTrackID = failedTrackID
        let originalFailedOrder = failedPlaybackOrder
        let originalPlayer = audioPlayer
        let originalTrackID = currentTrackID
        let originalIsPlaying = isPlaying
        func restoreSpeculativeFailure() {
            guard audioPlayer === originalPlayer,
                  currentTrackID == originalTrackID else { return }
            playbackError = originalError
            failedTrackID = originalFailedTrackID
            failedPlaybackOrder = originalFailedOrder
            isPlaying = originalIsPlaying
            updateNowPlaying()
        }
        let preserveOutgoing = !automatically || crossfading
        var attempted: Set<UUID> = []
        var candidateID: UUID? = nextID
        var failedToOpenRecording = false
        while let id = candidateID, attempted.insert(id).inserted {
            if id == currentTrackID {
                // The queue has wrapped to the recording that just completed.
                // Once a successor failed, reopening the finished recording
                // would mask an exhausted/corrupt queue and could loop forever.
                // Keep the failed candidate available for explicit retry.
                if automatically && !crossfading && failedToOpenRecording {
                    positionTimer?.invalidate()
                    positionTimer = nil
                    cancelFade()
                    audioPlayer?.stop()
                    audioPlayer = nil
                    isPlaying = false
                    interruptionState.cancelResume()
                    updateNowPlaying()
                    return
                }
                // A healthy single-entry repeat-all queue may replay itself.
                // A speculative crossfade or manual Next must not restart the
                // outgoing recording while it remains audible.
                if !automatically || crossfading { return }
                seek(to: 0)
                resume()
                return
            }
            if let target = library.song(with: id) {
                if beginPlayback(target, using: nextOrder,
                                 transition: crossfading ? crossfadeSeconds : 0,
                                 preserveExistingOnFailure: preserveOutgoing,
                                 startPaused: startPaused) { return }
                failedToOpenRecording = true
            }
            // Manual Next and speculative crossfade must never skip over a
            // damaged selection or mutate the still-audible queue.
            guard automatically && !crossfading,
                  attempted.count < nextOrder.queueIDs.count else {
                if !automatically || crossfading {
                    restoreSpeculativeFailure()
                }
                break
            }
            // A failed candidate must not inherit Repeat One's replay-current
            // rule: that would select the same corrupt file again and strand
            // other playable recordings. Probe the next distinct queue entry
            // once, without changing the user's configured repeat preference.
            // Deleted-current recovery must retain its wraparound policy for
            // *every* candidate, not just the first. Otherwise a corrupt
            // successor near the end of a Repeat Off queue strands playable
            // recordings earlier in the queue. The attempted-ID set bounds
            // traversal to one cycle, even when every recording is damaged.
            // Ordinary end-of-track recovery still respects Repeat Off.
            let recoveryLoop: PlaybackLoopMode =
                selectedIsMissing ? .all : (loopMode == .one ? .all : loopMode)
            candidateID = nextOrder.next(automatic: true, loop: recoveryLoop)
        }
        if automatically && !crossfading && !failedToOpenRecording {
            // No candidate could even be opened. An old failedTrackID from a
            // prior manual selection must not keep a completed player alive.
            stop()
        }
        // If a candidate failed to open, beginPlayback retained the last
        // failure and its speculative order for a later explicit retry.

    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    private func canCrossfade() -> Bool {
        guard let library else { return false }
        var nextOrder = playbackOrder
        nextOrder.retainAvailable(Set(library.tracks.map(\.id)))
        return nextOrder.canAdvanceAutomatically(loop: loopMode)
    }

    private func cancelFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        outgoingPlayer?.stop()
        outgoingPlayer = nil
    }

    private func startFade(duration: TimeInterval, from outgoing: AVAudioPlayer, to incoming: AVAudioPlayer,
                           outgoingTrackID: UUID?, outgoingIdentity: LocalAudioFileIdentity?) {
        let started = ProcessInfo.processInfo.systemUptime
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak outgoing, weak incoming] timer in
            Task { @MainActor in
                // Timer callbacks hop to the main actor asynchronously. A queued
                // callback from a cancelled fade must not lower the volume of
                // a newly resumed track or a replacement crossfade.
                guard let self, let outgoing, let incoming,
                      timer.isValid, self.fadeTimer === timer,
                      self.outgoingPlayer === outgoing,
                      self.audioPlayer === incoming,
                      self.isPlaying else {
                    timer.invalidate()
                    return
                }
                // Validate the incoming recording first: never restore its
                // volume after the file was replaced or removed.
                if self.recoverDeletedCurrentTrack() || self.retireUnsafeCurrentDecoder() { return }
                // Both decoders can be audible during a crossfade. The 200 ms
                // position timer validates only the incoming recording; verify
                // the outgoing file here before changing either volume.
                guard let outgoingTrackID, let outgoingIdentity,
                      let library = self.library,
                      let song = library.song(with: outgoingTrackID),
                      let url = library.ownedPlaybackURL(for: song),
                      LocalAudioFileIdentity(url: url) == outgoingIdentity else {
                    self.cancelFade()
                    incoming.volume = 1
                    return
                }
                let fraction = min(1, (ProcessInfo.processInfo.systemUptime - started) / max(0.1, duration))
                // Equal-power curves prevent a noticeable dip in perceived loudness.
                outgoing.volume = Float(cos(fraction * .pi / 2))
                incoming.volume = Float(sin(fraction * .pi / 2))
                if fraction >= 1 {
                    self.cancelFade()
                    incoming.volume = 1
                }
            }
        }
    }

    private func startTimer() {
        positionTimer?.invalidate()
        // A timer tick can already be queued on the main actor when a track
        // changes. Tie each callback to its timer and original player so it
        // cannot seek the UI clock or trigger a fade for a replacement track.
        let observedPlayer = audioPlayer
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak observedPlayer] timer in
            Task { @MainActor in
                guard let self, let observedPlayer, timer.isValid,
                      self.positionTimer === timer,
                      self.isPlaying, self.audioPlayer === observedPlayer else { return }
                // Library repair or deletion can remove a catalog entry while
                // the decoder is actively playing. The open file descriptor
                // may remain audible indefinitely without this check.
                // Never publish another clock tick or begin a crossfade from
                // an orphaned player; recover through the surviving queue.
                if self.recoverDeletedCurrentTrack() { return }
                // Atomic replacement can leave AVAudioPlayer decoding an old inode
                // even though the catalog path still resolves to a valid file.
                // Recheck the opened file identity before publishing progress or
                // starting a crossfade; retirement preserves queue and retry IDs.
                if self.retireUnsafeCurrentDecoder() { return }
                let player = observedPlayer
                self.currentTime = player.currentTime
                if self.isPlaying && self.playbackError == nil && self.crossfadeSeconds > 0.1 && self.repeatMode != .one &&
                   self.outgoingPlayer == nil && self.canCrossfade() && player.duration > self.crossfadeSeconds + 1 &&
                   player.duration - player.currentTime <= self.crossfadeSeconds {
                    self.advance(automatically: true, crossfading: true)
                }
            }
        }
    }

    private func updateNowPlaying() {
        // A recording can be removed by library reconciliation while playback
        // is paused or recovering. Never leave the removed song's title,
        // artwork, or elapsed time advertised on the lock screen. The player
        // and retry state remain untouched so a repaired import can recover.
        guard let library, let song = library.song(with: currentTrackID) else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artwork = library.artwork(for: song) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self] in
                guard let self, let type else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    let wasPlaying = self.isPlaying || self.interruptionState.wantsResume
                    self.pause()
                    self.interruptionState.began(wasPlaying: wasPlaying)
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    let allowed = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    if self.interruptionState.ended(systemAllowsResume: allowed) { self.resume() }
                }
            }
        })
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in self?.pause() }
        })
    }

    private func configureRemoteControls() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = true
        commands.previousTrackCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = true

        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }
}
