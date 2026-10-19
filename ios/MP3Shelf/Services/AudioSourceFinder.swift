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

    /// Internet Archive's file.length field is a byte count, not song
    /// duration. Check size here and check audible duration after download.
    /// Albums are allowed only when exactly one original file has a filename
    /// explicitly matching the requested song and the item credits its artist.
    static func archiveFileCandidate(name: String, source: String?, lengthBytes: String?,
                                      itemTitle: String, itemCreator: String,
                                      audioFileCount: Int, wish: PlaylistWish) -> Bool {
        guard safeMP3File(name), MusicMatching.key(itemCreator) == MusicMatching.key(wish.artist),
              !MusicMatching.key(wish.artist).isEmpty else { return false }
        if let lengthBytes {
            guard let bytes = Int64(lengthBytes), bytes > 0,
                  bytes <= 100 * 1024 * 1024 else { return false }
        }
        if audioFileCount == 1 {
            return exactMetadataMatch(title: itemTitle, creator: itemCreator, wish: wish)
        }
        guard source == "original" else { return false }
        let title = MusicMatching.key(wish.title)
        let stem = (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        let key = MusicMatching.key(stem)
        return !title.isEmpty &&
            (key == title || key == MusicMatching.key("\(wish.artist) - \(wish.title)"))
    }

    static func find(for wish: PlaylistWish) async throws -> AudioCatalogMatch? {
        guard !wish.title.isEmpty, !wish.artist.isEmpty else { return nil }
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "\"", with: " ")
                 .replacingOccurrences(of: "\n", with: " ")
        }
        var query = URLComponents(string: "https://archive.org/advancedsearch.php")!
        query.queryItems = [
            URLQueryItem(name: "q", value: "mediatype:audio AND (title:(\"\(escaped(wish.title))\") OR description:(\"\(escaped(wish.title))\")) AND creator:(\"\(escaped(wish.artist))\")"),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "rows", value: "20"),
            URLQueryItem(name: "output", value: "json")
        ]
        let search: SearchResponse = try await requestJSON(query.url!)
        for result in search.response.docs.prefix(20) {
            try Task.checkCancellation()
            guard safeIdentifier(result.identifier) else { continue }
            let metadataURL = URL(string: "https://archive.org/metadata/")!
                .appendingPathComponent(result.identifier)
            guard let item: ArchiveItem = try? await requestJSON(metadataURL),
                  let metadata = item.metadata,
                  let license = licensedURL(metadata.licenseurl?.value) else { continue }

            let audioFiles = (item.files ?? []).filter { safeMP3File($0.name) }
            let originalFiles = audioFiles.filter { $0.source == "original" }
            let eligibleFiles = originalFiles.isEmpty ? audioFiles : originalFiles
            // Some Archive items represent an album of individually downloadable
            // original MP3 files. Select only a uniquely named recording, never
            // an arbitrary album, concert mix, or generated derivative.
            let matches = eligibleFiles.filter { file in
                archiveFileCandidate(name: file.name, source: file.source,
                                     lengthBytes: file.length,
                                     itemTitle: metadata.title?.value ?? "",
                                     itemCreator: metadata.creator?.value ?? "",
                                     audioFileCount: eligibleFiles.count, wish: wish)
            }
            guard matches.count == 1, let file = matches.first else { continue }
            // Archive lengths are bytes, never time. The downloaded recording
            // is decoded and measured against Spotify's duration before saving.
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


// Openverse indexes openly-licensed audio from multiple original publishers.
// Only accept links to a single MP3 supplied by an explicitly supported source;
// never attempt Jamendo's download endpoint because its API terms prohibit
// building an offline-music caching application.
extension AudioSourceFinder {
    private struct OpenverseResponse: Decodable {
        let results: [OpenverseResult]
    }
    private struct OpenverseResult: Decodable {
        let title: String?
        let creator: String?
        let url: String?
        let foreign_landing_url: String?
        let license_url: String?
        let filetype: String?
        let duration: Double?
        let source: String?
        let filesize: Int?
    }

    static func openverseCandidate(
        title: String?, creator: String?, download: String?, landing: String?,
        license: String?, filetype: String?, duration: Double?, source: String?,
        filesize: Int?, wish: PlaylistWish
    ) -> AudioCatalogMatch? {
        guard let title, let creator, let source,
              ["wikimedia", "ccmixter", "fma"].contains(source.lowercased()),
              exactMetadataMatch(title: title.replacingOccurrences(of: "File:", with: "")
                                                  .replacingOccurrences(of: ".mp3", with: ""),
                                 creator: creator, wish: wish),
              let licenseURL = licensedURL(license),
              let download, let downloadURL = URL(string: download),
              let landing, let landingURL = URL(string: landing),
              downloadURL.scheme == "https", landingURL.scheme == "https",
              let host = downloadURL.host?.lowercased(), landingURL.host != nil,
              // Only accept direct files on the named publisher's trusted hosts.
              (
                  (source.lowercased() == "wikimedia" && host == "upload.wikimedia.org") ||
                  (source.lowercased() == "fma" && (host == "files.freemusicarchive.org" ||
                                                    host == "freemusicarchive.org")) ||
                  (source.lowercased() == "ccmixter" && (host == "ccmixter.org" ||
                                                         host.hasSuffix(".ccmixter.org")))
              ),
              downloadURL.pathExtension.lowercased() == "mp3",
              ["mp3", "audio/mpeg", "audio/mp3"].contains((filetype ?? "").lowercased()),
              filesize == nil || (filesize! > 0 && filesize! <= 100 * 1024 * 1024)
        else { return nil }

        if let expected = wish.durationSeconds, let duration {
            // Openverse API documents duration in milliseconds, including
            // short tracks. Never guess units based on an arbitrary threshold.
            let measured = duration / 1000.0
            guard abs(measured - expected) <= 4.0 else { return nil }
        }
        // Openverse supplies the creator, link and license but does not itself
        // certify that a publisher actually owns the recording.
        return AudioCatalogMatch(downloadURL: downloadURL, itemURL: landingURL,
                                 licenseURL: licenseURL, sourceName: "Openverse: \(source)")
    }

    static func findOpenverse(for wish: PlaylistWish) async throws -> AudioCatalogMatch? {
        guard !wish.artist.isEmpty, !wish.title.isEmpty else { return nil }
        // Openverse supports field-based search. Try title+creator first so
        // independent recordings don't get buried beneath general relevance
        // matches; use the broader query only if no unique eligible result.
        var firstSearchError: Error?
        for fieldSearch in [true, false] {
            try Task.checkCancellation()
            var components = URLComponents(string: "https://api.openverse.org/v1/audio/")!
            components.queryItems = [
                URLQueryItem(name: fieldSearch ? "title" : "q",
                             value: fieldSearch ? wish.title : "\"\(wish.title)\" \"\(wish.artist)\""),
                URLQueryItem(name: "extension", value: "mp3"),
                URLQueryItem(name: "page_size", value: "50")
            ]
            if fieldSearch {
                components.queryItems?.append(URLQueryItem(name: "creator", value: wish.artist))
            }
            // A failed focused request must not skip the broader lookup.
            // Keep errors retryable if no trustworthy result is found.
            let result: OpenverseResponse
            do {
                result = try await requestJSON(components.url!)
            } catch {
                if error is CancellationError { throw error }
                if firstSearchError == nil { firstSearchError = error }
                continue
            }
            let matches = result.results.compactMap {
                openverseCandidate(title: $0.title, creator: $0.creator, download: $0.url,
                                   landing: $0.foreign_landing_url, license: $0.license_url,
                                   filetype: $0.filetype, duration: $0.duration,
                                   source: $0.source, filesize: $0.filesize, wish: wish)
            }
            // Distinct candidate URLs may represent alternate performances.
            // Never choose one arbitrarily.
            let unique = Dictionary(grouping: matches, by: { $0.downloadURL.absoluteString })
            if unique.count == 1 { return unique.values.first?.first }
            if unique.count > 1 { return nil }
        }
        if let firstSearchError { throw firstSearchError }
        return nil
    }


    // Wikimedia Commons' MediaWiki file API is a separate upstream catalog:
    // Commons recordings may be absent from Openverse's index. Only explicit
    // machine-readable artist/license metadata and actual MP3 file URLs qualify.
    private struct CommonsResponse: Decodable { let query: CommonsQuery? }
    private struct CommonsQuery: Decodable { let pages: [String: CommonsPage] }
    private struct CommonsPage: Decodable {
        let title: String
        let imageinfo: [CommonsImage]?
    }
    private struct CommonsImage: Decodable {
        let url: String?
        let descriptionurl: String?
        let size: Int?
        let extmetadata: [String: CommonsField]?
    }
    private struct CommonsField: Decodable { let value: String }

    static func commonsCandidate(fileTitle: String, artistCredit: String?,
                                 download: String?, landing: String?,
                                 license: String?, bytes: Int?,
                                 wish: PlaylistWish) -> AudioCatalogMatch? {
        guard let artistCredit, !artistCredit.contains("<"),
              exactMetadataMatch(
                title: (fileTitle as NSString).lastPathComponent
                    .replacingOccurrences(of: "File:", with: "")
                    .replacingOccurrences(of: ".mp3", with: "", options: .caseInsensitive),
                creator: artistCredit.trimmingCharacters(in: .whitespacesAndNewlines),
                wish: wish),
              let licenseURL = licensedURL(license),
              let download, let audioURL = URL(string: download),
              audioURL.scheme == "https", audioURL.host?.lowercased() == "upload.wikimedia.org",
              audioURL.pathExtension.lowercased() == "mp3",
              let landing, let landingURL = URL(string: landing),
              landingURL.scheme == "https",
              landingURL.host?.lowercased() == "commons.wikimedia.org",
              bytes == nil || (bytes! > 0 && bytes! <= 100 * 1024 * 1024)
        else { return nil }
        return AudioCatalogMatch(downloadURL: audioURL, itemURL: landingURL,
                                 licenseURL: licenseURL, sourceName: "Wikimedia Commons")
    }

    static func findCommons(for wish: PlaylistWish) async throws -> AudioCatalogMatch? {
        guard !wish.title.isEmpty, !wish.artist.isEmpty else { return nil }
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: "\"\(wish.title)\" \"\(wish.artist)\""),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "20"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|size|extmetadata"),
            URLQueryItem(name: "iiextmetadatafilter", value: "Artist|LicenseUrl"),
            URLQueryItem(name: "format", value: "json")
        ]
        let result: CommonsResponse = try await requestJSON(components.url!)
        let matches = (result.query?.pages.values ?? Dictionary<String, CommonsPage>().values)
            .flatMap { page in
                (page.imageinfo ?? []).compactMap { info in
                    commonsCandidate(fileTitle: page.title,
                                     artistCredit: info.extmetadata?["Artist"]?.value,
                                     download: info.url, landing: info.descriptionurl,
                                     license: info.extmetadata?["LicenseUrl"]?.value,
                                     bytes: info.size, wish: wish)
                }
            }
        let unique = Dictionary(grouping: matches, by: { $0.downloadURL.absoluteString })
        return unique.count == 1 ? unique.values.first?.first : nil
    }

    static func findAcrossCatalogs(for wish: PlaylistWish) async throws -> AudioCatalogMatch? {
        try Task.checkCancellation()
        var firstError: Error?
        // Artist-enabled Audius tracks are a fast exact-match lookup; search
        // this endpoint before traversing up to 20 Archive metadata records.
        do {
            if let audius = try await findAudius(for: wish) { return audius }
        } catch {
            if error is CancellationError { throw error }
            firstError = error
        }
        try Task.checkCancellation()
        do {
            if let openverse = try await findOpenverse(for: wish) { return openverse }
        } catch {
            if error is CancellationError { throw error }
            if firstError == nil { firstError = error }
        }
        try Task.checkCancellation()
        do {
            if let commons = try await findCommons(for: wish) { return commons }
        } catch {
            if error is CancellationError { throw error }
            if firstError == nil { firstError = error }
        }
        try Task.checkCancellation()
        do {
            if let archive = try await find(for: wish) { return archive }
        } catch {
            if error is CancellationError { throw error }
            if firstError == nil { firstError = error }
        }
        // Network errors must not be recorded as permanent "unavailable".
        if let firstError { throw firstError }
        return nil
    }
}


