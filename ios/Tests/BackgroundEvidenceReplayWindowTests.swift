import Foundation

// Standalone QA model: a successful receipt is not proof of a physical iPhone.
// Run: swift ios/Tests/BackgroundEvidenceReplayWindowTests.swift
struct AuditEvent: Codable {
    let kind: String
    let session: String
    let process: String
    let task: String?
    let time: Int
}
struct ReplayWindow {
    let arm: AuditEvent
    let events: [AuditEvent]
    func completed(_ ticket: String) -> Bool {
        guard arm.kind == "auditArmed", arm.task == nil,
              !arm.session.trimmingCharacters(in: .whitespaces).isEmpty,
              !arm.process.trimmingCharacters(in: .whitespaces).isEmpty,
              !ticket.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        for wake in events where wake.kind == "osBackgroundWake"
            && wake.session == arm.session && wake.process != arm.process
            && !wake.process.isEmpty && (wake.task == nil || wake.task == ticket)
            && wake.time > arm.time {
            for callback in events where callback.kind == "urlSessionCompletion"
                && callback.session == arm.session && callback.process == wake.process
                && callback.task == ticket && callback.time > wake.time {
                if events.contains(where: {
                    $0.kind == "recordingStaged" && $0.session == arm.session
                    && $0.process == wake.process && $0.task == ticket
                    && $0.time > callback.time
                }) { return true }
            }
        }
        return false
    }
}
func e(_ kind: String, _ time: Int, _ task: String? = nil,
       _ process: String = "new", _ session: String = "current") -> AuditEvent {
    AuditEvent(kind: kind, session: session, process: process, task: task, time: time)
}
func check(_ value: Bool, _ message: String) { precondition(value, message) }
let arm = e("auditArmed", 100, nil, "old")
let good = [e("osBackgroundWake", 110), e("urlSessionCompletion", 120, "A"),
            e("recordingStaged", 130, "A")]
check(ReplayWindow(arm: arm, events: good).completed("A"), "valid restart rejected")
let attacks: [[AuditEvent]] = [
    [e("osBackgroundWake", 110, nil, "old"), good[1], good[2]],
    [good[0], e("urlSessionCompletion", 120, "A", "other"), good[2]],
    [good[0], good[1], e("recordingStaged", 130, "A", "other")],
    [e("osBackgroundWake", 110, nil, "new", "prior"), good[1], good[2]],
    [good[0], e("urlSessionCompletion", 120, "A", "new", "prior"), good[2]],
    [good[0], good[1], e("recordingStaged", 130, "A", "new", "prior")],
    [e("osBackgroundWake", 110, "B"), good[1], good[2]],
    [good[0], e("urlSessionCompletion", 120, "B"), good[2]],
    [good[0], good[1], e("recordingStaged", 130, "B")],
    [e("osBackgroundWake", 90), good[1], good[2]],
    [good[0], e("urlSessionCompletion", 110, "A"), good[2]],
    [good[0], good[1], e("recordingStaged", 120, "A")],
    [good[0], e("mockCompletion", 120, "A"), good[2]],
    [good[0], good[1], e("mockStaged", 130, "A")],
    [good[0], good[1]], [good[1], good[2]],
    [e("osBackgroundWake", 110, nil, ""), good[1], good[2]],
    [good[0], e("urlSessionCompletion", 120, "A", ""), good[2]],
    [good[0], good[1], e("recordingStaged", 130, "A", "")]
]
for (index, attack) in attacks.enumerated() {
    check(!ReplayWindow(arm: arm, events: attack).completed("A"),
          "replayed or mismatched evidence accepted: \(index)")
}
for index in 0..<128 {
    let target = "ticket-\(index)"
    let other = "ticket-\(index + 1)"
    let wake = e("osBackgroundWake", 110, index.isMultiple(of: 2) ? target : nil)
    let callback = e("urlSessionCompletion", 120, target)
    let noisy = [e("urlSessionCompletion", 119, other), wake,
                 e("recordingStaged", 130, other), callback]
    let decoded = try JSONDecoder().decode([AuditEvent].self,
                                           from: JSONEncoder().encode(noisy))
    check(!ReplayWindow(arm: arm, events: decoded).completed(target),
          "foreign staged bytes certified ticket \(index)")
    check(ReplayWindow(arm: arm, events: decoded + [e("recordingStaged", 131, target)]).completed(target),
          "valid interleaved callback rejected: \(index)")
}
check(!ReplayWindow(arm: arm, events: good).completed(" "), "empty task accepted")
print("PASS: 19 replay attacks; 128 JSON interleavings; valid restart preserved")
