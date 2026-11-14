#!/usr/bin/env python3
"""Fail-closed source regression for cancellation of manual URL audio imports.

Run: python3 ios/Tests/test-manual-download-cancellation.py
This checks production-source wiring, not an iOS runtime or URLSession integration.
"""
from pathlib import Path
import re
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "MP3Shelf/Services/MusicLibrary.swift"


def method_body():
    source = SOURCE.read_text(encoding="utf-8")
    start = source.index("    func downloadAudio(from remoteURL:")
    end = source.index("\n    }", start) + 6
    return source[start:end]


class ManualDownloadCancellationContract(unittest.TestCase):
    def test_download_completion_checks_cancellation_before_file_publication(self):
        body = method_body()
        self.assertRegex(
            body,
            r"URLSession\.shared\.download\(from: remoteURL\)"
            r"[\s\S]*?defer \{ try\? manager\.removeItem\(at: temporary\) \}"
            r"\s*//[^\n]*\n\s*//[^\n]*\n\s*try Task\.checkCancellation\(\)",
        )
        self.assertLess(body.index("try Task.checkCancellation()"),
                        body.index("manager.moveItem(at: temporary, to: staging)"))

    def test_import_uses_cancellable_transaction(self):
        body = method_body()
        call = body[body.index("let imported = try addLocalAudio("):]
        self.assertIn("cancellationAware: true)", call)
        self.assertLess(call.index("cancellationAware: true)"),
                        call.index("return ImportReport("))

    def test_temporary_files_are_cleaned_on_cancellation(self):
        body = method_body()
        self.assertIn("defer { try? manager.removeItem(at: temporary) }", body)
        self.assertIn("defer { try? manager.removeItem(at: staging) }", body)

    def test_shared_import_transaction_checks_before_publication(self):
        source = SOURCE.read_text(encoding="utf-8")
        start = source.index("    private func addLocalAudio(")
        end = source.index("\n    func ", start)
        helper = source[start:end]
        self.assertIn("if cancellationAware { try Task.checkCancellation() }", helper)
        self.assertIn("LocalAudioImportTransaction.perform(", helper)

    def test_no_cancellation_check_is_swallowed(self):
        body = method_body()
        self.assertNotRegex(body, r"try\?\s*Task\.checkCancellation\(\)")


if __name__ == "__main__":
    unittest.main()