// Audius exposes artist-enabled downloads through its public read-only API.
// We never use the streaming endpoint. Only exact, ungated, unambiguous
// downloadable recordings with compatible duration enter the download queue.
// Audius' Open Music License covers third-party music-player playback, subject
// to the uploader's access restrictions and alternative licensing choices.
extension AudioSourceFinder {
    private struct AudiusSearchResponse: Decodable {
        let data: [AudiusTrack]
    }
    struct AudiusTrack: Decodable {
        struct User: Decodable {
            let name: String?
            let handle: String?
        }
        let id: String
        let title: String
        let user: User?
        let duration: Double?
        let is_downloadable: Bool?
        let is_download_gated: Bool?
        let is_stream_gated: Bool?
        let is_unlisted: Bool?
        let download_conditions: AudiusGate?
        let permalink: String?
        let license: String?
        // Audius REST/SDK versions surface either "downloadable" or
        // "is_downloadable". Decode both; honor an explicit false.
        var downloadable: Bool? = nil
    }
    struct AudiusGate: Decodable {}

    static func audiusSearchURL(for wish: PlaylistWish) -> URL {
        var parts = URLComponents(string: "https://api.audius.co/v1/tracks/search")!
        parts.queryItems = [
            URLQueryItem(name: "query", value: "\(wish.artist) \(wish.title)"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "only_downloadable", value: "true")
        ]
        return parts.url!
    }

