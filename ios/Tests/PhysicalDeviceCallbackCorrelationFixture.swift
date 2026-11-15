import Foundation

// Independent evidence-correlation fixture. This models the acceptance rule,
// not the production PhysicalDeviceAudit implementation or hardware proof.
struct Event: Codable {
    let kind: String
    let process: String
    let session: String
    let task: String?
    let time: Int
}
struct Evidence {
    let armed: Event
    let events: [Event]

    func hasBackgroundCompletion(task: String) -> Bool {
        // An OS wake must precede a production delegate completion and a
        // staged-file event for the same task in the same restarted process.
        let matching = events.filter {
            $0.process == armed.process && $0.session == armed.session
        }.sorted { $0.time < $1.time }
        guard let wake = matching.first(where: { $0.kind == "osBackgroundWake" && $0.time > armed.time }) else { return false }
        guard let completion = matching.first(where: {
            $0.kind == "urlSessionCompletion" && $0.task == task && $0.time > wake.time
        }) else { return false }
        guard matching.contains(where: {
            $0.kind == "recordingStaged" && $0.task == task && $0.time > completion.time
        }) else { return false }
        return true
    }
}
func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}
let arm = Event(kind: "auditArmed", process: "process-2", session: "session-new", task: nil, time: 100)
func event(_ kind: String, _ time: Int, _ task: String? = nil,
           process: String = "process-2", session: String = "session-new") -> Event {
    Event(kind: kind, process: process, session: session, task: task, time: time)
}
let valid = [
    event("osBackgroundWake", 110),
    event("urlSessionCompletion", 120, "task-A"),
    event("recordingStaged", 130, "task-A")
]
check(Evidence(armed: arm, events: valid).hasBackgroundCompletion(task: "task-A"), "valid evidence rejected")
let invalid: [[Event]] = [
    // No OS callback or no durable staging event.
    Array(valid.dropFirst()),
    Array(valid.dropLast()),
    // A previous app process or audit session cannot supply the wake.
    [event("osBackgroundWake", 110, process: "process-old"), valid[1], valid[2]],
    [event("osBackgroundWake", 110, session: "session-old"), valid[1], valid[2]],
    // A completion and staging event for different tasks are not correlated.
    [valid[0], event("urlSessionCompletion", 120, "task-B"), valid[2]],
    [valid[0], valid[1], event("recordingStaged", 130, "task-B")],
    // Old events, reordered events and mock-only events are not proof.
    [event("osBackgroundWake", 90), valid[1], valid[2]],
    [valid[0], event("recordingStaged", 115, "task-A"), valid[1]],
    [valid[0], event("mockCompletion", 120, "task-A"), valid[2]],
    // A different process cannot provide the delegate callback.
    [valid[0], event("urlSessionCompletion", 120, "task-A", process: "process-old"), valid[2]],
    // A different audit session cannot provide staging evidence.
    [valid[0], valid[1], event("recordingStaged", 130, "task-A", session: "session-old")]
]
for (index, events) in invalid.enumerated() {
    check(!Evidence(armed: arm, events: events).hasBackgroundCompletion(task: "task-A"),
          "invalid evidence case \(index) was accepted")
}
// Exercise Codable with actual serialized events, not only in-memory structs.
let encoded = try JSONEncoder().encode(valid)
let decoded = try JSONDecoder().decode([Event].self, from: encoded)
check(Evidence(armed: arm, events: decoded).hasBackgroundCompletion(task: "task-A"),
      "JSON evidence round-trip failed")
print("PASS: same-process/session/task wake-completion-staging correlation; 11 negative cases")
