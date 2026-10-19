#!/usr/bin/env python3
"""Verify the artifacts staged for an Ice Sparkle release.

This deliberately uses only the Python standard library plus OpenSSL, which
keeps the check usable on the signing Mac as well as in GitHub Actions.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
EXPECTED_FEED_URL = "https://raw.githubusercontent.com/thunder951413/ice/updates/appcast.xml"
SHA256SUMS = re.compile(r"([0-9a-fA-F]{64})[ \t]+\*?Ice\.zip\Z")


class VerificationError(Exception):
    pass


def fail(message: str) -> None:
    raise VerificationError(message)


def positive_integer(value: object, label: str) -> int:
    text = str(value)
    if not re.fullmatch(r"[1-9][0-9]*", text):
        fail(f"{label} must be a positive integer, got {text!r}")
    return int(text)


def expected_archive_url(tag: str) -> str:
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        fail(f"invalid release tag {tag!r}")
    return f"https://github.com/thunder951413/ice/releases/download/{tag}/Ice.zip"


def sparkle_value(item: ET.Element, enclosure: ET.Element, name: str) -> str | None:
    """Read a Sparkle field whether a producer placed it on item or enclosure.

    If both forms exist, they must agree; accepting divergent metadata would
    make the release ambiguous to Sparkle clients.
    """
    item_value = item.findtext(f"{SPARKLE}{name}")
    enclosure_value = enclosure.get(f"{SPARKLE}{name}")
    if item_value is not None:
        item_value = item_value.strip()
    if enclosure_value is not None:
        enclosure_value = enclosure_value.strip()
    if item_value and enclosure_value and item_value != enclosure_value:
        fail(f"appcast item and enclosure sparkle:{name} disagree")
    return item_value or enclosure_value


def appcast_metadata(path: Path) -> dict[str, str]:
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as error:
        fail(f"cannot parse appcast.xml: {error}")
    item = root.find("./channel/item")
    if item is None:
        fail("appcast.xml must contain channel/item")
    enclosure = item.find("enclosure")
    if enclosure is None:
        fail("appcast.xml item must contain an enclosure")
    version = sparkle_value(item, enclosure, "version")
    if not version:
        fail("appcast enclosure must include sparkle:version")
    short_version = sparkle_value(item, enclosure, "shortVersionString")
    signature = enclosure.get(f"{SPARKLE}edSignature", "").strip()
    if not signature:
        fail("appcast enclosure must include sparkle:edSignature")
    length = enclosure.get("length", "").strip()
    url = enclosure.get("url", "").strip()
    content_type = enclosure.get("type", "").strip()
    if not length or not url or not content_type:
        fail("appcast enclosure must include url, length, and type")
    return {
        "version": version,
        "short_version": short_version or "",
        "signature": signature,
        "length": length,
        "url": url,
        "type": content_type,
    }


def read_plist_from_zip(path: Path) -> dict[str, object]:
    try:
        with zipfile.ZipFile(path) as archive:
            candidates = [
                name
                for name in archive.namelist()
                if re.fullmatch(r"(?:[^/]+/)*Ice\.app/Contents/Info\.plist", name)
            ]
            if len(candidates) != 1:
                fail("Ice.zip must contain exactly one Ice.app/Contents/Info.plist")
            return plistlib.loads(archive.read(candidates[0]))
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        fail(f"cannot read bundled Info.plist: {error}")


def read_sha256sums(path: Path, zip_path: Path) -> None:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        fail(f"cannot read SHA256SUMS: {error}")
    if len(lines) != 1:
        fail("SHA256SUMS must contain exactly one Ice.zip hash")
    match = SHA256SUMS.fullmatch(lines[0])
    if not match:
        fail("SHA256SUMS must be a single hash for the literal path Ice.zip")
    actual = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    if match.group(1).lower() != actual:
        fail("SHA256SUMS does not match Ice.zip")


def verify_signature(zip_path: Path, public_key: str, signature: str) -> None:
    try:
        raw_key = base64.b64decode(public_key, validate=True)
        raw_signature = base64.b64decode(signature, validate=True)
    except (ValueError, binascii.Error) as error:
        fail(f"invalid base64 Sparkle key or signature: {error}")
    if len(raw_key) != 32:
        fail("SUPublicEDKey must decode to a 32-byte Ed25519 key")
    if len(raw_signature) != 64:
        fail("sparkle:edSignature must decode to a 64-byte Ed25519 signature")
    # SubjectPublicKeyInfo DER wrapper for a raw Ed25519 public key.
    der_key = bytes.fromhex("302a300506032b6570032100") + raw_key
    openssl = os.environ.get("OPENSSL", "openssl")
    with tempfile.TemporaryDirectory() as directory:
        key_path = Path(directory) / "public.der"
        signature_path = Path(directory) / "signature"
        key_path.write_bytes(der_key)
        signature_path.write_bytes(raw_signature)
        result = subprocess.run(
            [
                openssl,
                "pkeyutl",
                "-verify",
                "-pubin",
                "-keyform",
                "DER",
                "-rawin",
                "-inkey",
                str(key_path),
                "-in",
                str(zip_path),
                "-sigfile",
                str(signature_path),
            ],
            text=True,
            capture_output=True,
        )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        fail(f"Ed25519 signature verification failed: {detail}")


def verify(args: argparse.Namespace) -> None:
    tag = args.tag
    archive_url = expected_archive_url(tag)
    zip_path = Path(args.zip)
    appcast_path = Path(args.appcast)
    sums_path = Path(args.sha256sums)
    repo_info_path = Path(args.info_plist)
    if not zip_path.is_file() or not appcast_path.is_file() or not sums_path.is_file() or not repo_info_path.is_file():
        fail("zip, appcast, SHA256SUMS, and repository Info.plist must all be files")

    try:
        repo_info = plistlib.loads(repo_info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"cannot read repository Info.plist: {error}")
    bundled_info = read_plist_from_zip(zip_path)
    metadata = appcast_metadata(appcast_path)
    short_version = str(bundled_info.get("CFBundleShortVersionString", ""))
    if tag[1:] != short_version:
        fail(f"tag {tag} does not match bundled CFBundleShortVersionString {short_version!r}")
    build = positive_integer(bundled_info.get("CFBundleVersion", ""), "CFBundleVersion")
    if build != positive_integer(metadata["version"], "appcast sparkle:version"):
        fail("bundled CFBundleVersion does not match appcast sparkle:version")
    if metadata["short_version"] and metadata["short_version"] != short_version:
        fail("appcast sparkle:shortVersionString does not match bundled version")
    if metadata["url"] != archive_url:
        fail("appcast enclosure URL must be the tagged public GitHub release archive URL")
    if metadata["type"] != "application/octet-stream":
        fail("appcast enclosure type must be application/octet-stream")
    if positive_integer(metadata["length"], "appcast enclosure length") != zip_path.stat().st_size:
        fail("appcast enclosure length does not match Ice.zip")
    bundled_key = str(bundled_info.get("SUPublicEDKey", ""))
    repo_key = str(repo_info.get("SUPublicEDKey", ""))
    if not bundled_key or bundled_key != repo_key:
        fail("bundled SUPublicEDKey does not match Ice/Info.plist")
    if str(bundled_info.get("SUFeedURL", "")) != EXPECTED_FEED_URL:
        fail("bundled SUFeedURL is not the required public updates-branch URL")
    if str(repo_info.get("SUFeedURL", "")) != EXPECTED_FEED_URL:
        fail("Ice/Info.plist SUFeedURL is not the required public updates-branch URL")
    read_sha256sums(sums_path, zip_path)
    verify_signature(zip_path, bundled_key, metadata["signature"])
    print(f"Verified {tag}: version {short_version}, build {build}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--print-appcast-build", action="store_true")
    parser.add_argument("--tag")
    parser.add_argument("--zip", default="Ice.zip")
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--sha256sums")
    parser.add_argument("--info-plist", default="Ice/Info.plist")
    args = parser.parse_args()
    try:
        metadata = appcast_metadata(Path(args.appcast))
        if args.print_appcast_build:
            print(positive_integer(metadata["version"], "appcast sparkle:version"))
            return 0
        if not args.tag or not args.sha256sums:
            parser.error("--tag and --sha256sums are required when verifying a release")
        verify(args)
        return 0
    except VerificationError as error:
        print(f"release verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
