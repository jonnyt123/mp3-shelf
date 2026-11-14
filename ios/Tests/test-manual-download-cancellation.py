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
            r"session\.download\(from: remoteURL\)"
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

    def test_redirected_response_must_remain_https(self):
        body = method_body()
        self.assertIn('ManualAudioURLPolicy.permits(http.url)', body)
        self.assertLess(body.index('ManualAudioURLPolicy.permits(http.url)'),
                        body.index("manager.moveItem(at: temporary, to: staging)"))
        self.assertIn("throw MusicLibraryError.invalidDownloadURL", body)

    def test_redirect_delegate_rejects_insecure_follow_up_before_transfer(self):
        source = SOURCE.read_text(encoding="utf-8")
        start = source.index("private final class ManualHTTPSRedirectDelegate:")
        end = source.index("\nstruct AutomaticDownloadProgress", start)
        delegate = source[start:end]
        self.assertIn("willPerformHTTPRedirection", delegate)
        self.assertIn('ManualAudioURLPolicy.permits(request.url)', delegate)
        self.assertIn("completionHandler(nil)", delegate)
        self.assertIn("completionHandler(request)", delegate)
        self.assertLess(delegate.index('ManualAudioURLPolicy.permits(request.url)'),
                        delegate.index("completionHandler(request)"))

    def test_manual_transfer_uses_dedicated_redirect_policy_session(self):
        body = method_body()
        self.assertIn("delegate: ManualHTTPSRedirectDelegate()", body)
        self.assertIn("session.download(from: remoteURL)", body)
        self.assertIn("defer { session.invalidateAndCancel() }", body)
        self.assertNotIn("URLSession.shared.download(from: remoteURL)", body)
        self.assertLess(body.index("session.download(from: remoteURL)"),
                        body.index("try Task.checkCancellation()"))

    def test_redirect_delegate_rejects_provider_restricted_hosts(self):
        source = SOURCE.read_text(encoding="utf-8")
        delegate = source[source.index("private final class ManualHTTPSRedirectDelegate:"):
                          source.index("\nstruct AutomaticDownloadProgress")]
        policy = source[source.index("private enum ManualAudioURLPolicy"):source.index("/// Reject insecure")]
        for domain in ("spotify.com", "spotifycdn.com", "scdn.co"):
            self.assertIn(domain, policy)
        self.assertIn('host.hasSuffix("." + $0)', policy)
        self.assertIn("ManualAudioURLPolicy.permits(request.url)", delegate)

    def test_initial_redirect_and_final_urls_share_one_policy(self):
        source = SOURCE.read_text(encoding="utf-8")
        body = method_body()
        delegate = source[source.index("private final class ManualHTTPSRedirectDelegate:"):
                          source.index("\nstruct AutomaticDownloadProgress")]
        self.assertIn("ManualAudioURLPolicy.permits(remoteURL)", body)
        self.assertIn("ManualAudioURLPolicy.permits(http.url)", body)
        self.assertIn("ManualAudioURLPolicy.permits(request.url)", delegate)
        self.assertNotIn('host.hasSuffix("spotify.com")', body)

    def test_canonical_domain_policy_matches_complete_dns_labels(self):
        source = SOURCE.read_text(encoding="utf-8")
        policy = source[source.index("private enum ManualAudioURLPolicy"):
                        source.index("/// Reject insecure")]
        self.assertIn('rawHost.drop(while: { $0 == "." })', policy)
        self.assertIn('CharacterSet(charactersIn: ".")', policy)
        self.assertIn('host == $0 || host.hasSuffix("." + $0)', policy)
        self.assertIn('url.scheme?.lowercased() == "https"', policy)

    def test_overlapping_manual_and_files_imports_share_progress_counter(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("private var activeImportOperations = 0", source)
        begin = source[source.index("    private func beginImportOperation()"):source.index("    private func endImportOperation()")]
        end = source[source.index("    private func endImportOperation()"):source.index("    // Fail closed if the saved catalog", source.index("    private func endImportOperation()"))]
        self.assertIn("activeImportOperations += 1", begin)
        self.assertIn("isImporting = true", begin)
        self.assertIn("activeImportOperations -= 1", end)
        self.assertIn("isImporting = activeImportOperations > 0", end)
        self.assertIn("precondition(activeImportOperations > 0", end)
        for signature in ("func importAudio(urls: [URL])", "func downloadAudio(from remoteURL:"):
            method = source[source.index(signature):]
            self.assertIn("beginImportOperation()", method[:450])
            self.assertIn("defer { endImportOperation() }", method[:450])
        self.assertEqual(source.count("defer { isImporting = false }"), 0)

    def test_redirected_direct_audio_extension_is_recognized(self):
        body = method_body()
        self.assertIn('let finalExtension = http.url?.pathExtension.lowercased() ?? ""', body)
        self.assertIn('let requestedExtension = remoteURL.pathExtension.lowercased()', body)
        self.assertIn('let ext = supported.contains(finalExtension) ? finalExtension : requestedExtension', body)
        self.assertLess(body.index('ManualAudioURLPolicy.permits(http.url)'),
                        body.index('let finalExtension = http.url?.pathExtension.lowercased()'))
        self.assertLess(body.index('let ext = supported.contains(finalExtension)'),
                        body.index('let actualExtension ='))

    def test_redirected_extension_fallback_preserves_existing_opaque_url_imports(self):
        body = method_body()
        self.assertIn('let requestedExtension = remoteURL.pathExtension.lowercased()', body)
        self.assertIn('supported.contains(finalExtension) ? finalExtension : requestedExtension', body)
        self.assertIn('mimeExtensions[mime] != nil', body)

    def test_no_cancellation_check_is_swallowed(self):
        body = method_body()
        self.assertNotRegex(body, r"try\?\s*Task\.checkCancellation\(\)")


if __name__ == "__main__":
    unittest.main()
