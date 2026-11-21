import Foundation
import XCTest
@testable import MP3Shelf

final class SpotifyTransportRetryPolicyTests: XCTestCase {
    func testOnlyRecoverableMetadataTransportFailuresAreRetried() {
        let recoverable: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet
        ]
        for code in recoverable {
            XCTAssertTrue(SpotifyTransportRetryPolicy.isTransient(URLError(code)),
                          "Expected transient transport retry for \(code)")
        }
    }

    func testCancellationAndSecurityFailuresNeverRetry() {
        let permanent: [URLError.Code] = [
            .cancelled, .secureConnectionFailed, .serverCertificateUntrusted,
            .userAuthenticationRequired, .unsupportedURL, .badURL,
            .appTransportSecurityRequiresSecureConnection
        ]
        for code in permanent {
            XCTAssertFalse(SpotifyTransportRetryPolicy.isTransient(URLError(code)),
                           "Unexpected retry for \(code)")
        }
        XCTAssertFalse(SpotifyTransportRetryPolicy.isTransient(
            NSError(domain: "FixtureFailure", code: 1)))
    }
}
