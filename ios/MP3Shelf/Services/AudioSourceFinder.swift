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
            let result: OpenverseResponse = try await requestJSON(components.url!)
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
        do {
            if let archive = try await find(for: wish) { return archive }
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
        // Network errors must not be recorded as permanent "unavailable".
        if let firstError { throw firstError }
        return nil
    }
}
