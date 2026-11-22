import Foundation

// Independent model of multi-record portable-backup allocation rules.
// Run: swift ios/Tests/PortableBackupMultiTrackIntegrityTests.swift
// This does not invoke the app's production restore implementation.
struct Segment {
    let owner: String
    let offset: Int
    let length: Int
}
enum ValidationError: Error { case corrupt }

func validateArchive(payload: Data, segments: [Segment], trackIDs: [String],
                     playlists: [[String]]) throws -> [String: Data] {
    guard !trackIDs.isEmpty, Set(trackIDs).count == trackIDs.count,
          !segments.isEmpty else { throw ValidationError.corrupt }
    let ids = Set(trackIDs)
    guard playlists.allSatisfy({ $0.allSatisfy(ids.contains) }),
          Set(segments.map(\.owner)).isSubset(of: ids) else {
        throw ValidationError.corrupt
    }
    var ranges: [(Int, Int, String)] = []
    for part in segments {
        guard part.offset >= 0, part.length > 0,
              part.offset <= payload.count,
              part.length <= payload.count - part.offset else {
            throw ValidationError.corrupt
        }
        ranges.append((part.offset, part.offset + part.length, part.owner))
    }
    ranges.sort { $0.0 < $1.0 }
    var cursor = 0
    var output: [String: Data] = [:]
    for (start, end, owner) in ranges {
        guard start == cursor, output[owner] == nil else { throw ValidationError.corrupt }
        output[owner] = payload.subdata(in: start..<end)
        cursor = end
    }
    guard cursor == payload.count, Set(output.keys) == ids else {
        throw ValidationError.corrupt
    }
    return output
}
func expectRejected(_ label: String, _ body: () throws -> Void) {
    do { try body(); fatalError("FAIL accepted \(label)") }
    catch ValidationError.corrupt { }
    catch { fatalError("FAIL unexpected \(label): \(error)") }
}
let first = Data([0x49, 0x44, 0x33, 0, 0, 0, 0x11])
let second = Data([0x49, 0x44, 0x33, 0, 0, 0, 0x22, 0x23])
let payload = first + second
let valid = [Segment(owner: "one", offset: 0, length: first.count),
             Segment(owner: "two", offset: first.count, length: second.count)]
let restored = try validateArchive(payload: payload, segments: valid,
                                   trackIDs: ["one", "two"],
                                   playlists: [["two", "one", "two"], []])
precondition(restored["one"] == first && restored["two"] == second)
func reject(_ label: String, _ segments: [Segment] = valid,
            _ ids: [String] = ["one", "two"],
            _ playlists: [[String]] = [["one", "two"]],
            _ bytes: Data = payload) {
    expectRejected(label) {
        _ = try validateArchive(payload: bytes, segments: segments,
                                trackIDs: ids, playlists: playlists)
    }
}
reject("duplicate track IDs", valid, ["one", "one"])
reject("dangling playlist reference", valid, ["one", "two"], [["three"]])
reject("unknown segment owner", [valid[0], Segment(owner: "three", offset: first.count, length: second.count)])
reject("missing audio segment", [valid[0]])
reject("duplicate audio segment", [valid[0], valid[0], valid[1]])
reject("overlapping audio", [valid[0], Segment(owner: "two", offset: 2, length: second.count)])
reject("gap in payload", [valid[0], Segment(owner: "two", offset: first.count + 1, length: second.count - 1)])
reject("trailing unclaimed bytes", valid, ["one", "two"], [["one"]], payload + Data([0]))
reject("negative offset", [Segment(owner: "one", offset: -1, length: first.count), valid[1]])
reject("negative length", [Segment(owner: "one", offset: 0, length: -1), valid[1]])
reject("overflow-sized length", [Segment(owner: "one", offset: 0, length: Int.max), valid[1]])
reject("empty track set", valid, [])
reject("empty payload", valid, ["one", "two"], [["one"]], Data())
precondition(try validateArchive(payload: payload, segments: valid,
                                 trackIDs: ["one", "two"], playlists: [["two", "one"]])["two"] == second)
print("PASS: multi-track portable archive ownership, ordering and 13 corruption boundaries")


// Deterministic adversarial allocation matrix: exercises arithmetic boundaries,
// split/merge mutations, shuffled metadata order and byte-exact ownership.
// The fixed seed makes any failure reproducible without a third-party test runner.
struct FixtureRNG {
    private var state: UInt64 = 0x6a09e667f3bcc909
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func count(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
}
var rng = FixtureRNG()
for iteration in 0..<512 {
    let trackCount = 2 + rng.count(12)
    var bytes = Data()
    var pieces: [Segment] = []
    var expected: [String: Data] = [:]
    for index in 0..<trackCount {
        let owner = "record-\(index)"
        let length = 1 + rng.count(512)
        let audio = Data((0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        pieces.append(Segment(owner: owner, offset: bytes.count, length: length))
        expected[owner] = audio
        bytes.append(audio)
    }
    let ids = (0..<trackCount).map { "record-\($0)" }
    let playlist = (0..<trackCount).reversed().map { "record-\($0)" }
    let shuffled = pieces.reversed()
    let roundTrip = try validateArchive(payload: bytes, segments: Array(shuffled),
                                       trackIDs: ids, playlists: [playlist])
    precondition(roundTrip == expected, "FAIL byte identity iteration \(iteration)")
    let victim = rng.count(trackCount)
    var overlapping = pieces
    overlapping[victim] = Segment(owner: pieces[victim].owner,
                                  offset: pieces[victim].offset,
                                  length: pieces[victim].length + 1)
    reject("extended segment \(iteration)", overlapping, ids, [playlist], bytes)
    var missing = pieces
    missing.remove(at: victim)
    reject("missing owner \(iteration)", missing, ids, [playlist], bytes)
    var duplicated = pieces
    duplicated.append(pieces[victim])
    reject("duplicate owner \(iteration)", duplicated, ids, [playlist], bytes)
    var truncated = bytes
    truncated.removeLast()
    reject("truncated payload \(iteration)", pieces, ids, [playlist], truncated)
}
print("PASS: 512 seeded multi-track byte-exact and corruption matrices")
