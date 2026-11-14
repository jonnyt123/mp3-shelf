import Foundation

// Run from repository root: swift ios/Tests/BackgroundConversionRecoveryTests.swift
// A conversion can own staged audio before its ticket enters processing.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift", encoding: .utf8)
guard let start = source.range(of: "    private func recoverAbandonedBackgroundTasks() async {") else {
    fatalError("Orphan recovery implementation not found")
}
let recovery = String(source[start.lowerBound...])
precondition(recovery.contains("isImporting: processing.contains(ticket.id) || conversions[ticket.id] != nil)"),
             "first inventory scan must protect conversion-owned staged audio")
precondition(recovery.contains("isImporting: processing.contains(id) || conversions[id] != nil)"),
             "second inventory scan must recheck conversion ownership after suspension")
print("PASS: conversion ownership blocks both orphan recovery scans")
