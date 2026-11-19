import Foundation

// Run from repository root: swift ios/Tests/ArchiveMixedFormatAmbiguityTests.swift
// Source-backed regression for the Archive candidate uniqueness gate.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
guard let begin = source.range(of: "    static func archiveCandidate(_ item: ArchiveItem,"),
      let end = source.range(of: "\n}\n\n\n// Openverse", range: begin.upperBound..<source.endIndex) else {
    fatalError("Archive candidate source boundaries changed")
}
let candidate = String(source[begin.lowerBound..<end.lowerBound])
func check(_ condition: Bool, _ message: String) {
    precondition(condition, "FAIL: " + message)
    print("PASS: " + message)
}
check(candidate.contains("audioExtensions.contains((file.name as NSString).pathExtension.lowercased())"),
      "candidate inventory counts other playable formats")
check(candidate.contains("eligible.allSatisfy({ safeMP3File($0.name) })"),
      "non-MP3 original disqualifies unattended MP3 selection")
check(candidate.contains("let originals = audioFiles.filter { $0.source == \"original\" }"),
      "originals remain authoritative over generated derivatives")

// Independent deterministic cases for the selection contract.
struct File { let name: String; let original: Bool }
let supported = Set(["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "wma"])
func safeAutomaticMP3(_ files: [File]) -> Bool {
    let audio = files.filter {
        supported.contains(($0.name as NSString).pathExtension.lowercased())
    }
    let originals = audio.filter(\.original)
    let eligible = originals.isEmpty ? audio : originals
    return eligible.count == 1 && eligible[0].name.lowercased().hasSuffix(".mp3")
}
check(safeAutomaticMP3([File(name: "Song.mp3", original: true)]),
      "single original MP3 remains eligible")
check(!safeAutomaticMP3([File(name: "Song.mp3", original: true),
                         File(name: "Song.flac", original: true)]),
      "competing FLAC original prevents false unique MP3")
check(!safeAutomaticMP3([File(name: "Song.mp3", original: true),
                         File(name: "Song.m4a", original: true)]),
      "competing M4A original prevents false unique MP3")
check(safeAutomaticMP3([File(name: "Song.mp3", original: true),
                        File(name: "Song.m4a", original: false)]),
      "generated derivative does not displace sole original")
check(!safeAutomaticMP3([File(name: "Song.wav", original: true),
                         File(name: "Song.mp3", original: false)]),
      "generated MP3 is not substituted for a WAV original")
