#!/usr/bin/env bash
set -euo pipefail

PBXPROJ="Ice.xcodeproj/project.pbxproj"

usage() {
  echo "Usage: $0 <increment>"
  echo "  increment: semver increment, e.g. 0.1 (minor), 0.0.1 (patch), 1.0 (major)"
  echo "  Example:"
  echo "    $0 0.1     # 1.0.0 -> 1.1.0  (minor bump, patch resets to 0)"
  echo "    $0 0.0.1   # 1.0.0 -> 1.0.1  (patch bump)"
  echo "    $0 1.0     # 1.0.0 -> 2.0.0  (major bump, minor+patch reset to 0)"
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

INCREMENT=$1

if ! [[ "$INCREMENT" =~ ^[0-9]+(\.[0-9]+)?(\.[0-9]+)?$ ]]; then
  echo "Error: increment must be a positive number (e.g., 0.1, 0.0.1, 1.0)"
  exit 1
fi

# Read current MARKETING_VERSION
CURRENT_VERSION=$(grep -m1 'MARKETING_VERSION' "$PBXPROJ" | sed 's/.*= //;s/;//' | xargs)
echo "Current version: $CURRENT_VERSION"

# Split into components (pad to 3)
IFS='.' read -ra C <<< "$CURRENT_VERSION"
while [[ ${#C[@]} -lt 3 ]]; do C+=( "0" ); done

IFS='.' read -ra I <<< "$INCREMENT"
while [[ ${#I[@]} -lt 3 ]]; do I+=( "0" ); done

# Find highest non-zero increment position (0=major, 1=minor, 2=patch)
LEVEL=-1
for i in 0 1 2; do
  if [[ "${I[i]}" -gt 0 ]]; then
    LEVEL=$i
    break
  fi
done

if [[ $LEVEL -eq -1 ]]; then
  echo "Error: increment is all zeros"
  exit 1
fi

# New version: bump at LEVEL, reset everything to the right
NEW_PARTS=("${C[@]}")
NEW_PARTS[$LEVEL]=$(( ${C[$LEVEL]} + ${I[$LEVEL]} ))
for ((j=LEVEL+1; j<3; j++)); do
  NEW_PARTS[j]=0
done

NEW_VERSION="${NEW_PARTS[0]}.${NEW_PARTS[1]}.${NEW_PARTS[2]}"
echo "New version: $NEW_VERSION"

# Bump build number
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PBXPROJ" | sed 's/.*= //;s/;//' | xargs)
NEW_BUILD=$(( CURRENT_BUILD + 1 ))
echo "Build number: $CURRENT_BUILD -> $NEW_BUILD"

# Update pbxproj
sed -i '' "s/MARKETING_VERSION = $CURRENT_VERSION;/MARKETING_VERSION = $NEW_VERSION;/g" "$PBXPROJ"
sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PBXPROJ"

echo "✓ Updated $PBXPROJ"

# Git commit + tag
if git diff --quiet "$PBXPROJ"; then
  echo "No changes to commit."
else
  git add "$PBXPROJ"
  git commit -m "chore: bump version to $NEW_VERSION (build $NEW_BUILD)"
  git tag "v$NEW_VERSION"
  echo "✓ Created commit and tag v$NEW_VERSION"

  if [[ "${SKIP_PUSH:-}" != "1" ]]; then
    echo "Pushing to origin..."
    git push origin main
    git push origin "v$NEW_VERSION"
    echo "✓ Pushed. GitHub Actions will build and create a draft release."
    echo "  → https://github.com/jordanbaird/Ice/releases"
  else
    echo "SKIP_PUSH=1, skipping git push."
    echo "Push manually: git push && git push --tags"
  fi
fi
