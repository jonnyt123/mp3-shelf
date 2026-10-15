import SwiftUI

@main
struct MP3ShelfApp: App {
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
                .onAppear { playback.connect(to: library) }
        }
    }
}
