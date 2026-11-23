import Foundation

// Standalone fault-injection fixture. This models durable archive publication,
// not production MusicLibrary execution or physical-device acceptance.
struct Journal: Codable {
    let archive: String
    let generation: Int
    let expectedBytes: Int
}

enum RecoveryError: Error { case invalidJournal, invalidArchive, unsafePath }
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3shelf-backup-qa-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func assertEqual(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    let passed = try condition()
    precondition(passed, message)
}

func safeRegularFile(_ url: URL) -> Bool {
    var info = stat()
    guard url.path.withCString({ lstat($0, &info) }) == 0 else { return false }
    return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) && info.st_nlink == 1
}

func safeDirectoryChain(_ url: URL) -> Bool {
    var current = url.deletingLastPathComponent().standardizedFileURL
    while true {
        var info = stat()
        guard current.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return false }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { return true }
        current = parent
    }
}

func recover(journal: URL, final: URL, staged: URL) throws -> Bool {
    guard journal.deletingLastPathComponent().standardizedFileURL ==
              final.deletingLastPathComponent().standardizedFileURL,
          staged.deletingLastPathComponent().standardizedFileURL ==
              final.deletingLastPathComponent().standardizedFileURL,
          safeDirectoryChain(journal), safeDirectoryChain(final),
          safeDirectoryChain(staged) else { throw RecoveryError.unsafePath }
    guard safeRegularFile(journal) else { throw RecoveryError.unsafePath }
    let bytes = try Data(contentsOf: journal)
    guard !bytes.isEmpty && bytes.count <= 4096,
          let record = try? JSONDecoder().decode(Journal.self, from: bytes),
          record.archive == final.lastPathComponent,
          record.generation > 0,
          record.expectedBytes > 0 else { throw RecoveryError.invalidJournal }
    // Existing final audio/backup always wins over a staged retry.
    if fm.fileExists(atPath: final.path) {
        guard safeRegularFile(final) else { throw RecoveryError.unsafePath }
        return false
    }
    guard safeRegularFile(staged) else { throw RecoveryError.unsafePath }
    let candidate = try Data(contentsOf: staged)
    guard candidate.count == record.expectedBytes else { throw RecoveryError.invalidArchive }
    try fm.moveItem(at: staged, to: final)
    return true
}

for index in 0..<80 {
    let folder = root.appendingPathComponent("case-\(index)")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let final = folder.appendingPathComponent("library.mp3shelf")
    let staged = folder.appendingPathComponent("library.pending")
    let journal = folder.appendingPathComponent("library.journal")
    let payload = Data((0..<256).map { UInt8(($0 + index) % 251) })
    try payload.write(to: staged)
    try JSONEncoder().encode(Journal(archive: final.lastPathComponent, generation: 1, expectedBytes: payload.count)).write(to: journal)
    switch index % 8 {
    case 0: // interrupted before publication: exact bytes recover
        try assertEqual(try recover(journal: journal, final: final, staged: staged), "publication failed")
        try assertEqual(try Data(contentsOf: final) == payload, "recovered bytes differ")
    case 1: // replay must never overwrite existing backup
        let existing = Data("existing user backup".utf8)
        try existing.write(to: final)
        try assertEqual(try recover(journal: journal, final: final, staged: staged) == false, "replayed publication")
        try assertEqual(try Data(contentsOf: final) == existing, "existing backup overwritten")
    case 2: // truncated staged backup must remain quarantined
        try Data(payload.dropLast()).write(to: staged)
        do { _ = try recover(journal: journal, final: final, staged: staged); fatalError("truncated accepted") }
        catch RecoveryError.invalidArchive { }
        try assertEqual(!fm.fileExists(atPath: final.path), "truncated backup published")
    case 3: // journal identity mismatch
        try JSONEncoder().encode(Journal(archive: "foreign.mp3shelf", generation: 1, expectedBytes: payload.count)).write(to: journal)
        do { _ = try recover(journal: journal, final: final, staged: staged); fatalError("foreign journal accepted") }
        catch RecoveryError.invalidJournal { }
    case 4: // empty and oversized journals
        try Data(repeating: 0x20, count: index % 16 == 4 ? 0 : 4097).write(to: journal)
        do { _ = try recover(journal: journal, final: final, staged: staged); fatalError("invalid journal accepted") }
        catch RecoveryError.invalidJournal { }
    case 5: // symlink staged payload must not escape sandbox
        let external = folder.appendingPathComponent("external")
        try payload.write(to: external)
        try fm.removeItem(at: staged)
        try fm.createSymbolicLink(at: staged, withDestinationURL: external)
        do { _ = try recover(journal: journal, final: final, staged: staged); fatalError("symlink accepted") }
        catch RecoveryError.unsafePath { }
        try assertEqual(try Data(contentsOf: external) == payload, "external bytes changed")
    case 6: // hard-linked staged payload must not be moved
        let external = folder.appendingPathComponent("external")
        try fm.moveItem(at: staged, to: external)
        try assertEqual(external.path.withCString { src in staged.path.withCString { dst in link(src, dst) } } == 0, "hardlink setup failed")
        do { _ = try recover(journal: journal, final: final, staged: staged); fatalError("hardlink accepted") }
        catch RecoveryError.unsafePath { }
        try assertEqual(try Data(contentsOf: external) == payload, "hardlink bytes changed")
    default: // malformed generation must fail closed
        try JSONEncoder().encode(Journal(archive: final.lastPathComponent, generation: 0, expectedBytes: payload.count)).write(to: journal)
        do { _ = try recover(journal: journal, final: final, staged: staged); fatalError("zero generation accepted") }
        catch RecoveryError.invalidJournal { }
    }
}
print("PASS: 80 standalone backup publication crash/replay/identity/bounds/link scenarios")

