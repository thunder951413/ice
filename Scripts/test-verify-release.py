#!/usr/bin/env python3
"""Fast negative and URL-contract tests for verify-release.py."""

from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import plistlib
import struct
import subprocess
import tempfile
import unittest
import zipfile
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

    def test_universal_macho_validation(self) -> None:
        fat_header = struct.pack(
            ">II" + ("IIIII" * 2),
            verify_release.FAT_MAGIC,
            2,
            verify_release.CPU_TYPE_X86_64,
            3,
            4096,
            1024,
            12,
            verify_release.CPU_TYPE_ARM64,
            0,
            8192,
            1024,
            14,
        )
        verify_release.verify_universal_macho(fat_header)

        single_arch_header = struct.pack("<IIIIIII", verify_release.MH_MAGIC_64, verify_release.CPU_TYPE_ARM64, 0, 2, 0, 0, 0)
        with self.assertRaisesRegex(verify_release.VerificationError, "universal"):
            verify_release.verify_universal_macho(single_arch_header)
        verify_release.verify_macho_binary(single_arch_header, require_x86_64=False)

        x86_only_header = struct.pack("<IIIIIII", verify_release.MH_MAGIC_64, verify_release.CPU_TYPE_X86_64, 0, 2, 0, 0, 0)
        with self.assertRaisesRegex(verify_release.VerificationError, "arm64"):
            verify_release.verify_macho_binary(x86_only_header, require_x86_64=False)

        arm64_only_fat = struct.pack(
            ">II" + ("IIIII" * 2),
            verify_release.FAT_MAGIC,
            2,
            verify_release.CPU_TYPE_ARM64,
            0,
            4096,
            1024,
            14,
            verify_release.CPU_TYPE_ARM64,
            2,
            8192,
            1024,
            14,
        )
        with self.assertRaisesRegex(verify_release.VerificationError, "x86_64"):
            verify_release.verify_universal_macho(arm64_only_fat)

    def test_end_to_end_signed_bundle_verification(self) -> None:
        openssl = verify_release.resolve_openssl()
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        key_pem = root / "ed25519.pem"
        gen = subprocess.run(
            [openssl, "genpkey", "-algorithm", "ED25519", "-out", str(key_pem)],
            capture_output=True,
            text=True,
        )
        if gen.returncode != 0:
            self.skipTest(f"{openssl} does not support Ed25519 key generation")

        pub_der = subprocess.check_output(
            [openssl, "pkey", "-in", str(key_pem), "-pubout", "-outform", "DER"]
        )
        public_key_b64 = base64.b64encode(pub_der[-32:]).decode("ascii")

        info = {
            "CFBundleExecutable": "Ice",
            "CFBundleShortVersionString": "0.12.6",
            "CFBundleVersion": "1131",
            "SUPublicEDKey": public_key_b64,
            "SUFeedURL": verify_release.EXPECTED_FEED_URL,
        }
        info_plist = root / "Info.plist"
        info_plist.write_bytes(plistlib.dumps(info))

        fat_binary = struct.pack(
            ">II" + ("IIIII" * 2),
            verify_release.FAT_MAGIC,
            2,
            verify_release.CPU_TYPE_X86_64,
            3,
            4096,
            1024,
            12,
            verify_release.CPU_TYPE_ARM64,
            0,
            8192,
            1024,
            14,
        )
        zip_path = root / "Ice.zip"
        with zipfile.ZipFile(zip_path, "w") as archive:
            archive.writestr("Ice.app/Contents/Info.plist", plistlib.dumps(info))
            archive.writestr("Ice.app/Contents/MacOS/Ice", fat_binary)

        sig_path = root / "Ice.zip.sig"
        subprocess.check_call(
            [
                openssl,
                "pkeyutl",
                "-sign",
                "-rawin",
                "-inkey",
                str(key_pem),
                "-in",
                str(zip_path),
                "-out",
                str(sig_path),
            ]
        )
        signature_b64 = base64.b64encode(sig_path.read_bytes()).decode("ascii")

        sums_path = root / "SHA256SUMS"
        sums_path.write_text(
            f"{hashlib.sha256(zip_path.read_bytes()).hexdigest()}  Ice.zip\n",
            encoding="utf-8",
        )

        appcast_path = root / "appcast.xml"
        appcast_path.write_text(
            f"""\
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>1131</sparkle:version>
    <sparkle:shortVersionString>0.12.6</sparkle:shortVersionString>
    <enclosure
      url="https://github.com/thunder951413/ice/releases/download/v0.12.6/Ice.zip"
      length="{zip_path.stat().st_size}"
      type="application/octet-stream"
      sparkle:edSignature="{signature_b64}" />
  </item></channel>
</rss>
""",
            encoding="utf-8",
        )

        args = argparse.Namespace(
            tag="v0.12.6",
            zip=str(zip_path),
            appcast=str(appcast_path),
            sha256sums=str(sums_path),
            info_plist=str(info_plist),
        )
        verify_release.verify(args)


if __name__ == "__main__":
    unittest.main()
