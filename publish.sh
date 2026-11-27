#!/bin/zsh
# Publishes the release that ./release.sh just built:
#   1. checks that main is clean, pushed, and has a CHANGELOG.md section for this version
#   2. tags the commit vX.Y.Z and pushes the tag
#   3. creates the GitHub release with Maben-Base.dmg and Maben-Base.zip, notes from CHANGELOG.md
#      -> every installed copy sees it within 6 hours and updates itself
#   4. rebuilds and deploys base.maben.gg (version, changelog). Its download buttons point at
#      releases/latest, so they serve the new version as soon as step 3 is done.
# Needs: gh (logged in as a maintainer), and ../maben/deploy.sh for step 4 (skipped if missing).
# ./ship.sh runs the whole release, this script included.
set -e
cd "$(dirname "$0")"
VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
TAG="v$VERSION"
DMG=dist/Maben-Base.dmg
ZIP=dist/Maben-Base.zip
BUILT="build/archive/notarized/Maben Base.app"

[[ -f $DMG && -f $ZIP && -d $BUILT ]] || { echo "Run ./release.sh first."; exit 1; }
[[ $(plutil -extract CFBundleShortVersionString raw "$BUILT/Contents/Info.plist") == "$VERSION" ]] \
  || { echo "dist/ holds another version than Info.plist ($VERSION). Run ./release.sh again."; exit 1; }
xcrun stapler validate "$BUILT" >/dev/null || { echo "The build isn't notarized."; exit 1; }

# What installed copies check before they update: Developer ID, our team, this app, notarized, this version.
# Checked on the app inside the zip, because that file is what they download. A release can't be changed
# once it is published, so one they would refuse must never get that far.
UNPACKED=$(mktemp -d)
ditto -x -k "$ZIP" "$UNPACKED"
REQ="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"${TEAM:-NJTYRVLSA8}\" and identifier \"$(plutil -extract CFBundleIdentifier raw Info.plist)\" and notarized"
codesign --verify --deep --strict -R="$REQ" "$UNPACKED/Maben Base.app" 2>/dev/null \
  && [[ $(plutil -extract CFBundleShortVersionString raw "$UNPACKED/Maben Base.app/Contents/Info.plist") == "$VERSION" ]] \
  || { rm -rf "$UNPACKED"; echo "The app in $ZIP wouldn't be accepted as an update. Run ./release.sh again."; exit 1; }
rm -rf "$UNPACKED"

[[ $(git branch --show-current) == main ]] || { echo "Publish from main."; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first."; exit 1; }
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "main isn't the same as origin/main. Push or pull first."; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists."; exit 1; }

NOTES=$(mktemp)
awk -v v="## $VERSION " 'index($0, v) == 1 {on=1; next} /^## / && on {exit} on' CHANGELOG.md | sed '/./,$!d' > "$NOTES"
[[ -s $NOTES ]] || { echo "CHANGELOG.md has no section '## $VERSION · <date>'."; exit 1; }

echo "Publishing Maben Base $VERSION…"
git tag -a "$TAG" -m "Maben Base $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" --title "Maben Base $VERSION" --notes-file "$NOTES" --verify-tag --latest
rm -f "$NOTES"
echo "GitHub release $TAG is live. Installed copies update within 6 hours."

# The website is not part of this repository. Its own deploy script builds it for this version and puts it online.
DEPLOY=../maben/deploy.sh
if [[ -x $DEPLOY ]]; then
  $DEPLOY base --version "$VERSION" --dist "$PWD/dist" \
    || { echo "The release is live, but the website wasn't updated. Run: $DEPLOY base --version $VERSION --dist $PWD/dist"; exit 1; }
else
  echo "Website not updated: $DEPLOY isn't there."
fi
