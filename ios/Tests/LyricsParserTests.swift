import Foundation

@main
struct LyricsParserTests {
    static func main() {
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), "Failed: \(label)")
            print("PASS: \(label)")
        }
        let lines = LyricsParser.parse("""
        [ar:Someone]
        [01:02.45]One lyric
        [00:10.5]Earlier lyric
        [01:02.450][01:03.00]Repeated lyric
        """)
        expect(lines.count == 4, "metadata headers skipped and multi-timestamp lyric kept")
        expect(lines.first?.text == "Earlier lyric", "lyrics sorted by timestamp")
        expect(abs((lines.first?.time ?? 0) - 10.5) < 0.001, "centisecond timestamp")
        expect(abs((lines.last?.time ?? 0) - 63) < 0.001, "later timestamp")
        let plain = LyricsParser.parse("First line\nSecond line")
        expect(plain.count == 2 && plain[0].time == nil, "plain text lyrics")
        let early = LyricsParser.parse("[00:01.25]First\n[00:03.00]Second\n[offset:+500]")
        expect(early.map(\.time) == [0.75, 2.5], "positive global offset advances every timestamp even when declared last")
        let late = LyricsParser.parse("\u{FEFF}[OFFSET:-250]\r\n[00:01.25]First\r\n[00:03.00]Second")
        expect(late.map(\.time) == [1.5, 3.25], "negative offset delays lyrics and accepts BOM and CRLF")
        let clamped = LyricsParser.parse("[offset:2000]\n[00:01.50]Second\n[00:00.50]First\n[00:01.50]Translation")
        expect(clamped.map(\.time) == [0, 0, 0], "advanced timestamps never seek before track start")
        expect(clamped.map(\.text) == ["First", "Second", "Translation"], "clamped timestamps preserve chronological and translation order")
        let ambiguous = LyricsParser.parse("[offset:500]\n[offset:-250]\n[00:03.00]Line")
        expect(ambiguous.first?.time == 3, "conflicting offsets leave original timing intact")
        let badOffset = LyricsParser.parse("[offset:999999999999999999999999]\n[00:03.00]Line")
        expect(badOffset.first?.time == 3, "overflowing offset is ignored")
        let repeated = LyricsParser.parse("[offset:500]\n[offset:500]\n[00:03.00]Line\nPlain lyric")
        expect(repeated.map(\.time) == [2.5, nil], "duplicate identical tags apply once and untimed lyrics stay untimed")
        let bracketed = LyricsParser.parse("[ar:Someone]\n[00:01.00][Chorus] We sing\n[00:02.00][Spoken]\n[unknown:metadata]")
        expect(bracketed.map(\.text) == ["[Chorus] We sing", "[Spoken]"], "timestamped bracketed lyrics are preserved without importing metadata")
        expect(bracketed.map(\.time) == [1, 2], "bracketed lyrics retain their timing")
        print("Lyrics parsing tests passed")
    }
}
