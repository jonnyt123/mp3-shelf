import Foundation

// Network-independent ccMixter RSS regression. Compile with AudioSourceFinder
// and its normal production model dependencies.
@main
enum CCMixterRSSParsingTests {
    static func main() {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            print("PASS: \(message)")
        }
        let wish = PlaylistWish(title: "Example Song", artist: "Example Artist")
        func feed(_ items: String) -> Data {
            Data(("<rss><channel>" + items + "</channel></rss>").utf8)
        }
        func item(_ enclosures: String, title: String = "Example Song") -> String {
            "<item><title>\(title)</title><dc:creator xmlns:dc=\"http://purl.org/dc/elements/1.1/\">Example Artist</dc:creator>" +
            "<link>https://ccmixter.org/files/example/123</link>" + enclosures + "</item>"
        }
        let a = "<enclosure type=\"audio/mpeg\" url=\"https://ccmixter.org/content/a.mp3\"/>"
        let b = "<enclosure type=\"audio/mpeg\" url=\"https://ccmixter.org/content/b.mp3\"/>"
        let one = AudioSourceFinder.ccMixterCandidates(in: feed(item(a)), matching: wish)
        expect(one?.count == 1, "single direct MP3 enclosure accepted")
        expect(one?.first?.downloadURL.absoluteString == "https://ccmixter.org/content/a.mp3",
               "exact enclosure URL retained")
        expect(AudioSourceFinder.ccMixterCandidates(in: feed(item(a + b)), matching: wish)?.isEmpty == true,
               "distinct MP3 enclosures are ambiguous and rejected")
        expect(AudioSourceFinder.ccMixterCandidates(in: feed(item(a + a)), matching: wish)?.count == 1,
               "duplicate identical enclosure is deterministic")
        let nested = item(a, title: "Example <b>Song</b>")
        expect(AudioSourceFinder.ccMixterCandidates(in: feed(nested), matching: wish)?.count == 1,
               "nested title markup preserves full recording title")
        let insecure = "<enclosure type=\"audio/mpeg\" url=\"http://ccmixter.org/content/a.mp3\"/>"
        expect(AudioSourceFinder.ccMixterCandidates(in: feed(item(insecure)), matching: wish)?.isEmpty == true,
               "insecure MP3 enclosure rejected")
        expect(AudioSourceFinder.ccMixterCandidates(in: feed(item(a + insecure)), matching: wish)?.isEmpty == true,
               "mixed secure and insecure enclosures rejected")
        expect(AudioSourceFinder.ccMixterCandidates(in: Data("<rss><item>".utf8), matching: wish) == nil,
               "malformed RSS fails closed")
    }
}
