import Foundation

// Offline regression fixture: compile alongside production SpotifyService.swift
// in the native test harness, with its iOS framework dependencies available.
@main
enum SpotifyTransportRetryPolicyTests {
    static func main() {
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }
        let recoverable: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet
        ]
        for code in recoverable {
            check(SpotifyTransportRetryPolicy.isTransient(URLError(code)),
                  "transient transport error \(code.rawValue)")
        }
        let permanent: [URLError.Code] = [
            .cancelled, .secureConnectionFailed, .serverCertificateUntrusted,
            .userAuthenticationRequired, .unsupportedURL, .badURL,
            .appTransportSecurityRequiresSecureConnection
        ]
        for code in permanent {
            check(!SpotifyTransportRetryPolicy.isTransient(URLError(code)),
                  "permanent or security error \(code.rawValue)")
        }
        check(!SpotifyTransportRetryPolicy.isTransient(
            NSError(domain: "FixtureFailure", code: 1)), "non-URL errors do not retry")
    }
}
