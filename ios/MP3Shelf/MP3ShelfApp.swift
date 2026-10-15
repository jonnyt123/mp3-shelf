import SwiftUI
import UIKit
#if DEBUG
import AVFoundation
#endif

final class MP3ShelfAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundAudioDownloader.identifier else {
            completionHandler()
            return
        }
        Task { @MainActor in
            BackgroundAudioDownloader.shared.setBackgroundEventsCompletion(completionHandler)
        }
    }
}

@main
struct MP3ShelfApp: App {
    @UIApplicationDelegateAdaptor(MP3ShelfAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = MusicLibrary()
    @StateObject private var playback = PlaybackController()
    @StateObject private var spotify = SpotifyService()
    #if DEBUG
    @State private var didStartVisualFixture = false
    #endif

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(library)
                .environmentObject(playback)
                .environmentObject(spotify)
                .preferredColorScheme(.dark)
                .onAppear {
                    playback.connect(to: library)
                    BackgroundAudioDownloader.shared.attach(to: library)
                    library.resumePendingDiscovery()
                    #if DEBUG
                    if !didStartVisualFixture &&
                        ProcessInfo.processInfo.arguments.contains("--mp3shelf-snapshot-player") {
                        didStartVisualFixture = true
                        Task { await installVisualQAPlayback() }
                    }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        BackgroundAudioDownloader.shared.attach(to: library)
                        library.resumePendingDiscovery()
                    }
                }
        }
    }

    #if DEBUG
    /// Explicitly invoked by CI for a real Now Playing screenshot.
    /// Creates our own short sine-wave WAV; no commercial sound recordings,
    /// service credentials or mock download successes are introduced.
    @MainActor
    private func installVisualQAPlayback() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MP3Shelf Visual QA.wav")
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                let sampleRate = 22_050.0
                let frameCount = AVAudioFrameCount(sampleRate * 32)
                guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: sampleRate,
                                                 channels: 1, interleaved: false),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                     frameCapacity: frameCount),
                      let channel = buffer.floatChannelData?[0] else { return }
                buffer.frameLength = frameCount
                for sample in 0..<Int(frameCount) {
                    let fade = min(1.0, Double(sample) / sampleRate)
                    channel[sample] = Float(sin(2 * .pi * 220 * Double(sample) / sampleRate)
                                            * 0.045 * fade)
                }
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            _ = await library.importAudio(urls: [url])
            guard let imported = library.tracks.first(where: {
                $0.originalFileName == url.lastPathComponent
            }) else { return }
            library.rename(imported, title: "Velvet Echo", artist: "MP3 Shelf Studio")
            if let track = library.song(with: imported.id) {
                playback.play(track, queue: [track])
            }
        } catch {
            print("Visual QA fixture generation failed: \(error)")
        }
    }
    #endif
}
