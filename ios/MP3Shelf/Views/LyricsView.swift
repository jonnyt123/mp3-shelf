import SwiftUI
import UniformTypeIdentifiers

struct LyricsView: View {
    let songID: UUID
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var playback: PlaybackController
    @State private var showPicker = false
    @State private var alert: String?

    var body: some View {
        Group {
            if let song = library.song(with: songID) {
                let lines = library.lyrics(for: song)
                if lines.isEmpty {
                    ContentUnavailableView("No offline lyrics yet", systemImage: "text.quote",
                        description: Text("Import a .lrc synchronized lyric file or a plain .txt lyric file for this song."))
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(spacing: 22) {
                                ForEach(lines) { line in
                                    Text(line.text)
                                        .font(.title3.weight(isActive(line, in: lines) ? .bold : .regular))
                                        .foregroundStyle(isActive(line, in: lines) ? ShelfTheme.mint : ShelfTheme.subdued)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(line.id)
                                        .onTapGesture { if let time = line.time { playback.seek(to: time) } }
                                }
                            }
                            .padding(24)
                        }
                        .onChange(of: playback.currentTime) { _, _ in
                            if let line = lines.last(where: { $0.time != nil && ($0.time ?? 0) <= playback.currentTime }) {
                                withAnimation(.easeInOut(duration: 0.3)) { reader.scrollTo(line.id, anchor: .center) }
                            }
                        }
                    }
                }
            }
        }
        .background(PremiumBackdrop())
        .tint(ShelfTheme.accent)
        .navigationTitle("Lyrics")
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("Import LRC") { showPicker = true }
        } }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.plainText, UTType(filenameExtension: "lrc") ?? .plainText]) { result in
            switch result {
            case .success(let url):
                do { try library.importLyrics(from: url, for: songID) }
                catch { alert = error.localizedDescription }
            case .failure(let error): alert = error.localizedDescription
            }
        }
        .alert("Lyrics Import", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) { alert = nil }
        } message: { Text(alert ?? "") }
    }

    private func isActive(_ line: LyricLine, in lines: [LyricLine]) -> Bool {
        guard let time = line.time, time <= playback.currentTime else { return false }
        return !(lines.first(where: { ($0.time ?? -.infinity) > time })?.time ?? .infinity <= playback.currentTime)
    }
}
