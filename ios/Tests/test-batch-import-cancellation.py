#!/usr/bin/env python3
"""Execute the real MusicLibrary.importAudio batch loop in a portable Swift harness.

Usage: python3 ios/Tests/test-batch-import-cancellation.py ios/MP3Shelf/Services/MusicLibrary.swift
The harness substitutes only iOS security-scope and audio-import dependencies;
the production importAudio method body is compiled unchanged.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
signature = "    func importAudio(urls: [URL]) async -> ImportReport {"
start = source.index(signature)
opening = source.index("{", start)
depth = 1
end = opening + 1
while depth:
    if source[end] == "{":
        depth += 1
    elif source[end] == "}":
        depth -= 1
    end += 1
method = source[start:end]
assert "cancellationAware: true" in method
assert "if Task.isCancelled" in method
assert "error is CancellationError" in method

harness = """import Foundation
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { true }
    func stopAccessingSecurityScopedResource() {}
}
struct ImportReport {
    var imported = 0
    var skipped = 0
    var errors: [String] = []
}
final class Library {
    var isImporting = false
    var opened: [String] = []
    var cancelAfterFirst = false
    func addLocalAudio(sourceURL: URL, originalName: String,
                       cancellationAware: Bool) throws -> Bool {
        precondition(cancellationAware)
        opened.append(originalName)
        if cancelAfterFirst {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return true
    }
""" + method + """
}
@main struct Runner {
    static func main() async {
        let urls = ["first.mp3", "second.mp3", "third.mp3"].map {
            URL(fileURLWithPath: "/tmp/" + $0)
        }
        let preCancelled = Library()
        let stopped = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await preCancelled.importAudio(urls: urls)
        }.value
        precondition(preCancelled.opened.isEmpty)
        precondition(stopped.imported == 0 && stopped.errors.count == 1)
        precondition(!preCancelled.isImporting)

        let midBatch = Library()
        midBatch.cancelAfterFirst = true
        let partial = await Task { await midBatch.importAudio(urls: urls) }.value
        precondition(midBatch.opened == ["first.mp3"])
        precondition(partial.imported == 1 && partial.errors.count == 1)
        precondition(!midBatch.isImporting)

        let complete = Library()
        let normal = await complete.importAudio(urls: urls)
        precondition(normal.imported == 3 && normal.errors.isEmpty)
        precondition(complete.opened.count == 3)
        print("PASS: pre-cancel, mid-batch cancel, and normal batch import")
    }
}
"""
with tempfile.TemporaryDirectory() as directory:
    swift = Path(directory) / "BatchImport.swift"
    binary = Path(directory) / "batch-import"
    swift.write_text(harness)
    compile_result = subprocess.run(
        ["swiftc", "-parse-as-library", str(swift), "-o", str(binary)],
        capture_output=True, text=True
    )
    if compile_result.returncode:
        print(compile_result.stderr, file=sys.stderr)
        sys.exit(compile_result.returncode)
    result = subprocess.run([str(binary)], capture_output=True, text=True)
    print(result.stdout, end="")
    if result.returncode:
        print(result.stderr, file=sys.stderr)
    sys.exit(result.returncode)
