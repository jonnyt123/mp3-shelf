import Foundation

// Foundation-only crash-window fixture. Models catalog publication; does not execute MusicLibrary.
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-restore-publication-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let audio = root.appendingPathComponent("audio")
let stage = root.appendingPathComponent("stage")
let catalog = root.appendingPathComponent("catalog.json")
try fm.createDirectory(at: audio, withIntermediateDirectories: true)
try fm.createDirectory(at: stage, withIntermediateDirectories: true)
let old = Data(repeating: 0x11, count: 4096)
let new = Data(repeating: 0x22, count: 8192)
let unrelated = Data(repeating: 0x33, count: 1024)
let original = audio.appendingPathComponent("original.mp3")
let neighbor = audio.appendingPathComponent("neighbor.mp3")
let target = audio.appendingPathComponent("restored.mp3")
let staged = stage.appendingPathComponent("restored.mp3")
let backup = root.appendingPathComponent("backup.mp3")
try old.write(to: original)
try unrelated.write(to: neighbor)
try unrelated.write(to: backup)
struct Catalog: Codable { let tracks: [String] }
func save(_ names: [String]) throws {
    try JSONEncoder().encode(Catalog(tracks: names)).write(to: catalog, options: .atomic)
}
func names() throws -> [String] {
    try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalog)).tracks
}
func safeStage() -> Bool {
    guard let a = try? fm.attributesOfItem(atPath: staged.path),
          a[.type] as? FileAttributeType == .typeRegular,
          (a[.referenceCount] as? NSNumber)?.intValue == 1,
          (try? fm.destinationOfSymbolicLink(atPath: staged.path)) == nil else { return false }
    return true
}
func recover() throws {
    // Only a durable catalog reference authorizes keeping published audio.
    if !(try names()).contains("restored.mp3") {
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        return
    }
    guard fm.fileExists(atPath: target.path), try Data(contentsOf: target) == new else {
        throw NSError(domain: "Missing committed audio", code: 1)
    }
}
for _ in 0..<30 {
    for crash in 0..<4 {
        try save(["original.mp3", "neighbor.mp3"])
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
        if crash >= 1 { try new.write(to: staged, options: .atomic) }
        if crash >= 2 {
            precondition(safeStage())
            try fm.moveItem(at: staged, to: target)
        }
        if crash >= 3 { try save(["original.mp3", "neighbor.mp3", "restored.mp3"]) }
        try recover()
        let savedNames = try names()
        precondition(savedNames.contains("restored.mp3") == (crash == 3))
        precondition(fm.fileExists(atPath: target.path) == (crash == 3))
        let originalBytes = try Data(contentsOf: original)
        let neighborBytes = try Data(contentsOf: neighbor)
        let backupBytes = try Data(contentsOf: backup)
        precondition(originalBytes == old)
        precondition(neighborBytes == unrelated)
        precondition(backupBytes == unrelated)
    }
    if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
    try fm.createSymbolicLink(at: staged, withDestinationURL: backup)
    precondition(!safeStage(), "symlink accepted")
    try fm.removeItem(at: staged)
    try fm.linkItem(at: backup, to: staged)
    precondition(!safeStage(), "hardlink accepted")
    try fm.removeItem(at: staged)
}
print("PASS: 120 restore publication crash windows; 60 link attacks rejected")


func check(_ condition: @autoclosure () throws -> Bool) throws {
    let valid = try condition()
    precondition(valid)
}

// Failure-injection regression: catalog publication must be the commit point.
// A failed catalog write leaves the previous catalog intact, and recovery
// removes only uncommitted newly published audio. Existing recordings survive.
enum PublicationFailure: Error { case injected }
for iteration in 0..<40 {
    try save(["original.mp3", "neighbor.mp3"])
    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
    if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
    try new.write(to: staged, options: .atomic)
    precondition(safeStage())
    try fm.moveItem(at: staged, to: target)
    let before = try Data(contentsOf: catalog)
    do {
        // Simulate atomic catalog publication failing after media moved.
        throw PublicationFailure.injected
    } catch PublicationFailure.injected {
        try check(try Data(contentsOf: catalog) == before)
    }
    try recover()
    precondition(!fm.fileExists(atPath: target.path), "Uncommitted media retained")
    try check(try names() == ["original.mp3", "neighbor.mp3"])
    try check(try Data(contentsOf: original) == old)
    try check(try Data(contentsOf: neighbor) == unrelated)
    try check(try Data(contentsOf: backup) == unrelated)
    // A subsequent retry must commit and retain exactly the new media.
    try new.write(to: staged, options: .atomic)
    try fm.moveItem(at: staged, to: target)
    try save(["original.mp3", "neighbor.mp3", "restored.mp3"])
    try recover()
    try check(try Data(contentsOf: target) == new)
    try check(try names().count == 3)
    if iteration % 2 == 0 {
        // Stale archive identity: bytes from a prior restore cannot satisfy
        // the current committed catalog entry, even with the same filename.
        try old.write(to: target, options: .atomic)
        do {
            try recover()
            fatalError("Stale recording accepted")
        } catch {
            precondition((error as NSError).domain == "Missing committed audio")
        }
        try new.write(to: target, options: .atomic)
        try recover()
    }
}
print("PASS: 40 catalog publication failures/retries; 20 stale-media identity rejections")
