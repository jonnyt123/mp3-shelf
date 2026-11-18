import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Catalog discovery uses actual public file listings and recording metadata.
enum AudioSourceFinder {
    struct FlexibleText: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let item = try decoder.singleValueContainer()
            if let string = try? item.decode(String.self) { value = string }
            else if let strings = try? item.decode([String].self) { value = strings.first ?? "" }
            else { value = "" }
        }
    }
    struct SearchResponse: Decodable { let response: SearchBody }
    // Archive indexes occasionally include null or malformed records. Preserve
    // valid siblings, but retain the raw page count for pagination and budget
    // accounting: silently shrinking the page could authorize a false unique
    // automatic match when an uninspected recording was present.
    struct SearchBody: Decodable {
        let docs: [SearchItem]
        let numFound: Int?
        let rawItemCount: Int

        private enum CodingKeys: String, CodingKey { case docs, numFound }
        private struct LossyItem: Decodable {
            let value: SearchItem?
            init(from decoder: Decoder) throws {
                value = try? SearchItem(from: decoder)
            }
        }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            let entries = try fields.decode([LossyItem].self, forKey: .docs)
            rawItemCount = entries.count
            docs = entries.compactMap(\.value)
            numFound = try? fields.decode(Int.self, forKey: .numFound)
        }
    }
    struct SearchItem: Decodable {
        let identifier: String
        let title: FlexibleText?
        let creator: FlexibleText?
    }
    struct ArchiveItem: Decodable {
        let metadata: ItemMetadata?
        let files: [ArchiveFile]?
        let hasMalformedFileRows: Bool

        private enum CodingKeys: String, CodingKey { case metadata, files }

        // One corrupt file entry must not hide a valid recording in the same
        // Archive item. Each surviving file still passes exact-match and
        // downloaded-byte validation before it can enter the library.
        private struct LossyFile: Decodable {
            let value: ArchiveFile?
            init(from decoder: Decoder) throws {
                value = try? ArchiveFile(from: decoder)
            }
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            metadata = try? fields.decode(ItemMetadata.self, forKey: .metadata)
            if let rows = try? fields.decode([LossyFile].self, forKey: .files) {
                hasMalformedFileRows = rows.contains { $0.value == nil }
                files = rows.compactMap(\.value)
            } else {
                hasMalformedFileRows = true
                files = nil
            }
        }
    }
    struct ItemMetadata: Decodable {
        let title: FlexibleText?
        let creator: FlexibleText?
        let licenseurl: FlexibleText?
    }
    struct ArchiveFile: Decodable {
        let name: String
        let source: String?
        let size: String?
        // Archive's per-file values may be JSON strings or numbers.
        // Invalid optional evidence must not discard an otherwise readable
        // catalog item; candidate validation still rejects bad durations.
        let length: String?
        // A present but unreadable size must not silently become absent evidence.
        let hasInvalidSize: Bool
        let hasInvalidLength: Bool

        private enum CodingKeys: String, CodingKey {
            case name, source, size, length
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            name = try fields.decode(String.self, forKey: .name)
            source = try? fields.decode(String.self, forKey: .source)
            size = Self.optionalNumberText(fields, key: .size)
            hasInvalidSize = fields.contains(.size) && size == nil
            length = Self.optionalNumberText(fields, key: .length)
            hasInvalidLength = fields.contains(.length) && length == nil
        }

        private static func optionalNumberText(
            _ fields: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
        ) -> String? {
            if let value = try? fields.decode(String.self, forKey: key) { return value }
            if let value = try? fields.decode(Int64.self, forKey: key) {
                return String(value)
            }
            if let value = try? fields.decode(Double.self, forKey: key),
               value.isFinite {
                return String(value)
            }
            return nil
        }
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

    /// Network permission is attached to each individual catalog request,
    /// not merely checked once before starting a playlist scan. This prevents
    /// an in-flight lookup silently switching to cellular when Wi-Fi drops.
    static func catalogRequest(for url: URL, allowsCellular: Bool = false) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsCellular
        request.allowsConstrainedNetworkAccess = allowsCellular
        request.setValue("MP3Shelf/1.1 (personal offline audio library)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Catalog lookups never forward metadata requests to an unexpected host.
    /// URLSession.shared follows redirects and can silently change the origin;
    /// reject them so each catalog's explicit endpoint remains authoritative.
    private final class CatalogRedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let catalogSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration,
                          delegate: CatalogRedirectBlocker(), delegateQueue: nil)
    }()

    static func validatedCatalogBody(_ data: Data, response: URLResponse,
                                     maximumBytes: Int) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        guard http.statusCode == 200 else { throw SourceError.http(http.statusCode) }
        guard !data.isEmpty, data.count <= maximumBytes else { throw SourceError.invalidResponse }
        return data
    }

    private static func requestCatalogData(_ url: URL, allowsCellular: Bool,
                                           maximumBytes: Int) async throws -> Data {
        let request = catalogRequest(for: url, allowsCellular: allowsCellular)
        let (data, response) = try await catalogSession.data(for: request)
        return try validatedCatalogBody(data, response: response, maximumBytes: maximumBytes)
    }

    private static func requestJSON<T: Decodable>(
        _ url: URL, allowsCellular: Bool = false
    ) async throws -> T {
        let data = try await requestCatalogData(
            url, allowsCellular: allowsCellular, maximumBytes: 1_999_999)
        return try JSONDecoder().decode(T.self, from: data)
    }

    enum SourceError: LocalizedError {
        case unavailable
        case http(Int)
        case invalidResponse
        case catalogsUnavailable([String])
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Some catalog item details could not be read."
            case .http(let status):
                switch status {
                case 401, 403: return "Catalog refused the request (HTTP \(status))."
                case 429: return "Catalog rate limit reached (HTTP 429)."
                default: return "Catalog returned HTTP \(status)."
                }
            case .invalidResponse: return "Catalog returned an unreadable response."
            case .catalogsUnavailable(let failures):
                return "No catalogs could complete the search. " + failures.joined(separator: " • ")
            }
        }
    }

    /// Archive file.size is bytes; file.length is duration and may be decimal.
    /// The importer validates the actual recording duration after download.
    /// Albums are allowed only when exactly one original file has a filename
    /// explicitly matching the requested song and the item credits its artist.
    static func archiveFileCandidate(name: String, source: String?, sizeBytes: String?,
                                      itemTitle: String, itemCreator: String,
                                      audioFileCount: Int, wish: PlaylistWish) -> Bool {
        guard safeMP3File(name), MusicMatching.key(itemCreator) == MusicMatching.key(wish.artist),
              !MusicMatching.key(wish.artist).isEmpty else { return false }
        if let sizeBytes {
            guard let bytes = Int64(sizeBytes), bytes > 0,
                  bytes <= 100 * 1024 * 1024 else { return false }
        }
        // A lone generated derivative is not the original recording. Archive
        // metadata can contain only a transcode after the source was removed.
        // Missing source is tolerated for legacy uploads, but an explicit
        // non-original classification must never be auto-imported.
        guard source == nil || source == "original" else { return false }
        if audioFileCount == 1 {
            return exactMetadataMatch(title: itemTitle, creator: itemCreator, wish: wish)
        }
        guard source == "original" else { return false }
        let title = MusicMatching.key(wish.title)
        let stem = (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        // Preserve exact numeric titles first; only strip explicit track-number
        // separators, never arbitrary leading digits (e.g. "99 Red Balloons").
        let withoutTrackNumber = (name as NSString).deletingPathExtension.replacingOccurrences(
            of: #"^\s*[0-9]{1,3}\s*[._-]\s*"#, with: "", options: .regularExpression).replacingOccurrences(of: "_", with: " ")
        let artistTitle = MusicMatching.key("\(wish.artist) - \(wish.title)")
        return !title.isEmpty && [stem, withoutTrackNumber].contains { candidate in
            let key = MusicMatching.key(candidate)
            return key == title || key == artistTitle
        }
    }

    // Avoid spending an entire iOS background processing window on up to
    // 40 sequential Archive metadata requests for a single Spotify song.
    // Prefer likely exact hits and leave time for the next playlist track.
    enum ArchiveLookupBudget {
        static let maxDetailRequestsPerPage = 8
        static let maxElapsedSeconds: TimeInterval = 45

        static func canRequestDetails(completed: Int, startedAt: Date,
                                      now: Date) -> Bool {
            completed >= 0 && completed < maxDetailRequestsPerPage &&
                now.timeIntervalSince(startedAt) < maxElapsedSeconds
        }

        static func stillWithinWindow(startedAt: Date, now: Date) -> Bool {
            now.timeIntervalSince(startedAt) < maxElapsedSeconds
        }
    }

    static func archiveSearchRowsComplete(_ body: SearchBody) -> Bool {
        // A syntactically decoded row with an unsafe identifier is still an
        // uninspected recording. Skipping it must not make another file appear
        // uniquely identified for unattended download.
        // Inconsistent totals can conceal omitted recordings. A catalog page
        // claiming fewer total hits than returned rows is not a trustworthy
        // uniqueness proof, even if every returned identifier is valid.
        body.docs.count == body.rawItemCount &&
            body.numFound.map { $0 >= body.rawItemCount && $0 >= 0 } != false &&
            body.docs.allSatisfy { safeIdentifier($0.identifier) } &&
            archiveIndexDuplicatesAgree(body.docs)
    }

    // An identifier may appear repeatedly in the index. Contradictory
    // title/creator evidence cannot be silently discarded by the later
    // inspectedIdentifiers dedupe, which would otherwise permit a false
    // unique automatic recording selection.
    static func archiveIndexDuplicatesAgree(_ docs: [SearchItem]) -> Bool {
        var identities: [String: String] = [:]
        for doc in docs {
            let identity = MusicMatching.key(doc.title?.value ?? "") + "\u{0}" +
                MusicMatching.key(doc.creator?.value ?? "")
            if let previous = identities[doc.identifier], previous != identity {
                return false
            }
            identities[doc.identifier] = identity
        }
        return true
    }

    // A short page before the reported total is exhausted may indicate a
    // truncated index response. Treat it as incomplete, not a final page.
    static func archivePageComplete(page: Int, rows: Int, reportedTotal: Int?) -> Bool {
        guard page > 0, rows >= 0, rows <= 20 else { return false }
        guard let reportedTotal else { return rows < 20 }
        let preceding = (page - 1) * 20
        guard reportedTotal >= preceding + rows else { return false }
        return rows == min(20, max(0, reportedTotal - preceding))
    }

    static let maxArchiveSearchPages = 2

    static func archiveIndexRelevance(title: String, creator: String,
                                      for wish: PlaylistWish) -> Int {
        let titleScore = MusicMatching.key(title) == MusicMatching.key(wish.title) ? 2 : 0
        let creatorScore = MusicMatching.key(creator) == MusicMatching.key(wish.artist) ? 1 : 0
        return titleScore + creatorScore
    }

    static func archiveSearchURL(for wish: PlaylistWish, page: Int) -> URL {
        // Archive advanced-search treats punctuation as query syntax even inside
        // quoted values. Keep human-readable recording terms, but never allow
        // playlist metadata to inject fields, boolean operators or wildcards.
        func escaped(_ value: String) -> String {
            let words = value.unicodeScalars.map { scalar -> String in
                if CharacterSet.alphanumerics.contains(scalar) ||
                   scalar == " " || scalar == "-" || scalar == "'" {
                    return String(scalar)
                }
                return " "
            }.joined()
            return words.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        var query = URLComponents(string: "https://archive.org/advancedsearch.php")!
        query.queryItems = [
            URLQueryItem(name: "q", value: "mediatype:audio AND (title:(\"\(escaped(wish.title))\") OR description:(\"\(escaped(wish.title))\")) AND creator:(\"\(escaped(wish.artist))\")"),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "creator"),
            URLQueryItem(name: "rows", value: "20"),
            URLQueryItem(name: "page", value: String(max(1, min(page, maxArchiveSearchPages)))),
            URLQueryItem(name: "output", value: "json")
        ]
        return query.url!
    }

    static func find(for wish: PlaylistWish,
                     allowsCellular: Bool = false) async throws -> AudioCatalogMatch? {
        guard !wish.title.isEmpty, !wish.artist.isEmpty else { return nil }
        // The public search API supports pagination. Within a finite time
        // budget prioritize likely exact title/artist entries before probing
        // Archive item metadata. All files still require full verification.
        let lookupStartedAt = Date()
        var detailLookupFailed = false
        // A budget-truncated scan cannot prove a sole candidate is unique.
        // Keep the result retryable instead of auto-downloading a possibly
        // different recording hidden in the uninspected results.
        var searchIncomplete = false
        var uniqueCandidates: [URL: AudioCatalogMatch] = [:]
        // Archive can repeat an identifier within and across search pages.
        // A duplicate is not another recording and must not consume a scarce
        // metadata request or conceal a distinct result behind the budget.
        var inspectedIdentifiers: Set<String> = []
        var expectedIndexTotal: Int?
        for page in 1...maxArchiveSearchPages {
            try Task.checkCancellation()
            guard ArchiveLookupBudget.stillWithinWindow(
                startedAt: lookupStartedAt, now: Date()) else {
                searchIncomplete = true
                break
            }
            let search: SearchResponse = try await requestJSON(
                archiveSearchURL(for: wish, page: page),
                allowsCellular: allowsCellular)
            // A malformed search row can conceal another exact recording. Do not
            // turn a lossy page into a falsely unique automatic selection.
            // Preserve a retryable incomplete-search result even when a valid
            // candidate appears in the remaining rows.
            if !archiveSearchRowsComplete(search.response) {
                searchIncomplete = true
            }
            if !archivePageComplete(page: page, rows: search.response.rawItemCount,
                                    reportedTotal: search.response.numFound) {
                searchIncomplete = true
            }
            // A changing total between pages means the index snapshot was not
            // stable. Do not infer a unique recording from inconsistent pages.
            if let reported = search.response.numFound {
                if let previous = expectedIndexTotal, previous != reported {
                    searchIncomplete = true
                }
                expectedIndexTotal = reported
            }
            let ranked = search.response.docs.enumerated().sorted { left, right in
                let l = archiveIndexRelevance(
                    title: left.element.title?.value ?? "",
                    creator: left.element.creator?.value ?? "", for: wish)
                let r = archiveIndexRelevance(
                    title: right.element.title?.value ?? "",
                    creator: right.element.creator?.value ?? "", for: wish)
                return l == r ? left.offset < right.offset : l > r
            }
            var detailRequests = 0
            for entry in ranked {
                try Task.checkCancellation()
                let result = entry.element
                guard safeIdentifier(result.identifier),
                      !inspectedIdentifiers.contains(result.identifier) else { continue }
                guard ArchiveLookupBudget.canRequestDetails(
                    completed: detailRequests, startedAt: lookupStartedAt,
                    now: Date()) else {
                    // A valid, previously unseen identifier remains uninspected.
                    // Duplicates and malformed rows cannot invalidate coverage.
                    searchIncomplete = true
                    break
                }
                inspectedIdentifiers.insert(result.identifier)
                detailRequests += 1
                let metadataURL = URL(string: "https://archive.org/metadata/")!
                    .appendingPathComponent(result.identifier)
                let item: ArchiveItem
                do {
                    item = try await requestJSON(metadataURL, allowsCellular: allowsCellular)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    detailLookupFailed = true
                    continue
                }
                if let match = archiveCandidate(item, identifier: result.identifier, for: wish) {
                    uniqueCandidates[match.downloadURL] = match
                    // Different Archive files may be distinct editions with
                    // identical text metadata. Never auto-select arbitrarily.
                    if uniqueCandidates.count > 1 { return nil }
                }
            }
            if !ArchiveLookupBudget.stillWithinWindow(
                startedAt: lookupStartedAt, now: Date()) {
                searchIncomplete = true
                break
            }
            // Archive's numFound is the authoritative total. A full final
            // page is not necessarily incomplete when exactly 40 hits exist.
            // If the count is absent, conservatively infer continuation from
            // a full page rather than silently authorizing a false match.
            let inspectedThrough = page * 20
            let hasMorePages = search.response.numFound.map { inspectedThrough < $0 }
                ?? (search.response.rawItemCount >= 20)
            if !hasMorePages { break }
            if page == maxArchiveSearchPages {
                searchIncomplete = true
            }
        }
        // An unreadable item may contain the requested recording. Allow the
        // caller's bounded retries instead of persisting a false no-match.
        if detailLookupFailed || searchIncomplete { throw SourceError.unavailable }
        return uniqueCandidates.count == 1 ? uniqueCandidates.values.first : nil
    }

    /// Archive metadata may encode duration as seconds or a clock timestamp.
    /// Parse the entire value; malformed or overflowing fields cannot authorize
    /// an unattended recording match.
    static func archiveDurationSeconds(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if !raw.contains(":") {
            guard let seconds = Double(raw), seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        }
        let fields = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else { return nil }
        var total = 0.0
        for (index, field) in fields.enumerated() {
            guard !field.isEmpty, field.count <= 8,
                  field.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  let value = Double(field), value.isFinite, value >= 0 else { return nil }
            // Only the final (seconds) component may contain fractions.
            if index < fields.count - 1 && value.rounded(.towardZero) != value { return nil }
            if index > 0 && value >= 60 { return nil }
            total = total * 60 + value
        }
        return total.isFinite && total > 0 ? total : nil
    }

    static func archiveCandidate(_ item: ArchiveItem, identifier: String,
                                 for wish: PlaylistWish) -> AudioCatalogMatch? {
        // An unreadable sibling may be another original recording.
        // Never treat the remaining file as uniquely identified.
        guard safeIdentifier(identifier), let metadata = item.metadata,
              !item.hasMalformedFileRows else { return nil }
        let audioFiles = (item.files ?? []).filter { safeMP3File($0.name) }
        let originals = audioFiles.filter { $0.source == "original" }
        let rawEligible = originals.isEmpty ? audioFiles : originals
        // Duplicate catalog rows do not create additional recordings. Count
        // distinct physical filenames before applying single-track metadata
        // rules, but reject conflicting evidence rather than trusting row order.
        let grouped = Dictionary(grouping: rawEligible, by: { $0.name })
        guard grouped.values.allSatisfy({ rows in
            guard let first = rows.first else { return false }
            return rows.allSatisfy {
                !$0.hasInvalidSize && !first.hasInvalidSize &&
                !$0.hasInvalidLength && !first.hasInvalidLength &&
                $0.source == first.source && $0.size == first.size &&
                $0.length == first.length
            }
        }) else { return nil }
        let eligible = grouped.keys.sorted().compactMap { grouped[$0]?.first }
        let matches = eligible.filter { file in
            !file.hasInvalidSize && !file.hasInvalidLength && archiveFileCandidate(name: file.name, source: file.source, sizeBytes: file.size,
                                 itemTitle: metadata.title?.value ?? "",
                                 itemCreator: metadata.creator?.value ?? "",
                                 audioFileCount: eligible.count, wish: wish)
        }
        // Catalog metadata can repeat the same physical file row. Repeated
        // identical rows are one recording, not two competing versions.
        // Conflicting metadata for the same filename is untrustworthy: never
        // let ordering decide which duration/size/source is authoritative.
        let byName = Dictionary(grouping: matches, by: { $0.name })
        guard byName.count == 1, let rows = byName.values.first,
              let file = rows.first,
              rows.allSatisfy({ $0.source == file.source &&
                                $0.size == file.size && $0.length == file.length })
        else { return nil }
        // An exact title/creator can still describe a preview, radio edit or
        // alternate master. When Spotify provides runtime evidence, Archive
        // must independently identify the chosen file's duration before it
        // becomes eligible for unattended download. Missing/invalid lengths
        // remain available for manual review, not automatic selection.
        if let expected = wish.durationSeconds {
            guard expected.isFinite, expected > 0,
                  let measured = archiveDurationSeconds(file.length),
                  abs(measured - expected) <= 4.0 else { return nil }
        }
        return AudioCatalogMatch(
            downloadURL: URL(string: "https://archive.org/download/")!
                .appendingPathComponent(identifier).appendingPathComponent(file.name),
            itemURL: URL(string: "https://archive.org/details/")!.appendingPathComponent(identifier),
            licenseURL: licensedURL(metadata.licenseurl?.value), sourceName: "Internet Archive")
    }
}


// Openverse indexes openly-licensed audio from multiple original publishers.
// Only accept links to a single MP3 supplied by an explicitly supported source;
// never attempt Jamendo's download endpoint because its API terms prohibit
// building an offline-music caching application.
extension AudioSourceFinder {
    private struct OpenverseResponse: Decodable {
        let results: [OpenverseResult]
        let page_count: Int?
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

    static func catalogFileTitle(_ value: String) -> String {
        var title = value
        if title.hasPrefix("File:") { title = String(title.dropFirst(5)) }
        if title.lowercased().hasSuffix(".mp3") { title = String(title.dropLast(4)) }
        return title
    }

    static func openverseCandidate(
        title: String?, creator: String?, download: String?, landing: String?,
        license: String?, filetype: String?, duration: Double?, source: String?,
        filesize: Int?, wish: PlaylistWish
    ) -> AudioCatalogMatch? {
        guard let title, let creator, let source,
              ["wikimedia", "ccmixter", "fma"].contains(source.lowercased()),
              exactMetadataMatch(title: catalogFileTitle(title),
                                 creator: creator, wish: wish),
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

        // A title/artist pair is not sufficient to distinguish edits, covers,
        // remasters or similarly named recordings. When Spotify supplies a
        // duration, require finite catalog evidence before auto-selection.
        if let expected = wish.durationSeconds {
            guard expected.isFinite, expected > 0,
                  let duration, duration.isFinite, duration > 0 else { return nil }
            // Openverse documents duration in milliseconds, including short
            // tracks; do not infer units from an arbitrary threshold.
            let measured = duration / 1000.0
            guard measured.isFinite, measured > 0,
                  abs(measured - expected) <= 4.0 else { return nil }
        }
        // Openverse supplies the creator, link and license but does not itself
        // certify that a publisher actually owns the recording.
        return AudioCatalogMatch(downloadURL: downloadURL, itemURL: landingURL,
                                 licenseURL: licensedURL(license), sourceName: "Openverse: \(source)")
    }

    static func consistentOpenverseDuplicate(_ first: AudioCatalogMatch,
                                             _ second: AudioCatalogMatch) -> Bool {
        first.downloadURL == second.downloadURL &&
            first.itemURL == second.itemURL &&
            first.sourceName == second.sourceName
    }

    static let maxOpenversePages = 2

    /// Keep extra queries bounded for battery life and anonymous API limits.
    /// A second page is only useful when no verified recording was found on
    /// the first page and the catalog reports that more results exist.
    static func shouldSearchNextOpenversePage(page: Int, pageCount: Int?,
                                              returned: Int, eligible: Int) -> Bool {
        guard page > 0, page < maxOpenversePages, eligible == 0 else { return false }
        return pageCount.map { page < $0 } ?? (returned >= 50)
    }

    static func openverseSearchURL(for wish: PlaylistWish, fieldSearch: Bool,
                                   page: Int) -> URL {
        var components = URLComponents(string: "https://api.openverse.org/v1/audio/")!
        components.queryItems = [
            URLQueryItem(name: fieldSearch ? "title" : "q",
                         value: fieldSearch ? wish.title : "\"\(wish.title)\" \"\(wish.artist)\""),
            URLQueryItem(name: "extension", value: "mp3"),
            URLQueryItem(name: "page_size", value: "50"),
            URLQueryItem(name: "page", value: String(max(1, min(page, maxOpenversePages))))
        ]
        if fieldSearch {
            components.queryItems?.append(URLQueryItem(name: "creator", value: wish.artist))
        }
        return components.url!
    }

    static func findOpenverse(for wish: PlaylistWish,
                             allowsCellular: Bool = false) async throws -> AudioCatalogMatch? {
        guard !wish.artist.isEmpty, !wish.title.isEmpty else { return nil }
        // A single page's unique match is not necessarily unambiguous:
        // another page or the broader query can contain a different recording
        // with the same title/creator. Gather a bounded cross-query inventory
        // before authorizing an automatic download.
        var firstSearchError: Error?
        var candidates: [String: AudioCatalogMatch] = [:]
        for fieldSearch in [true, false] {
            for page in 1...maxOpenversePages {
                try Task.checkCancellation()
                let result: OpenverseResponse
                do {
                    result = try await requestJSON(
                        openverseSearchURL(for: wish, fieldSearch: fieldSearch, page: page),
                        allowsCellular: allowsCellular)
                } catch {
                    if error is CancellationError { throw error }
                    if firstSearchError == nil { firstSearchError = error }
                    break
                }
                for match in result.results.compactMap({
                    openverseCandidate(title: $0.title, creator: $0.creator, download: $0.url,
                                       landing: $0.foreign_landing_url, license: $0.license_url,
                                       filetype: $0.filetype, duration: $0.duration,
                                       source: $0.source, filesize: $0.filesize, wish: wish)
                }) {
                    let key = match.downloadURL.absoluteString
                    // A catalog may repeat the same direct file URL with
                    // contradictory publisher or landing-page attribution.
                    // URL deduplication is safe only when that evidence agrees.
                    if let previous = candidates[key],
                       !consistentOpenverseDuplicate(previous, match) {
                        throw SourceError.catalogsUnavailable([
                            "Openverse: conflicting metadata for the same audio URL."
                        ])
                    }
                    candidates[key] = match
                    // Different URLs may represent different recordings.
                    // Never choose one automatically once ambiguity is known.
                    if candidates.count > 1 { return nil }
                }
                // A bounded scan cannot establish uniqueness if more pages
                // remain unexamined. Do not auto-import the first match.
                let hasMorePages = result.page_count.map { page < $0 }
                    ?? (result.results.count >= 50)
                if page >= maxOpenversePages && hasMorePages {
                    throw SourceError.catalogsUnavailable([
                        "Openverse: search exceeded the safe page budget."
                    ])
                }
                if !hasMorePages { break }
            }
        }
        // An incomplete provider search cannot prove that a single match is
        // unambiguous. Let the caller retry instead of auto-importing it.
        if let firstSearchError { throw firstSearchError }
        return candidates.count == 1 ? candidates.values.first : nil
    }

    // Wikimedia Commons' MediaWiki file API is a separate upstream catalog:
    // Commons recordings may be absent from Openverse's index. Only explicit
    // machine-readable artist metadata and actual MP3 file URLs qualify.
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
              let download, let audioURL = URL(string: download),
              audioURL.scheme == "https", audioURL.host?.lowercased() == "upload.wikimedia.org",
              audioURL.pathExtension.lowercased() == "mp3",
              let landing, let landingURL = URL(string: landing),
              landingURL.scheme == "https",
              landingURL.host?.lowercased() == "commons.wikimedia.org",
              bytes == nil || (bytes! > 0 && bytes! <= 100 * 1024 * 1024)
        else { return nil }
        // Commons imageinfo does not provide decoded audio duration. A matching
        // filename and artist cannot distinguish a radio edit, live version,
        // or alternate master when Spotify supplies a specific runtime. Do
        // not silently bypass the duration gate used by the other catalogs.
        // Keep this source eligible for wishes without duration evidence;
        // downloaded bytes still undergo the importer's codec verification.
        if let expected = wish.durationSeconds {
            guard expected.isFinite, expected > 0 else { return nil }
            return nil
        }
        return AudioCatalogMatch(downloadURL: audioURL, itemURL: landingURL,
                                 licenseURL: licensedURL(license), sourceName: "Wikimedia Commons")
    }

    static func findCommons(for wish: PlaylistWish,
                           allowsCellular: Bool = false) async throws -> AudioCatalogMatch? {
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
        let result: CommonsResponse = try await requestJSON(components.url!, allowsCellular: allowsCellular)
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

    /// Search independent catalogs concurrently while the app is
    /// active, retaining alternates *before* it hands downloads to iOS. This
    /// lets a locked iPhone use a different verified source without needing
    /// to restart foreground source discovery.
    struct CatalogLookup: Sendable {
        let rank: Int
        let provider: String
        let candidate: AudioCatalogMatch?
        let failure: String?
    }

    struct CatalogSearchReport: Sendable {
        let candidates: [AudioCatalogMatch]
        let warnings: [String]
        let details: [String]
    }

    static func catalogReport(from results: [CatalogLookup]) throws -> CatalogSearchReport {
        let ordered = results.sorted { $0.rank < $1.rank }
        let candidates = uniqueDownloadSources(ordered.compactMap(\.candidate))
        let warnings = ordered.compactMap { result in
            result.failure.map { "\(result.provider): \($0)" }
        }
        // A healthy catalog's empty result is still useful. One optional
        // provider outage must not consume five retries for every playlist song.
        if candidates.isEmpty && !ordered.isEmpty && warnings.count == ordered.count {
            throw SourceError.catalogsUnavailable(warnings)
        }
        let details = ordered.map { result in
            "\(result.provider): " + (result.candidate != nil ? "matching file found" :
                result.failure.map { "lookup failed — \($0)" } ?? "no matching file found")
        }
        return CatalogSearchReport(candidates: candidates, warnings: warnings, details: details)
    }

    static func uniqueDownloadSources(_ ordered: [AudioCatalogMatch]) -> [AudioCatalogMatch] {
        var visited: Set<URL> = []
        return ordered.filter { visited.insert($0.downloadURL).inserted }
    }

    /// Smoothed per-provider success rate. New sources start at a neutral
    /// 50%, so one failure cannot permanently suppress any catalog.
    /// Equal scores preserve discovery order, and missing audio never counts
    /// as a successful download.
    static func prioritize(_ matches: [AudioCatalogMatch],
                           successfulProviders: [String],
                           failedProviders: [String]) -> [AudioCatalogMatch] {
        let successes = Dictionary(successfulProviders.map { ($0, 1) },
                                   uniquingKeysWith: +)
        let failures = Dictionary(failedProviders.map { ($0, 1) },
                                  uniquingKeysWith: +)
        func confidence(_ provider: String) -> Double {
            let success = successes[provider, default: 0]
            let failure = failures[provider, default: 0]
            return Double(success + 1) / Double(success + failure + 2)
        }
        return uniqueDownloadSources(matches).enumerated().sorted { lhs, rhs in
            let left = confidence(lhs.element.sourceName)
            let right = confidence(rhs.element.sourceName)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    static func nextAlternative(to currentURL: URL, from remaining: [AudioCatalogMatch], at date: Date = .now)
        -> (source: AudioCatalogMatch, remaining: [AudioCatalogMatch])? {
        var seen: Set<URL> = [currentURL]
        let eligible = remaining.filter {
            let url = $0.downloadURL
            guard !seen.contains(url), url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.port == nil,
                  url.fragment == nil, !AudioSourceLinks.hasExpired(url, at: date)
            else { return false }
            // Persisted fallback URLs can outlive a provider's original
            // validation. Never retry a private-network or loopback endpoint.
            let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard lower != "localhost", !lower.hasSuffix(".localhost"),
                  !lower.hasSuffix(".local"), !lower.hasSuffix(".internal")
            else { return false }
            let octets = lower.split(separator: ".", omittingEmptySubsequences: false)
            if octets.count == 4 && octets.allSatisfy({ UInt8($0) != nil }) {
                // Public catalog files use DNS hosts. Reject literal IPs to
                // avoid private, link-local and rebinding-prone queue entries.
                return false
            }
            guard !lower.contains(":"), lower.contains(".") else { return false }
            // Old queue manifests may contain a direct Spotify/media URL or a
            // numeric IP encoded as an integer/hex/octal hostname. Neither is
            // an independently hosted, public DNS audio source. Do not allow
            // the fallback path to bypass discovery's source restrictions.
            for blocked in ["spotify.com", "spotifycdn.com", "scdn.co",
                            "youtube.com", "googlevideo.com", "jamendo.com"] {
                if lower == blocked || lower.hasSuffix("." + blocked) { return false }
            }
            let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
            guard !labels.contains(where: { $0.isEmpty }) else { return false }
            if labels.allSatisfy({ label in
                let value = String(label)
                return value.allSatisfy(\.isNumber) ||
                    value.lowercased().hasPrefix("0x") &&
                    UInt64(value.dropFirst(2), radix: 16) != nil
            }) { return false }
            seen.insert(url)
            return true
        }
        guard let first = eligible.first else { return nil }
        return (first, Array(eligible.dropFirst()))
    }

    static func discover(for wish: PlaylistWish,
                         allowsCellular: Bool = false) async throws -> CatalogSearchReport {
        try Task.checkCancellation()
        let found = await withTaskGroup(of: CatalogLookup.self, returning: [CatalogLookup].self) { group in
            group.addTask {
                do {
                    return CatalogLookup(rank: 0, provider: "Audius",
                        candidate: try await findAudius(for: wish, allowsCellular: allowsCellular),
                        failure: nil)
                } catch {
                    return CatalogLookup(rank: 0, provider: "Audius", candidate: nil,
                                         failure: error.localizedDescription)
                }
            }
            group.addTask {
                do {
                    return CatalogLookup(rank: 1, provider: "Openverse",
                        candidate: try await findOpenverse(for: wish, allowsCellular: allowsCellular),
                        failure: nil)
                } catch {
                    return CatalogLookup(rank: 1, provider: "Openverse", candidate: nil,
                                         failure: error.localizedDescription)
                }
            }
            group.addTask {
                do {
                    return CatalogLookup(rank: 2, provider: "Wikimedia Commons",
                        candidate: try await findCommons(for: wish, allowsCellular: allowsCellular),
                        failure: nil)
                } catch {
                    return CatalogLookup(rank: 2, provider: "Wikimedia Commons", candidate: nil,
                                         failure: error.localizedDescription)
                }
            }
            group.addTask {
                do {
                    return CatalogLookup(rank: 3, provider: "Internet Archive",
                        candidate: try await find(for: wish, allowsCellular: allowsCellular),
                        failure: nil)
                } catch {
                    return CatalogLookup(rank: 3, provider: "Internet Archive", candidate: nil,
                                         failure: error.localizedDescription)
                }
            }
            group.addTask {
                do {
                    return CatalogLookup(rank: 4, provider: "ccMixter",
                        candidate: try await findCCMixter(for: wish, allowsCellular: allowsCellular),
                        failure: nil)
                } catch {
                    return CatalogLookup(rank: 4, provider: "ccMixter", candidate: nil,
                                         failure: error.localizedDescription)
                }
            }
            var results: [CatalogLookup] = []
            for await result in group { results.append(result) }
            return results
        }
        try Task.checkCancellation()
        return try catalogReport(from: found)
    }

    static func findDownloadCandidates(for wish: PlaylistWish,
                                       allowsCellular: Bool = false) async throws -> [AudioCatalogMatch] {
        try await discover(for: wish, allowsCellular: allowsCellular).candidates
    }

    static func findAcrossCatalogs(for wish: PlaylistWish,
                                   allowsCellular: Bool = false) async throws -> AudioCatalogMatch? {
        try await findDownloadCandidates(for: wish, allowsCellular: allowsCellular).first
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

    // Search pagination is bounded: an exact-looking first-page recording is
    // not unambiguous if another version is hidden on the next page.
    static let audiusPageSize = 25
    static let maxAudiusPages = 2

    static func audiusSearchURL(for wish: PlaylistWish, page: Int = 1) -> URL {
        var parts = URLComponents(string: "https://api.audius.co/v1/tracks/search")!
        let safePage = max(1, min(page, maxAudiusPages))
        parts.queryItems = [
            URLQueryItem(name: "query", value: "\(wish.artist) \(wish.title)"),
            URLQueryItem(name: "limit", value: String(audiusPageSize)),
            URLQueryItem(name: "offset", value: String((safePage - 1) * audiusPageSize)),
            URLQueryItem(name: "only_downloadable", value: "true")
        ]
        return parts.url!
    }

    static func audiusHasUninspectedResults(returned: Int, page: Int) -> Bool {
        returned >= audiusPageSize && page >= maxAudiusPages
    }

    static func audiusPermalink(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return nil }
        let value: String
        if raw.hasPrefix("/"), !raw.hasPrefix("//") {
            value = "https://audius.co" + raw
        } else { value = raw }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              ["audius.co", "www.audius.co"].contains(host),
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let segments = url.path.split(separator: "/")
        guard segments.count == 2, !segments.contains("."), !segments.contains("..") else { return nil }
        return url
    }

    static func audiusCandidate(_ track: AudiusTrack, for wish: PlaylistWish) -> AudioCatalogMatch? {
        guard (track.is_downloadable == true || track.downloadable == true),
              track.is_downloadable != false, track.downloadable != false,
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

        // Resolve only an explicit track path on the trusted Audius origin.
        guard let page = audiusPermalink(track.permalink) else { return nil }
        // Download can return the original format. The importer must check
        // the actual codec; the download API does not document original=false.
        let download = URLComponents(string:
            "https://api.audius.co/v1/tracks/\(track.id)/download")!
        guard let fileURL = download.url else { return nil }
        return AudioCatalogMatch(
            downloadURL: fileURL, itemURL: page,
            licenseURL: URL(string: "https://audius.org/open-music-license.pdf")!,
            sourceName: "Audius (artist-enabled download)")
    }

    static func findAudius(for wish: PlaylistWish,
                           allowsCellular: Bool = false) async throws -> AudioCatalogMatch? {
        guard !wish.artist.isEmpty, !wish.title.isEmpty else { return nil }
        var candidates: [String: AudioCatalogMatch] = [:]
        for page in 1...maxAudiusPages {
            try Task.checkCancellation()
            let response: AudiusSearchResponse = try await requestJSON(
                audiusSearchURL(for: wish, page: page), allowsCellular: allowsCellular)
            try Task.checkCancellation()
            for match in response.data.compactMap({ audiusCandidate($0, for: wish) }) {
                candidates[match.downloadURL.absoluteString] = match
                // Distinct exact-looking downloadable files can be different
                // masters or versions. Never select one arbitrarily.
                if candidates.count > 1 { return nil }
            }
            // A full final page cannot certify uniqueness. Return a retryable
            // catalog error instead of automatically importing a possible
            // wrong recording; do not request unbounded pages per playlist song.
            if audiusHasUninspectedResults(returned: response.data.count, page: page) {
                throw SourceError.unavailable
            }
            if response.data.count < audiusPageSize { break }
        }
        return candidates.count == 1 ? candidates.values.first : nil
    }
}


// Optional web-wide discovery. Search-engine results are navigation hints;
// a result page alone is not evidence of a matching downloadable audio file.
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
            // Keep the fallback on the publisher's own site, not a
            // web-search-engine index that may miss newly uploaded songs.
            base = "https://ccmixter.org/search"; key = "search_text"; term = query
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

    static var automaticFallbackEnabled: Bool {
        UserDefaults.standard.object(forKey: "MP3Shelf.automaticWebFallback") as? Bool ?? true
    }

    static func searchRequest(query: String, apiKey: String,
                              allowsCellular: Bool) -> URLRequest {
        var parts = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        parts.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "20"),
            URLQueryItem(name: "search_lang", value: "en"),
            URLQueryItem(name: "result_filter", value: "web")
        ]
        var request = AudioSourceFinder.catalogRequest(for: parts.url!, allowsCellular: allowsCellular)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.timeoutInterval = 20
        return request
    }

    static func search(for wish: PlaylistWish, using apiKey: String,
                       depth: SearchDepth = .quick,
                       allowsCellular: Bool = true) async throws -> [WebAudioSearchResult] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SearchFailure.missingKey }
        var merged: [WebAudioSearchResult] = []
        var seen: Set<String> = []
        var firstError: Error?
        // Query variants improve coverage while keeping total network/API
        // usage explicit and user-selectable. Never download search hits here.
        for query in searchQueries(for: wish, depth: depth) {
            try Task.checkCancellation()
            let request = searchRequest(query: query, apiKey: key, allowsCellular: allowsCellular)
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
// Manual links remain reviewable; automatic matching also checks recording
// identity before handing a source to normal download validation.
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

    private static func readHTML(_ pageURL: URL, allowsCellular: Bool,
                                  session: URLSession) async throws -> String {
        guard WebAudioSearch.sanitizedResultURL(pageURL.absoluteString) != nil,
              pageURL.port == nil || pageURL.port == 443 else {
            throw InspectionError.invalidURL
        }
        var request = AudioSourceFinder.catalogRequest(for: pageURL, allowsCellular: allowsCellular)
        request.timeoutInterval = 12
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-999999", forHTTPHeaderField: "Range")
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
        return html
    }

    static func inspect(_ pageURL: URL, maxProbes: Int = 8,
                        allowsCellular: Bool = true) async throws -> [URL] {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let html = try await readHTML(pageURL, allowsCellular: allowsCellular, session: session)
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
            var probe = AudioSourceFinder.catalogRequest(for: link, allowsCellular: allowsCellular)
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

    static func matchingSources(on pageURL: URL, for wish: PlaylistWish,
                                allowsCellular: Bool) async throws -> [AudioCatalogMatch] {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let html = try await readHTML(pageURL, allowsCellular: allowsCellular, session: session)
        return AutomaticWebAudioFinder.matches(in: html, pageURL: pageURL, wish: wish)
    }

    static func verifyAutomaticSources(_ sources: [AudioCatalogMatch],
                                       allowsCellular: Bool) async throws
        -> (sources: [AudioCatalogMatch], details: [String]) {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var accepted: [AudioCatalogMatch] = []
        var details: [String] = []
        for source in AudioSourceFinder.uniqueDownloadSources(sources).prefix(6) {
            try Task.checkCancellation()
            var request = AudioSourceFinder.catalogRequest(for: source.downloadURL,
                                                             allowsCellular: allowsCellular)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 8
            request.setValue("audio/*", forHTTPHeaderField: "Accept")
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, isVerifiedAudioResponse(http) {
                    accepted.append(source)
                    details.append("Web file \(source.downloadURL.host ?? "source"): audio response confirmed")
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    details.append("Web file \(source.downloadURL.host ?? "source"): skipped (HTTP \(code), no supported direct audio response)")
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                details.append("Web file \(source.downloadURL.host ?? "source"): \(error.localizedDescription)")
            }
        }
        return (Array(accepted.prefix(3)), details)
    }
}


/// Web fallback submits only independently identifiable audio files to the
/// existing checked importer. Search snippets alone never identify a recording.
enum AutomaticWebAudioFinder {
    struct Result: Sendable {
        let sources: [AudioCatalogMatch]
        let details: [String]
    }

    static func automaticURL(_ url: URL) -> URL? {
        guard let safe = WebAudioSearch.sanitizedResultURL(url.absoluteString),
              let host = safe.host?.lowercased(),
              !["spotify.com", "spotifycdn.com", "scdn.co", "jamendo.com", "youtube.com", "googlevideo.com"]
                .contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return safe
    }

    static func fileMatches(_ url: URL, wish: PlaylistWish) -> Bool {
        guard automaticURL(url) != nil,
              ["mp3", "m4a", "aac", "wav", "aif", "aiff"].contains(url.pathExtension.lowercased()),
              !MusicMatching.key(wish.title).isEmpty,
              !MusicMatching.key(wish.artist).isEmpty else { return false }
        let stem = MusicMatching.key(url.deletingPathExtension().lastPathComponent)
        return stem == MusicMatching.key(wish.artist + " " + wish.title) ||
            stem == MusicMatching.key(wish.title + " " + wish.artist)
    }

    private static func durationMatches(_ value: Any?, wish: PlaylistWish) -> Bool {
        guard let value else { return true }
        let seconds: Double
        if let number = value as? Double { seconds = number }
        else if let raw = value as? String {
            // Publishers emit either ISO-8601 durations or numeric seconds.
            // Reject partial matches, whitespace, signs and non-finite values:
            // an incorrect duration must never authorize automatic selection.
            if raw.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#,
                         options: .regularExpression) != nil {
                guard let parsed = Double(raw) else { return false }
                seconds = parsed
            } else {
                let pattern = #"^PT(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?$"#
                let normalized = raw.uppercased()
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: normalized,
                        range: NSRange(location: 0, length: (normalized as NSString).length))
                else { return false }
                let string = normalized as NSString
                func number(_ index: Int) -> Double {
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? 0 : Double(string.substring(with: range)) ?? 0
                }
                // ISO-8601 clock fields must be well-formed. A value such as
                // PT1M90S or PT2H75M must not be normalized into a plausible
                // Spotify runtime and silently authorize the wrong recording.
                let hours = number(1)
                let minutes = number(2)
                let secondsField = number(3)
                guard hours.isFinite, minutes.isFinite, secondsField.isFinite,
                      hours >= 0, minutes >= 0, secondsField >= 0,
                      minutes < 60, secondsField < 60 else { return false }
                seconds = hours * 3600 + minutes * 60 + secondsField
            }
        } else { return false }
        guard seconds.isFinite, seconds > 0 else { return false }
        return wish.durationSeconds.map { abs($0 - seconds) <= 4 } ?? true
    }

    // A matching title/artist is not sufficient to identify the exact recording.
    // Require at least one duration claim when Spotify supplies a duration, and
    // reject conflicting claims even if another claim happens to match.
    static func recordingDurationEvidenceMatches(
        recording: Any?, audio: Any?, wish: PlaylistWish
    ) -> Bool {
        guard recording != nil || audio != nil || wish.durationSeconds == nil else { return false }
        return durationMatches(recording, wish: wish) && durationMatches(audio, wish: wish)
    }

    static func matches(in html: String, pageURL: URL,
                        wish: PlaylistWish) -> [AudioCatalogMatch] {
        guard automaticURL(pageURL) != nil, html.utf8.count <= 1_000_000 else { return [] }
        var sources: [AudioCatalogMatch] = []
        func add(_ raw: String) {
            guard let url = AudioLandingPageInspector.candidateURL(raw, relativeTo: pageURL,
                                                                   explicitlyDownloadable: true),
                  let safe = automaticURL(url) else { return }
            sources.append(AudioCatalogMatch(downloadURL: safe, itemURL: pageURL,
                licenseURL: nil, sourceName: "Web: \(pageURL.host ?? "audio source")"))
        }
        // A generic page may still expose a file whose own filename identifies
        // both artist and title. Title-only album links are never auto-assigned.
        for url in AudioLandingPageInspector.candidates(in: html, pageURL: pageURL)
            where fileMatches(url, wish: wish) { add(url.absoluteString) }

        let pattern = #"<script\b[^>]*\btype\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return sources }
        let text = html as NSString
        var nodes: [[String: Any]] = []
        var identifiers: [String: [String: Any]] = [:]
        func collect(_ value: Any, depth: Int) {
            guard depth < 12, nodes.count < 2000 else { return }
            if let object = value as? [String: Any] {
                nodes.append(object)
                if let id = object["@id"] as? String,
                   object.count > (identifiers[id]?.count ?? 0) { identifiers[id] = object }
                for child in object.values { collect(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { collect(child, depth: depth + 1) }
            }
        }
        for script in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let raw = text.substring(with: script.range(at: 1))
            if let root = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) {
                collect(root, depth: 0)
            }
        }
        func resolved(_ value: [String: Any]) -> [String: Any] {
            guard let id = value["@id"] as? String, let target = identifiers[id] else { return value }
            return target.merging(value) { _, explicit in explicit }
        }
        func names(_ value: Any?) -> [String] {
            if let string = value as? String { return [string] }
            if let object = value as? [String: Any], let name = resolved(object)["name"] as? String { return [name] }
            if let array = value as? [Any] { return array.flatMap { names($0) } }
            return []
        }
        func types(_ object: [String: Any]) -> Set<String> {
            let raw = (object["@type"] as? [String]) ?? (object["@type"] as? String).map { [$0] } ?? []
            return Set(raw.map { ($0.components(separatedBy: CharacterSet(charactersIn: "/#")).last ?? $0).lowercased() })
        }
        for raw in nodes {
            let node = resolved(raw)
            let kind = types(node)
            guard kind.contains("musicrecording") || kind.contains("audioobject"),
                  let title = node["name"] as? String,
                  names(node["byArtist"] ?? node["creator"]).contains(where: {
                    AudioSourceFinder.exactMetadataMatch(title: title, creator: $0, wish: wish)
                  }) else { continue }
            var media: [Any] = kind.contains("audioobject") ? [node] : []
            for key in ["audio", "associatedMedia", "encoding"] {
                if let array = node[key] as? [Any] { media.append(contentsOf: array) }
                else if let object = node[key] { media.append(object) }
            }
            for value in media {
                guard let rawAudio = value as? [String: Any] else { continue }
                let audio = resolved(rawAudio)
                guard !types(audio).contains("videoobject"),
                      recordingDurationEvidenceMatches(recording: node["duration"],
                                                       audio: audio["duration"], wish: wish),
                      let url = audio["contentUrl"] as? String else { continue }
                if let title = audio["name"] as? String,
                   MusicMatching.key(title) != MusicMatching.key(wish.title) { continue }
                let credits = names(audio["byArtist"] ?? audio["creator"])
                if !credits.isEmpty && !credits.contains(where: {
                    MusicMatching.key($0) == MusicMatching.key(wish.artist)
                }) { continue }
                add(url)
            }
        }
        return AudioSourceFinder.uniqueDownloadSources(sources)
    }

    static func find(for wish: PlaylistWish, apiKey: String,
                     allowsCellular: Bool, excluding failedURLs: Set<URL> = []) async throws -> Result {
        let hits = try await WebAudioSearch.search(for: wish, using: apiKey,
                                                   depth: .quick, allowsCellular: allowsCellular)
        var candidates = hits.filter { fileMatches($0.url, wish: wish) }.prefix(3).map {
            AudioCatalogMatch(downloadURL: $0.url, itemURL: $0.url, licenseURL: nil,
                              sourceName: "Web: \($0.url.host ?? "audio source")")
        }
        var details = ["Web search: \(hits.count) results returned"]
        let pages = WebAudioSearch.pagesWorthInspecting(hits, for: wish, limit: 2)
            .filter { WebAudioSearch.resultScore($0, for: wish) >= 80 && automaticURL($0.url) != nil }
        for page in pages {
            try Task.checkCancellation()
            do {
                let found = try await AudioLandingPageInspector.matchingSources(on: page.url,
                    for: wish, allowsCellular: allowsCellular)
                candidates.append(contentsOf: found)
                details.append("Web page \(page.url.host ?? "source"): \(found.count) identifiable audio links")
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                details.append("Web page \(page.url.host ?? "source"): \(error.localizedDescription)")
            }
        }
        candidates.removeAll { failedURLs.contains($0.downloadURL) }
        let checked = try await AudioLandingPageInspector.verifyAutomaticSources(candidates,
                                                                                 allowsCellular: allowsCellular)
        try Task.checkCancellation()
        details.append(contentsOf: checked.details)
        details.append("Web fallback: \(checked.sources.count) matching direct audio files confirmed")
        return Result(sources: checked.sources, details: details)
    }
}

