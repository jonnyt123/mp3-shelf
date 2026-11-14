import Foundation

// Offline regression: Internet Archive derivatives must not be mistaken for
// the exact source recording when original-file metadata is absent.
@main
enum ArchiveOriginalRecordingSelectionTests {
    static func main() throws {
        func expect(_ value: Bool, _ message: String) {
            guard value else { fatalError("FAIL: \(message)") }
            print("PASS: \(message)")
        }
        let wish = PlaylistWish(title: "Example Song", artist: "Example Artist", album: "")
        func item(_ files: String) throws -> AudioSourceFinder.ArchiveItem {
            let json = """
            {"metadata":{"title":"Example Song","creator":"Example Artist"},
             "files":[\(files)]}
            """
            return try JSONDecoder().decode(AudioSourceFinder.ArchiveItem.self, from: Data(json.utf8))
        }
        let original = #"{"name":"Example Song.mp3","source":"original","size":"120000"}"#
        let derived = #"{"name":"Example Song.mp3","source":"derivative","size":"120000"}"#
        let legacy = #"{"name":"Example Song.mp3","size":"120000"}"#
        let other = #"{"name":"Other Song.mp3","source":"original","size":"120000"}"#
        func match(_ files: String) throws -> AudioCatalogMatch? {
            AudioSourceFinder.archiveCandidate(try item(files), identifier: "safe_item", for: wish)
        }
        expect(try match(original) != nil, "explicit original recording accepted")
        expect(try match(derived) == nil, "transcoded derivative cannot auto-select")
        expect(try match(legacy) != nil, "legacy item with omitted source remains discoverable")
        expect(try match(original + "," + derived) != nil,
               "derivative cannot make a unique original appear ambiguous")
        expect(try match(other + "," + derived) == nil,
               "derivative matching title cannot override unrelated original")
        expect(try match(original + "," + legacy) != nil,
               "explicit original takes precedence over unspecified legacy file")
        expect(try match(#"{"name":"Example Song.mp3","source":"derivative","size":"0"}"#) == nil,
               "empty derived audio is never accepted")
    }
}
