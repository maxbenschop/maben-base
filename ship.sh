#!/bin/zsh
# One command for a whole release, from the working tree to every installed copy:
#   ./ship.sh [patch|minor|major|X.Y.Z]   release. Without an argument: the version in Info.plist if it has
#                                         no tag yet, otherwise the next patch version.
#   ./ship.sh --check [patch|…]           show what would be released and change nothing
#
# Steps, stopping at the first one that fails:
#   1. version    sets it in Info.plist and turns "## Unreleased" in CHANGELOG.md into "## X.Y.Z · <date>"
#   2. tests      swift build, swift test
#   3. merge      commits the working tree to a branch, opens the pull request, waits for the
#                 "Build and test" check and merges it (skipped when main already holds everything)
#   4. build      ./release.sh: universal build, signed with the Developer ID, notarized by Apple
#   5. publish    ./publish.sh: tag, GitHub release, website
#   6. proof      downloads the published zip and checks it the way an installed copy does before updating
# After a failure, fix the cause and run it again: it continues from what is already done.
#
# Needs no passwords: Xcode's signed-in Apple account signs and notarizes, and `gh` is logged in.
# This file is the same in every Maben app; the app's name and bundle ID come from Info.plist.
set -e
cd "$(dirname "$0")"
die() { print -r -- "ship: $*" >&2; exit 1 }
step() { print -r -- "── $*" }

CHECK=0
[[ $1 == --check ]] && { CHECK=1; shift }
HOW=${1:-}

NAME=$(plutil -extract CFBundleName raw Info.plist)
ID=$(plutil -extract CFBundleIdentifier raw Info.plist)
CURRENT=$(plutil -extract CFBundleShortVersionString raw Info.plist)
FILE=${NAME// /-}
TEAM="${TEAM:-NJTYRVLSA8}"

command -v gh >/dev/null || die "gh is not installed (brew install gh)."
gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"
command -v xcodegen >/dev/null || die "xcodegen is not installed (brew install xcodegen)."
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
git fetch -q --tags origin main

# Versions are written without a trailing .0: 1.8, not 1.8.0.
bump() {
  local -a p; p=(${(s:.:)1}); while (( $#p < 3 )) p+=(0)
  case $2 in
    patch) (( p[3] += 1 ));;
    minor) (( p[2] += 1 )); p[3]=0;;
    major) (( p[1] += 1 )); p[2]=0; p[3]=0;;
  esac
  local v="$p[1].$p[2].$p[3]"; print -r -- ${v%.0}
}
tagged() { git rev-parse -q --verify "refs/tags/v$1" >/dev/null }

# patch, minor and major count from the latest release, so running the same command again after a
# failure gives the same version.
LATEST=$(git tag -l 'v*' --sort=-v:refname | head -1)
BASE=${${LATEST#v}:-$CURRENT}
case $HOW in
  "") if tagged $CURRENT; then NEXT=$(bump $CURRENT patch); else NEXT=$CURRENT; fi;;
  patch|minor|major) NEXT=$(bump $BASE $HOW);;
  <->.<->|<->.<->.<->) NEXT=$HOW;;
  *) die "usage: ./ship.sh [--check] [patch|minor|major|X.Y.Z]";;
