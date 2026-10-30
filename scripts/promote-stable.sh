#!/usr/bin/env bash
# Promote one release from Latest onto Stable by editing the single Sparkle appcast.
#
# One appcast, served at releases/latest/download/appcast.xml (an asset of the newest
# published release). Every new release item is tagged <sparkle:channel>latest</sparkle:channel>.
# Sparkle shows a tagged item only to clients whose allowed channels include that name.
# Untagged items are shown to everyone, including copies that do not understand channels.
# Stable is the untagged items. Promotion removes the channel tag from one item.
#
# Promote after ~7 days on Latest, never on a Friday. The weekly job
# (scripts/stable-promote-job.sh) does that on Tuesdays. This script is the same
# step by hand, for a hotfix.
#
# Release assets of older releases must never be deleted: the appcast points at
# their DMGs. Rollback is to ship the previous good code with a higher version
# number and promote it. Sparkle never downgrades.
#
#     bash scripts/promote-stable.sh vX.Y [--yes] [--dry-run]
#
# --yes skips the confirmation. --dry-run runs the checks and prints the feed diff.
# It does not upload.

set -euo pipefail

cd "$(dirname "$0")/.."

YES=false
DRY=false
TAG=""

usage() {
  echo "Usage: bash scripts/promote-stable.sh vX.Y [--yes] [--dry-run]" >&2
}

for arg in "$@"; do
  case "$arg" in
    --yes) YES=true ;;
    --dry-run) DRY=true ;;
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

running=$(gh run list --workflow release.yml --status in_progress --json databaseId -q length | tr -d '[:space:]')
if [[ "$running" != "0" ]]; then
  echo "Refusing: a release workflow is in progress ($running). It would overwrite the feed." >&2
  exit 1
fi

LATEST_TAG=$(gh release view --json tagName -q .tagName)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if ! gh release download "$LATEST_TAG" -p appcast.xml -D "$TMP"; then
  echo "Refusing: $LATEST_TAG has no appcast.xml asset." >&2
  exit 1
fi
if [[ ! -s "$TMP/appcast.xml" ]]; then
  echo "Refusing: $LATEST_TAG has no appcast.xml asset." >&2
  exit 1
fi

version="${TAG#v}"

cat > "$TMP/feed.py" <<'PY'
import re, sys

ITEM_RE = re.compile(r"<item\b[^>]*>.*?</item>", re.DOTALL)
SHORT_RE = re.compile(r"<sparkle:shortVersionString>([^<]*)</sparkle:shortVersionString>")
CHANNEL_RE = re.compile(r"<sparkle:channel\b")
URL_RE = re.compile(r"""<enclosure\b[^>]*\burl=(?:"([^"]+)"|'([^']+)')""")
CHANNEL_LINE_RE = re.compile(
    r"\r?\n?[ \t]*<sparkle:channel>\s*latest\s*</sparkle:channel>[ \t]*\r?"
)


def load_items(path):
    text = open(path, encoding="utf-8").read()
    return text, ITEM_RE.findall(text)


def short_version(item):
    match = SHORT_RE.search(item)
    return match.group(1).strip() if match else ""


def enclosure_url(item):
    match = URL_RE.search(item)
    if not match:
        return ""
    return match.group(1) or match.group(2) or ""


def inspect(path, version):
    _text, found = load_items(path)
    target = None
    untagged = []
    for item in found:
        short = short_version(item)
        if short == version and target is None:
            target = item
        if short and not CHANNEL_RE.search(item):
            untagged.append(short)
    if target is None:
        print("status=absent")
        return
    if not CHANNEL_RE.search(target):
        print("status=already")
        return
    print("status=ok")
    print("url=%s" % enclosure_url(target))
    if untagged:
        for short in untagged:
            print("stable=%s" % short)
    else:
        print("stable=")


