import Foundation

// Compile with AudioSourceFinder and the same native model dependencies.
// MediaWiki's "continue.gsroffset" is an untrusted pagination cursor.
@main
enum CommonsPaginationSafetyTests {
    static func main() {
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            print("PASS: \(name)")
        }
        func accepts(_ current: Int, _ proposed: Int?, _ page: Int) -> Int? {
            try? AudioSourceFinder.commonsNextOffset(
                current: current, proposed: proposed, page: page)
        }
        expect(accepts(0, nil, 1) == nil, "complete first page ends search")
        expect(accepts(0, 20, 1) == 20, "valid next page advances")
        expect(accepts(20, 40, 1) == 40, "continuation advances monotonically")
        expect(accepts(20, 20, 1) == nil, "repeated offset rejected")
        expect(accepts(20, 0, 1) == nil, "backward offset rejected")
        expect(accepts(0, -1, 1) == nil, "negative offset rejected")
        expect(accepts(0, 10001, 1) == nil, "unbounded offset rejected")
        expect(accepts(20, 40, 2) == nil, "third page cannot silently authorize auto import")
        expect(accepts(20, nil, 2) == nil, "complete second page ends search")
        func token(_ value: String?) -> String? {
            try? AudioSourceFinder.commonsContinuationToken(value)
        }
        expect(token("gsroffset||") == "gsroffset||",
               "MediaWiki generic continuation token is preserved verbatim")
        expect(token(nil) == nil, "missing generic continuation token rejects partial search")
        expect(token("") == nil, "empty continuation token rejected")
        expect(token(String(repeating: "x", count: 257)) == nil,
               "oversized continuation token rejected")
        expect(token("gsroffset||\\n") == nil, "control characters rejected")
        func readable(_ hasQuery: Bool, _ hasContinuation: Bool,
                      _ hasOffset: Bool, _ hasToken: Bool,
                      hasAPIError: Bool = false) -> Bool {
            AudioSourceFinder.commonsPageIsReadable(
                hasQuery: hasQuery, hasContinuation: hasContinuation,
                hasOffset: hasOffset, hasToken: hasToken,
                hasAPIError: hasAPIError)
        }
        expect(readable(true, false, false, false),
               "completed page with an empty pages dictionary is readable")
        expect(readable(true, true, true, true),
               "continuation with both cursor fields is readable")
        expect(!readable(false, false, false, false),
               "missing query cannot masquerade as completed search")
        expect(!readable(false, true, true, true),
               "malformed second-page response cannot authorize first-page candidate")
        expect(!readable(true, true, false, true),
               "continuation without generator offset is incomplete")
        expect(!readable(true, true, true, false),
               "continuation without generic token is incomplete")
        expect(readable(true, false, false, false, hasAPIError: false),
               "valid empty query is not a provider failure")
        expect(!readable(true, false, false, false, hasAPIError: true),
               "API error alongside query cannot authorize a candidate")
        expect(!readable(true, true, true, true, hasAPIError: true),
               "API error on later page invalidates earlier candidate")
        expect(!readable(false, false, false, false, hasAPIError: true),
               "error-only response cannot masquerade as no results")
        // MediaWiki requires both query parameters on the second request:
        // continue=<token>&gsroffset=<offset>. Neither is optional.

    }
}
