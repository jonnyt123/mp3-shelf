import SwiftUI
import UIKit
import BackgroundTasks
#if DEBUG
import AVFoundation
#endif

/// Background URLSession handles file transfers; BGProcessingTask provides
/// best-effort runtime for the catalog lookup queue that precedes them.
/// iOS chooses when (or whether) a background processing window is granted.
enum MP3ShelfBackgroundDiscovery {
    static let identifier = "com.jonnyt.mp3shelf.discovery"

    @MainActor static weak var foregroundLibrary: MusicLibrary?

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let worker = Task { @MainActor in
                // On a headless launch there is no visible SwiftUI scene.
                // Retain a library for the complete processing window.
                let library = foregroundLibrary ?? MusicLibrary()
                let finishedNormally = await library.runBackgroundDiscoveryBatch()
                processing.setTaskCompleted(success: finishedNormally)
                if library.hasPendingDiscoveryWork {
                    schedule()
                }
            }
            processing.expirationHandler = { worker.cancel() }
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(10 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Background processing is opportunistic, and iOS can reject
            // requests due to system limits or user configuration. Queued
            // file transfers and foreground resume remain fully functional.
            print("MP3 Shelf background source discovery scheduling: \(error)")
        }
    }
}

final class MP3ShelfAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                         [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MP3ShelfBackgroundDiscovery.register()
        return true
    }

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
                    MP3ShelfBackgroundDiscovery.foregroundLibrary = library
                    BackgroundAudioDownloader.shared.attach(to: library)
                    library.resumePendingDiscovery()
                    #if DEBUG
                    let snapshotArguments = ProcessInfo.processInfo.arguments
                    if !didStartVisualFixture &&
                        (snapshotArguments.contains("--mp3shelf-snapshot-player") ||
                         snapshotArguments.contains("--mp3shelf-snapshot-filled-library") ||
                         snapshotArguments.contains("--mp3shelf-snapshot-search")) {
                        didStartVisualFixture = true
                        Task {
                            await installVisualQAAudio(
                                playing: snapshotArguments.contains("--mp3shelf-snapshot-player"))
                        }
                    }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        BackgroundAudioDownloader.shared.attach(to: library)
                        library.resumePendingDiscovery()
                    } else if phase == .background && library.hasPendingDiscoveryWork {
                        // BGProcessingTasks are scheduled before suspension;
                        // the next launch may be delayed or skipped by iOS.
                        MP3ShelfBackgroundDiscovery.schedule()
                    }
                }
        }
    }

    #if DEBUG
    /// CI-only synthetic recordings for visual QA of a populated library
    /// and working Now Playing controls. None are present in release builds.
    /// The generated WAVs are original audio with no third-party rights.
    @MainActor
    private func installVisualQAAudio(playing: Bool) async {
        let examples: [(title: String, frequency: Double)] = [
            ("Velvet Echo", 220),
            ("Coastline", 293.66),
            ("After Hours", 329.63)
        ]
        var playable: [MusicTrack] = []
        for (index, example) in examples.enumerated() {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("MP3Shelf Visual QA \(index).wav")
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
                        channel[sample] = Float(
                            sin(2 * Double.pi * example.frequency * Double(sample) / sampleRate)
                            * 0.045 * fade)
                    }
                    let file = try AVAudioFile(forWriting: url, settings: format.settings)
                    try file.write(from: buffer)
                }
                _ = await library.importAudio(urls: [url])
                guard let imported = library.tracks.first(where: {
                    $0.originalFileName == url.lastPathComponent
                }) else { continue }
                library.rename(imported, title: example.title, artist: "MP3 Shelf Studio")
                if let updated = library.song(with: imported.id) { playable.append(updated) }
            } catch {
                print("Visual QA audio creation failed: \(error)")
            }
        }
        if playing, let first = playable.first {
            playback.play(first, queue: playable)
        }
    }
    #endif
}
