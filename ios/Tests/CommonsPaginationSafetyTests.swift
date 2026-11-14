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
    }
}
