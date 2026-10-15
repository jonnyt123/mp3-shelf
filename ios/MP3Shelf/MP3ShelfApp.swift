import SwiftUI
import UIKit

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
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        BackgroundAudioDownloader.shared.attach(to: library)
                        library.resumePendingDiscovery()
                    }
                }
        }
    }
}
