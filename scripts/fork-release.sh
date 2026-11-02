#!/usr/bin/env bash
# Publishes the tagged commit as a GitHub release and points Casks/puremac.rb at it. homebrew-tap copies that cask, so
# this also asks it to sync. Tag the commit first, as fork-<version>, which keeps it apart from upstream's v<version>.
#
# The version is stamped into the build, not committed, so upstream's version bumps can't conflict with ours. Ad-hoc
# signed on purpose: a public build must not carry the personal identity scripts/install.sh signs with.
#
#   scripts/fork-release.sh 3.4.0
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?Usage: $0 <version>}"
tag="fork-$version"
repo=jonaprieto/PureMac
if [[ -n "$(git status --porcelain)" ]]; then echo "Commit your changes first." >&2; exit 1; fi
if [[ "$(git branch --show-current)" != fork ]]; then echo "Run this from the fork branch." >&2; exit 1; fi
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "$tag^{commit}")" ]]; then echo "$tag must point at HEAD." >&2; exit 1; fi

rm -rf build
xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Release -derivedDataPath build \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" CODE_SIGNING_ALLOWED=NO -quiet build

app=build/Build/Products/Release/PureMac.app
cp LICENSE "$app/Contents/Resources/LICENSE"
codesign --force --options runtime --sign - "$app"
codesign --verify --strict "$app"
zip="build/PureMac-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)

git push origin HEAD "$tag"
# gh won't read tag notes together with -R, and -R keeps this from ever reaching upstream.
gh release create "$tag" "$zip" -R "$repo" --title "PureMac fork $version" --verify-tag \
  --notes "$(git tag -l --format='%(contents:body)' "$tag")"

perl -pi -e "s/^  version .*/  version \"$version\"/; s/^  sha256 .*/  sha256 \"$sha\"/" Casks/puremac.rb
git commit -q -m "chore: point the cask at release $version" Casks/puremac.rb
git push origin HEAD
gh workflow run sync.yml -R jonaprieto/homebrew-tap
