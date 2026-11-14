import Foundation

/// MP3 Shelf provides a playlist-scoped session; unscoped local requests fail.
public enum ShelfExtractionNetwork {
    @TaskLocal public static var session: URLSession? = nil

    private static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return ["youtube.com", "youtube-nocookie.com", "ytimg.com", "googlevideo.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard allowed(request.url) else { throw URLError(.unsupportedURL) }
        guard let session else { throw URLError(.notConnectedToInternet) }
        try Task.checkCancellation()
        return try await session.data(for: request, delegate: nil)
    }
    static func data(from url: URL) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url))
    }
}
