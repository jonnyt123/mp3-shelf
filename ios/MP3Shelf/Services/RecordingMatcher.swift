import Foundation
import ShelfMatching

struct RecordingAssessment: Sendable {
    enum Decision: String, Sendable { case rejected, review, automatic }
    let candidate: RecordingCandidate
    let decision: Decision
    let score: Int
    let reason: String
}

enum RecordingMatcher {
    static func acceptsAudioResponse(status: Int, mime: String?, prefix: Data) -> Bool {
        guard status == 200 || status == 206 else { return false }
        return (mime ?? "").lowercased().withCString { type in
            prefix.withUnsafeBytes { bytes in
                ShelfAudioResponseIsMP4(Int32(status), type,
                    bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) != 0
            }
        }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "MP3Shelf.recordingMatching") as? Bool ?? true
    }
    static func validID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil
    }

    static func cleanedTitle(_ value: String) -> String {
        // Strip presentation labels, while keeping live/remix/radio-edit and
        // remaster qualifiers as recording identity evidence.
        let quality = #"(?:hd|hq|4k|1080p|720p|2160p)"#
        let media = #"(?:(?:music|lyrics?|animated)\s+)?(?:audio|video|visuali[sz]er)|lyrics?|visuali[sz]er"#
        let labels = #"(?:official\s*)?(?:"# + quality + #"\s*)?(?:"# + media + #")(?:\s*"# + quality + #")?|"# + quality
        var title = value.replacingOccurrences(
            of: "[\\(\\[]\\s*(?:" + labels + ")[\\s.!]*[\\)\\]]",
            with: "", options: [.regularExpression, .caseInsensitive])
        title = title.replacingOccurrences(
            of: "\\s*[-|]\\s*(?:" + labels + ")\\s*$",
            with: "", options: [.regularExpression, .caseInsensitive])
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanedArtist(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s*(?:-\s*Topic|\s+Official|VEVO)\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func versions(_ title: String) -> UInt32 {
        let patterns = [#"\blive\b"#, #"\bremix\b"#, #"\b(?:cover|karaoke)\b"#,
                        #"\binstrumental\b"#, #"\b(?:sped\s*up|slowed|nightcore|8d)\b"#,
                        #"\bremaster(?:ed)?\b"#, #"\bradio\s*edit\b"#]
        return patterns.enumerated().reduce(UInt32(0)) { mask, entry in
            title.range(of: entry.element, options: [.regularExpression, .caseInsensitive]) == nil
                ? mask : mask | (1 << UInt32(entry.offset))
        }
    }

    static func assess(_ candidate: RecordingCandidate, for wish: PlaylistWish) -> RecordingAssessment {
        let title = MusicMatching.key(cleanedTitle(wish.title))
        let primaryArtist = wish.artistNames?.first ?? wish.artist
        let artist = MusicMatching.key(primaryArtist)
        let foundTitle = MusicMatching.key(cleanedTitle(candidate.title))
        let foundArtist = MusicMatching.key(cleanedArtist(candidate.uploader))
        let result = title.withCString { requestedTitle in
            artist.withCString { requestedArtist in
                foundTitle.withCString { candidateTitle in
                    foundArtist.withCString { candidateArtist in
                        var input = ShelfMatchInput(requested_title: requestedTitle, requested_artist: requestedArtist,
                            candidate_title: candidateTitle, candidate_artist: candidateArtist,
                            requested_duration: wish.durationSeconds ?? 0,
                            candidate_duration: candidate.durationSeconds ?? 0,
                            requested_versions: versions(wish.title), candidate_versions: versions(candidate.title),
                            verified_channel: candidate.verifiedArtist ? 1 : 0, live_stream: candidate.isLive ? 1 : 0)
                        return ShelfMatchEvaluate(&input)
                    }
                }
            }
        }
        let decision: RecordingAssessment.Decision = !validID(candidate.id) ? .rejected :
            result.decision == ShelfMatchAutomatic ? .automatic :
            result.decision == ShelfMatchReview ? .review : .rejected
        let reason: String
        switch result.reason {
        case ShelfMatchExact: reason = decision == .automatic ? "Artist, title and duration match" : "Artist credit needs review"
        case ShelfMatchMissingIdentity: reason = "Missing recording identity"
        case ShelfMatchWrongArtist: reason = "Different artist or missing artist credit"
        case ShelfMatchWrongTitle: reason = "Different song title"
        case ShelfMatchWrongVersion: reason = "Live, remix, cover or edit does not match"
        case ShelfMatchWrongDuration: reason = "Recording length differs by more than four seconds"
        case ShelfMatchUnknownDuration: reason = "Length is missing; review required"
        case ShelfMatchSimilarTitle: reason = "Similar title; review required"
        case ShelfMatchLiveStream: reason = "Ongoing livestream"
        default: reason = "Recording needs review"
        }
        return RecordingAssessment(candidate: candidate, decision: decision, score: Int(result.score), reason: reason)
    }

    static func rank(_ candidates: [RecordingCandidate], for wish: PlaylistWish) -> [RecordingAssessment] {
        var seen = Set<String>()
        return candidates.filter { validID($0.id) && seen.insert($0.id).inserted }
            .map { assess($0, for: wish) }.sorted {
                $0.score == $1.score ? $0.candidate.id < $1.candidate.id : $0.score > $1.score
            }
    }

    static func automaticChoice(_ ranked: [RecordingAssessment], excluding failedIDs: Set<String> = []) -> RecordingCandidate? {
        let eligible = ranked.filter { $0.decision == .automatic && !failedIDs.contains($0.candidate.id) }
        guard let best = eligible.first else { return nil }
        if eligible.count > 1 && best.score - eligible[1].score < 3 { return nil }
        return best.candidate
    }
}

/// Search response parsing is independent of extraction and the transfer queue.
enum RecordingSearchParser {
    static func duration(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.last! < 60,
              parts.count == 2 || numbers[1] < 60 else { return nil }
        let seconds = numbers.reduce(0.0) { $0 * 60 + Double($1) }
        return seconds > 0 && seconds <= 8 * 3600 ? seconds : nil
    }

    static func candidates(in json: Data) throws -> [RecordingCandidate] {
        let root = try JSONSerialization.jsonObject(with: json)
        var found: [RecordingCandidate] = []
        var seen = Set<String>()
        func text(_ value: Any?) -> String {
            guard let object = value as? [String: Any] else { return "" }
            if let simple = object["simpleText"] as? String { return simple }
            return (object["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        }
        func walk(_ value: Any, depth: Int) {
            guard depth < 24, found.count < 30 else { return }
            if let object = value as? [String: Any] {
                if let video = object["videoRenderer"] as? [String: Any],
                   let id = video["videoId"] as? String, RecordingMatcher.validID(id), seen.insert(id).inserted {
                    let badges = (video["ownerBadges"] as? [[String: Any]] ?? []).compactMap {
                        ($0["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String
                    }
                    let liveBadges = (video["badges"] as? [[String: Any]] ?? []).compactMap {
                        ($0["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String
                    }
                    found.append(RecordingCandidate(id: id, title: String(text(video["title"]).prefix(500)),
                        uploader: String(text(video["ownerText"] ?? video["longBylineText"] ?? video["shortBylineText"]).prefix(300)),
                        durationSeconds: duration(text(video["lengthText"])),
                        verifiedArtist: badges.contains("BADGE_STYLE_TYPE_VERIFIED_ARTIST"),
                        isLive: liveBadges.contains("BADGE_STYLE_TYPE_LIVE_NOW")))
                    return
                }
                for nested in object.values { walk(nested, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for nested in array { walk(nested, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return found
    }

    static func initialData(in html: Data) -> Data? {
        guard html.count <= 3_000_000 else { return nil }
        let bytes = [UInt8](html)
        for marker in ["var ytInitialData =", "ytInitialData =", "window[\"ytInitialData\"] ="] {
            guard let range = html.range(of: Data(marker.utf8)) else { continue }
            var start = range.upperBound
            while start < bytes.count && [9, 10, 13, 32].contains(bytes[start]) { start += 1 }
            guard start < bytes.count, bytes[start] == 123 else { continue }
            var depth = 0, quoted = false, escaped = false
            for index in start..<bytes.count {
                let byte = bytes[index]
                if quoted {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quoted = false }
                } else if byte == 34 { quoted = true }
                else if byte == 123 { depth += 1 }
                else if byte == 125 {
                    depth -= 1
                    if depth == 0 { return html.subdata(in: start..<(index + 1)) }
                }
            }
        }
        return nil
    }
}
