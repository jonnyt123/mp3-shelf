import Foundation
import AudioToolbox

@main
enum DownloadedAudioFormatTests {
    static func main() throws {
        let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ios/Tests/Fixtures")
        guard try DownloadedAudioFormat.isMP3(fixtures.appendingPathComponent("valid-mp3.mp3")) else {
            fatalError("Real MP3 must be accepted")
        }
        guard try !DownloadedAudioFormat.isMP3(fixtures.appendingPathComponent("transfer-tone.m4a")) else {
            fatalError("Readable AAC must not be accepted as MP3")
        }
        let disguisedFLAC = fixtures.appendingPathComponent("flac-named-mp3.mp3")
        let bytes = try Data(contentsOf: disguisedFLAC)
        precondition(bytes.prefix(4) == Data("fLaC".utf8), "Missing valid FLAC fixture")
        do {
            guard try !DownloadedAudioFormat.isMP3(disguisedFLAC) else {
                fatalError("FLAC renamed to MP3 must be rejected")
            }
        } catch {
            // Recent AVFoundation rejects this misleading suffix before
            // exposing a codec. That specific invalid-file error is rejection;
            // missing/unreadable fixtures and unrelated failures must still fail.
            let failure = error as NSError
            guard failure.domain == "com.apple.coreaudio.avfaudio",
                  failure.code == Int(kAudioFileInvalidFileError) else { throw error }
        }
        print("PASS: actual codec determines MP3 eligibility")
    }
}
