import Foundation

// Compile with BackgroundAudioDownloader and its native dependencies.
// Offline fixture: no network, URLSession daemon or cellular data required.
@main
enum RestoredCellularUpgradePolicyTests {
    static func main() {
        func expect(_ actual: Bool, _ expected: Bool, _ scenario: String) {
            guard actual == expected else { fatalError("FAIL: \(scenario)") }
            print("PASS: \(scenario)")
        }
        func request(_ cellular: Bool) -> URLRequest {
            var value = URLRequest(url: URL(string: "https://example.org/recording.mp3")!)
            value.allowsCellularAccess = cellular
            return value
        }
        func upgrade(_ original: URLRequest?, _ current: URLRequest?) -> Bool {
            BackgroundAudioDownloader.needsCellularUpgrade(original: original, current: current)
        }
        expect(upgrade(request(false), request(false)), true,
               "original Wi-Fi task upgrades")
        expect(upgrade(nil, request(false)), true,
               "restored task with currentRequest only upgrades")
        expect(upgrade(nil, nil), true,
               "restored task without either request upgrades after explicit consent")
        expect(upgrade(request(false), request(true)), true,
               "original Wi-Fi restriction cannot be masked by redirected current request")
        expect(upgrade(request(true), request(false)), true,
               "current Wi-Fi restriction is respected")
        expect(upgrade(request(true), request(true)), false,
               "already-cellular task is not replaced")
        expect(upgrade(nil, request(true)), false,
               "restored current cellular task is not replaced")
        expect(upgrade(request(true), nil), false,
               "known original cellular task is not replaced")
    }
}
