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
        let offsetRegex = try! NSRegularExpression(pattern: #"^\s*\[offset:\s*([+-]?[0-9]+)\s*\]\s*$"#,
                                                   options: .caseInsensitive)
        var offsets = Set<Int>()
        var items: [(TimeInterval?, String)] = []
        let input = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
        for original in input.components(separatedBy: .newlines) {
            let range = NSRange(original.startIndex..<original.endIndex, in: original)
            if let match = offsetRegex.firstMatch(in: original, range: range) {
                // A global offset must fit within the supported LRC time range.
                // Conflicting declarations are ambiguous; do not guess a shift.
                if let capture = Range(match.range(at: 1), in: original),
                   let milliseconds = Int(original[capture]),
                   (-60_000_000...60_000_000).contains(milliseconds) {
                    offsets.insert(milliseconds)
                }
                continue
            }
            let matches = regex.matches(in: original, range: range)
            let text = regex.stringByReplacingMatches(in: original, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if matches.isEmpty {
                guard !text.hasPrefix("[") else { continue }
                items.append((nil, text))
                continue
            }
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
        // Positive LRC offsets advance lyrics; negative offsets delay them.
        // Apply after sorting so lines clamped to zero retain their chronology.
        let shift = offsets.count == 1 ? Double(offsets.first ?? 0) / 1_000 : 0
        return items.enumerated().map { index, item in
            LyricLine(id: index, time: item.0.map { max(0, $0 - shift) }, text: item.1)
        }
    }
}
