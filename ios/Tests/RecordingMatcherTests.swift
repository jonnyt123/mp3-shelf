import Foundation

func checkMatch(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: " + message) }
    print("PASS: " + message)
}

@main enum RecordingMatcherTests {
    static func main() throws {
        let wish = PlaylistWish(title: "The Song", artist: "The Artist", album: "Album", spotifyURL: nil, durationSeconds: 212)
        let topic = RecordingCandidate(id: "abcdefghijk", title: "The Song (Official Audio)", uploader: "The Artist - Topic", durationSeconds: 212)
        checkMatch(RecordingMatcher.assess(topic, for: wish).decision == .automatic, "topic credit, neutral annotation and duration identify the recording")
        for label in ["HQ Audio", "Official Animated Video", "Official Music Video 4K", "Official Lyric Video"] {
            let presented = RecordingCandidate(id: topic.id, title: "The Artist - The Song (\(label))",
                uploader: "The Artist", durationSeconds: 212)
            checkMatch(RecordingMatcher.assess(presented, for: wish).decision == .automatic,
                       "presentation labels do not change recording identity: \(label)")
        }
        let remaster = RecordingCandidate(id: topic.id, title: "The Song (2022 Remaster)",
            uploader: "The Artist", durationSeconds: 212)
        checkMatch(RecordingMatcher.assess(remaster, for: wish).decision == .rejected,
                   "remaster annotation remains recording identity rather than presentation noise")
        let cover = RecordingCandidate(id: "lmnopqrstuv", title: "The Artist - The Song (Cover)", uploader: "Someone Else", durationSeconds: 212)
        checkMatch(RecordingMatcher.assess(cover, for: wish).decision == .rejected, "a matching title and duration cannot admit a cover")
        let clip = RecordingCandidate(id: "lmnopqrstuv", title: "The Song", uploader: "The Artist", durationSeconds: 30)
        checkMatch(RecordingMatcher.assess(clip, for: wish).decision == .rejected, "preview cannot substitute for full recording")
        var duplicate = topic
        duplicate = RecordingCandidate(id: "lmnopqrstuv", title: duplicate.title, uploader: duplicate.uploader, durationSeconds: duplicate.durationSeconds)
        checkMatch(RecordingMatcher.automaticChoice(RecordingMatcher.rank([topic, duplicate], for: wish)) == nil,
                   "equally strong distinct recordings require review")
        var official = topic
        official.verifiedArtist = true
        let ranked = RecordingMatcher.rank([official, duplicate], for: wish)
        checkMatch(RecordingMatcher.automaticChoice(ranked)?.id == official.id, "verified artist evidence breaks a meaningful ranking tie")
        checkMatch(RecordingMatcher.automaticChoice(ranked, excluding: [official.id])?.id == duplicate.id,
                   "failed recording can move to the next compatible source")
        let reupload = RecordingCandidate(id: "lmnopqrstuv", title: "The Artist - The Song", uploader: "Random Music", durationSeconds: 212)
        checkMatch(RecordingMatcher.assess(reupload, for: wish).decision == .review,
                   "artist name in video title alone remains reviewable")
        var collaboration = wish
        collaboration.artist = "The Artist, Guest Artist"
        collaboration.artistNames = ["The Artist", "Guest Artist"]
        checkMatch(RecordingMatcher.assess(topic, for: collaboration).decision == .automatic,
                   "primary artist comes from Spotify artist fields rather than splitting band names")
        let json = #"{"contents":[{"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"The Song (Official Audio)"}]},"ownerText":{"runs":[{"text":"The Artist - Topic"}]},"lengthText":{"simpleText":"3:32"},"ownerBadges":[{"metadataBadgeRenderer":{"style":"BADGE_STYLE_TYPE_VERIFIED_ARTIST"}}]}},{"videoRenderer":{"videoId":"lmnopqrstuv","title":{"simpleText":"Another Song"},"lengthText":{"simpleText":"LIVE"}}}]}"#
        let data = Data(json.utf8)
        let html = Data(("<script>var ytInitialData = " + json + "; var next = {};</script>").utf8)
        checkMatch(RecordingSearchParser.initialData(in: html) == data, "balanced JSON extraction stops at the correct closing brace")
        let parsed = try RecordingSearchParser.candidates(in: data)
        checkMatch(parsed.count == 2 && parsed[0].verifiedArtist && parsed[0].durationSeconds == 212,
                   "search parser keeps ID, recording title, artist badge and duration")
        checkMatch(RecordingSearchParser.duration("1:03:32") == 3812 && RecordingSearchParser.duration("3:99") == nil,
                   "duration parser accepts hours and rejects invalid seconds")
        checkMatch(RecordingSearchParser.duration("1::23") == nil && RecordingSearchParser.duration(":23") == nil,
                   "missing time components cannot masquerade as a valid duration")
        let link = URL(string: "https://r1.googlevideo.com/videoplayback?mime=audio%2Fmp4&sig=sample&expire=100&clen=1000")!
        checkMatch(AudioSourceLinks.isResolvedAudioURL(link), "only a resolved signed AAC endpoint passes video-source admission")
        checkMatch(AudioSourceLinks.hasExpired(link, at: Date(timeIntervalSince1970: 101)), "expired media links are distinguishable from recording failures")
        checkMatch(!AudioSourceLinks.isResolvedAudioURL(URL(string: "https://r1.googlevideo.com/videoplayback?mime=video%2Fmp4&sig=sample")!),
                   "video and muxed media cannot enter the audio-only queue")
        checkMatch(!AudioSourceLinks.isResolvedAudioURL(URL(string: "https://googlevideo.com.evil.example/videoplayback?mime=audio%2Fmp4&sig=sample")!),
                   "lookalike media hosts are rejected")
        checkMatch(AudioSourceLinks.youtubeVideoID(topic.pageURL) == topic.id, "persisted source page retains a stable resolver ID")
    }
}
