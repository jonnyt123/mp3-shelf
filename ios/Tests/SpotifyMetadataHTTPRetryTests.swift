import Foundation

// Compile with production SpotifyService.swift on a macOS/Xcode iOS test
// surface. This exercises the same status classifier used by request(_:).
@main
enum SpotifyMetadataHTTPRetryTests {
    static func main() {
        let retryable = [408, 425, 500, 502, 503, 504, 599]
        let permanent = [200, 201, 301, 400, 401, 403, 404, 409, 422, 429, 600]
        for status in retryable {
            precondition(SpotifyMetadataHTTPRetryPolicy.isTransient(status),
                         "Expected retry for HTTP \(status)")
            print("PASS: transient HTTP \(status)")
        }
        for status in permanent {
            precondition(!SpotifyMetadataHTTPRetryPolicy.isTransient(status),
                         "Unexpected retry for HTTP \(status)")
            print("PASS: permanent HTTP \(status)")
        }
    }
}
