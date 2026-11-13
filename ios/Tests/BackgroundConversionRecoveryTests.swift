import Foundation

// Run from repository root: swift ios/Tests/BackgroundConversionRecoveryTests.swift
// Recovery must never replace a queued URLSession ticket while a conversion
// owns its staged file, including the gap before processing registration.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift", encoding: .utf8)
guard let start = source.range(of: "    private func recoverAbandonedBackgroundTasks() async {"),
      let end = source.range(of: "    // MARK:", range: start.upperBound..<source.endIndex) else {
    // Fall back to the next declaration if the source has no MARK separator.
    let tail = String(source[start?.lowerBound ?? source.startIndex...])
    precondition(tail.contains("isImporting: processing.contains(ticket.id) || conversions[ticket.id] != nil)"))
    precondition(tail.contains("isImporting: processing.contains(id) || conversions[id] != nil)"))
    print("PASS: conversion ownership blocks both orphan recovery scans")
    exit(0)
}
let recovery = String(source[start.lowerBound..<end.lowerBound])
precondition(recovery.contains("isImporting: processing.contains(ticket.id) || conversions[ticket.id] != nil)"),
             "first inventory scan must protect conversion-owned staged audio")
precondition(recovery.contains("isImporting: processing.contains(id) || conversions[id] != nil)"),
             "second inventory scan must recheck conversion ownership after suspension")
print("PASS: conversion ownership blocks both orphan recovery scans")