// Official ccMixter ccHost Query API exposes an RSS feed without an API key.
// Exact metadata and a directly hosted MP3 enclosure are still
// mandatory; an enclosure alone does not establish recording identity.
extension AudioSourceFinder {
    struct CCMixterFeedTrack {
        var title = ""
        var creator = ""
        var landingURL = ""
        var downloadURL = ""
        var licenseURL = ""
        var ambiguousEnclosure = false
        var ambiguousMetadata = false
    }

    private final class CCMixterRSSReader: NSObject, XMLParserDelegate {
        var tracks: [CCMixterFeedTrack] = []
        private var current: CCMixterFeedTrack?
        private var activeField = ""
        private var characters = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let field = String(elementName.split(separator: ":").last ?? "").lowercased()
            if field == "item" {
                current = CCMixterFeedTrack()
            } else if field == "enclosure", current != nil {
                let type = (attributeDict["type"] ?? "").lowercased()
                let raw = attributeDict["url"] ?? ""
                if type == "audio/mpeg" || URL(string: raw)?.pathExtension.lowercased() == "mp3" {
                    // A feed item with multiple distinct recordings cannot
                    // authorize an unattended choice based on XML element order.
                    if let previous = current?.downloadURL, !previous.isEmpty, previous != raw {
                        current?.ambiguousEnclosure = true
                    } else if current?.ambiguousEnclosure == false {
                        current?.downloadURL = raw
                    }
                }
            } else if field == "license", current != nil {
                if let url = attributeDict["rdf:resource"] ?? attributeDict["resource"] ??
                        attributeDict["href"] {
                    current?.licenseURL = url
                }
            }
            activeField = current == nil ? "" : field
            characters = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if ["title", "creator", "author", "link", "license"].contains(activeField) {
                characters += string
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let field = String(elementName.split(separator: ":").last ?? "").lowercased()
            let content = characters.trimmingCharacters(in: .whitespacesAndNewlines)
            if current != nil {
                switch field {
                case "title":
                    if !current!.title.isEmpty && current!.title != content { current?.ambiguousMetadata = true }
                    if !content.isEmpty { current?.title = content }
                case "creator":
                    if !current!.creator.isEmpty && current!.creator != content { current?.ambiguousMetadata = true }
                    if !content.isEmpty { current?.creator = content }
                case "author":
                    // RSS author and Dublin Core creator are two claims about
                    // the same recording identity. A conflicting fallback must
                    // not be silently ignored when creator is already present.
                    if !content.isEmpty {
                        if let creator = current?.creator, !creator.isEmpty,
                           MusicMatching.key(creator) != MusicMatching.key(content) {
                            current?.ambiguousMetadata = true
                        } else if current?.creator.isEmpty == true {
                            current?.creator = content
                        }
                    }
                case "link":
                    if !current!.landingURL.isEmpty && current!.landingURL != content { current?.ambiguousMetadata = true }
                    if !content.isEmpty { current?.landingURL = content }
                case "license":
                    if !content.isEmpty { current?.licenseURL = content }
                case "item":
                    if let entry = current { tracks.append(entry) }
                    current = nil
                default: break
                }
            }
            activeField = ""
            characters = ""
        }

