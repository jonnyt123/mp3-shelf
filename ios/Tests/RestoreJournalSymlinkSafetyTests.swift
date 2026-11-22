import Foundation

// Standalone filesystem regression fixture. Does not execute production restore.
// swift ios/Tests/RestoreJournalSymlinkSafetyTests.swift
func check(_ condition: Bool, _ message: String) {
    guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-restore-link-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let outside = root.appendingPathComponent("outside")
let workspace = root.appendingPathComponent("workspace")
try fm.createDirectory(at: outside, withIntermediateDirectories: true)
try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
let victim = outside.appendingPathComponent("owned.mp3")
let bytes = Data((0..<8192).map { UInt8($0 % 251) })
try bytes.write(to: victim, options: .atomic)
let journal = workspace.appendingPathComponent("restore-journal.json")
let archive = workspace.appendingPathComponent("restored.mp3")
let hostile = workspace.appendingPathComponent("incoming")
try fm.createSymbolicLink(at: hostile, withDestinationURL: outside)

func isSafeChild(_ destination: URL, under base: URL) -> Bool {
    let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL
    let resolved = destination.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    let prefix = resolvedBase.path.hasSuffix("/") ? resolvedBase.path : resolvedBase.path + "/"
    return resolved.path.hasPrefix(prefix) && resolved.path != resolvedBase.path
}

// The archive may contain relative paths; lexical containment alone is insufficient.
let adversarial = ["../outside/owned.mp3", "incoming/owned.mp3", "incoming/../incoming/owned.mp3", "/tmp/owned.mp3"]
for entry in adversarial {
    let candidate = workspace.appendingPathComponent(entry)
    check(entry.hasPrefix("/") || !isSafeChild(candidate, under: workspace), "accepted escaping archive path: \(entry)")
}
check(isSafeChild(archive, under: workspace), "rejected ordinary child")
check(!isSafeChild(workspace, under: workspace), "accepted root as file")

// A symlink at the journal path must not be used as a trusted recovery record.
try fm.createSymbolicLink(at: journal, withDestinationURL: victim)
var isLink = false
if let attributes = try? fm.attributesOfItem(atPath: journal.path),
   let kind = attributes[.type] as? FileAttributeType {
    isLink = kind == .typeSymbolicLink
}
check(isLink, "journal symlink was not detected")
check((try Data(contentsOf: victim)) == bytes, "journal inspection modified external audio")

// A destination switched to a symlink after path validation must be rechecked
// immediately before publication; reject rather than writing through it.
try fm.createSymbolicLink(at: archive, withDestinationURL: victim)
check(!isSafeChild(archive, under: workspace), "accepted swapped destination symlink")
check((try Data(contentsOf: victim)) == bytes, "destination inspection changed external audio")

// A sibling with the same textual prefix is never inside the workspace.
let sibling = root.appendingPathComponent("workspace-evil/track.mp3")
check(!isSafeChild(sibling, under: workspace), "accepted sibling prefix confusion")
print("PASS: 4 escaping paths, journal/destination symlinks, root and sibling containment; 8192 external bytes preserved")
print("LIMITATION: Foundation filesystem fixture only; production restore, Xcode and iPhone UNVERIFIED")
