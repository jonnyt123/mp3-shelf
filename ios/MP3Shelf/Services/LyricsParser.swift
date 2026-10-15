import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval?
    let text: String
}

enum LyricsError: LocalizedError {
    case unsupported
    var errorDescription: String? { "Choose a UTF-8 .lrc or .txt lyric file smaller than 500 KB." }
}

/// LRC timestamps [mm:ss.xx] may occur multiple times on one line.
enum LyricsParser {
    static func parse(_ content: String) -> [LyricLine] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#)
        var items: [(TimeInterval?, String)] = []
        for original in content.components(separatedBy: .newlines) {
            let range = NSRange(original.startIndex..<original.endIndex, in: original)
            let matches = regex.matches(in: original, range: range)
            let text = regex.stringByReplacingMatches(in: original, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("[") else { continue }
            if matches.isEmpty { items.append((nil, text)); continue }
            for match in matches {
                func value(_ capture: Int) -> String? {
                    guard let range = Range(match.range(at: capture), in: original) else { return nil }
                    return String(original[range])
                }
                guard let minutes = Int(value(1) ?? ""), let seconds = Int(value(2) ?? ""), seconds < 60 else { continue }
                let digits = value(3) ?? "0"
                let fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                items.append((Double(minutes * 60 + seconds) + fraction, text))
            }
        }
        if items.contains(where: { $0.0 != nil }) {
            items.sort { ($0.0 ?? .infinity) < ($1.0 ?? .infinity) }
        }
        return items.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
