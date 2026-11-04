#!/bin/bash
# Dictation benchmark: scores one speech model plus the app's post-processing on the fixed German
# dictation corpus (benchmarks/dictation/corpus.json), per audio tier (macOS `say` voices, real
# recordings), prints one table and compares it with benchmarks/dictation/baseline.json. It fails
# only on a regression against that baseline.
#
#   bash scripts/dictation-benchmark.sh [--model parakeet-ultra] [--voices "Anna,Eddy (German (Germany))"]
#                                       [--real-audio DIR] [--no-say] [--update-baseline]
#
# Real recordings: --real-audio, else $WHISPERSHORTCUT_BENCH_AUDIO_DIR, else (when it exists) the
# private repo's business/pilot-praxis/benchmark-audio/magnus next to this checkout. Without any of
# them the real tier is skipped. The .wav files are copied into build/dictation-benchmark/audio/real/
# because the sandboxed test host can only read inside the checkout.
#
# Why a config file and no environment variable or test-plan edit: neither a shell export nor the
# TEST_RUNNER_ prefix reaches the sandboxed macOS test host (see OfflineWhisperBenchmarkTests), and
# the checked-in .xctestplan files must not change. The test reads repo files by #filePath, so this
# script writes build/dictation-benchmark/config.json; the test enables itself only while that file
# is younger than six hours, and the trap below removes it again on exit.
#
# Kills and restarts nothing: it does not touch running apps. It does use the CPU / Neural Engine
# for minutes, so do not run it while you need the machine for a live test session.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

MODEL="parakeet-ultra"
VOICES="Anna,Eddy (German (Germany))"
REAL_AUDIO="${WHISPERSHORTCUT_BENCH_AUDIO_DIR:-}"
NO_SAY=0
UPDATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --voices) VOICES="$2"; shift 2 ;;
    --real-audio) REAL_AUDIO="$2"; shift 2 ;;
    --no-say) NO_SAY=1; shift ;;
    --update-baseline) UPDATE=1; shift ;;
    -h|--help) sed -n 2,21p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

OUT="$ROOT/build/dictation-benchmark"
CONFIG="$OUT/config.json"
LOG="$OUT/xcodebuild.log"
mkdir -p "$OUT"
trap 'rm -f "$CONFIG"' EXIT

if [ -z "$REAL_AUDIO" ]; then
  DEFAULT_REAL="$ROOT/../business/pilot-praxis/benchmark-audio/magnus"
  [ -d "$DEFAULT_REAL" ] && REAL_AUDIO="$DEFAULT_REAL"
fi

