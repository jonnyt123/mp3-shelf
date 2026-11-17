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
        didSet { playbackOrder.setShuffle(isShuffled) }
    }
    @Published var repeatMode: RepeatMode = .off
    @Published var crossfadeSeconds: Double = UserDefaults.standard.double(forKey: "mp3shelf.crossfadeSeconds") {
        didSet { UserDefaults.standard.set(crossfadeSeconds, forKey: "mp3shelf.crossfadeSeconds") }
    }

    private weak var library: MusicLibrary?
    private var audioPlayer: AVAudioPlayer?
    private var positionTimer: Timer?
    private var fadeTimer: Timer?
    private var outgoingPlayer: AVAudioPlayer?
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
    }

    func playQueuedTrackNext(_ id: UUID) {
        _ = playbackOrder.playNext(id)
    }

    func removeQueuedTrack(_ id: UUID) {
        _ = playbackOrder.removeUpcoming(id)
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
        var nextOrder = playbackOrder
        if let songs {
            nextOrder.reset(queue: songs.map(\.id), current: track.id, shuffled: isShuffled)
        } else if nextOrder.queueIDs.isEmpty || !nextOrder.queueIDs.contains(track.id) {
            nextOrder.reset(queue: library.tracks.map(\.id), current: track.id, shuffled: isShuffled)
        } else {
            nextOrder.retainAvailable(Set(library.tracks.map(\.id)))
            nextOrder.select(track.id)
        }
        beginPlayback(track, using: nextOrder, transition: transition)
    }

    /// Playback order commits only after AVAudioPlayer successfully starts.
    /// A corrupted or missing file cannot consume shuffle history.
    private func beginPlayback(_ track: MusicTrack, using nextOrder: PlaybackOrder,
                               transition: TimeInterval = 0,
                               preserveExistingOnFailure: Bool = true) -> Bool {
        guard let library else { return false }
        do {
            try activateAudio()
            let player = try AVAudioPlayer(contentsOf: library.fileURL(for: track))
            player.delegate = relay
            guard player.prepareToPlay(), player.duration.isFinite, player.duration > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if transition > 0, let previous = audioPlayer, previous.isPlaying {
                player.volume = 0
                guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
                cancelFade()
                outgoingPlayer = previous
                previous.delegate = nil
                audioPlayer = player
                startFade(duration: transition, from: previous, to: player)
            } else {
                player.volume = 1
                guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
                cancelFade()
                audioPlayer?.stop()
                audioPlayer = player
            }
            relay.invalidatePendingCompletions()
            playbackError = nil
            failedTrackID = nil
            failedPlaybackOrder = nil
            interruptionState.cancelResume()
            playbackOrder = nextOrder
            currentTrackID = track.id
            duration = player.duration
            currentTime = 0
            isPlaying = true
            startTimer()
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
            let previousIsAudible = audioPlayer?.isPlaying == true
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

    func retryFailedPlayback() {
        guard let library, let track = library.song(with: failedTrackID) else {
            playbackError = "This song is no longer in your library. Choose another song."
            return
        }
        if var order = failedPlaybackOrder {
            order.retainAvailable(Set(library.tracks.map(\.id)))
            order.setShuffle(isShuffled)
            order.select(track.id)
            beginPlayback(track, using: order)
        } else { play(track) }
    }

    func togglePlayback() { isPlaying ? pause() : resume() }

    func pause() {
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

    func resume() {
        relay.invalidatePendingCompletions()
        interruptionState.cancelResume()
        // Automatic advancement retires the finished player when the next
        // recording cannot be opened. Lock-screen Play must retry that failed
        // selection rather than silently succeeding with no audio player.
        // A deliberately stopped session has no failedTrackID and stays stopped.
        guard let audioPlayer else {
            if failedTrackID != nil { retryFailedPlayback() }
            return
        }
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
        cancelFade()
        positionTimer?.invalidate()
        positionTimer = nil
        currentTrackID = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        playbackOrder = PlaybackOrder()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to seconds: TimeInterval) {
        guard let audioPlayer, seconds.isFinite else { return }
        // AVAudioPlayer can enqueue a completion before a seek, particularly
        // when scrubbing backwards at the end of a recording. That completion
        // belongs to the old playback position, not the newly sought position.
        // Invalidate it before changing the player's clock so it cannot
        // advance the queue or report a spurious decode failure after scrubbing.
        relay.invalidatePendingCompletions()
        cancelFade()
        audioPlayer.volume = 1
        let position = max(0, min(seconds, audioPlayer.duration))
        audioPlayer.currentTime = position
        currentTime = position
        updateNowPlaying()
    }

    func next() { advance(automatically: false) }

    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        guard let library else { return }
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
        let originalIsPlaying = isPlaying
        func restoreSelectionState() {
            guard audioPlayer === originalPlayer,
                  currentTrackID == originalTrackID else { return }
            playbackError = originalError
            failedTrackID = originalFailedTrackID
            failedPlaybackOrder = originalFailedOrder
            isPlaying = originalIsPlaying
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
                restoreSelectionState()
                seek(to: 0)
                return
            }
            guard let target = library.song(with: id) else { continue }
            if beginPlayback(target, using: nextOrder) { return }
        }
        // Leave the current recording and its playback order intact when
        // every previous candidate is unavailable.
        restoreSelectionState()
    }

    private func advance(automatically: Bool, crossfading: Bool = false) {
        guard let library else { return }
        if automatically && repeatMode == .one {
            seek(to: 0)
            resume()
            return
        }
        var nextOrder = playbackOrder
        nextOrder.retainAvailable(Set(library.tracks.map(\.id)))
        guard let nextID = nextOrder.next(automatic: automatically, loop: loopMode) else {
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
                                 preserveExistingOnFailure: preserveOutgoing) { return }
                failedToOpenRecording = true
            }
            // Manual Next and speculative crossfade must never skip over a
            // damaged selection or mutate the still-audible queue.
            guard automatically && !crossfading,
                  attempted.count < nextOrder.queueIDs.count else { break }
            candidateID = nextOrder.next(automatic: true, loop: loopMode)
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

    private func startFade(duration: TimeInterval, from outgoing: AVAudioPlayer, to incoming: AVAudioPlayer) {
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
