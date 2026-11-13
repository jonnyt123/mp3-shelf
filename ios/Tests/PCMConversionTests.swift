import Foundation

// Run from the repository root after building the encoder for Simulator:
// swift ios/Tests/PCMConversionTests.swift <Debug-iphonesimulator products> <Simulator UUID>
// Compiles the actual production converter, links the built encoder objects,
// and executes real AAC/WAV -> MP3 conversions on the selected Simulator.
// No Spotify credentials, network calls, project edits or Apple signing account.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift ios/Tests/PCMConversionTests.swift <Simulator-products> <Simulator-UUID>")
}
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let products = URL(fileURLWithPath: CommandLine.arguments[1])
let device = CommandLine.arguments[2]
let source = try String(contentsOf: root.appendingPathComponent("ios/MP3Shelf/Services/MusicLibrary.swift"), encoding: .utf8)
guard let start = source.range(of: "private final class ShelfPCMConversion {") else {
    fatalError("Production converter boundary changed; update the fixture explicitly")
}
let converter = String(source[start.lowerBound...])
let fixture = #"""
import Foundation
import AVFoundation
import ShelfEncoder
// Only error identities are required by the extracted production converter.
enum MusicLibraryError: Error {
    case downloadFailed, conversionUnsupportedFormat, conversionTooLong, recordingDurationMismatch
}
__CONVERTER__
@main enum PCMConversionTests {
    static func main() throws {
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: " + name)
            print("PASS: " + name)
        }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("pcm-conversion-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let original = URL(fileURLWithPath: CommandLine.arguments[1])
        let originalBytes = try Data(contentsOf: original)
        let staged = folder.appendingPathComponent("download.mp3")
        let alias = folder.appendingPathComponent("download.m4a")
        try fm.copyItem(at: original, to: staged)
        try fm.linkItem(at: staged, to: alias)
        func verifyMP3(_ url: URL, duration: Double, channels: AVAudioChannelCount) throws {
            let audio = try AVAudioFile(forReading: url)
            check(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEGLayer3,
                  "output is actual MPEG Layer III")
            check(audio.processingFormat.channelCount == channels,
                  "output retains channel count")
            let seconds = Double(audio.length) / audio.processingFormat.sampleRate
            check(abs(seconds - duration) < 0.2, "output retains complete recording duration")
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096)!
            var decoded: AVAudioFramePosition = 0
            var hasSignal = false
            while audio.framePosition < audio.length {
                let frames = AVAudioFrameCount(min(4096, audio.length - audio.framePosition))
                try audio.read(into: buffer, frameCount: frames)
                check(buffer.frameLength > 0, "MP3 decoder advances")
                decoded += AVAudioFramePosition(buffer.frameLength)
                if let pcm = buffer.floatChannelData {
                    hasSignal = hasSignal || (0..<Int(buffer.frameLength)).contains { abs(pcm[0][$0]) > 0.001 }
                }
            }
            check(decoded == audio.length && hasSignal, "entire saved MP3 decodes with real audio")
        }
        let converted = folder.appendingPathComponent("mono.mp3")
        try ShelfPCMConversion.encode(alias, to: converted, expectedDuration: 2, progress: Progress())
        try verifyMP3(converted, duration: 2, channels: 1)
        print("PASS: complete AAC recording converts through final partial block and EOF")

        let stereo = folder.appendingPathComponent("stereo.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        tone.frameLength = 8192
        for channel in 0..<2 {
            for frame in 0..<8192 {
                tone.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44100)) * 0.2
            }
        }
        do {
            let writer = try AVAudioFile(forWriting: stereo, settings: format.settings)
            try writer.write(from: tone)
        }
        let stereoMP3 = folder.appendingPathComponent("stereo.mp3")
        try ShelfPCMConversion.encode(stereo, to: stereoMP3, expectedDuration: nil, progress: Progress())
        try verifyMP3(stereoMP3, duration: 8192.0 / 44100.0, channels: 2)
        print("PASS: exact block-boundary stereo conversion flushes successfully")

        let sentinel = Data("existing user audio must remain intact".utf8)
        let occupied = folder.appendingPathComponent("occupied.mp3")
        try sentinel.write(to: occupied)
        do {
            try ShelfPCMConversion.encode(alias, to: occupied, expectedDuration: 2, progress: Progress())
            preconditionFailure("Existing output was accepted")
        } catch {}
        let occupiedBytes = try Data(contentsOf: occupied)
        check(occupiedBytes == sentinel, "existing destination bytes are preserved")

        let cancelledOutput = folder.appendingPathComponent("cancelled.mp3")
        let cancellation = Progress(totalUnitCount: 1)
        cancellation.cancel()
        do {
            try ShelfPCMConversion.encode(alias, to: cancelledOutput, expectedDuration: 2, progress: cancellation)
            preconditionFailure("Cancelled conversion succeeded")
        } catch is CancellationError {}
        check(!fm.fileExists(atPath: cancelledOutput.path), "cancelled conversion creates no output")

        let mismatched = folder.appendingPathComponent("mismatch.mp3")
        do {
            try ShelfPCMConversion.encode(alias, to: mismatched, expectedDuration: 30, progress: Progress())
            preconditionFailure("Mismatched recording duration accepted")
        } catch MusicLibraryError.recordingDurationMismatch {}
        check(!fm.fileExists(atPath: mismatched.path), "duration mismatch creates no output")
        let stagedBytes = try Data(contentsOf: staged)
        check(stagedBytes == originalBytes, "conversion and failures preserve original staged audio")
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-conversion-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let file = temporary.appendingPathComponent("Tests.swift")
try fixture.replacingOccurrences(of: "__CONVERTER__", with: converter)
    .write(to: file, atomically: true, encoding: .utf8)
let header = root.appendingPathComponent("ios/Packages/ShelfMP3Encoder/Adapter/include/ShelfEncoder.h")
try "module ShelfEncoder { header \"\(header.path)\" export * }\n"
    .write(to: temporary.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)
func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "PCMConversionTests", code: Int(process.terminationStatus))
    }
}
let executable = temporary.appendingPathComponent("tests")
try run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-parse-as-library",
         "-target", "arm64-apple-ios17.0-simulator", "-I", temporary.path, file.path,
         products.appendingPathComponent("ShelfEncoder.o").path,
         products.appendingPathComponent("LAME.o").path, "-o", executable.path])
try run(["xcrun", "simctl", "spawn", device, executable.path,
         root.appendingPathComponent("ios/Tests/Fixtures/transfer-tone.m4a").path])