        func read(_ data: Data) -> [CCMixterFeedTrack]? {
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = self
            return parser.parse() ? tracks : nil
        }
    }

    static func ccMixterSearchURL(for wish: PlaylistWish) -> URL {
        var parts = URLComponents(string: "https://ccmixter.org/api/query")!
        parts.queryItems = [
            URLQueryItem(name: "f", value: "rss"),
            URLQueryItem(name: "search", value: wish.title),
            URLQueryItem(name: "search_type", value: "match"),
            URLQueryItem(name: "limit", value: "20")
        ]
        return parts.url!
    }

    static func ccMixterCandidate(_ track: CCMixterFeedTrack,
                                   for wish: PlaylistWish) -> AudioCatalogMatch? {
        guard !track.ambiguousEnclosure, !track.ambiguousMetadata,
              exactMetadataMatch(title: track.title, creator: track.creator, wish: wish),
              let page = URL(string: track.landingURL), page.scheme == "https",
              let pageHost = page.host?.lowercased(),
              (pageHost == "ccmixter.org" || pageHost == "www.ccmixter.org"),
              page.path.hasPrefix("/files/"), page.user == nil, page.password == nil,
              let download = URL(string: track.downloadURL),
              download.scheme == "https",
              let host = download.host?.lowercased(),
              (host == "ccmixter.org" || host.hasSuffix(".ccmixter.org")),
              download.user == nil, download.password == nil,
              download.pathExtension.lowercased() == "mp3"
        else { return nil }
        return AudioCatalogMatch(downloadURL: download, itemURL: page,
                                 licenseURL: licensedURL(track.licenseURL), sourceName: "ccMixter")
    }

    static func ccMixterCandidates(in rssData: Data,
                                   matching wish: PlaylistWish) -> [AudioCatalogMatch]? {
        guard let tracks = CCMixterRSSReader().read(rssData) else { return nil }
        return uniqueDownloadSources(tracks.compactMap {
            ccMixterCandidate($0, for: wish)
        })
    }

    static func findCCMixter(for wish: PlaylistWish,
                             allowsCellular: Bool = false) async throws -> AudioCatalogMatch? {
        guard !wish.title.isEmpty, !wish.artist.isEmpty else { return nil }
        // Use the same redirect-blocking ephemeral catalog transport as JSON
        // searches. URLSession.shared can follow a cross-origin redirect,
        // leaking a catalog lookup and bypassing the intended Wi-Fi policy.
        let data = try await requestCatalogData(
            ccMixterSearchURL(for: wish), allowsCellular: allowsCellular,
            maximumBytes: 1_000_000)
        guard let matches = ccMixterCandidates(in: data, matching: wish)
        else { throw SourceError.invalidResponse }
        // Distinct eligible uploads may be separate remixes or releases.
        // Do not treat matching RSS text as proof that versions are identical.
        return matches.count == 1 ? matches.first : nil
    }
}
