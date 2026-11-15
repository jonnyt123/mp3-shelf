import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Run from repository root:
// swift ios/Tests/CatalogRedirectNetworkConsentTests.swift
// Compile and execute the actual production helper, not a copied policy.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
let start = "    static func redirectRequestPreservingNetworkPolicy("
let end = "\n    private static let catalogSession"
guard let begin = source.range(of: start),
      let finish = source.range(of: end, range: begin.lowerBound..<source.endIndex) else {
    fatalError("Production redirect policy helper not found")
}
let method = String(source[begin.lowerBound..<finish.lowerBound])
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("mp3-catalog-policy-\(UUID().uuidString).swift")
let harness = """
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
enum AudioSourceFinder {
\(method)
}
func check(_ name: String, _ original: URLRequest?, _ proposed: URLRequest,
           _ cellular: Bool, _ expensive: Bool, _ constrained: Bool) {
    let result = AudioSourceFinder.redirectRequestPreservingNetworkPolicy(proposed, original: original)
    precondition(result.allowsCellularAccess == cellular, name + " cellular")
    precondition(result.allowsExpensiveNetworkAccess == expensive, name + " expensive")
    precondition(result.allowsConstrainedNetworkAccess == constrained, name + " constrained")
    precondition(result.url == proposed.url, name + " URL")
    print("PASS: " + name)
}
let url = URL(string: "https://api.openverse.org/v1/audio/?page=2")!
var allowed = URLRequest(url: url)
allowed.allowsCellularAccess = true
allowed.allowsExpensiveNetworkAccess = true
allowed.allowsConstrainedNetworkAccess = true
var restricted = URLRequest(url: url)
restricted.allowsCellularAccess = false
restricted.allowsExpensiveNetworkAccess = false
restricted.allowsConstrainedNetworkAccess = false
check("Wi-Fi-only request survives permissive redirect", restricted, allowed, false, false, false)
check("explicit cellular consent survives", allowed, allowed, true, true, true)
check("missing original metadata fails closed", nil, allowed, false, false, false)
check("redirect cannot expand cellular consent", allowed, restricted, false, false, false)
var mixed = allowed
mixed.allowsExpensiveNetworkAccess = false
check("independent expensive restriction", mixed, allowed, true, false, true)
var mixed2 = allowed
mixed2.allowsConstrainedNetworkAccess = false
check("independent constrained restriction", mixed2, allowed, true, true, false)
"""
defer { try? FileManager.default.removeItem(at: temporary) }
try harness.write(to: temporary, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", temporary.path]
try process.run()
process.waitUntilExit()
precondition(process.terminationStatus == 0, "Compiled production redirect policy regression failed")
