import Foundation
import YouTubeKit

/// MP3 Shelf owns search parsing, selection and queue policy. YouTubeKit only
/// resolves a selected ID into a media URL, entirely on the requesting iPhone.
actor NativeAudioEngine {
    static let shared = NativeAudioEngine()
    private var resolving = false
    private var resolutionWaiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    private func acquireResolution() async throws {
        try Task.checkCancellation()
        if !resolving { resolving = true; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { resolutionWaiters.append((id, continuation)) }
            }
        }, onCancel: { Task { await self.cancelResolutionWaiter(id) } })
    }

    private func cancelResolutionWaiter(_ id: UUID) {
        guard let index = resolutionWaiters.firstIndex(where: { $0.0 == id }) else { return }
        resolutionWaiters.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func releaseResolution() {
        if resolutionWaiters.isEmpty { resolving = false }
        else { resolutionWaiters.removeFirst().1.resume() }
    }

    enum Failure: LocalizedError, SourceLookupRetryableError {
        case searchHTTP(Int), unreadableSearch, oversizedSearch, noAudio, mediaResponse(Int, String), changedRecording, extractionFailed(String), networkUnavailable, queueUnavailable
        var shouldRetrySourceLookup: Bool {
            switch self {
            case .searchHTTP(let status), .mediaResponse(let status, _):
                return BackgroundTransferRetryPolicy.isTemporaryHTTP(status)
            default: return false
            }
        }
        var errorDescription: String? {
            switch self {
            case .searchHTTP(let code): return "Recording search returned HTTP \(code)."
            case .unreadableSearch: return "The source returned a verification page or changed its search response."
            case .oversizedSearch: return "The recording search exceeded its response-size limit."
            case .noAudio: return "This source did not provide a supported AAC audio file."
            case .mediaResponse(let code, let type): return "The resolved source returned HTTP \(code) (\(type)) instead of supported AAC audio."
            case .changedRecording: return "The resolved recording no longer matches this song's identity and length."
            case .extractionFailed(let reason): return "Audio extraction failed (\(reason)). Try another recording; the source may have changed or restricted this one."
            case .networkUnavailable: return "Open MP3 Shelf on Wi-Fi, or allow cellular for this playlist."
            case .queueUnavailable: return "The transfer queue is full or this song is no longer in the playlist."
            }
        }
    }

    private final class SourceRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(Self.allowed) == true ? request : nil)
        }
        static func allowed(_ url: URL) -> Bool {
            guard url.scheme == "https", let host = url.host?.lowercased(),
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
            return ["youtube.com", "youtube-nocookie.com", "ytimg.com", "googlevideo.com"].contains {
                host == $0 || host.hasSuffix("." + $0)
            }
        }
    }

    private func session(allowsCellular: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowsCellular
        configuration.allowsExpensiveNetworkAccess = allowsCellular
        configuration.allowsConstrainedNetworkAccess = allowsCellular
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 50
        return URLSession(configuration: configuration, delegate: SourceRedirects(), delegateQueue: nil)
    }

    func search(for wish: PlaylistWish, allowsCellular: Bool) async throws -> [RecordingCandidate] {
        let connection = session(allowsCellular: allowsCellular)
        defer { connection.invalidateAndCancel() }
        var parts = URLComponents(string: "https://www.youtube.com/results")!
        parts.queryItems = [URLQueryItem(name: "search_query", value: "\(wish.artistNames?.first ?? wish.artist) \(wish.title) audio"),
                            URLQueryItem(name: "sp", value: "EgIQAQ=="), URLQueryItem(name: "hl", value: "en")]
        var request = AudioSourceFinder.catalogRequest(for: parts.url!, allowsCellular: allowsCellular)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (bytes, response) = try await connection.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadableSearch }
        guard http.statusCode == 200 else { throw Failure.searchHTTP(http.statusCode) }
        guard response.expectedContentLength <= 3_000_000 else { throw Failure.oversizedSearch }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 3_000_000 else { throw Failure.oversizedSearch }
            data.append(byte)
        }
        guard let json = RecordingSearchParser.initialData(in: data) else { throw Failure.unreadableSearch }
        return try RecordingSearchParser.candidates(in: json)
    }

    func resolve(_ candidate: RecordingCandidate, for wish: PlaylistWish,
                 allowsCellular: Bool, userSelected: Bool = false) async throws -> AudioCatalogMatch {
        guard RecordingMatcher.validID(candidate.id) else { throw Failure.changedRecording }
        try await acquireResolution()
        defer { releaseResolution() }
        let connection = session(allowsCellular: allowsCellular)
        defer { connection.invalidateAndCancel() }
        do {
            return try await ShelfExtractionNetwork.$session.withValue(connection) {
                try Task.checkCancellation()
                let video = YouTube(videoID: candidate.id, methods: [.local])
                guard let metadata = try await video.metadata,
                      let author = metadata.author, let duration = metadata.durationSeconds,
                      duration.isFinite, duration > 0 else { throw Failure.changedRecording }
                let actual = RecordingCandidate(id: candidate.id, title: metadata.title,
                    uploader: author, durationSeconds: duration,
                    verifiedArtist: candidate.verifiedArtist && RecordingMatcher.cleanedArtist(author) == RecordingMatcher.cleanedArtist(candidate.uploader),
                    isLive: metadata.isLive)
                let checked = RecordingMatcher.assess(actual, for: wish)
                guard checked.decision == .automatic || (userSelected && checked.decision == .review) else {
                    throw Failure.changedRecording
                }
                let streams = try await video.streams
                let candidates = streams.filterAudioOnly().filter { $0.fileExtension == .m4a }
                    .map { RecordingStreamProbe.Candidate(url: $0.url, bitrate: $0.bitrate ?? $0.averageBitrate) }
                let audioURL = try await RecordingStreamProbe.resolve(candidates) { url in
                    try await Self.checkAudioResponse(from: url, connection: connection, allowsCellular: allowsCellular)
                }
                guard let audioURL else { throw Failure.noAudio }
                try Task.checkCancellation()
                return AudioCatalogMatch(downloadURL: audioURL, itemURL: candidate.pageURL,
                    licenseURL: nil, sourceName: "MP3 Shelf matching · YouTube")
            }
        } catch let error as YouTubeKitError {
            try Task.checkCancellation()
            throw Failure.extractionFailed(error.rawValue)
        }
    }

    nonisolated private static func checkAudioResponse(from url: URL, connection: URLSession,
                                                       allowsCellular: Bool) async throws {
        // A signed URL is not evidence that its response is audio.
        guard !AudioSourceLinks.hasExpired(url, at: Date().addingTimeInterval(30)) else { throw Failure.noAudio }
        var request = AudioSourceFinder.catalogRequest(for: url, allowsCellular: allowsCellular)
        request.setValue(nil, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-63", forHTTPHeaderField: "Range")
        let (bytes, response) = try await connection.bytes(for: request)
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= 100 * 1024 * 1024 else { throw Failure.noAudio }
        var prefix = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            prefix.append(byte)
            if prefix.count == 64 { break }
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard RecordingMatcher.acceptsAudioResponse(status: code, mime: response.mimeType, prefix: prefix) else {
            throw Failure.mediaResponse(code, response.mimeType ?? "missing content type")
        }
        guard !AudioSourceLinks.hasExpired(url, at: Date().addingTimeInterval(30)) else { throw Failure.noAudio }
    }
}