    static func audiusCandidate(_ track: AudiusTrack, for wish: PlaylistWish) -> AudioCatalogMatch? {
        guard (track.is_downloadable ?? track.downloadable) == true,
              track.is_download_gated != true,
              track.download_conditions == nil,
              track.is_stream_gated != true,
              track.is_unlisted != true,
              let creditedArtist = track.user?.name,
              exactMetadataMatch(title: track.title, creator: creditedArtist, wish: wish),
              !track.id.isEmpty, track.id.count <= 120,
              track.id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              let duration = track.duration, duration > 0, duration <= 3600,
              wish.durationSeconds.map({ abs($0 - duration) <= 4.0 }) ?? true
        else { return nil }

        // A permalink must identify a normal public Audius music page.
        let page: URL
        if let raw = track.permalink, let url = URL(string: raw),
           url.scheme?.lowercased() == "https",
           let host = url.host?.lowercased(),
           host == "audius.co" || host == "www.audius.co" {
            page = url
        } else {
            // The canonical track page cannot be derived reliably from an
            // API id alone: skip items without trustworthy attribution.
            return nil
        }
        // The public download endpoint serves MP3 by default; original=false
        // specifically avoids requesting an original file of unknown format.
        var download = URLComponents(string:
            "https://api.audius.co/v1/tracks/\(track.id)/download")!
        download.queryItems = [URLQueryItem(name: "original", value: "false")]
        guard let fileURL = download.url else { return nil }
        return AudioCatalogMatch(
            downloadURL: fileURL, itemURL: page,
            licenseURL: URL(string: "https://audius.org/open-music-license.pdf")!,
            sourceName: "Audius (artist-enabled download)")
    }

