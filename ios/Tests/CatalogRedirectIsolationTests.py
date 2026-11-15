#!/usr/bin/env python3
"""Offline source-wiring regression for catalog redirect isolation.

Run: python3 ios/Tests/CatalogRedirectIsolationTests.py
This checks production source wiring, not native URLSession behavior.
"""
from pathlib import Path
import re
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "MP3Shelf/Services/AudioSourceFinder.swift"

class CatalogRedirectIsolationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_all_catalog_data_requests_use_redirect_guard(self):
        self.assertNotIn("URLSession.shared.data(for: request)", self.source)
        self.assertGreaterEqual(self.source.count("catalogSession.data(for: request)"), 3)

    def test_redirect_is_rejected_not_reissued(self):
        body = self.source.split("private final class CatalogRedirectBlocker:", 1)[1].split(
            "private static let catalogSession:", 1)[0]
        self.assertRegex(body, r"willPerformHTTPRedirection")
        self.assertRegex(body, r"completionHandler\(nil\)")
        self.assertNotRegex(body, r"completionHandler\(request\)")

    def test_ephemeral_session_has_bounded_timeouts(self):
        body = self.source.split("private static let catalogSession:", 1)[1].split(
            "private static func requestJSON", 1)[0]
        self.assertIn("URLSessionConfiguration.ephemeral", body)
        self.assertIn("timeoutIntervalForRequest = 18", body)
        self.assertIn("timeoutIntervalForResource = 25", body)
        self.assertIn("delegate: CatalogRedirectBlocker()", body)

if __name__ == "__main__":
    unittest.main()
