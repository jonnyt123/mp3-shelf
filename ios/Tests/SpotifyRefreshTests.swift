import Foundation

// Run from repository root: swift ios/Tests/SpotifyRefreshTests.swift
// Execute the production refresh orchestration with controlled token transport
// and persistence. No browser, Keychain, Spotify credentials or network calls.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/SpotifyService.swift", encoding: .utf8)
func section(_ start: String, _ end: String) -> String {
    guard let a = source.range(of: start),
          let b = source.range(of: end, range: a.upperBound..<source.endIndex) else {
        fatalError("Production refresh boundary changed; update the fixture explicitly")
    }
    return String(source[a.lowerBound..<b.lowerBound])
}
let method = section("    private func refreshAccessToken() async throws {", "    private func exchangeToken(")
    .replacingOccurrences(of: "private func refreshAccessToken", with: "func refreshAccessToken")
let types = section("private struct SpotifyTokens: Codable {", "/// Refuse any redirected")
    .replacingOccurrences(of: "private struct SpotifyTokens", with: "struct SpotifyTokens")
    .replacingOccurrences(of: "private enum SpotifyError", with: "enum SpotifyError")
let fixture = #"""
import Foundation
@MainActor final class RefreshHarness {
    var token: SpotifyTokens?
    var clientID = "fixture-client"
    var authorizationGeneration: UInt64 = 0
    var refreshTask: Task<SpotifyTokens, Error>?
    var exchangeCount = 0
    var storeCount = 0
    var failStore = false
    var exchange: (() async throws -> SpotifyTokens)!
    init(_ token: SpotifyTokens) { self.token = token }
    func store(tokens value: SpotifyTokens) throws {
        if failStore { throw SpotifyError.api("Fixture persistence failed") }
        storeCount += 1
        token = value
    }
    func exchangeToken(_ fields: [String: String], oldRefresh: String?) async throws -> SpotifyTokens {
        exchangeCount += 1
        return try await exchange()
    }
    func disconnect() {
        authorizationGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        token = nil
    }
__METHOD__
}
@main enum RefreshTests {
    @MainActor static func main() async throws {
        func check(_ value: Bool, _ label: String) {
            precondition(value, "FAIL: " + label)
            print("PASS: " + label)
        }
        let old = SpotifyTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast)
        let fresh = SpotifyTokens(accessToken: "fresh-access", refreshToken: "rotated-refresh", expiresAt: .distantFuture)
        // A waiter may durably store the shared result before the refresh
        // owner's continuation resumes. The owner must recognize that success.
        let first = RefreshHarness(old)
        first.exchange = {
            try first.store(tokens: fresh)
            return fresh
        }
        try await first.refreshAccessToken()
        check(first.token?.refreshToken == fresh.refreshToken && first.storeCount == 1 && first.refreshTask == nil,
              "owner accepts shared result already persisted by a waiter")

        // Providers may rotate the refresh credential without changing access.
        let sameAccess = SpotifyTokens(accessToken: old.accessToken, refreshToken: "rotated-only", expiresAt: .distantFuture)
        let waiter = RefreshHarness(old)
        waiter.refreshTask = Task { sameAccess }
        try await waiter.refreshAccessToken()
        check(waiter.token?.refreshToken == "rotated-only" && waiter.storeCount == 1,
              "waiter persists rotated refresh token even when access token is unchanged")

        let renewed = SpotifyTokens(accessToken: old.accessToken, refreshToken: old.refreshToken, expiresAt: .distantFuture)
        let renewal = RefreshHarness(old)
        renewal.exchange = { renewed }
        try await renewal.refreshAccessToken()
        check(renewal.token?.expiresAt == .distantFuture && renewal.storeCount == 1,
              "unchanged credential strings still persist renewed expiry")

        let concurrent = RefreshHarness(old)
        concurrent.exchange = {
            try await Task.sleep(nanoseconds: 20_000_000)
            return fresh
        }
        let a = Task { try await concurrent.refreshAccessToken() }
        await Task.yield()
        let b = Task { try await concurrent.refreshAccessToken() }
        try await a.value
        try await b.value
        check(concurrent.exchangeCount == 1 && concurrent.token?.refreshToken == fresh.refreshToken,
              "overlapping refreshes share one transport and retain rotated credentials")

        let disconnected = RefreshHarness(old)
        disconnected.exchange = {
            disconnected.disconnect()
            return fresh
        }
        do {
            try await disconnected.refreshAccessToken()
            preconditionFailure("Disconnected owner accepted stale token")
        } catch {}
        check(disconnected.token == nil && disconnected.storeCount == 0 && disconnected.refreshTask == nil,
              "disconnect during exchange cannot resurrect credentials")

        let switched = RefreshHarness(old)
        switched.exchange = {
            switched.authorizationGeneration &+= 1
            switched.token = SpotifyTokens(accessToken: "other-account", refreshToken: "other-refresh", expiresAt: .distantFuture)
            return fresh
        }
        do {
            try await switched.refreshAccessToken()
            preconditionFailure("Account switch accepted stale token")
        } catch {}
        check(switched.token?.accessToken == "other-account" && switched.storeCount == 0,
              "account switch preserves replacement account credentials")

        let storage = RefreshHarness(old)
        storage.failStore = true
        storage.exchange = { fresh }
        do {
            try await storage.refreshAccessToken()
            preconditionFailure("Persistence failure was hidden")
        } catch {}
        check(storage.token?.refreshToken == old.refreshToken && storage.refreshTask == nil,
              "failed persistence retains recoverable old credentials and releases shared task")
        storage.failStore = false
        try await storage.refreshAccessToken()
        check(storage.token?.refreshToken == fresh.refreshToken && storage.exchangeCount == 2,
              "refresh can be retried after a persistence failure")

        let cancelled = RefreshHarness(old)
        cancelled.exchange = {
            try await Task.sleep(nanoseconds: 20_000_000)
            return fresh
        }
        let cancelledCall = Task { try await cancelled.refreshAccessToken() }
        await Task.yield()
        cancelledCall.cancel()
        do {
            try await cancelledCall.value
            preconditionFailure("Cancelled refresh accepted credentials")
        } catch {}
        check(cancelled.storeCount == 0 && cancelled.refreshTask == nil,
              "cancelled caller does not persist a late refresh result")
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spotify-refresh-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("Refresh.swift")
try (types + "\n" + fixture.replacingOccurrences(of: "__METHOD__", with: method))
    .write(to: file, atomically: true, encoding: .utf8)
func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "SpotifyRefreshTests", code: Int(process.terminationStatus))
    }
}
try run(["swiftc", "-parse-as-library", file.path, "-o", directory.appendingPathComponent("tests").path])
try run([directory.appendingPathComponent("tests").path])
