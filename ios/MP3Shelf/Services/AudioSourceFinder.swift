import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Evidence for a downloadable MP3 that an independent catalog labels as
/// Creative Commons or public domain. License metadata is supplied by the
/// uploader, not independently certified by MP3 Shelf.
struct AudioCatalogMatch {
    let downloadURL: URL
    let itemURL: URL
    let licenseURL: URL
    let sourceName: String
}

/// No Spotify audio APIs, stream extraction, scraping, YouTube conversion, or
/// guessed media URLs. Only explicitly license-labeled archive MP3 files.
enum AudioSourceFinder {
    private struct FlexibleText: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let item = try decoder.singleValueContainer()
            if let string = try? item.decode(String.self) { value = string }
            else if let strings = try? item.decode([String].self) { value = strings.first ?? "" }
            else { value = "" }
        }
    }
    private struct SearchResponse: Decodable { let response: SearchBody }
    private struct SearchBody: Decodable { let docs: [SearchItem] }
    private struct SearchItem: Decodable { let identifier: String }
    private struct ArchiveItem: Decodable {
        let metadata: ItemMetadata?
        let files: [ArchiveFile]?
    }
    private struct ItemMetadata: Decodable {
        let title: FlexibleText?
        let creator: FlexibleText?
        let licenseurl: FlexibleText?
    }
    private struct ArchiveFile: Decodable {
        let name: String
        let source: String?
        let length: String?
    }

    static func exactMetadataMatch(title: String, creator: String, wish: PlaylistWish) -> Bool {
        let song = MusicMatching.key(wish.title)
        let artist = MusicMatching.key(wish.artist)
        return !song.isEmpty && !artist.isEmpty &&
            MusicMatching.key(title) == song && MusicMatching.key(creator) == artist
    }

    static func licensedURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), let host = url.host?.lowercased(),
              ["creativecommons.org", "www.creativecommons.org"].contains(host),
              url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http",
              url.path.lowercased().hasPrefix("/licenses/") ||
                  url.path.lowercased().hasPrefix("/publicdomain/") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 &&
        value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil &&
        !value.contains("..")
    }

    private static func safeMP3File(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 255 &&
        value.lowercased().hasSuffix(".mp3") &&
        !value.contains("/") && !value.contains("\\") &&
        !value.contains("..")
    }

    private static func requestJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue("MP3Shelf/1.1 (personal offline audio library)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count < 2_000_000 else { throw SourceError.unavailable }
        return try JSONDecoder().decode(T.self, from: data)
    }

    enum SourceError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Audio-source catalog unavailable." }
    }

    static func find(for wish: PlaylistWish) async throws -> AudioCatalogMatch? {
        guard !wish.title.isEmpty, !wish.artist.isEmpty else { return nil }
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "\"", with: " ")
                 .replacingOccurrences(of: "\n", with: " ")
        }
        var query = URLComponents(string: "https://archive.org/advancedsearch.php")!
        query.queryItems = [
            URLQueryItem(name: "q", value: "mediatype:audio AND title:(\"\(escaped(wish.title))\") AND creator:(\"\(escaped(wish.artist))\")"),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "rows", value: "8"),
            URLQueryItem(name: "output", value: "json")
        ]
        let search: SearchResponse = try await requestJSON(query.url!)
        for result in search.response.docs.prefix(8) {
            try Task.checkCancellation()
            guard safeIdentifier(result.identifier) else { continue }
            let metadataURL = URL(string: "https://archive.org/metadata/")!
                .appendingPathComponent(result.identifier)
            guard let item: ArchiveItem = try? await requestJSON(metadataURL),
                  let metadata = item.metadata,
                  let license = licensedURL(metadata.licenseurl?.value),
                  exactMetadataMatch(title: metadata.title?.value ?? "",
                                     creator: metadata.creator?.value ?? "",
                                     wish: wish) else { continue }

            let candidates = (item.files ?? []).filter { safeMP3File($0.name) }
            let original = candidates.filter { $0.source == "original" }
            let files = original.isEmpty ? candidates : original
            // One file only: don't mistake an album or concert for a single track.
            guard files.count == 1, let file = files.first else { continue }
            // If both have duration metadata, reject alternate takes and edits.
            if let expected = wish.durationSeconds {
                guard let lengthString = file.length,
                      let measured = Double(lengthString),
                      abs(measured - expected) <= 4.0 else { continue }
            }
            let itemURL = URL(string: "https://archive.org/details/")!
                .appendingPathComponent(result.identifier)
            let downloadURL = URL(string: "https://archive.org/download/")!
                .appendingPathComponent(result.identifier)
                .appendingPathComponent(file.name)
            return AudioCatalogMatch(downloadURL: downloadURL, itemURL: itemURL,
                                     licenseURL: license, sourceName: "Internet Archive")
        }
        return nil
    }
}
