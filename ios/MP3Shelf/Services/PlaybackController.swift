import AVFoundation
import MediaPlayer
import UIKit
import Foundation
import Combine

private final class AudioCompletionRelay: NSObject, AVAudioPlayerDelegate {
    var finished: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { finished?() }
}

@MainActor
final class PlaybackController: NSObject, ObservableObject {
    @Published private(set) var currentTrackID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var crossfadeSeconds: Double = UserDefaults.standard.double(forKey: "mp3shelf.crossfadeSeconds") {
        didSet { UserDefaults.standard.set(crossfadeSeconds, forKey: "mp3shelf.crossfadeSeconds") }
    }

    private weak var library: MusicLibrary?
    private var audioPlayer: AVAudioPlayer?
    private var positionTimer: Timer?
    private var fadeTimer: Timer?
    private var outgoingPlayer: AVAudioPlayer?
    private var queue: [UUID] = []

    /// Read-only queue preview for the native Now Playing screen.
    /// Uses the active playback order and never mutates the playlist.
    var upcomingTracks: [MusicTrack] {
        guard let library, let currentTrackID,
              let index = queue.firstIndex(of: currentTrackID) else { return [] }
        return queue.dropFirst(index + 1).prefix(3)
            .compactMap { library.song(with: $0) }
    }

    private let relay = AudioCompletionRelay()
    private var remoteControlsConfigured = false

    func connect(to library: MusicLibrary) {
        self.library = library
        guard !remoteControlsConfigured else { return }
        remoteControlsConfigured = true
        relay.finished = { [weak self] in
            Task { @MainActor in self?.advance(automatically: true) }
        }
        configureRemoteControls()
    }

    private func activateAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    func play(_ track: MusicTrack, queue songs: [MusicTrack]? = nil, transition: TimeInterval = 0) {
        guard let library else { return }
        if let songs { queue = songs.map(\.id) }
        if queue.isEmpty { queue = library.tracks.map(\.id) }
        if !queue.contains(track.id) { queue.append(track.id) }

        do {
            try activateAudio()
            let player = try AVAudioPlayer(contentsOf: library.fileURL(for: track))
            player.delegate = relay
            player.prepareToPlay()
            if transition > 0, let previous = audioPlayer, previous.isPlaying {
                player.volume = 0
                guard player.play() else { return }
                cancelFade()
                outgoingPlayer = previous
                previous.delegate = nil
                audioPlayer = player
                startFade(duration: transition, from: previous, to: player)
            } else {
                player.volume = 1
                guard player.play() else { return }
                cancelFade()
                audioPlayer?.stop()
                audioPlayer = player
            }
            currentTrackID = track.id
            duration = player.duration
            currentTime = 0
            isPlaying = true
            startTimer()
            updateNowPlaying()
        } catch {
            print("MP3 Shelf playback failed: \(error)")
            isPlaying = false
        }
    }

    func togglePlayback() { isPlaying ? pause() : resume() }

    func pause() {
        if outgoingPlayer != nil { cancelFade(); audioPlayer?.volume = 1 }
        audioPlayer?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard let audioPlayer else { return }
        do {
            try activateAudio()
            isPlaying = audioPlayer.play()
            if isPlaying { startTimer() }
            updateNowPlaying()
        } catch {
            print("MP3 Shelf could not resume audio: \(error)")
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        cancelFade()
        positionTimer?.invalidate()
        positionTimer = nil
        currentTrackID = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to seconds: TimeInterval) {
        guard let audioPlayer, seconds.isFinite else { return }
        let position = max(0, min(seconds, audioPlayer.duration))
        audioPlayer.currentTime = position
        currentTime = position
        updateNowPlaying()
    }

    func next() { advance(automatically: false) }

    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        guard let library, let id = currentTrackID else { return }
        let playable = queue.filter { library.song(with: $0) != nil }
        guard let index = playable.firstIndex(of: id), !playable.isEmpty else { return }
        let previousIndex = index > 0 ? index - 1 : (repeatMode == .all ? playable.count - 1 : 0)
        if let target = library.song(with: playable[previousIndex]) { play(target) }
    }

    private func advance(automatically: Bool, crossfading: Bool = false) {
        guard let library, let id = currentTrackID else { return }
        if automatically && repeatMode == .one { seek(to: 0); resume(); return }
        let playable = queue.filter { library.song(with: $0) != nil }
        guard let index = playable.firstIndex(of: id), !playable.isEmpty else { stop(); return }
        let nextID: UUID?
        if isShuffled, playable.count > 1 {
            nextID = playable.filter { $0 != id }.randomElement()
        } else if index + 1 < playable.count {
            nextID = playable[index + 1]
        } else if repeatMode == .all || !automatically {
            nextID = playable.first
        } else {
            nextID = nil
        }
        if let nextID, let target = library.song(with: nextID) { play(target, transition: crossfading ? crossfadeSeconds : 0) }
        else { stop() }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    private func canCrossfade() -> Bool {
        guard let library, let id = currentTrackID else { return false }
        let playable = queue.filter { library.song(with: $0) != nil }
        guard let index = playable.firstIndex(of: id) else { return false }
        return (isShuffled && playable.count > 1) || index + 1 < playable.count || repeatMode == .all
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
                guard let self, let outgoing, let incoming, self.audioPlayer === incoming else {
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
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.audioPlayer else { return }
                self.currentTime = player.currentTime
                if self.isPlaying && self.crossfadeSeconds > 0.1 && self.repeatMode != .one &&
                   self.outgoingPlayer == nil && self.canCrossfade() && player.duration > self.crossfadeSeconds + 1 &&
                   player.duration - player.currentTime <= self.crossfadeSeconds {
                    self.advance(automatically: true, crossfading: true)
                }
            }
        }
    }

    private func updateNowPlaying() {
        guard let library, let song = library.song(with: currentTrackID) else { return }
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
