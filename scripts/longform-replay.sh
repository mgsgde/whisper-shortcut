#!/bin/bash
# Long-form seam replay: for each recording in <dir>/longform, transcribe the whole file once
# and again as Dictate Live pieces, and report how much the live cut costs.
#
#   bash scripts/longform-replay.sh --dir <benchmark-audio dir>
#                                   [--cuts real|splitter] [--model parakeet-ultra]
#                                   [--soft-silence <s>] [--soft-boost <dB>] [--soft-after <s>]
#                                   [--no-soft] [--out <file>]
#
# --cuts real (the default) splits each wav at the rotation times in
# longform/<id>.pieces.log. The wav starts 0.5 s before "LIVE-DICTATE: Starting". A piece the
# log calls "Silent piece skipped" is not transcribed. A missing or unparseable log skips that
# case. --cuts splitter uses LivePieceSplitter. --no-soft is RotationPolicy.liveWithoutSoftCut.
# --soft-silence, --soft-boost and --soft-after override that policy's soft-cut fields.
#
# <dir> holds longform/<id>.wav, the pieces logs and longform-corpus.json (read-only; this repo
# stays free of that audio and of the report). The script copies the wavs, the logs and the
# corpus into build/longform-replay/, because the sandboxed test host can only read inside the
# checkout.
#
# Why a config file and no environment variable: neither a shell export nor the TEST_RUNNER_
# prefix reaches the sandboxed macOS test host (see OfflineWhisperBenchmarkTests). The test
# reads build/longform-replay/config.json and runs only while that file is younger than six
# hours. The trap below removes it on exit, so a later run-tests.sh does not start this.
#
# Vocabulary is the corpus "glossary" array when the file has one, otherwise none. The whole
# file and every live piece get the same list. The report is plain text, printed here, and
# with --out also written to that path. It is not committed in this repo.
#
# Kills and restarts nothing. It does use the CPU / Neural Engine for several minutes.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

MODEL="parakeet-ultra"
DIR=""
OUT_FILE=""
CUTS="real"
NO_SOFT="0"
SOFT_SILENCE=""
SOFT_BOOST=""
SOFT_AFTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --cuts)
      CUTS="$2"
      if [ "$CUTS" != "real" ] && [ "$CUTS" != "splitter" ]; then
        echo "--cuts must be real or splitter" >&2
        exit 2
      fi
      shift 2
      ;;
    --soft-silence) SOFT_SILENCE="$2"; shift 2 ;;
    --soft-boost) SOFT_BOOST="$2"; shift 2 ;;
    --soft-after) SOFT_AFTER="$2"; shift 2 ;;
    --no-soft) NO_SOFT="1"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$DIR" ]; then
  echo "--dir is required (the benchmark-audio directory)" >&2
  exit 2
fi
if [ ! -f "$DIR/longform-corpus.json" ]; then
  echo "no longform-corpus.json in $DIR" >&2
  exit 2
fi

shopt -s nullglob
WAVS=("$DIR"/longform/*.wav)
shopt -u nullglob
if [ ${#WAVS[@]} -eq 0 ]; then
  echo "no wav files in $DIR/longform" >&2
  exit 2
fi

OUT="$ROOT/build/longform-replay"
CONFIG="$OUT/config.json"
LOG="$OUT/xcodebuild.log"
mkdir -p "$OUT"
trap 'rm -f "$CONFIG"' EXIT

rm -f "$OUT"/*.wav "$OUT"/*.pieces.log "$OUT"/*.meta.json
cp "${WAVS[@]}" "$OUT"/
shopt -s nullglob
LOGS=("$DIR"/longform/*.pieces.log)
METAS=("$DIR"/longform/*.meta.json)
shopt -u nullglob
if [ ${#LOGS[@]} -gt 0 ]; then cp "${LOGS[@]}" "$OUT"/; fi
if [ ${#METAS[@]} -gt 0 ]; then cp "${METAS[@]}" "$OUT"/; fi
cp "$DIR/longform-corpus.json" "$OUT/longform-corpus.json"
echo "Replaying ${#WAVS[@]} recordings from $DIR (cuts=$CUTS)"

MODEL="$MODEL" AUDIO_DIR="$OUT" CORPUS="$OUT/longform-corpus.json" CONFIG="$CONFIG" \
CUTS="$CUTS" NO_SOFT="$NO_SOFT" SOFT_SILENCE="$SOFT_SILENCE" SOFT_BOOST="$SOFT_BOOST" \
SOFT_AFTER="$SOFT_AFTER" \
python3 - <<'PY'
import json, os
cfg = {
    "model": os.environ["MODEL"],
    "audioDir": os.environ["AUDIO_DIR"],
    "corpus": os.environ["CORPUS"],
    "cuts": os.environ["CUTS"],
    "noSoft": os.environ["NO_SOFT"] == "1",
}
for key, env in (("softSilence", "SOFT_SILENCE"), ("softBoost", "SOFT_BOOST"), ("softAfter", "SOFT_AFTER")):
    raw = os.environ.get(env, "")
    if raw:
        cfg[key] = float(raw)
json.dump(cfg, open(os.environ["CONFIG"], "w"), indent=2)
PY
if [ $? -ne 0 ]; then
  echo "could not write $CONFIG" >&2
  exit 1
fi

xcodebuild test -scheme WhisperShortcut-AppStore -testPlan WhisperShortcut-AppStore \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData-tests \
  -skipPackagePluginValidation -skipMacroValidation -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 1800 \
  '-only-testing:WhisperShortcutTests/LongformSeamReplayTests/replay()' > "$LOG" 2>&1
STATUS=$?

LOG="$LOG" OUT="$OUT" OUT_FILE="$OUT_FILE" python3 - <<'PY'
import os, sys
log = os.environ["LOG"]
marker = "REPLAY\t"
lines = []
for raw in open(log, errors="replace"):
    pos = raw.find(marker)
    if pos >= 0:
        lines.append(raw[pos + len(marker):].rstrip("\n"))
if not lines:
    print("long-form replay did not run — see log: " + log)
    sys.exit(1)
text = "\n".join(lines) + "\n"
sys.stdout.write(text)
open(os.path.join(os.environ["OUT"], "report.txt"), "w", encoding="utf-8").write(text)
out_file = os.environ.get("OUT_FILE") or ""
if out_file:
    parent = os.path.dirname(out_file)
    if parent:
        os.makedirs(parent, exist_ok=True)
    open(out_file, "w", encoding="utf-8").write(text)
    print("wrote " + out_file, file=sys.stderr)
PY
PYSTATUS=$?
[ $PYSTATUS -ne 0 ] && exit $PYSTATUS
exit $STATUS
