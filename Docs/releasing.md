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
mkdir -p build/releases/v0.12.1
ditto -c -k --sequesterRsrc --keepParent \
  build/DerivedData/Build/Products/Release/Ice.app build/releases/v0.12.1/Ice.zip
```

Commit the source and push the current release branch before creating the tag.
Do not overwrite unrelated `main` history. Prepare release notes in a file.

The `updates` branch is already initialized in this repository. For a new fork,
initialize it once using your authenticated local account before the first
release (`git push origin HEAD:refs/heads/updates`). GitHub's built-in workflow
token may reject creating a branch at a commit that changes workflow files.
Subsequent feed writes need only the workflow's Contents write permission.

## Trigger publication

The tag starts a workflow that waits up to five minutes for the three assets.
Have the archive and notes ready before pushing the tag:

```sh
git tag v0.12.1
git push origin v0.12.1
gh release create v0.12.1 --repo thunder951413/ice --verify-tag --draft \
  --target "$(git rev-parse v0.12.1)" --title 'Ice 0.12.1' \
  --notes-file build/releases/v0.12.1/notes.md build/releases/v0.12.1/Ice.zip
python3 Scripts/create-appcast.py --directory build/releases/v0.12.1
OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl python3 Scripts/verify-release.py \
  --tag v0.12.1 --zip build/releases/v0.12.1/Ice.zip \
  --appcast build/releases/v0.12.1/appcast.xml \
  --sha256sums build/releases/v0.12.1/SHA256SUMS
gh release upload v0.12.1 --repo thunder951413/ice \
  build/releases/v0.12.1/appcast.xml build/releases/v0.12.1/SHA256SUMS
```

`create-appcast.py` signs the exact archive via Sparkle's local Keychain and
checks that its public key and feed match the bundled app. It never exports the
private key. Use an OpenSSL build supporting Ed25519 for local verification;
the macOS system LibreSSL may not support it.

GitHub Actions downloads the assets and verifies the hash, versions, feed URL,
public key, length and Ed25519 signature. It publishes the draft, then writes
the feed to `updates` through GitHub's Contents API. Feed writes use bounded
retries with a freshly fetched blob SHA, then verify both the API response and
the public raw URL. The workflow never writes to the default branch or
force-pushes. Older builds cannot replace a newer feed or become latest.
Published releases can be revalidated to repair feed publication after a failure.
A missing-asset timeout can be retried after uploading the assets; do not replace
an archive that has already been published and signed. If the workflow itself
needs a fix after a tag is created, push the fix to the release branch and run
it against the existing tag without moving that tag:

```sh
gh workflow run release.yml --repo thunder951413/ice \
  --ref codex/macos27-compat -f tag=v0.12.1
```

## Public update channel

The app reads the feed at
`https://raw.githubusercontent.com/thunder951413/ice/updates/appcast.xml` and
downloads archives from
`https://github.com/thunder951413/ice/releases/download/vX.Y.Z/Ice.zip`.
These public URLs do not require a GitHub token and avoid API rate limits. The
app clears Sparkle's persisted feed override during setup so older local
overrides cannot keep it on the API endpoint. Existing Keychain items from
earlier builds are left untouched and are no longer read for update requests.

Version 0.12.0 still reads the same `updates/appcast.xml` through the old
GitHub Contents API URL, so it can discover this release. The new appcast's
public archive URL works for that migration, provided the API request succeeds.
If its anonymous API rate limit is exhausted, install 0.12.1 manually once.
Users migrating from upstream
must install the fork once manually to adopt its feed and signing key; a URL
change alone cannot migrate the trust anchor.
