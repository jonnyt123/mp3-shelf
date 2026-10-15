import SwiftUI

// A dark-first, thumb-friendly layout that inherits the user's Dynamic Type settings.
enum ShelfTheme {
    static let background = Color(red: 0.043, green: 0.052, blue: 0.089)
    static let surface = Color(red: 0.097, green: 0.110, blue: 0.167)
    static let accent = Color(red: 0.55, green: 0.43, blue: 1.00)
    static let subdued = Color(red: 0.65, green: 0.69, blue: 0.79)
}

struct MainView: View {
    @EnvironmentObject private var playback: PlaybackController
    @State private var showPlayer = false

    var body: some View {
        TabView {
            tabPage { LibraryView() }
                .tabItem { Label("Library", systemImage: "music.note.list") }
            tabPage { PlaylistsView() }
                .tabItem { Label("Playlists", systemImage: "square.stack.fill") }
            tabPage { DownloadView() }
                .tabItem { Label("Import", systemImage: "square.and.arrow.down.fill") }
            tabPage { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(ShelfTheme.accent)
        .sheet(isPresented: $showPlayer) { NowPlayingView() }
    }

    private func tabPage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .background(ShelfTheme.background.ignoresSafeArea())
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if playback.currentTrackID != nil {
                        MiniPlayer { showPlayer = true }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    }
                }
        }
    }
}

struct ArtworkTile: View {
    let track: MusicTrack?
    var size: CGFloat = 52
    @EnvironmentObject private var library: MusicLibrary

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(LinearGradient(colors: [ShelfTheme.accent.opacity(0.85), Color(red: 0.18, green: 0.68, blue: 0.79)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let track, let artwork = library.artwork(for: track) {
                Image(uiImage: artwork)
                    .resizable().scaledToFill()
                    .frame(width: size, height: size).clipped()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }
}

struct EmptyShelfView: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(ShelfTheme.accent)
                .frame(width: 96, height: 96)
                .background(ShelfTheme.surface, in: RoundedRectangle(cornerRadius: 26))
            Text(title).font(.title3.bold())
            Text(subtitle).multilineTextAlignment(.center)
                .foregroundStyle(ShelfTheme.subdued)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 64)
    }
}

extension TimeInterval {
    var shelfClock: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let seconds = Int(self)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
