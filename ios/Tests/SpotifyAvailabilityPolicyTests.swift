import Foundation

// Run with the native SpotifyService source included in the iOS test target.
// This is a deterministic policy fixture; it does not assert live Spotify access.
@main
enum SpotifyAvailabilityPolicyTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }

        check(SpotifyAvailabilityPolicy.localFlag(present: false, decoded: nil) == nil,
              "absent local flag retains unknown status")
        check(SpotifyAvailabilityPolicy.playableFlag(present: false, decoded: nil) == nil,
              "absent playable flag retains unknown status")
        check(SpotifyAvailabilityPolicy.localFlag(present: true, decoded: nil) == true,
              "malformed or null local flag blocks automatic discovery")
        check(SpotifyAvailabilityPolicy.playableFlag(present: true, decoded: nil) == false,
              "malformed or null playable flag blocks automatic discovery")
        check(SpotifyAvailabilityPolicy.localFlag(present: true, decoded: false) == false,
              "explicit nonlocal recording remains eligible")
        check(SpotifyAvailabilityPolicy.playableFlag(present: true, decoded: true) == true,
              "explicit playable recording remains eligible")
        check(SpotifyAvailabilityPolicy.localFlag(present: true, decoded: true) == true,
              "explicit local-only recording remains excluded")
        check(SpotifyAvailabilityPolicy.playableFlag(present: true, decoded: false) == false,
              "explicit unplayable recording remains excluded")
        print("Spotify availability policy fixtures complete")
    }
}