let externalFolder = root.appendingPathComponent("external-recovery")
try fm.createDirectory(at: externalFolder, withIntermediateDirectories: true)
let aliasFolder = root.appendingPathComponent("external-alias")
try fm.createSymbolicLink(at: aliasFolder, withDestinationURL: externalFolder)
for index in 0..<64 {
    let folder = root.appendingPathComponent("boundary-\(index)")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let final = folder.appendingPathComponent("library.mp3shelf")
    let staged = folder.appendingPathComponent("library.pending")
    let journal = folder.appendingPathComponent("library.journal")
    let external = externalFolder.appendingPathComponent("foreign-\(index).pending")
    let bytes = Data("USER-ARCHIVE-\(index)".utf8)
    try bytes.write(to: staged)
    try bytes.write(to: external)
    let record = Journal(archive: final.lastPathComponent, generation: 1, expectedBytes: bytes.count)
    try JSONEncoder().encode(record).write(to: journal)
    do {
        _ = try recover(journal: journal, final: final, staged: external)
        fatalError("foreign directory staged archive accepted")
    } catch RecoveryError.unsafePath { }
    let aliasStaged = aliasFolder.appendingPathComponent("foreign-\(index).pending")
    let aliasFinal = aliasFolder.appendingPathComponent("library.mp3shelf")
    let aliasJournal = aliasFolder.appendingPathComponent("library.journal")
    try JSONEncoder().encode(record).write(to: externalFolder.appendingPathComponent("library.journal"))
    do {
        _ = try recover(journal: aliasJournal, final: aliasFinal, staged: aliasStaged)
        fatalError("symlink ancestor accepted")
    } catch RecoveryError.unsafePath { }
    try assertEqual(!fm.fileExists(atPath: final.path), "foreign staged archive published")
    try assertEqual(try Data(contentsOf: staged) == bytes, "local staged archive changed")
    try assertEqual(try Data(contentsOf: external) == bytes, "external staged archive changed")
    try assertEqual(!fm.fileExists(atPath: externalFolder.appendingPathComponent("library.mp3shelf").path),
                    "redirected archive published")
    try assertEqual(try recover(journal: journal, final: final, staged: staged),
                    "valid local recovery failed")
    try assertEqual(try Data(contentsOf: final) == bytes, "valid recovery bytes changed")
}
print("PASS: 64 cross-directory staging and 64 redirected-ancestor rejection cases")
