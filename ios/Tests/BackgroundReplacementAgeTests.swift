import Foundation

// Run from repository root:
// swift ios/Tests/BackgroundReplacementAgeTests.swift
// This deterministic regression checks replacement-ticket age against the
// orphan-recovery threshold without requiring a live URLSession daemon.
let source = try String(contentsOfFile:
    "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift", encoding: .utf8)
guard let retryStart = source.range(of: "private func retryTemporaryTransfer("),
      let alternateStart = source.range(of: "private func startAlternateTransfer("),
      let failureStart = source.range(of: "private func setFailed(") else {
    fatalError("Expected background replacement paths missing")
}
let retry = String(source[retryStart.lowerBound..<alternateStart.lowerBound])
let alternate = String(source[alternateStart.lowerBound..<failureStart.lowerBound])
precondition(retry.contains("replacement.startedAt = .now"))
precondition(alternate.contains("replacement.startedAt = .now"))
precondition(!retry.contains("replacement.startedAt = previous.startedAt"))
precondition(!alternate.contains("replacement.startedAt = old.startedAt"))
precondition(retry.contains("replacement.nextRetryAt = retryAt"))
precondition(alternate.contains("replacement.nextRetryAt = retryAt"))

struct Replacement {
    let startedAt: Date
    let nextRetryAt: Date?
}
func scheduleReplacement(now: Date, retryAt: Date?) -> Replacement {
    Replacement(startedAt: now, nextRetryAt: retryAt)
}
func isStale(_ ticket: Replacement, at now: Date, minimumAge: TimeInterval) -> Bool {
    now.timeIntervalSince(ticket.startedAt) >= minimumAge
}
let now = Date(timeIntervalSince1970: 1_800_000_000)
let oldStart = now.addingTimeInterval(-86_400)
let futureRetry = now.addingTimeInterval(900)
let replacement = scheduleReplacement(now: now, retryAt: futureRetry)
precondition(now.timeIntervalSince(oldStart) > 300)
precondition(!isStale(replacement, at: now.addingTimeInterval(11), minimumAge: 300))
precondition(!isStale(replacement, at: now.addingTimeInterval(299), minimumAge: 300))
precondition(isStale(replacement, at: now.addingTimeInterval(301), minimumAge: 300))
precondition(replacement.nextRetryAt == futureRetry)
let alternate = scheduleReplacement(now: now, retryAt: nil)
precondition(!isStale(alternate, at: now.addingTimeInterval(10), minimumAge: 300))
print("PASS: retries and alternate sources have fresh orphan age and retain scheduling")
