import Foundation

// Independent Foundation-only regression. This is not an Xcode or iPhone PASS.
// The production downloader must reject a non-regular active ticket journal
// before decoding or replacing it; fileExists follows symlinks and is unsafe.
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-active-manifest-\(UUID())", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func isRegularManifest(_ url: URL) -> Bool {
    guard let attributes = try? fm.attributesOfItem(atPath: url.path),
          let type = attributes[.type] as? FileAttributeType else { return false }
    return type == .typeRegular
}

func safeCheckpoint(_ data: Data, at url: URL) throws {
    guard isRegularManifest(url) else {
        throw NSError(domain: "MP3ManifestPathSafety", code: 1)
    }
    try data.write(to: url, options: .atomic)
}

let external = root.appendingPathComponent("external-evidence")
let original = Data("preserve existing download ownership".utf8)
try original.write(to: external, options: .atomic)
let staged = root.appendingPathComponent("staged.mp3")
let audio = Data([0x49, 0x44, 0x33, 0x04, 0, 0, 0, 0])
try audio.write(to: staged, options: .atomic)

for (label, target) in [("external", external),
                        ("dangling", root.appendingPathComponent("missing"))] {
    let folder = root.appendingPathComponent(label, isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let active = folder.appendingPathComponent("tickets.json")
    try fm.createSymbolicLink(at: active, withDestinationURL: target)
    guard !isRegularManifest(active) else {
        fatalError("FAIL: symlink accepted as regular active journal")
    }
    do {
        try safeCheckpoint(Data("[]".utf8), at: active)
        fatalError("FAIL: symlink checkpoint accepted")
    } catch let error as NSError where error.domain == "MP3ManifestPathSafety" && error.code == 1 {
        let attributes = try fm.attributesOfItem(atPath: active.path)
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              try Data(contentsOf: external) == original,
              try Data(contentsOf: staged) == audio else {
            fatalError("FAIL: symlink, external evidence or staged audio modified")
        }
    }
}

let directory = root.appendingPathComponent("directory-collision", isDirectory: true)
try fm.createDirectory(at: directory, withIntermediateDirectories: true)
guard !isRegularManifest(directory) else { fatalError("FAIL: directory accepted") }
do {
    try safeCheckpoint(Data("[]".utf8), at: directory)
    fatalError("FAIL: directory checkpoint accepted")
} catch let error as NSError where error.domain == "MP3ManifestPathSafety" && error.code == 1 {
    guard (try fm.attributesOfItem(atPath: directory.path))[.type] as? FileAttributeType == .typeDirectory else {
        fatalError("FAIL: directory collision destroyed")
    }
}

let valid = root.appendingPathComponent("valid.json")
try Data("[{\"id\":1}]".utf8).write(to: valid, options: .atomic)
try safeCheckpoint(Data("[]".utf8), at: valid)
guard try Data(contentsOf: valid) == Data("[]".utf8),
      try Data(contentsOf: external) == original,
      try Data(contentsOf: staged) == audio else {
    fatalError("FAIL: normal checkpoint or evidence preservation")
}
print("PASS: active manifest symlink, dangling link, directory and regular-file fixture")


// A redirected parent can expose a regular-looking leaf outside the intended
// journal directory. Reject it without modifying queued state or staged audio.
let existing = root.appendingPathComponent("existing.json")
let queued = Data(#"[{"id":"queued","status":"queued"}]"#.utf8)
try queued.write(to: existing, options: .atomic)
let redirectedParent = root.appendingPathComponent("redirected-parent")
try fm.createSymbolicLink(at: redirectedParent, withDestinationURL: root)
let redirectedManifest = redirectedParent.appendingPathComponent("existing.json")

func safeCheckpointWithoutRedirectedParent(_ data: Data, at url: URL) throws {
    var current = url.deletingLastPathComponent()
    while current.path != "/" {
        let attributes = try fm.attributesOfItem(atPath: current.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw NSError(domain: "MP3ManifestPathSafety", code: 2)
        }
        current.deleteLastPathComponent()
    }
    try safeCheckpoint(data, at: url)
}
do {
    try safeCheckpointWithoutRedirectedParent(Data("[]".utf8), at: redirectedManifest)
    fatalError("FAIL: redirected parent checkpoint accepted")
} catch let error as NSError where error.domain == "MP3ManifestPathSafety" && error.code == 2 {
    guard try Data(contentsOf: existing) == queued,
          try Data(contentsOf: staged) == audio,
          try Data(contentsOf: external) == original else {
        fatalError("FAIL: redirected parent changed journal or audio")
    }
}
try safeCheckpointWithoutRedirectedParent(Data("[]".utf8), at: existing)
guard try Data(contentsOf: existing) == Data("[]".utf8) else {
    fatalError("FAIL: ordinary journal checkpoint rejected")
}
print("PASS: redirected parent denied without altering queued state or audio")
