import SwiftUI

// MP3 Shelf visual system: a quiet obsidian foundation with three intentional
// accents. Artwork and key calls-to-action carry color; dense content stays calm.
enum ShelfTheme {
    static let background = Color(red: 0.043, green: 0.051, blue: 0.075)
    static let surface = Color(red: 0.087, green: 0.100, blue: 0.145)
    static let elevated = Color(red: 0.112, green: 0.129, blue: 0.180)
    static let accent = Color(red: 0.715, green: 0.610, blue: 0.995)
    static let coral = Color(red: 0.992, green: 0.569, blue: 0.486)
    static let mint = Color(red: 0.455, green: 0.865, blue: 0.779)
    static let subdued = Color(red: 0.646, green: 0.674, blue: 0.737)
    static let border = Color.white.opacity(0.09)

    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.32, green: 0.23, blue: 0.54),
                 Color(red: 0.15, green: 0.27, blue: 0.34),
                 Color(red: 0.12, green: 0.14, blue: 0.24)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func artworkColors(for name: String) -> [Color] {
        let seed = name.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 997 }
        switch seed % 4 {
        case 0: return [Color(red: 0.72, green: 0.45, blue: 0.80),
                        Color(red: 0.24, green: 0.24, blue: 0.57)]
        case 1: return [Color(red: 0.93, green: 0.49, blue: 0.45),
                        Color(red: 0.46, green: 0.23, blue: 0.42)]
        case 2: return [Color(red: 0.33, green: 0.76, blue: 0.73),
                        Color(red: 0.16, green: 0.37, blue: 0.54)]
        default: return [Color(red: 0.48, green: 0.55, blue: 0.95),
                         Color(red: 0.26, green: 0.29, blue: 0.58)]
        }
    }
}

struct PremiumBackdrop: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ShelfTheme.background
            RadialGradient(colors: [ShelfTheme.accent.opacity(0.095), .clear],
                           center: .topTrailing, startRadius: 20, endRadius: 430)
                .frame(height: 430)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct PremiumEyebrow: View {
    let title: String
    var color: Color = ShelfTheme.mint
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(2.0)
            .foregroundStyle(color)
    }
}

struct PremiumSectionHeading: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ShelfTheme.subdued)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

struct PremiumIcon: View {
    let symbol: String
    var color: Color = ShelfTheme.accent
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.39, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3)
                .strokeBorder(color.opacity(0.16), lineWidth: 1))
    }
}

struct PremiumCard: ViewModifier {
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .background(ShelfTheme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(ShelfTheme.border, lineWidth: 1))
    }
}

extension View {
    func premiumCard(radius: CGFloat = 22) -> some View {
        modifier(PremiumCard(radius: radius))
    }
}

struct MainView: View {
    @EnvironmentObject private var playback: PlaybackController
    @State private var showPlayer = false

    // Debug-only deep-page snapshots for automated design QA. The public
    // release always opens on the Listen tab.
    @State private var selectedTab: Int = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--mp3shelf-snapshot-playlists") { return 1 }
        if args.contains("--mp3shelf-snapshot-add-music") { return 2 }
        if args.contains("--mp3shelf-snapshot-settings") { return 3 }
        #endif
        return 0
    }()

    var body: some View {
        TabView(selection: $selectedTab) {
            tabPage { LibraryView() }
                .tabItem { Label("Listen", systemImage: "music.note.house.fill") }
                .tag(0)
            tabPage { PlaylistsView() }
                .tabItem { Label("Playlists", systemImage: "square.stack.fill") }
                .tag(1)
            tabPage { DownloadView() }
                .tabItem { Label("Add Music", systemImage: "plus.circle.fill") }
                .tag(2)
            tabPage { SettingsView() }
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(3)
        }
        .tint(ShelfTheme.accent)
        .toolbarBackground(ShelfTheme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .sheet(isPresented: $showPlayer) { NowPlayingView() }
    }

    private func tabPage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .background(PremiumBackdrop())
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if playback.currentTrackID != nil {
                        MiniPlayer { showPlayer = true }
                            .padding(.horizontal, 13)
                            .padding(.bottom, 7)
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
            RoundedRectangle(cornerRadius: size * 0.19)
                .fill(LinearGradient(colors: ShelfTheme.artworkColors(for: track?.title ?? "MP3 Shelf"),
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let track, let artwork = library.artwork(for: track) {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Circle()
                    .strokeBorder(.white.opacity(0.15), lineWidth: max(1, size * 0.009))
                    .frame(width: size * 0.76, height: size * 0.76)
                    .offset(x: size * 0.27, y: -size * 0.23)
                Circle()
                    .fill(.white.opacity(0.09))
                    .frame(width: size * 0.43, height: size * 0.43)
                    .offset(x: -size * 0.33, y: size * 0.35)
                HStack(alignment: .center, spacing: max(2, size * 0.035)) {
                    ForEach(0..<6, id: \.self) { index in
                        Capsule()
                            .fill(.white.opacity(0.9))
                            .frame(width: max(2, size * 0.052),
                                   height: size * 0.43 * [0.31, 0.67, 0.96, 0.52, 0.82, 0.37][index])
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.19))
        .overlay(RoundedRectangle(cornerRadius: size * 0.19)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct EmptyShelfView: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        VStack(spacing: 14) {
            PremiumIcon(symbol: symbol, color: ShelfTheme.mint, size: 68)
                .padding(.bottom, 3)
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text(subtitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(ShelfTheme.subdued)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 26)
        .padding(.vertical, 40)
        .premiumCard(radius: 26)
    }
}

extension TimeInterval {
    var shelfClock: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let seconds = Int(self)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
