import Foundation

// Standalone crash-journal model; not a production archive-service integration test.
// Run: swift ios/Tests/RestoreCrashJournalRecoveryTests.swift
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-crash-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let live = root.appendingPathComponent("live")
let stage = root.appendingPathComponent("stage")
let backup = root.appendingPathComponent("backup")
let journal = root.appendingPathComponent("journal")
let old = Data(repeating: 0x41, count: 4096)
let next = Data(repeating: 0x42, count: 8192)
func make(_ url: URL, _ bytes: Data) throws {
    try fm.createDirectory(at: url, withIntermediateDirectories: false)
    try bytes.write(to: url.appendingPathComponent("song.mp3"), options: .atomic)
    try Data("library-index".utf8).write(to: url.appendingPathComponent("index.json"), options: .atomic)
}
func isRegularUnredirectedFile(_ url: URL) -> Bool {
    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
          let kind = attrs[.type] as? FileAttributeType else { return false }
    return kind == .typeRegular
}
func matches(_ url: URL, _ bytes: Data) -> Bool {
    let song = url.appendingPathComponent("song.mp3")
    let index = url.appendingPathComponent("index.json")
    // Do not follow redirected metadata/audio inside a seemingly valid backup.
    return isRegularUnredirectedFile(song) && isRegularUnredirectedFile(index) &&
        (try? Data(contentsOf: song)) == bytes &&
        (try? Data(contentsOf: index)) == Data("library-index".utf8)
}
func reset() throws {
    for url in [live, stage, backup, journal] where (try? fm.attributesOfItem(atPath: url.path)) != nil {
        try fm.removeItem(at: url)
    }
    try make(live, old)
    try make(stage, next)
}
func isSymbolicLink(_ url: URL) -> Bool {
    (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
}
func recover() throws {
    for url in [live, stage, backup, journal] where isSymbolicLink(url) {
        throw NSError(domain: "redirected-transaction-path", code: 5)
    }
    guard fm.fileExists(atPath: journal.path) else { return }
    let phase = try String(contentsOf: journal, encoding: .utf8)
    guard ["prepared", "old-moved", "installed"].contains(phase) else {
        throw NSError(domain: "invalid-journal", code: 1)
    }
    if fm.fileExists(atPath: backup.path) {
        guard matches(backup, old) else { throw NSError(domain: "invalid-backup", code: 2) }
        if fm.fileExists(atPath: live.path) {
            guard matches(live, next) else { throw NSError(domain: "ambiguous-live", code: 3) }
            try fm.removeItem(at: backup)
        } else {
            try fm.moveItem(at: backup, to: live)
        }
    } else {
        guard matches(live, old) else { throw NSError(domain: "missing-original", code: 4) }
    }
    if fm.fileExists(atPath: stage.path) { try fm.removeItem(at: stage) }
    try fm.removeItem(at: journal)
}
func check(_ ok: Bool, _ message: String) { if !ok { fatalError(message) } }
try reset()
try Data("prepared".utf8).write(to: journal, options: .atomic)
try recover()
check(matches(live, old) && !fm.fileExists(atPath: journal.path), "prepared recovery")
try reset()
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try recover()
check(matches(live, old) && !fm.fileExists(atPath: backup.path), "rollback after move")
try reset()
try Data("installed".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try fm.moveItem(at: stage, to: live)
try recover()
check(matches(live, next) && !fm.fileExists(atPath: backup.path), "installed recovery")
try reset()
try Data("unknown".utf8).write(to: journal, options: .atomic)
do { try recover(); fatalError("bad journal accepted") } catch {}
check(matches(live, old) && fm.fileExists(atPath: journal.path), "bad journal mutated live")
try reset()
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try make(live, Data([0x77]))
do { try recover(); fatalError("foreign live accepted") } catch {}
check(matches(live, Data([0x77])) && matches(backup, old), "foreign live overwritten")
try reset()
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.removeItem(at: live)
do { try recover(); fatalError("missing original accepted") } catch {}
check(fm.fileExists(atPath: journal.path), "missing original journal discarded")

// Repeating recovery after a completed install must not remove the committed audio.
try reset()
try Data("installed".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try fm.moveItem(at: stage, to: live)
try recover()
try recover()
check(matches(live, next) && !fm.fileExists(atPath: backup.path), "installed recovery idempotence")
// Repeating rollback must preserve both the original recording and its index.
try reset()
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try recover()
try recover()
check(matches(live, old) && !fm.fileExists(atPath: stage.path), "rollback idempotence")
// A corrupted backup must remain available for diagnosis rather than being discarded.
try reset()
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try Data("corrupt".utf8).write(to: backup.appendingPathComponent("song.mp3"), options: .atomic)
var rejectedCorruptBackup = false
do { try recover() } catch { rejectedCorruptBackup = true }
check(rejectedCorruptBackup && fm.fileExists(atPath: journal.path) &&
      fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: live.path),
      "corrupt backup destroyed evidence")
// Journal redirection must not authorize changes to outside transaction metadata.
try reset()
let outsideJournal = root.appendingPathComponent("outside-journal")
try Data("prepared".utf8).write(to: outsideJournal, options: .atomic)
try fm.createSymbolicLink(at: journal, withDestinationURL: outsideJournal)
var rejectedJournal = false
do { try recover() } catch { rejectedJournal = true }
check(rejectedJournal && matches(live, old) && matches(stage, next) &&
      (try Data(contentsOf: outsideJournal)) == Data("prepared".utf8),
      "journal symlink changed outside data")
try fm.removeItem(at: journal)

// Backup redirection must not be treated as a legitimate original recording.
try reset()
let outsideBackup = root.appendingPathComponent("outside-backup")
try make(outsideBackup, old)
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.removeItem(at: live)
try fm.createSymbolicLink(at: backup, withDestinationURL: outsideBackup)
var rejectedBackup = false
do { try recover() } catch { rejectedBackup = true }
check(rejectedBackup && matches(outsideBackup, old) &&
      fm.fileExists(atPath: journal.path) && !fm.fileExists(atPath: live.path),
      "backup symlink consumed outside audio")

// Stage redirection must not be cleaned up as an ordinary transaction directory.
try reset()
let outsideStage = root.appendingPathComponent("outside-stage")
try make(outsideStage, next)
try fm.removeItem(at: stage)
try fm.createSymbolicLink(at: stage, withDestinationURL: outsideStage)
try Data("prepared".utf8).write(to: journal, options: .atomic)
var rejectedStage = false
do { try recover() } catch { rejectedStage = true }
check(rejectedStage && matches(live, old) && matches(outsideStage, next) &&
      fm.fileExists(atPath: journal.path), "stage symlink altered transaction")

// A redirected live library must never be deleted, replaced, or used for rollback.
try reset()
let outsideLive = root.appendingPathComponent("outside-live")
try make(outsideLive, old)
try fm.removeItem(at: live)
try fm.createSymbolicLink(at: live, withDestinationURL: outsideLive)
try Data("prepared".utf8).write(to: journal, options: .atomic)
var rejectedLive = false
do { try recover() } catch { rejectedLive = true }
check(rejectedLive && matches(outsideLive, old) && matches(stage, next) &&
      fm.fileExists(atPath: journal.path), "live symlink modified external audio")

// A dangling journal link must be rejected rather than silently interpreted as
// an absent journal, which would conceal an incomplete transaction.
try reset()
let missingJournal = root.appendingPathComponent("missing-journal-target")
try fm.createSymbolicLink(at: journal, withDestinationURL: missingJournal)
var rejectedDangling = false
do { try recover() } catch { rejectedDangling = true }
check(rejectedDangling && matches(live, old) && matches(stage, next) &&
      isSymbolicLink(journal), "dangling journal symlink was ignored")

// An invalid journal object must not be read as a valid phase or cleaned up.
try reset()
try fm.createDirectory(at: journal, withIntermediateDirectories: false)
var rejectedJournalDirectory = false
do { try recover() } catch { rejectedJournalDirectory = true }
check(rejectedJournalDirectory && matches(live, old) && matches(stage, next) &&
      fm.fileExists(atPath: journal.path), "journal directory was consumed")

// A backup with valid-looking metadata but damaged audio cannot be restored.
try reset()
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try Data().write(to: backup.appendingPathComponent("song.mp3"), options: .atomic)
var rejectedTruncated = false
do { try recover() } catch { rejectedTruncated = true }
check(rejectedTruncated && fm.fileExists(atPath: journal.path) &&
      fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: live.path),
      "truncated backup destroyed recovery evidence")
// A backup's top-level directory can be genuine while its audio points outside.
// The recovery model must not follow that link or discard the journal.
try reset()
let externalAudio = root.appendingPathComponent("external-audio.mp3")
try old.write(to: externalAudio, options: .atomic)
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try fm.removeItem(at: backup.appendingPathComponent("song.mp3"))
try fm.createSymbolicLink(at: backup.appendingPathComponent("song.mp3"), withDestinationURL: externalAudio)
var rejectedLinkedAudio = false
do { try recover() } catch { rejectedLinkedAudio = true }
check(rejectedLinkedAudio && !fm.fileExists(atPath: live.path) &&
      fm.fileExists(atPath: journal.path) && isSymbolicLink(backup.appendingPathComponent("song.mp3")) &&
      (try Data(contentsOf: externalAudio)) == old, "nested audio symlink accepted")

// Index metadata must be equally protected, even when the recording is intact.
try reset()
let externalIndex = root.appendingPathComponent("external-index.json")
try Data("library-index".utf8).write(to: externalIndex, options: .atomic)
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try fm.removeItem(at: backup.appendingPathComponent("index.json"))
try fm.createSymbolicLink(at: backup.appendingPathComponent("index.json"), withDestinationURL: externalIndex)
var rejectedLinkedIndex = false
do { try recover() } catch { rejectedLinkedIndex = true }
check(rejectedLinkedIndex && !fm.fileExists(atPath: live.path) &&
      fm.fileExists(atPath: journal.path) && isSymbolicLink(backup.appendingPathComponent("index.json")) &&
      (try Data(contentsOf: externalIndex)) == Data("library-index".utf8), "nested index symlink accepted")

print("PASS: 18 crash-journal model cases")
