import Foundation

@main
enum DownloadedAudioSignatureTests {
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func main() throws {
        let mp4: [UInt8] = [0, 0, 0, 24] + Array("ftypM4A ".utf8) + Array(repeating: 0, count: 16)
        check(DownloadedAudioSignature.identify(prefix: mp4, fileSize: 40) == .m4a, "MP4/AAC download is not mislabeled MP3")
        let mp3: [UInt8] = [0xFF, 0xFB, 0x90, 0x64] + Array(repeating: 0, count: 20)
        check(DownloadedAudioSignature.identify(prefix: mp3, fileSize: 512) == .mp3, "MPEG Layer III is MP3")
        let id3: [UInt8] = Array("ID3".utf8) + [4, 0, 0, 0, 0, 0, 0] + mp3
        check(DownloadedAudioSignature.identify(prefix: id3, fileSize: 512) == .mp3, "ID3-prefixed MP3 is supported")
        let adts: [UInt8] = [0xFF, 0xF1, 0x50, 0x80] + Array(repeating: 0, count: 20)
        check(DownloadedAudioSignature.identify(prefix: adts, fileSize: 128) == .aac, "AAC ADTS is detected")
        check(DownloadedAudioSignature.identify(prefix: Array("RIFF".utf8) + [0, 0, 0, 64] + Array("WAVE".utf8), fileSize: 64) == .wav, "WAV is detected")
        check(DownloadedAudioSignature.identify(prefix: Array("FORM".utf8) + [0, 0, 0, 64] + Array("AIFC".utf8), fileSize: 64) == .aiff, "AIFF-C is detected")
        check(DownloadedAudioSignature.identify(prefix: Array("fLaC".utf8) + Array(repeating: 0, count: 20), fileSize: 128) == .flac, "FLAC is detected")
        check(DownloadedAudioSignature.identify(prefix: Array("<html>not audio</html>".utf8), fileSize: 100) == nil, "HTML response is rejected")
        check(DownloadedAudioSignature.identify(prefix: Array("{\"error\":403}".utf8), fileSize: 100) == nil, "JSON response is rejected")
        check(DownloadedAudioSignature.identify(prefix: mp4, fileSize: 12) == nil, "Truncated audio is rejected")
        check(DownloadedAudioSignature.identify(prefix: [0, 0, 0, 90] + Array("ftypM4A ".utf8), fileSize: 40) == nil, "MP4 box larger than file is rejected")
        check(DownloadedAudioSignature.identify(prefix: Array("ID3".utf8) + [4, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F] + mp3, fileSize: 512) == nil, "Oversized ID3 tag is rejected")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let misleadingPath = folder.appendingPathComponent("download.mp3")
        try Data(mp4).write(to: misleadingPath)
        let detected = try DownloadedAudioSignature.identify(misleadingPath)
        check(detected == .m4a, "Detection ignores misleading staged filename")
        let alias = folder.appendingPathComponent("download.m4a")
        try FileManager.default.linkItem(at: misleadingPath, to: alias)
        let linkedData = try Data(contentsOf: alias)
        check(linkedData == Data(mp4), "Correctly suffixed hard link preserves audio bytes")
        try FileManager.default.removeItem(at: alias)
        check(FileManager.default.fileExists(atPath: misleadingPath.path), "Removing decode alias retains recoverable staged download")
    }
}