    static func findAudius(for wish: PlaylistWish) async throws -> AudioCatalogMatch? {
        guard !wish.artist.isEmpty, !wish.title.isEmpty else { return nil }
        let response: AudiusSearchResponse = try await requestJSON(audiusSearchURL(for: wish))
        let matched = response.data.compactMap { audiusCandidate($0, for: wish) }
        let unique = Dictionary(grouping: matched, by: { $0.downloadURL.absoluteString })
        // Two exact-looking recordings are ambiguous even when both providers
        // label them as downloadable. Do not silently choose one.
        return unique.count == 1 ? unique.values.first?.first : nil
    }
}


// Optional web-wide discovery. Unlike the licensed catalog adapters, these
// are search-engine results: pages are NOT assumed to be directly downloadable
// or authorized. The user examines the source before supplying a permitted file.
#if canImport(Security)
import Security
#endif

struct WebAudioSearchResult: Identifiable {
    let title: String
    let description: String
    let url: URL
    var id: String { url.absoluteString }
    var isDirectAudio: Bool {
        ["mp3", "m4a", "aac", "wav", "aif", "aiff"].contains(url.pathExtension.lowercased())
    }
}

enum WebAudioSearch {
    private static let service = "MP3Shelf.WebAudioSearch"
    private static let account = "brave-search-key"

    private struct Response: Decodable {
        let web: Web?
        struct Web: Decodable { let results: [Hit] }
        struct Hit: Decodable {
            let title: String?
            let description: String?
            let url: String?
        }
    }

    enum SearchFailure: LocalizedError {
        case missingKey, rejectedKey, rateLimited, unavailable, invalidResponse
        var errorDescription: String? {
            switch self {
            case .missingKey: return "Add a Brave Search API key to search web results inside MP3 Shelf."
            case .rejectedKey: return "The search provider rejected the API key. Check the key in Web Search."
            case .rateLimited: return "Web search hit its rate or credit limit. Retry later or use browser search."
            case .unavailable: return "The web search provider is unavailable. Retry or open the browser search."
            case .invalidResponse: return "The web search provider returned an unexpected response."
            }
        }
    }

