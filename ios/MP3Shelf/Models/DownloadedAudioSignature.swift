import Foundation

/// Identifies a completed download from its bytes, not its URL, MIME label or
/// temporary filename. The final AVFoundation decoder still verifies the codec.
/// This cheap check keeps HTML/JSON and obvious container mismatches away from
/// AVAudioFile, which otherwise tries to parse every staged file as an MP3.
enum DownloadedAudioSignature {
    enum Container: String {
        case mp3, m4a, aac, wav, aiff, flac

        var fileExtension: String { rawValue }
    }

    enum Error: LocalizedError {
        case unsupportedOrInvalidAudio

        var errorDescription: String? {
            "The source did not return a recognizable complete audio file. Try another source."
        }
    }

    /// Reads at most 64 bytes; does not load a potentially 100 MB audio file.
    static func identify(_ url: URL) throws -> Container? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              fileSize >= 16 else { return nil }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let prefix = try input.read(upToCount: 64) ?? Data()
        return identify(prefix: Array(prefix), fileSize: fileSize)
    }

    /// Exposed to the isolated Swift regression tests without AVFoundation.
    static func identify(prefix bytes: [UInt8], fileSize: Int64) -> Container? {
        guard fileSize >= 16, bytes.count >= 12 else { return nil }
        func match(_ offset: Int, _ ascii: [UInt8]) -> Bool {
            bytes.count >= offset + ascii.count &&
                Array(bytes[offset..<(offset + ascii.count)]) == ascii
        }
        if match(0, Array("fLaC".utf8)) { return .flac }
        if match(0, Array("RIFF".utf8)) && match(8, Array("WAVE".utf8)) { return .wav }
        if match(0, Array("FORM".utf8)) &&
            (match(8, Array("AIFF".utf8)) || match(8, Array("AIFC".utf8))) { return .aiff }
        if match(4, Array("ftyp".utf8)) {
            let size = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if size >= 16 && Int64(size) <= fileSize { return .m4a }
            return nil
        }
        if match(0, Array("ID3".utf8)), bytes.count >= 10 {
            // A syntactically valid ID3v2 prefix may precede a large artwork
            // tag, so do not require the first MPEG frame within 64 bytes.
            guard (2...4).contains(bytes[3]), bytes[4] != 0xFF,
                  bytes[6...9].allSatisfy({ $0 < 0x80 }) else { return nil }
            let tagSize = bytes[6...9].reduce(Int64(0)) { ($0 << 7) | Int64($1) }
            let footer = bytes[3] == 4 && (bytes[5] & 0x10) != 0 ? Int64(10) : 0
            return tagSize + 10 + footer < fileSize ? .mp3 : nil
        }
        if bytes[0] == 0xFF {
            // ADTS AAC: 12-bit sync, MPEG layer 00, valid frequency index.
            if bytes[1] & 0xF6 == 0xF0 && bytes[2] & 0x3C != 0x3C { return .aac }
            // MPEG Layer III: reject reserved version, bitrate and sample rate.
            if bytes[1] & 0xE6 == 0xE2,
               bytes[1] & 0x18 != 0x08,
               bytes[2] & 0xF0 != 0xF0,
               bytes[2] & 0x0C != 0x0C { return .mp3 }
        }
        return nil
    }
}
