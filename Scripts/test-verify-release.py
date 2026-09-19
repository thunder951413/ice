#!/usr/bin/env python3
"""Fast negative and URL-contract tests for verify-release.py."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-release.py")
SPEC = importlib.util.spec_from_file_location("verify_release", SCRIPT)
assert SPEC and SPEC.loader
verify_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify_release)


class ReleaseVerifierTests(unittest.TestCase):
    def write_appcast(self, body: str) -> Path:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "appcast.xml"
        path.write_text(body, encoding="utf-8")
        return path

    def test_public_release_url_is_exact(self) -> None:
        self.assertEqual(
            verify_release.expected_archive_url("v0.12.1"),
            "https://github.com/thunder951413/ice/releases/download/v0.12.1/Ice.zip",
        )
        for bad_tag in ("0.12.1", "v0.12", "v0.12.1/extra", "vnext"):
            with self.subTest(tag=bad_tag), self.assertRaises(verify_release.VerificationError):
                verify_release.expected_archive_url(bad_tag)

    def test_rejects_conflicting_versions(self) -> None:
        path = self.write_appcast("""\
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item><sparkle:version>1126</sparkle:version>
    <enclosure url="https://example.invalid/Ice.zip" length="1"
      type="application/octet-stream" sparkle:version="1125" sparkle:edSignature="x" />
  </item></channel>
</rss>
""")
        with self.assertRaisesRegex(verify_release.VerificationError, "disagree"):
            verify_release.appcast_metadata(path)

    def test_rejects_missing_signature(self) -> None:
        path = self.write_appcast("""\
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item><sparkle:version>1126</sparkle:version>
    <enclosure url="https://example.invalid/Ice.zip" length="1" type="application/octet-stream" />
  </item></channel>
</rss>
""")
        with self.assertRaisesRegex(verify_release.VerificationError, "edSignature"):
            verify_release.appcast_metadata(path)


if __name__ == "__main__":
    unittest.main()
