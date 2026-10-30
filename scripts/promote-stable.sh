#!/usr/bin/env bash
# Point the Stable update channel at a published release's appcast.
#
# Stable is a permanent GitHub prerelease (tag `stable`) whose only asset is appcast.xml.
# Prereleases never become "latest", so the Latest feed
# (releases/latest/download/appcast.xml) is left alone. Run from the submodule root;
# `gh` and `git` use this checkout's remote. No tokens are hardcoded.
#
#     bash scripts/promote-stable.sh vX.Y [--yes] [--force]
#
# Refuses drafts, prereleases, a missing appcast, and a version that is not newer than
# what Stable already serves. --force re-uploads the same version. --yes skips the prompt.
# Promote after ~5–7 days on Latest without a regression, at most every two weeks, never
# on a Friday (.cursor/commands/release.md).

set -euo pipefail

cd "$(dirname "$0")/.."

YES=false
FORCE=false
TAG=""

usage() {
  echo "Usage: bash scripts/promote-stable.sh vX.Y [--yes] [--force]" >&2
}

for arg in "$@"; do
  case "$arg" in
    --yes) YES=true ;;
    --force) FORCE=true ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
    *)
      if [[ -n "$TAG" ]]; then
        echo "Unexpected argument: $arg" >&2
        usage
        exit 1
      fi
      TAG="$arg"
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  usage
  exit 1
fi

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Refusing: tag must look like vX.Y or vX.Y.Z (got $TAG)." >&2
  exit 1
fi

if ! state=$(gh release view "$TAG" --json isDraft,isPrerelease --jq 'if .isDraft then "draft" elif .isPrerelease then "prerelease" else "release" end'); then
  echo "Refusing: $TAG is not a GitHub release." >&2
  exit 1
fi
case "$state" in
  draft)
    echo "Refusing: $TAG is a draft." >&2
    exit 1
    ;;
  prerelease)
    echo "Refusing: $TAG is a prerelease." >&2
    exit 1
    ;;
  release) ;;
  *)
    echo "Refusing: could not read release $TAG ($state)." >&2
    exit 1
    ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if ! gh release download "$TAG" -p appcast.xml -D "$TMP"; then
  echo "Refusing: $TAG has no appcast.xml asset." >&2
  exit 1
fi
if [[ ! -s "$TMP/appcast.xml" ]]; then
  echo "Refusing: $TAG has no appcast.xml asset." >&2
  exit 1
fi

version="${TAG#v}"
needle="<sparkle:shortVersionString>${version}</sparkle:shortVersionString>"
if ! grep -q -F "$needle" "$TMP/appcast.xml"; then
  echo "Refusing: appcast.xml from $TAG does not contain $needle." >&2
  exit 1
fi

old_version=""
mkdir -p "$TMP/old"
if gh release download stable -p appcast.xml -D "$TMP/old" 2>/dev/null && [[ -s "$TMP/old/appcast.xml" ]]; then
  old_version=$(sed -n 's/.*<sparkle:shortVersionString>\([^<]*\)<\/sparkle:shortVersionString>.*/\1/p' "$TMP/old/appcast.xml")
  old_version=${old_version%%$'\n'*}
fi

if [[ -z "$old_version" ]]; then
  echo "Stable currently serves: none yet"
else
  echo "Stable currently serves: $old_version"
  if [[ "$old_version" == "$version" ]]; then
    if [[ "$FORCE" != true ]]; then
      echo "Refusing: $TAG is not newer than Stable ($old_version). Re-upload the same version with --force." >&2
      exit 1
    fi
  else
    newest=$(printf '%s\n%s\n' "$old_version" "$version" | sort -V | tail -n 1)
    if [[ "$newest" != "$version" ]]; then
      echo "Refusing: $TAG is not newer than Stable ($old_version)." >&2
      exit 1
    fi
  fi
fi

if [[ "$YES" != true ]]; then
  read -r -p "Promote $TAG to Stable? [y/N] " answer
  case "$answer" in
    y|Y) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

notes="Update feed for the Stable channel (appcast.xml only). Not a release; download the app from the latest vX release."
title="Stable update channel"

if ! gh release view stable --json tagName >/dev/null 2>&1; then
  tag_exists=false
  if git rev-parse -q --verify "refs/tags/stable" >/dev/null 2>&1; then
    tag_exists=true
  elif git ls-remote --exit-code --tags origin "refs/tags/stable" >/dev/null 2>&1; then
    tag_exists=true
  fi
  if [[ "$tag_exists" == true ]]; then
    gh release create stable --prerelease --title "$title" --notes "$notes"
  else
    if ! target=$(git rev-list -n 1 "$TAG"); then
      echo "Refusing: cannot resolve $TAG to a commit." >&2
      exit 1
    fi
    gh release create stable --prerelease --target "$target" --title "$title" --notes "$notes"
  fi
fi

gh release upload stable "$TMP/appcast.xml" --clobber
gh release edit stable --prerelease --latest=false

echo "Stable now serves $TAG. Check: curl -sL https://github.com/mgsgde/whisper-shortcut/releases/download/stable/appcast.xml | grep shortVersionString"