def edit(path, version):
    text, _found = load_items(path)
    state = {"removed": False}

    def replace(match):
        item = match.group(0)
        if short_version(item) != version:
            return item
        new_item, count = CHANNEL_LINE_RE.subn("", item, count=1)
        if count != 1:
            sys.exit("Refusing: could not remove <sparkle:channel>latest</sparkle:channel> from %s." % version)
        state["removed"] = True
        return new_item

    new_text = ITEM_RE.sub(replace, text)
    if not state["removed"]:
        sys.exit("Refusing: the feed has no item for %s." % version)
    open(path, "w", encoding="utf-8").write(new_text)


def verify(path, version):
    _text, found = load_items(path)
    for item in found:
        if short_version(item) == version:
            return 1 if CHANNEL_RE.search(item) else 0
    return 1


command, path, version_arg = sys.argv[1], sys.argv[2], sys.argv[3]
if command == "inspect":
    inspect(path, version_arg)
elif command == "edit":
    edit(path, version_arg)
elif command == "verify":
    sys.exit(verify(path, version_arg))
else:
    sys.exit("unknown command")
PY

info=$(python3 "$TMP/feed.py" inspect "$TMP/appcast.xml" "$version")
status=$(printf '%s\n' "$info" | sed -n 's/^status=//p')

case "$status" in
  absent)
    echo "Refusing: the feed from $LATEST_TAG has no item whose shortVersionString is $version." >&2
    exit 1
    ;;
  already)
    echo "already on Stable"
    exit 0
    ;;
  ok) ;;
  *)
    echo "Refusing: could not read the appcast from $LATEST_TAG." >&2
    exit 1
    ;;
esac

stables=$(printf '%s\n' "$info" | sed -n 's/^stable=//p' | sed '/^$/d' || true)
current=""
if [[ -n "$stables" ]]; then
  current=$(printf '%s\n' "$stables" | sort -V | tail -n 1 || true)
fi

if [[ -z "$current" ]]; then
  echo "Stable currently serves: none"
else
  echo "Stable currently serves: $current"
  newest=$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -n 1 || true)
  if [[ "$current" == "$version" || "$newest" != "$version" ]]; then
    echo "Refusing: $TAG is not newer than Stable ($current)." >&2
    exit 1
  fi
fi

url=$(printf '%s\n' "$info" | sed -n 's/^url=//p')
if [[ -z "$url" ]]; then
  echo "Refusing: the $version item has no enclosure URL." >&2
  exit 1
fi
if ! curl -sfIL -o /dev/null "$url"; then
  echo "Refusing: enclosure URL did not answer: $url" >&2
  exit 1
fi

cp "$TMP/appcast.xml" "$TMP/appcast.original.xml"
python3 "$TMP/feed.py" edit "$TMP/appcast.xml" "$version"

if [[ "$DRY" == true ]]; then
  echo "dry-run: feed diff (not uploaded):"
  diff -u "$TMP/appcast.original.xml" "$TMP/appcast.xml" || true
  exit 0
fi

if [[ "$YES" != true ]]; then
  read -r -p "Promote $TAG to Stable? [y/N] " answer
  case "$answer" in
    y|Y) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# Only appcast.xml is replaced. Older releases' DMGs stay; the feed still links to them.
gh release upload "$LATEST_TAG" "$TMP/appcast.xml" --clobber

REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner)
FEED_URL="https://github.com/${REPO_SLUG}/releases/latest/download/appcast.xml"
ok=0
for attempt in 1 2 3 4 5 6; do
  if curl -fsL "$FEED_URL" -o "$TMP/verify.xml" && python3 "$TMP/feed.py" verify "$TMP/verify.xml" "$version"; then
    ok=1
    break
  fi
  if [[ "$attempt" -lt 6 ]]; then
    echo "Feed not updated yet (attempt $attempt/6); sleeping 10s for the CDN."
    sleep 10
  fi
done
if [[ "$ok" -ne 1 ]]; then
  echo "Refusing: $FEED_URL still does not serve $TAG as an untagged item." >&2
  exit 1
fi
echo "Stable now serves $TAG"
