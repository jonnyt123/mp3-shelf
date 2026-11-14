import Foundation

// Source-bound, network-independent regression for catalog response redirects.
// Compile with AudioSourceFinder.swift and its native model dependencies.
@main
enum CatalogResponseOriginTests {
    static func main() {
        func expect(_ result: Bool, _ label: String) {
            guard result else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }
        let original = URL(string: "https://api.openverse.org/v1/audio/?page=1")!
        let trusted = AudioSourceFinder.trustedCatalogResponse
        expect(trusted(requested: original, final: original),
               "unchanged HTTPS catalog origin is accepted")
        expect(trusted(requested: original,
                       final: URL(string: "https://api.openverse.org/v1/audio/?page=2")),
               "same-origin pagination is accepted")
        expect(trusted(requested: original,
                       final: URL(string: "https://API.OPENVERSE.ORG/v1/audio/")),
               "hostname matching is case insensitive")
        expect(!trusted(requested: original,
                        final: URL(string: "http://api.openverse.org/v1/audio/")),
               "HTTPS downgrade is rejected")
        expect(!trusted(requested: original,
                        final: URL(string: "https://evil.example/v1/audio/")),
               "cross-origin catalog redirects are rejected")
        expect(!trusted(requested: original,
                        final: URL(string: "https://api.openverse.org.evil.example/v1/audio/")),
               "lookalike subdomain is rejected")
        expect(!trusted(requested: original,
                        final: URL(string: "https://user:pass@api.openverse.org/v1/audio/")),
               "credential-bearing final URLs are rejected")
        expect(!trusted(requested: original,
                        final: URL(string: "https://api.openverse.org:8443/v1/audio/")),
               "unexpected final port is rejected")
        expect(!trusted(requested: original,
                        final: URL(string: "https://api.openverse.org/v1/audio/#fragment")),
               "fragment-bearing final URL is rejected")
        expect(!trusted(requested: original, final: nil),
               "missing final URL is rejected")
        expect(!trusted(requested: URL(string: "http://api.openverse.org/v1/audio/")!,
                        final: original),
               "insecure original request is rejected")
    }
}