    enum SearchDepth: Int, CaseIterable, Identifiable {
        case quick = 1, thorough = 3, extensive = 5
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .quick: return "Quick • 1 search/song"
            case .thorough: return "Thorough • 3 searches/song"
            case .extensive: return "Extensive • 5 searches/song"
            }
        }
    }

    enum BrowserProvider: String, CaseIterable, Identifiable {
        case brave = "Brave"
        case google = "Google"
        case bing = "Bing"
        case duckDuckGo = "DuckDuckGo"
        case bandcamp = "Bandcamp"
        case soundCloud = "SoundCloud"
        case archive = "Internet Archive"
        case freeMusicArchive = "Free Music Archive"
        case ccMixter = "ccMixter"
        case audius = "Audius"
        var id: String { rawValue }
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\""
    }

    static func searchQuery(for wish: PlaylistWish) -> String {
        "\(quoted(wish.artist)) \(quoted(wish.title)) download"
    }

    static func searchQueries(for wish: PlaylistWish, depth: SearchDepth) -> [String] {
        let target = "\(quoted(wish.artist)) \(quoted(wish.title))"
        let queries = [
            searchQuery(for: wish),
            "\(target) site:bandcamp.com OR site:soundcloud.com",
            "\(target) filetype:mp3",
            "\(target) official digital music download",
            "\(target) site:archive.org OR site:freemusicarchive.org OR site:ccmixter.org"
        ]
        return Array(queries.prefix(depth.rawValue))
    }

    static func browserURL(for wish: PlaylistWish,
                           provider: BrowserProvider = .brave) -> URL {
        let query = "\(wish.artist) \(wish.title)"
        let base: String
        let key: String
        let term: String
        switch provider {
        case .brave:
            base = "https://search.brave.com/search"; key = "q"
            term = searchQuery(for: wish)
        case .google:
            base = "https://www.google.com/search"; key = "q"; term = query + " mp3 download"
        case .bing:
            base = "https://www.bing.com/search"; key = "q"; term = query + " audio download"
        case .duckDuckGo:
            base = "https://duckduckgo.com/"; key = "q"; term = query + " download"
        case .bandcamp:
            base = "https://bandcamp.com/search"; key = "q"; term = query
        case .soundCloud:
            base = "https://soundcloud.com/search/sounds"; key = "q"; term = query
        case .archive:
            base = "https://archive.org/search"; key = "query"; term = query
        case .freeMusicArchive:
            base = "https://www.google.com/search"; key = "q"
            term = query + " site:freemusicarchive.org"
        case .ccMixter:
            base = "https://www.google.com/search"; key = "q"
            term = query + " site:ccmixter.org"
        case .audius:
            base = "https://www.google.com/search"; key = "q"
            term = query + " site:audius.co"
        }
        var parts = URLComponents(string: base)!
        parts.queryItems = [URLQueryItem(name: key, value: term)]
        return parts.url!
    }

    static func sanitizedResultURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              !host.hasSuffix(".onion"), host != "localhost",
              // Do not connect to raw IP addresses, including loopback,
              // private ranges, link-local and IPv6 literals.
              !host.contains(":"),
              host.range(of: #"^[0-9]+(\.[0-9]+){3}$"#,
                         options: .regularExpression) == nil,
              !["open.spotify.com", "accounts.spotify.com"].contains(host)
        else { return nil }
        return url
    }

    /// Rank likely artist/title references and direct file links first.
    /// Scores are only navigation hints, never evidence of license or identity.
    static func resultScore(_ hit: WebAudioSearchResult, for wish: PlaylistWish) -> Int {
        let combined = MusicMatching.key(hit.title + " " + hit.description +
                                         " " + hit.url.lastPathComponent)
        let title = MusicMatching.key(wish.title)
        let artist = MusicMatching.key(wish.artist)
        let titlePresent = !title.isEmpty && combined.contains(title)
        let artistPresent = !artist.isEmpty && combined.contains(artist)
        var score = hit.isDirectAudio ? 40 : 0
        if titlePresent { score += 20 }
        if artistPresent { score += 20 }
        if titlePresent && artistPresent { score += 40 }
        return score
    }

    /// Choose a small, relevant set of source pages to inspect for declared
    /// downloadable media. A hit needs at least title or artist evidence;
    /// arbitrary low-relevance pages are excluded from automatic page reads.
    static func pagesWorthInspecting(_ hits: [WebAudioSearchResult],
                                     for wish: PlaylistWish, limit: Int) -> [WebAudioSearchResult] {
        guard limit > 0 else { return [] }
        return hits.enumerated()
            .filter { !$0.element.isDirectAudio &&
                      resultScore($0.element, for: wish) >= 20 }
            .sorted { left, right in
                let a = resultScore(left.element, for: wish)
                let b = resultScore(right.element, for: wish)
                return a == b ? left.offset < right.offset : a > b
            }
            .prefix(limit)
            .map(\.element)
    }

    private static func duplicateKey(for url: URL) -> String {
        // Result pages commonly differ only by #fragments or tracking query
        // parameters. Keep their original URLs for navigation and downloads.
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        let filteredItems = parts?.queryItems?.filter {
            let name = $0.name.lowercased()
            return !name.hasPrefix("utm_") && !["fbclid", "gclid"].contains(name)
        }
        parts?.queryItems = filteredItems
        return parts?.url?.absoluteString ?? url.absoluteString
    }

    static func search(for wish: PlaylistWish, using apiKey: String,
                       depth: SearchDepth = .quick) async throws -> [WebAudioSearchResult] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SearchFailure.missingKey }
        var merged: [WebAudioSearchResult] = []
        var seen: Set<String> = []
        var firstError: Error?
        // Query variants improve coverage while keeping total network/API
        // usage explicit and user-selectable. Never download search hits here.
        for query in searchQueries(for: wish, depth: depth) {
            try Task.checkCancellation()
            var parts = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            parts.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "count", value: "20"),
                URLQueryItem(name: "search_lang", value: "en"),
                URLQueryItem(name: "result_filter", value: "web")
            ]
            var request = URLRequest(url: parts.url!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
            request.timeoutInterval = 20
            do {
                let (bytes, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw SearchFailure.invalidResponse
                }
                switch http.statusCode {
                case 200: break
                case 401, 403: throw SearchFailure.rejectedKey
                case 429: throw SearchFailure.rateLimited
                default: throw SearchFailure.unavailable
                }
                guard bytes.count <= 2_000_000,
                      let page = try? JSONDecoder().decode(Response.self, from: bytes)
                else { throw SearchFailure.invalidResponse }
                for hit in page.web?.results ?? [] {
                    guard let url = sanitizedResultURL(hit.url),
                          seen.insert(duplicateKey(for: url)).inserted else { continue }
                    let title = hit.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    merged.append(WebAudioSearchResult(
                        title: title.isEmpty ? url.host ?? "Web result" : title,
                        description: hit.description ?? "",
                        url: url
                    ))
                    if merged.count >= 75 { break }
                }
                if merged.count >= 75 { break }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Authentication and credit limits cannot be solved by trying
                // another query; stop rather than making extra paid calls.
                if let problem = error as? SearchFailure {
                    switch problem {
                    case .rejectedKey, .rateLimited: throw error
                    default: break
                    }
                }
                if firstError == nil { firstError = error }
            }
        }
        if merged.isEmpty, let firstError { throw firstError }
        // Stable ranking keeps equally-scored items in provider discovery
        // order and prioritizes files/links with both title and artist text.
        return merged.enumerated().sorted { a, b in
            let lhs = resultScore(a.element, for: wish)
            let rhs = resultScore(b.element, for: wish)
            return lhs == rhs ? a.offset < b.offset : lhs > rhs
        }.map(\.element)
    }

    static func loadKey() -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        var values = query
        values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        values[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(values as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }
}


