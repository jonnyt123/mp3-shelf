import Foundation

// Compile with the production SpotifyService.swift in the iOS Swift harness.
// No live Spotify credentials or network requests are required.
@main
enum SpotifyTokenTransportRetryTests {
    static func main() {
        func check(_ result: Bool, _ description: String) {
            guard result else { fatalError("FAIL: \(description)") }
            print("PASS: \(description)")
        }

        let lostConnection = URLError(.networkConnectionLost)
        let timeout = URLError(.timedOut)
        check(SpotifyTokenTransportRetryPolicy.canRetry(
            isRefreshGrant: true, attempts: 0, error: lostConnection
        ), "refresh retries after first connection loss")
        check(SpotifyTokenTransportRetryPolicy.canRetry(
            isRefreshGrant: true, attempts: 1, error: timeout
        ), "refresh retries after second transient interruption")
        check(!SpotifyTokenTransportRetryPolicy.canRetry(
            isRefreshGrant: true, attempts: 2, error: timeout
        ), "refresh stops after bounded retry budget")
        check(!SpotifyTokenTransportRetryPolicy.canRetry(
            isRefreshGrant: false, attempts: 0, error: lostConnection
        ), "authorization code exchange is never replayed")
        for error in [URLError(.cancelled), URLError(.secureConnectionFailed),
                      URLError(.serverCertificateUntrusted),
                      URLError(.userAuthenticationRequired)] {
            check(!SpotifyTokenTransportRetryPolicy.canRetry(
                isRefreshGrant: true, attempts: 0, error: error
            ), "security, cancellation and authentication failures are permanent")
        }
        check(!SpotifyTokenTransportRetryPolicy.canRetry(
            isRefreshGrant: true, attempts: 0,
            error: NSError(domain: "Unexpected", code: 1)
        ), "unclassified errors are not retried")
    }
}
