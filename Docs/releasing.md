# Releasing Ice

Build and Apple-sign on the local development Mac with Xcode 27. The GitHub
workflow verifies and publishes the prepared archive; Apple certificates and
the Sparkle private key stay on the Mac. The Sparkle Keychain account for this
fork is `thunder951413-ice`. Keep a secure offline backup of that signing key;
losing it prevents signing compatible future updates.

## Prepare a version

Update both build configurations in `Ice.xcodeproj/project.pbxproj`: marketing
version must match the intended `vX.Y.Z` tag and the build number must increase.
Keep `SUFeedURL` and `SUPublicEDKey` in `Ice/Info.plist` consistent with the fork.
Run relevant regressions, then build and package, for example:

```sh
CONFIGURATION=Release ./Scripts/build-local.sh
mkdir -p build/releases/v0.12.0
ditto -c -k --sequesterRsrc --keepParent \
  build/DerivedData/Build/Products/Release/Ice.app build/releases/v0.12.0/Ice.zip
```

Commit the source and push the current release branch before creating the tag.
Do not overwrite unrelated `main` history. Prepare release notes in a file.

## Trigger publication

The tag starts a workflow that waits up to five minutes for the three assets.
Have the archive and notes ready before pushing the tag:

```sh
git tag v0.12.0
git push origin v0.12.0
gh release create v0.12.0 --repo thunder951413/ice --verify-tag --draft \
  --target "$(git rev-parse v0.12.0)" --title 'Ice 0.12.0' \
  --notes-file build/releases/v0.12.0/notes.md build/releases/v0.12.0/Ice.zip
asset_id=$(gh api repos/thunder951413/ice/releases \
  --jq '.[] | select(.tag_name == "v0.12.0") | .assets[] | select(.name == "Ice.zip") | .id')
python3 Scripts/create-appcast.py --asset-id "$asset_id" \
  --directory build/releases/v0.12.0
OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl python3 Scripts/verify-release.py \
  --tag v0.12.0 --zip build/releases/v0.12.0/Ice.zip \
  --appcast build/releases/v0.12.0/appcast.xml \
  --sha256sums build/releases/v0.12.0/SHA256SUMS
gh release upload v0.12.0 --repo thunder951413/ice \
  build/releases/v0.12.0/appcast.xml build/releases/v0.12.0/SHA256SUMS
```

`create-appcast.py` signs the exact archive via Sparkle's local Keychain and
checks that its public key and feed match the bundled app. It never exports the
private key. Use an OpenSSL build supporting Ed25519 for local verification;
the macOS system LibreSSL may not support it.

GitHub Actions downloads the assets and verifies the hash, versions, feed URL,
public key, length and Ed25519 signature. It publishes the draft, then writes
the feed to `updates` through GitHub's Contents API. It never writes to `main`
or force-pushes. Older builds cannot replace a newer feed or become latest.
Published releases can be revalidated to repair feed publication after a failure.
A missing-asset timeout can be retried after uploading the assets; do not replace
an archive that has already been published and signed.

## Private repository access

The app reads the feed at
`https://api.github.com/repos/thunder951413/ice/contents/appcast.xml?ref=updates`.
Enclosures use this repository's release-asset API URLs. Private repositories
require a token with Contents read access, configured in About → GitHub updates
and stored only in the local Keychain. Never embed a GitHub token in the app,
appcast, repository URL or release archive. Public repositories need no token.

Users migrating from upstream must install the fork once manually to adopt
its feed and signing key. A changed URL alone cannot migrate the trust anchor.
