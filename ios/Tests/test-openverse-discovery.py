#!/usr/bin/env python3
"""Execute the actual production pagination body against deterministic provider pages."""
from pathlib import Path
import subprocess
import tempfile
import sys

source = Path(sys.argv[1] if len(sys.argv) > 1 else 'ios/MP3Shelf/Services/AudioSourceFinder.swift').read_text()
start = source.index('    static func findOpenverse(for wish: PlaylistWish,')
end = source.index('    // Wikimedia Commons', start)
body = source[start:end]
harness = r'''
import Foundation
struct PlaylistWish { var artist = "Artist"; var title = "Song" }
struct AudioCatalogMatch { let downloadURL: URL }
struct Item {
    var title = "Song", creator = "Artist"
    var url: String
    var foreign_landing_url = "", license_url = "", filetype = "mp3", source = ""
    var duration = 1.0, filesize = 1
}
struct OpenverseResponse { var results: [Item]; var page_count: Int? }
enum Failure: Error { case provider }
@MainActor enum AudioSourceFinder {
    static let maxOpenversePages = 2
    static var pages: [String: OpenverseResponse] = [:]
    static var failures = Set<String>()
    static var calls: [String] = []
    static var cancel = false
    static func openverseSearchURL(for wish: PlaylistWish, fieldSearch: Bool, page: Int) -> URL {
        URL(string: "https://fixture.example/\(fieldSearch ? "focused" : "broad")/\(page)")!
    }
    static func requestJSON(_ url: URL, allowsCellular: Bool) async throws -> OpenverseResponse {
        let key = url.path
        calls.append(key)
        if cancel { throw CancellationError() }
        if failures.contains(key) { throw Failure.provider }
        return pages[key] ?? OpenverseResponse(results: [], page_count: 1)
    }
    static func openverseCandidate(title: String, creator: String, download: String,
        landing: String, license: String, filetype: String, duration: Double,
        source: String, filesize: Int, wish: PlaylistWish) -> AudioCatalogMatch? {
        // Candidate eligibility has its own production tests. This fixture isolates inventory traversal.
        guard title == wish.title, creator == wish.artist else { return nil }
        return AudioCatalogMatch(downloadURL: URL(string: download)!)
    }
__BODY__
}
@main struct Tests {
    @MainActor static func main() async throws {
        func page(_ urls: [String], _ count: Int? = 1) -> OpenverseResponse {
            OpenverseResponse(results: urls.map { Item(url: "https://audio.example/" + $0) }, page_count: count)
        }
        func reset() {
            AudioSourceFinder.pages = [:]; AudioSourceFinder.calls = []
            AudioSourceFinder.failures = []; AudioSourceFinder.cancel = false
        }
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, "FAIL: " + label); print("PASS: " + label)
        }
        reset()
        AudioSourceFinder.pages = ["/focused/1": page(["a"], 2), "/focused/2": page(["b"])]
        let later = try await AudioSourceFinder.findOpenverse(for: PlaylistWish())
        check(later == nil && AudioSourceFinder.calls == ["/focused/1", "/focused/2"], "later page ambiguity blocks selection")
        reset()
        AudioSourceFinder.pages = ["/focused/1": page(["a"]), "/broad/1": page(["b"])]
        let broad = try await AudioSourceFinder.findOpenverse(for: PlaylistWish())
        check(broad == nil && AudioSourceFinder.calls.count == 2, "broad query ambiguity blocks selection")
        reset()
        AudioSourceFinder.pages = ["/focused/1": page(["a"], 2), "/focused/2": page(["a"]), "/broad/1": page(["a"])]
        let duplicate = try await AudioSourceFinder.findOpenverse(for: PlaylistWish())
        check(duplicate?.downloadURL.lastPathComponent == "a" && AudioSourceFinder.calls.count == 3, "duplicate recording remains eligible after both queries")
        reset()
        AudioSourceFinder.pages = ["/focused/1": page(["a"], 2)]
        AudioSourceFinder.failures = ["/focused/2"]
        do { _ = try await AudioSourceFinder.findOpenverse(for: PlaylistWish()); fatalError("partial search accepted") }
        catch Failure.provider { print("PASS: partial search failure remains retryable") }
        check(AudioSourceFinder.calls.contains("/broad/1"), "focused failure still attempts broad query")
        reset()
        AudioSourceFinder.cancel = true
        do { _ = try await AudioSourceFinder.findOpenverse(for: PlaylistWish()); fatalError("cancellation swallowed") }
        catch is CancellationError { check(AudioSourceFinder.calls.count == 1, "cancellation stops further requests") }
        reset()
        AudioSourceFinder.pages = ["/focused/1": page([], 100), "/focused/2": page([], 100), "/broad/1": page([], 100), "/broad/2": page([], 100)]
        let absent = try await AudioSourceFinder.findOpenverse(for: PlaylistWish())
        check(absent == nil && AudioSourceFinder.calls.count == 4, "traffic respects four-request budget")
        reset()
        let empty = try await AudioSourceFinder.findOpenverse(for: PlaylistWish(artist: ""))
        check(empty == nil && AudioSourceFinder.calls.isEmpty, "missing identity performs no request")
    }
}
'''.replace('__BODY__', body)
with tempfile.TemporaryDirectory(prefix='mp3-openverse-') as folder:
    folder = Path(folder)
    fixture = folder / 'main.swift'
    fixture.write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', str(fixture), '-o', str(folder / 'test')], check=True)
    subprocess.run([str(folder / 'test')], check=True)