REAL_DIR=""
if [ -n "$REAL_AUDIO" ] && ls "$REAL_AUDIO"/*.wav >/dev/null 2>&1; then
  REAL_DIR="$OUT/audio/real"
  rm -rf "$REAL_DIR"
  mkdir -p "$REAL_DIR"
  cp "$REAL_AUDIO"/*.wav "$REAL_DIR"/
  echo "Real tier: $(ls "$REAL_DIR" | wc -l | tr -d ' ') recordings from $REAL_AUDIO"
else
  echo "Real tier skipped: no recordings (pass --real-audio DIR or set WHISPERSHORTCUT_BENCH_AUDIO_DIR)."
fi

MODEL="$MODEL" VOICES="$VOICES" REAL_DIR="$REAL_DIR" NO_SAY="$NO_SAY" UPDATE="$UPDATE" CONFIG="$CONFIG" \
python3 - <<'PY'
import json, os
tiers = []
if os.environ["NO_SAY"] != "1":
    for voice in [v.strip() for v in os.environ["VOICES"].split(",") if v.strip()]:
        # "Eddy (German (Germany))" → tier name "say-Eddy"
        tiers.append({"name": "say-" + voice.split(" (")[0], "kind": "say", "voice": voice})
if os.environ["REAL_DIR"]:
    tiers.append({"name": "real", "kind": "wav", "dir": os.environ["REAL_DIR"]})
json.dump({"model": os.environ["MODEL"], "tiers": tiers,
           "updateBaseline": os.environ["UPDATE"] == "1"}, open(os.environ["CONFIG"], "w"), indent=2)
PY
if ! grep -q '"kind"' "$CONFIG"; then
  echo "No tier to run (--no-say and no real recordings)." >&2
  exit 2
fi

xcodebuild test -scheme WhisperShortcut-AppStore -testPlan WhisperShortcut-AppStore \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData-tests \
  -skipPackagePluginValidation -skipMacroValidation -parallel-testing-enabled NO \
  '-only-testing:WhisperShortcutTests/DictationBenchmarkTests/benchmark()' > "$LOG" 2>&1
STATUS=$?

LOG="$LOG" OUT="$OUT" ROOT="$ROOT" UPDATE="$UPDATE" python3 - <<'PY'
import json, os, sys
log, out, root, update = os.environ["LOG"], os.environ["OUT"], os.environ["ROOT"], os.environ["UPDATE"] == "1"
lines = [l.rstrip("\n") for l in open(log, errors="replace") if l.startswith("BENCH-")]
json_lines = [l for l in lines if l.startswith("BENCH-JSON ")]
if not json_lines:
    print("benchmark did not run (0 tests?) — see log: " + log)
    sys.exit(1)
run = json.loads(json_lines[-1][len("BENCH-JSON "):])
open(os.path.join(out, "last-run.tsv"), "w").write("\n".join(lines) + "\n")
json.dump(run, open(os.path.join(out, "last-run.json"), "w"), indent=2, sort_keys=True)

cases = [l.split("\t") for l in lines if l.startswith("BENCH-CASE\t")]
scores = [l.split("\t") for l in lines if l.startswith("BENCH-SCORE\t")]
notes = [l.split("\t") for l in lines if l.startswith("BENCH-NOTE\t")]

print()
print(f"Model {run['model']}   corpus {run['corpusHash']}")
for n in notes:
    print(f"note [{n[1]}] {n[2]}")

groups = {}
for c in cases:
    groups.setdefault((c[1], c[2]), []).append(c)
for (tier, mode), items in groups.items():
    bad = [c for c in items if c[4] != "PASS"]
    if not bad:
        continue
    print(f"\n{tier} {mode}: {len(bad)} of {len(items)} not passing")
    for c in bad:
        if c[4] == "MISSING":
            print(f"  MISSING {c[3]}")
        else:
            print(f"  FAIL {c[3]}\n       got:      {c[5]}\n       expected: {c[6]}")

# One table: rows = metric, columns = "<tier> <mode>".
columns, metrics, cells = [], [], {}
for s in scores:
    _, tier, mode, metric, value, frac, base, delta, status = s
    col = f"{tier} {mode}"
    if col not in columns:
        columns.append(col)
    if metric not in metrics:
        metrics.append(metric)
    text = value
    if delta != "-":
        text += f" ({delta})"
    if status == "REGRESSION":
        text += " !"
    cells[(metric, col)] = text
width0 = max([len(m) for m in metrics] + [6])
widths = [max(len(c), *(len(cells.get((m, c), "")) for m in metrics)) for c in columns]
print()
print("metric".ljust(width0) + "  " + "  ".join(c.ljust(w) for c, w in zip(columns, widths)))
for m in metrics:
    print(m.ljust(width0) + "  " + "  ".join(cells.get((m, c), "").ljust(w) for c, w in zip(columns, widths)))
regressions = [s for s in scores if s[8] == "REGRESSION"]
print(f"\n{len(regressions)} regression(s)." if regressions else "\nNo regressions.")

if update:
    path = os.path.join(root, "benchmarks", "dictation", "baseline.json")
    try:
        baseline = json.load(open(path))
    except (FileNotFoundError, ValueError):
        baseline = {}
    entry = baseline.setdefault(run["model"], {"tiers": {}})
    entry["corpusHash"] = run["corpusHash"]
    entry.setdefault("tiers", {})
    updated = []
    for name, tier in run["tiers"].items():
        missing = tier.get("missing") or []
        if missing:
            preview = ", ".join(missing[:3])
            print(f"Baseline NOT updated for {name}: {len(missing)} recordings missing ({preview}…)")
            continue
        entry["tiers"][name] = tier
        updated.append(name)
    if updated:
        json.dump(baseline, open(path, "w"), indent=2, sort_keys=True, ensure_ascii=False)
        open(path, "a").write("\n")
        print("Baseline updated for tiers: " + ", ".join(updated) + f" ({path})")
PY
PYSTATUS=$?
[ $PYSTATUS -ne 0 ] && exit $PYSTATUS
exit $STATUS
