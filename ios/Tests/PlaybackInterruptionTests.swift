import Foundation

@main
enum PlaybackInterruptionTests {
    static func main() {
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
        }
        var state = PlaybackInterruptionState()
        state.began(wasPlaying: true)
        check(state.ended(systemAllowsResume: true), "Playing audio resumes when permitted")
        check(!state.ended(systemAllowsResume: true), "Resume permission is consumed once")
        state.began(wasPlaying: false)
        check(!state.ended(systemAllowsResume: true), "Paused audio stays paused")
        state.began(wasPlaying: true)
        check(!state.ended(systemAllowsResume: false), "System denial prevents resume")
        check(!state.wantsResume, "System denial clears stale intent")
        state.began(wasPlaying: true)
        state.cancelResume()
        check(!state.ended(systemAllowsResume: true), "Manual pause, stop or route loss prevents resume")
        state.began(wasPlaying: true)
        state.began(wasPlaying: false)
        check(state.ended(systemAllowsResume: true), "Repeated begin preserves active listening intent")
        print("PASS: playback interruption resume policy")
    }
}
