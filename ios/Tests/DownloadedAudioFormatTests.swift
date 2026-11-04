import Foundation

@main
enum DownloadedAudioFormatTests {
    static func main() throws {
        let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ios/Tests/Fixtures")
        guard try DownloadedAudioFormat.isMP3(fixtures.appendingPathComponent("valid-mp3.mp3")) else {
            fatalError("Real MP3 must be accepted")
        }
        guard try !DownloadedAudioFormat.isMP3(fixtures.appendingPathComponent("flac-named-mp3.mp3")) else {
            fatalError("FLAC renamed to MP3 must be rejected")
        }
        print("PASS: actual codec determines MP3 eligibility")
    }
}
