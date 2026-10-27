#!/bin/bash
# Sync WhisperShortcut/Localizable.xcstrings and InfoPlist.xcstrings with the keys the compiler extracts.
#
# Why: plain `xcodebuild build` does NOT write extracted keys back into the source catalogs (only the
# Xcode IDE does). `xcodebuild -exportLocalizations` does run the extraction and emits synced copies
# under `<xcloc>/Source Contents/` (observed 2026-10-26: the export also rewrites the project's own
# catalogs in place). This script exports, then merges those copies back:
#   - new keys are added (English source from the export),
#   - existing entries (including every `de` translation) are kept untouched,
#   - keys no longer in code get "extractionState": "stale" (manual keys are left alone),
#   - keys with no letters (" ", "·", "%@") get "shouldTranslate": false.
#
# Usage: bash scripts/sync-strings.sh [--xcloc <existing de.xcloc dir>]   (skips the slow export)
set -euo pipefail
cd "$(dirname "$0")/.."

XCLOC=""
if [ "${1:-}" = "--xcloc" ]; then XCLOC="${2:?path to .xcloc}"; fi
if [ -z "$XCLOC" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  xcodebuild -exportLocalizations -project WhisperShortcut.xcodeproj -scheme WhisperShortcut \
    -derivedDataPath build/DerivedData -localizationPath "$TMP" -exportLanguage de > "$TMP/export.log" 2>&1 \
    || { tail -30 "$TMP/export.log"; exit 1; }
  XCLOC="$TMP/de.xcloc"
fi

python3 - "$XCLOC" <<'PY'
import json, re, sys
xcloc = sys.argv[1]
for name in ("Localizable.xcstrings", "InfoPlist.xcstrings"):
    repo_path = f"WhisperShortcut/{name}"
    exp_path = f"{xcloc}/Source Contents/WhisperShortcut/{name}"
    repo = json.load(open(repo_path))
    exp = json.load(open(exp_path))
    strings = repo["strings"]
    added = stale = 0
    for key, entry in exp["strings"].items():
        if key not in strings:
            strings[key] = entry
            added += 1
        elif strings[key].get("extractionState") == "stale":
            del strings[key]["extractionState"]
    for key, entry in strings.items():
        if key not in exp["strings"] and entry.get("extractionState") not in ("manual", "stale"):
            entry["extractionState"] = "stale"
            stale += 1
        if key.startswith("CFBundle"):  # app name stays a proper name
            entry.setdefault("shouldTranslate", False)
        if not re.search(r"[A-Za-z]", re.sub(r"%(?:\d+\$)?l{0,2}[@dfsuxXcCgGeEi]", "", key)):
            entry.setdefault("shouldTranslate", False)
    repo["strings"] = dict(sorted(strings.items(), key=lambda kv: kv[0].lower()))
    with open(repo_path, "w") as f:
        json.dump(repo, f, indent=2, separators=(",", " : "), ensure_ascii=False)
        f.write("\n")
    print(f"{name}: {len(strings)} keys (+{added} new, {stale} newly stale)")
PY
