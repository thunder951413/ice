#!/usr/bin/env python3
"""Sign a prepared Ice.zip using Sparkle's local Keychain and create its feed."""
import argparse
import base64
import hashlib
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
REPOSITORY = 'thunder951413/ice'
FEED_URL = f'https://api.github.com/repos/{REPOSITORY}/contents/appcast.xml?ref=updates'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--asset-id', required=True, type=int)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--sparkle-bin', type=Path, default=Path('build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin'))
    parser.add_argument('--account', default='thunder951413-ice')
    args = parser.parse_args()
    if args.asset_id <= 0:
        parser.error('--asset-id must be positive')
    archive = args.directory / 'Ice.zip'
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read('Ice.app/Contents/Info.plist'))
    public_key = subprocess.check_output([
        str(args.sparkle_bin / 'generate_keys'), '--account', args.account, '-p',
    ], text=True).strip()
    if info.get('SUPublicEDKey') != public_key or info.get('SUFeedURL') != FEED_URL:
        parser.error('Archive uses a different signing key or update feed')
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[1-9]\d*', build):
        parser.error('Archive must have semantic version and positive build number')
    signature = subprocess.check_output([
        str(args.sparkle_bin / 'sign_update'), '--account', args.account, '-p', str(archive),
    ], text=True).strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        parser.error('Invalid signature returned by Sparkle')
    ET.register_namespace('sparkle', SPARKLE)
    root = ET.Element('rss', version='2.0')
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'Ice updates · thunder951413/ice'
    ET.SubElement(channel, 'link').text = f'https://github.com/{REPOSITORY}/releases'
    ET.SubElement(channel, 'description').text = 'Signed Ice releases from thunder951413/ice.'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Ice {version}'
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = build
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = '14.0'
    # Inline release notes avoid forwarding update credentials to another host.
    ET.SubElement(item, 'description').text = 'See the GitHub Release for changes and compatibility notes.'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://api.github.com/repos/{REPOSITORY}/releases/assets/{args.asset_id}',
        'length': str(archive.stat().st_size), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}edSignature': signature,
    })
    ET.indent(root)
    ET.ElementTree(root).write(args.directory / 'appcast.xml', encoding='utf-8', xml_declaration=True)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (args.directory / 'SHA256SUMS').write_text(f'{digest}  Ice.zip\n')
    print(f'Prepared signed appcast for Ice {version} ({build})')


if __name__ == '__main__':
    main()
