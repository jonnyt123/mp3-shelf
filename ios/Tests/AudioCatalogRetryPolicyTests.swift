import Foundation

// Compile with the production AudioSourceFinder and its normal native dependencies.
// These assertions exercise the same bounded policy used by catalog URLSession requests.
@main
enum AudioCatalogRetryPolicyTests {
    static func main() {
        func expect(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }
        let policy = AudioSourceFinder.catalogRetryDelay
        expect(policy(status: 429, retryAfter: nil, attempt: 0) == 1.5,
               "429 without Retry-After gets one short retry")
        expect(policy(status: 503, retryAfter: "2", attempt: 0) == 2,
               "503 honors bounded Retry-After seconds")
        expect(policy(status: 429, retryAfter: "0", attempt: 0) == 0,
               "zero-second Retry-After is not mistaken for missing")
        expect(policy(status: 429, retryAfter: "120", attempt: 0) == nil,
               "long throttling cooldown is deferred, not ignored")
        expect(policy(status: 429, retryAfter: "Wed, 21 Oct 2030 07:28:00 GMT", attempt: 0) == nil,
               "HTTP-date cooldown is not bypassed")
        expect(policy(status: 429, retryAfter: "-1", attempt: 0) == nil &&
               policy(status: 429, retryAfter: "NaN", attempt: 0) == nil,
               "invalid and nonfinite cooldowns are rejected")
        expect(policy(status: 429, retryAfter: nil, attempt: 1) == nil,
               "second throttle response never triggers a third request")
        expect(policy(status: 401, retryAfter: nil, attempt: 0) == nil &&
               policy(status: 403, retryAfter: nil, attempt: 0) == nil &&
               policy(status: 404, retryAfter: nil, attempt: 0) == nil,
               "auth failures and missing catalog records are never retried")
        expect(policy(status: 500, retryAfter: nil, attempt: 0) == nil &&
               policy(status: 200, retryAfter: nil, attempt: 0) == nil,
               "unapproved response classes never trigger retries")
    }
}
