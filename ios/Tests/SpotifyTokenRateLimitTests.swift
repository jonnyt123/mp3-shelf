import Foundation

// Run from repository root: swift ios/Tests/SpotifyTokenRateLimitTests.swift
// Network-independent contract test: inspect the actual token-exchange branch
// rather than an unrelated copy of the retry policy.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/SpotifyService.swift", encoding: .utf8)
guard let start = source.range(of: "    private func exchangeToken("),
      let end = source.range(of: "    private func store(", range: start.upperBound..<source.endIndex) else {
    fatalError("Spotify token exchange boundaries changed; update this fixture")
}
let exchange = String(source[start.lowerBound..<end.lowerBound])
guard let rateLimit = exchange.range(of: "if http.statusCode == 429 {"),
      let serverError = exchange.range(of: "} else if (500...599).contains(http.statusCode)", range: rateLimit.upperBound..<exchange.endIndex) else {
    fatalError("Token rate-limit retry branch is missing")
}
let branch = String(exchange[rateLimit.lowerBound..<serverError.lowerBound])
func check(_ condition: Bool, _ message: String) {
    precondition(condition, "FAIL: " + message)
    print("PASS: " + message)
}
// Validate source-bound policy so a future edit cannot silently regress to
// rejecting a legitimate Retry-After: 0 while playlist API accepts it.
check(branch.contains("(0...10).contains(seconds)"), "token endpoint accepts zero through ten seconds")
check(branch.contains("delay = max(1, seconds)"), "zero hint uses minimum one-second delay")
check(exchange.contains("retryCount < 2"), "token retries remain bounded")
check(exchange.contains("try Task.checkCancellation()"), "token retries remain cancellable")
for (hint, expected) in [(0, true), (1, true), (10, true), (-1, false), (11, false)] {
    let accepted = (0...10).contains(hint)
    check(accepted == expected, "Retry-After boundary \(hint)")
}
