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
        print("Lyrics parsing tests passed")
    }
}
