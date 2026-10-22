import Foundation

// Pure Foundation parser so the importer can be tested independently of iOS.
enum PlaylistCSVError: LocalizedError {
    case unreadable, missingTitleColumn, empty

    var errorDescription: String? {
        switch self {
        case .unreadable: return "This file is not valid UTF-8, UTF-16 or Latin-1 text."
        case .missingTitleColumn: return "No song title column was found. Expected Track Name, Name or Title."
        case .empty: return "No tracks were found in this playlist file."
        }
    }
}

enum PlaylistCSV {
    static func parse(_ data: Data) throws -> [PlaylistWish] {
        guard let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw PlaylistCSVError.unreadable
        }
        let text = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        let delimiter: Character = firstLine.filter { $0 == "\t" }.count > firstLine.filter { $0 == "," }.count ? "\t" : ","
        let rows = parseRows(text, delimiter: delimiter).filter { $0.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) }
        guard let header = rows.first else { throw PlaylistCSVError.empty }

        func canonical(_ str: String) -> String {
            str.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        let fields = header.map(canonical)
        func column(_ aliases: [String]) -> Int? {
            fields.firstIndex(where: { aliases.contains($0) })
        }
        guard let titleColumn = column(["trackname", "track", "title", "song", "songtitle", "name"]) else {
            throw PlaylistCSVError.missingTitleColumn
        }
        let artistColumn = column(["artistname", "artistnames", "artist", "artists", "artistss"])
        let albumColumn = column(["albumname", "album", "release"])
        let spotifyColumn = column(["trackuri", "spotifyuri", "trackurl", "spotifyurl", "url"])
        func cell(_ row: [String], _ index: Int?) -> String {
            guard let index, row.indices.contains(index) else { return "" }
            return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let items: [PlaylistWish] = rows.dropFirst().compactMap { row in
            let title = cell(row, titleColumn)
            guard !title.isEmpty else { return nil }
            let uri = cell(row, spotifyColumn)
            let link: String?
            if uri.hasPrefix("spotify:track:") {
                link = "https://open.spotify.com/track/" + String(uri.dropFirst("spotify:track:".count))
            } else if uri.hasPrefix("https://open.spotify.com/track/") {
                link = uri
            } else {
                link = nil
            }
            return PlaylistWish(title: title, artist: cell(row, artistColumn),
                                album: cell(row, albumColumn), spotifyURL: link)
        }
        if items.isEmpty { throw PlaylistCSVError.empty }
        return items
    }

    static func parseRows(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else { quoted.toggle() }
            } else if char == delimiter && !quoted {
                row.append(field)
                field = ""
            } else if (char == "\n" || char == "\r" || char == "\r\n") && !quoted {
                if char == "\r" && index + 1 < characters.count && characters[index + 1] == "\n" { index += 1 }
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(char)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

enum MusicMatching {
    static func key(_ text: String) -> String {
        var base = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if let range = base.range(of: #"\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring)\b[^\)\]]*[\)\]]"#, options: .regularExpression) {
            base.removeSubrange(range)
        }
        return base.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Reuse only a single matching offline recording whose duration is
    /// compatible with the requested Spotify track. Title/artist alone is
    /// insufficient to cancel a paid-for, in-progress background download
    /// when an alternate version has already been saved.
    static func reusableOfflineTrack(for wish: PlaylistWish,
                                     in library: [MusicTrack]) -> MusicTrack? {
        guard let track = matchingTrack(for: wish, in: library) else { return nil }
        if let expected = wish.durationSeconds,
           (!track.duration.isFinite || abs(track.duration - expected) > 4) {
            return nil
        }
        return track
    }

    static func matchingTrack(for wish: PlaylistWish, in library: [MusicTrack]) -> MusicTrack? {
        let name = key(wish.title)
        guard !name.isEmpty else { return nil }
        let sameTitle = library.filter { key($0.title) == name }
        let artist = key(wish.artist)
        if !artist.isEmpty {
            let both = sameTitle.filter {
                let candidate = key($0.artist)
                return candidate == artist || (!candidate.isEmpty && (artist.contains(candidate) || candidate.contains(artist)))
            }
            // Don't guess if multiple recordings share this metadata.
            return both.count == 1 ? both[0] : nil
        }
        return sameTitle.count == 1 ? sameTitle[0] : nil
    }
}


/// Verify identity evidence inside imported audio before assigning playlist
/// metadata. Missing tags are inconclusive; contradictory tags are a mismatch.
/// The caller separately validates playable media and Spotify's duration.
enum SourceAudioIdentity {
    enum Conflict: String {
        case title, artist
    }

    static func conflictingField(title: String?, artist: String?,
                                 requested: PlaylistWish) -> Conflict? {
        func normalized(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let key = MusicMatching.key(text)
            guard !key.isEmpty,
                  !["unknown", "unknownartist", "untitled", "track"].contains(key)
            else { return nil }
            return key
        }

        let wantedTitle = MusicMatching.key(requested.title)
        if let embedded = normalized(title), !wantedTitle.isEmpty,
           embedded != wantedTitle {
            return .title
        }
        let wantedArtist = MusicMatching.key(requested.artist)
        if let embedded = normalized(artist), !wantedArtist.isEmpty,
           embedded != wantedArtist &&
           !embedded.contains(wantedArtist) && !wantedArtist.contains(embedded) {
            return .artist
        }
        return nil
    }
}