// A conservative, read-only landing-page inspector. It finds direct audio URLs
// explicitly advertised in HTML or AudioObject metadata; it does not run
// JavaScript, follow streaming manifests, scrape media players or bypass DRM.
// Candidates still require user approval and normal download validation.
enum AudioLandingPageInspector {
    enum InspectionError: LocalizedError {
        case invalidURL, unsupportedPage, oversizedPage, redirect, network
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Only public HTTPS music pages can be inspected."
            case .unsupportedPage: return "This page did not return readable HTML."
            case .oversizedPage: return "The source page is too large for safe inspection."
            case .redirect: return "This page redirects elsewhere. Open it in the browser to inspect the publisher."
            case .network: return "Could not inspect this page. Open it in your browser."
            }
        }
    }

    private static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff"
    ]
    private static let supportedMIMEs: Set<String> = [
        "audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a",
        "audio/aac", "audio/wav", "audio/x-wav", "audio/aiff",
        "audio/x-aiff"
    ]

    static func isVerifiedAudioResponse(_ response: HTTPURLResponse) -> Bool {
        guard (200...299).contains(response.statusCode),
              let mime = response.mimeType?.lowercased(),
              supportedMIMEs.contains(mime),
              response.expectedContentLength <= 100 * 1024 * 1024
        else { return false }
        return true
    }

    static func candidateURL(_ value: String, relativeTo page: URL,
                             explicitlyDownloadable: Bool = false) -> URL? {
        let decoded = value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard decoded.count <= 2_048,
              let url = URL(string: decoded, relativeTo: page)?.absoluteURL,
              let safe = WebAudioSearch.sanitizedResultURL(url.absoluteString)
        else { return nil }

        let fileExtension = safe.pathExtension.lowercased()
        if supportedExtensions.contains(fileExtension) { return safe }

        // Publishers sometimes use /download?id=123 rather than a .mp3
        // suffix. Only consider these when the HTML explicitly describes
        // an audio link. The live HEAD response must also verify audio MIME.
        let excluded: Set<String> = [
            "m3u", "m3u8", "mpd", "pls", "asx", "html", "htm",
            "json", "xml", "js", "css", "pdf"
        ]
        return explicitlyDownloadable && !excluded.contains(fileExtension) ? safe : nil
    }

    /// Read <audio>, <source>, <a download> and audio <meta> tags, plus
    /// Schema.org AudioObject.contentUrl. Only HTTPS file URLs are surfaced.
    static func candidates(in html: String, pageURL: URL) -> [URL] {
        guard WebAudioSearch.sanitizedResultURL(pageURL.absoluteString) != nil,
              html.utf8.count <= 1_000_000 else { return [] }
        // Prefer explicit publisher-declared audio/download metadata over
        // arbitrary <a href="track.mp3"> links on a compilation page.
        // Preserve discovered order within each confidence tier.
        var declared: [URL] = []
        var linked: [URL] = []
        var seen = Set<String>()
        func add(_ raw: String, explicitlyDownloadable: Bool = false,
                 publisherDeclared: Bool = false) {
            guard let url = candidateURL(raw, relativeTo: pageURL,
                                         explicitlyDownloadable: explicitlyDownloadable),
                  seen.insert(url.absoluteString).inserted else { return }
            if publisherDeclared {
                if declared.count < 25 { declared.append(url) }
            } else if linked.count < 25 {
                linked.append(url)
            }
        }

        func attributes(_ tag: String) -> [String: String] {
            var result: [String: String] = [:]
            let pattern = #"([A-Za-z_][A-Za-z0-9_:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
            let value = tag as NSString
            for match in regex.matches(in: tag, range: NSRange(location: 0, length: value.length)) {
                let name = value.substring(with: match.range(at: 1)).lowercased()
                let attribute = (2...4).first { match.range(at: $0).location != NSNotFound }
                    .map { value.substring(with: match.range(at: $0)) } ?? ""
                result[name] = attribute
            }
            return result
        }
        let tagPattern = #"<(?:a|audio|source|meta|link)\b[^>]*>"#
        if let regex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]) {
            let value = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: value.length)) {
                let tag = value.substring(with: match.range)
                let lower = tag.lowercased()
                let attrs = attributes(tag)
                if lower.hasPrefix("<meta") {
                    let property = (attrs["property"] ?? attrs["name"] ?? "").lowercased()
                    if ["og:audio", "og:audio:secure_url", "twitter:player:stream"].contains(property),
                       let url = attrs["content"] {
                        add(url, explicitlyDownloadable: true, publisherDeclared: true)
                    }
                } else if (lower.hasPrefix("<a") && !lower.hasPrefix("<audio")) ||
                          lower.hasPrefix("<link") {
                    if let url = attrs["href"] {
                        let isDownload = lower.hasPrefix("<a") &&
                            tag.range(of: #"\sdownload(?:\s|=|>)"#,
                                      options: [.regularExpression, .caseInsensitive]) != nil
                        let audioType = supportedMIMEs.contains(
                            attrs["type"]?.lowercased() ?? "")
                        add(url, explicitlyDownloadable: isDownload || audioType,
                            publisherDeclared: isDownload || audioType)
                    }
                } else if let url = attrs["src"] {
                    let audioType = supportedMIMEs.contains(
                        attrs["type"]?.lowercased() ?? "")
                    let audioElement = lower.hasPrefix("<audio")
                    add(url, explicitlyDownloadable: audioType || audioElement,
                        publisherDeclared: audioType || audioElement)
                }
            }
        }

        // Schema.org documents may embed a direct downloadable file in
        // <script type="application/ld+json"> ... AudioObject.contentUrl.
        let scriptPattern = #"<script\b([^>]*)>(.*?)</script\s*>"#
        if let regex = try? NSRegularExpression(
            pattern: scriptPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let value = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: value.length)) {
                let tag = value.substring(with: match.range(at: 1))
                guard attributes(tag)["type"]?.lowercased() == "application/ld+json" else { continue }
                let json = value.substring(with: match.range(at: 2))
                guard let data = json.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data)
                else { continue }
                func walk(_ node: Any, depth: Int) {
                    guard depth < 12, declared.count < 25 else { return }
                    if let dictionary = node as? [String: Any] {
                        let types = ([dictionary["@type"] as? String].compactMap { $0 } +
                                     (dictionary["@type"] as? [String] ?? []))
                        if types.contains(where: { $0.lowercased().hasSuffix("audioobject") }),
                           let raw = dictionary["contentUrl"] as? String {
                            add(raw, explicitlyDownloadable: true, publisherDeclared: true)
                        }
                        for nested in dictionary.values { walk(nested, depth: depth + 1) }
                    } else if let array = node as? [Any] {
                        for nested in array { walk(nested, depth: depth + 1) }
                    }
                }
                walk(root, depth: 0)
            }
        }
        return Array((declared + linked).prefix(25))
    }

    /// Reject redirects before they reach a local network host or a different
    /// publisher; let the user follow redirects in a normal browser instead.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func inspect(_ pageURL: URL, maxProbes: Int = 8) async throws -> [URL] {
        guard WebAudioSearch.sanitizedResultURL(pageURL.absoluteString) != nil,
              pageURL.port == nil || pageURL.port == 443 else {
            throw InspectionError.invalidURL
        }
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 12
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-999999", forHTTPHeaderField: "Range")
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // Stream only bounded HTML into memory. The Range header is a hint,
        // not a guarantee: servers can ignore it and return gigabytes.
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw InspectionError.network }
        if (300...399).contains(http.statusCode) { throw InspectionError.redirect }
        guard http.statusCode == 200 || http.statusCode == 206,
              ["text/html", "application/xhtml+xml"].contains(http.mimeType?.lowercased() ?? "")
        else { throw InspectionError.unsupportedPage }
        let maximumBytes = 1_000_000
        if http.expectedContentLength > Int64(maximumBytes) {
            throw InspectionError.oversizedPage
        }
        var data = Data()
        data.reserveCapacity(min(Int(max(0, http.expectedContentLength)), maximumBytes))
        for try await byte in stream {
            try Task.checkCancellation()
            if data.count >= maximumBytes { throw InspectionError.oversizedPage }
            data.append(byte)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw InspectionError.unsupportedPage
        }
        let links = candidates(in: html, pageURL: pageURL)
        var accepted: [URL] = []
        var probed = 0
        for link in links {
            try Task.checkCancellation()
            if supportedExtensions.contains(link.pathExtension.lowercased()) {
                accepted.append(link)
                continue
            }
            // An extensionless endpoint might return a web page, an audio
            // stream or a protected download. HEAD must confirm supported
            // downloadable audio before offering it to the user.
            guard probed < max(0, min(maxProbes, 8)) else { continue }
            probed += 1
            var probe = URLRequest(url: link)
            probe.httpMethod = "HEAD"
            probe.timeoutInterval = 8
            probe.setValue("audio/*", forHTTPHeaderField: "Accept")
            if let result = try? await session.data(for: probe),
               let http = result.1 as? HTTPURLResponse,
               isVerifiedAudioResponse(http) {
                accepted.append(link)
            }
        }
        return accepted
    }
}