esac
tagged $NEXT && die "v$NEXT is already released. If only the website is behind: ../maben/deploy.sh ${${NAME#Maben }:l} --version $NEXT --dist $PWD/dist"
if [[ -n $LATEST && $(print -l ${LATEST#v} $NEXT | sort -V | tail -1) != $NEXT ]]; then
  die "$NEXT is older than the latest release ($LATEST). Installed copies never go back a version."
fi

# The notes: this version's section when it is already written, otherwise what is under "## Unreleased".
if grep -q "^## $NEXT " CHANGELOG.md; then SECTION="## $NEXT "; RENAME=0
elif grep -q "^## Unreleased" CHANGELOG.md; then SECTION="## Unreleased"; RENAME=1
else die "CHANGELOG.md has no '## Unreleased' section. Write there what changed, one line per change people will notice."
fi
NOTES=$(mktemp)
awk -v v="$SECTION" 'index($0, v) == 1 {on=1; next} /^## / && on {exit} on' CHANGELOG.md | sed '/./,$!d' > "$NOTES"
grep -q '[^[:space:]]' "$NOTES" || die "The '$SECTION' section in CHANGELOG.md is empty."

BRANCH=$(git branch --show-current)
[[ -n $BRANCH ]] || die "Not on a branch."
git merge-base --is-ancestor origin/main HEAD || die "This branch doesn't hold the latest main. Run: git pull --rebase origin main"
CHANGES=$(git status --porcelain)
NEEDS_MERGE=1
[[ $BRANCH == main && -z $CHANGES && $RENAME == 0 && $CURRENT == $NEXT && $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] && NEEDS_MERGE=0

print -r -- "$NAME $CURRENT → $NEXT   ($REPO, branch $BRANCH)"
print -r -- "Release notes:"; sed 's/^/  /' "$NOTES"
if (( NEEDS_MERGE )); then
  print -r -- "Goes into the pull request (besides the version and the changelog heading):"
  if [[ -n $CHANGES ]]; then git status --short | sed 's/^/  /'; else print -r -- "  nothing uncommitted; the commits on $BRANCH"; fi
else
  print -r -- "main already holds this version: building and publishing it as it is."
fi
(( CHECK )) && { rm -f "$NOTES"; print -r -- "Checked only. Nothing was changed."; exit 0 }

# 1. Version
if [[ $CURRENT != $NEXT ]]; then
  /usr/bin/sed -i '' -e '/<key>CFBundleShortVersionString<\/key>/{n;s|<string>.*</string>|<string>'"$NEXT"'</string>|;}' Info.plist
  [[ $(plutil -extract CFBundleShortVersionString raw Info.plist) == $NEXT ]] || die "Couldn't set the version in Info.plist."
fi
if (( RENAME )); then
  /usr/bin/sed -i '' -e "s/^## Unreleased.*$/## $NEXT · $(LC_ALL=C date '+%-d %B %Y')/" CHANGELOG.md
fi

# 2. Tests
step "Tests"
LOG=$(mktemp)
swift build >"$LOG" 2>&1 || { tail -40 "$LOG"; die "swift build failed."; }
# MABEN_LIVE=1 adds the test that runs the updater against the release GitHub serves today.
MABEN_LIVE=1 swift test >"$LOG" 2>&1 || { grep -E "error:|failed|Executed" "$LOG" | tail -40; die "swift test failed."; }
grep -E "Executed .* tests" "$LOG" | tail -1
rm -f "$LOG"

# 3. Merge
if (( NEEDS_MERGE )); then
  step "Pull request"
  [[ $BRANCH == main ]] && { BRANCH="release-$NEXT"; git switch -q -c "$BRANCH"; }
  if [[ -n $(git status --porcelain) ]]; then git add -A; git commit -q -m "$NAME $NEXT"; fi
  git push -q -u origin "$BRANCH"
  PR=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')
  if [[ -z $PR ]]; then
    gh pr create --base main --head "$BRANCH" --title "$NAME $NEXT" --body-file "$NOTES" >/dev/null
    PR=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')
  fi
  [[ -n $PR ]] || die "Couldn't open the pull request."
  print -r -- "https://github.com/$REPO/pull/$PR — waiting for the checks (about 5 minutes)…"
  # The checks the branch rules require decide; they take a moment to appear after the push.
  for i in {1..30}; do
    [[ $(gh pr checks "$PR" --required --json name --jq length 2>/dev/null || echo 0) -gt 0 ]] && break
    sleep 10
  done
  gh pr checks "$PR" --required --watch --fail-fast --interval 20 >/dev/null \
    || { gh pr checks "$PR" || true; die "A required check failed. Fix it, then run ./ship.sh again."; }
  # Other checks (a secret scanner, for one) don't stop the release, but a failed one is worth a look.
  OTHER=$(gh pr checks "$PR" --json name,bucket --jq '[.[] | select(.bucket == "fail") | .name] | join(", ")' 2>/dev/null || true)
  [[ -n $OTHER ]] && print -r -- "Note: not required, but failed: $OTHER. Look at https://github.com/$REPO/pull/$PR/checks"
  # --admin: the branch rules ask for a review by someone else, and the maintainer is the only one here.
  # The required check has passed by now (the line above waits for it).
  gh pr merge "$PR" --squash --admin >/dev/null
  git fetch -q origin main
  # The squashed commit on main must be exactly this branch before the local branch is let go.
  git diff --quiet HEAD origin/main || die "main isn't the same as $BRANCH after merging pull request $PR. Look before going on."
  git switch -q -C main origin/main
  git branch -q -D "$BRANCH" 2>/dev/null || true
fi
rm -f "$NOTES"

# 4 and 5. Build, then publish
step "Build, sign, notarize"
./release.sh
step "Publish"
./publish.sh

# 6. Proof: what the release page serves is what an installed copy will accept.
step "Proof"
PROOF=$(mktemp -d)
curl -fsSL -o "$PROOF/app.zip" "https://github.com/$REPO/releases/download/v$NEXT/$FILE.zip"
ditto -x -k "$PROOF/app.zip" "$PROOF"
REQ="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM\" and identifier \"$ID\" and notarized"
codesign --verify --deep --strict -R="$REQ" "$PROOF/$NAME.app" \
  && [[ $(plutil -extract CFBundleShortVersionString raw "$PROOF/$NAME.app/Contents/Info.plist") == $NEXT ]] \
  || { rm -rf "$PROOF"; die "The published zip would NOT be accepted by installed copies. Look at https://github.com/$REPO/releases/tag/v$NEXT now."; }
rm -rf "$PROOF"
print -r -- "$NAME $NEXT is released: https://github.com/$REPO/releases/tag/v$NEXT"
print -r -- "Installed copies update themselves within 6 hours."
[[ -n ${OTHER:-} ]] && print -r -- "Still to look at: the check that failed without being required ($OTHER)."
exit 0
