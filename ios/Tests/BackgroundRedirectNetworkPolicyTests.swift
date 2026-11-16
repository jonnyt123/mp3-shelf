import Foundation

// Deterministic, offline policy fixture compiled with production downloader.
@main
enum BackgroundRedirectNetworkPolicyTests {
    static func main() {
        func request(_ url: String, _ cellular: Bool) -> URLRequest {
            var r = URLRequest(url: URL(string: url)!)
            r.allowsCellularAccess = cellular
            r.allowsExpensiveNetworkAccess = cellular
            r.allowsConstrainedNetworkAccess = cellular
            return r
        }
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }
        let wifi = request("https://example.org/a.mp3", false)
        let cellular = request("https://example.org/a.mp3", true)
        let redirected = request("https://cdn.example.org/a.mp3", true)
        let strict = BackgroundAudioDownloader.safeRedirectRequest(redirected, original: wifi)
        check(strict?.allowsCellularAccess == false, "Wi-Fi-only remains Wi-Fi-only")
        check(strict?.allowsExpensiveNetworkAccess == false, "expensive networks remain disallowed")
        check(strict?.allowsConstrainedNetworkAccess == false, "constrained networks remain disallowed")
        check(BackgroundAudioDownloader.safeRedirectRequest(redirected, original: nil)?.allowsCellularAccess == false,
              "missing restored request does not imply consent")
        check(BackgroundAudioDownloader.safeRedirectRequest(redirected, original: cellular)?.allowsCellularAccess == true,
              "explicit cellular consent remains permitted")
        check(BackgroundAudioDownloader.safeRedirectRequest(wifi, original: cellular)?.allowsCellularAccess == false,
              "redirect cannot relax its own restrictions")
        check(BackgroundAudioDownloader.safeRedirectRequest(request("http://example.org/a.mp3", true),
              original: cellular) == nil, "HTTPS downgrade is rejected")
    }
}
