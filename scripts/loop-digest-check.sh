#!/usr/bin/env bash
# Decides whether a scheduled loop's digest is complete — or the run FAILED. One file, three
# callers (the jobs that write a $DIGEST), same shape as scripts/loop-prompt.sh.
#
#     bash scripts/loop-digest-check.sh <digest> [--min-bytes N] [--section '## X']…
#                                       [--ledger <file> --ledger-match '<grep -E pattern>']
#
# Exit 0 when complete. Otherwise exit 1 and print ONE line: `digest incomplete: <reason>` —
# the job puts that line in its FAILED mail, so it has to say what is missing, not just that
# something is.
#
# Why (loop-ledger L11, 2026-09-19): growth-review-job.sh's pass started a subagent, `claude -p`
# killed it at its 600 s background ceiling, and the job's only check — `[ ! -f "$DIGEST" ]` —
# accepted a 253-byte file reading "(provisional — numbers being gathered…)" and mailed it as a
# success. A file that exists is not a digest that was written.
#
# Checks, in this order (the first failure is the reason):
#   1. the path exists and is a regular file;
#   2. size ≥ --min-bytes (default 2048);
#   3. the first line starts with `VERDICT:`;
#   4. no line contains `provisional` (case-insensitive) — the stub's own word for itself;
#   5. every --section heading is present as a line that STARTS with that text (prefix match,
#      so `## Open questions (would loosen a gate, …)` satisfies `## Open questions`);
#   6. with --ledger: `grep -Eq -- "$MATCH" "$LEDGER"` succeeds — the run's row reached the
#      ledger, not only the digest.
# bash 3.2 (macOS /bin/bash).
set -euo pipefail

usage() {
  echo "usage: loop-digest-check.sh <digest> [--min-bytes N] [--section '## X']… [--ledger <file> --ledger-match <grep -E pattern>]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
DIGEST="$1"; shift
MIN_BYTES=2048
LEDGER=""
LEDGER_MATCH=""
SECTIONS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --min-bytes)    shift; MIN_BYTES="${1:?--min-bytes needs a number}" ;;
    --section)      shift; SECTIONS+=("${1:?--section needs a heading}") ;;
    --ledger)       shift; LEDGER="${1:?--ledger needs a file}" ;;
    --ledger-match) shift; LEDGER_MATCH="${1:?--ledger-match needs a pattern}" ;;
    *) usage ;;
  esac
  shift
done
if [ -n "$LEDGER" ] && [ -z "$LEDGER_MATCH" ]; then
  echo "loop-digest-check.sh: --ledger needs --ledger-match" >&2; exit 2
fi
if [ -z "$LEDGER" ] && [ -n "$LEDGER_MATCH" ]; then
  echo "loop-digest-check.sh: --ledger-match needs --ledger" >&2; exit 2
fi

incomplete() { echo "digest incomplete: $*"; exit 1; }

# 1. exists
[ -e "$DIGEST" ] || incomplete "no file at $DIGEST"
[ -f "$DIGEST" ] || incomplete "$DIGEST is not a regular file"

# 2. size
SIZE="$(wc -c < "$DIGEST" | tr -d ' ')"
[ "$SIZE" -ge "$MIN_BYTES" ] || incomplete "$SIZE bytes, below the $MIN_BYTES-byte floor (a stub, not a digest)"

# 3. verdict line
FIRST="$(head -n 1 "$DIGEST")"
case "$FIRST" in
  VERDICT:*) ;;
  *) incomplete "first line does not start with 'VERDICT:' (got: ${FIRST:0:60})" ;;
esac

# 4. provisional marker
if grep -qi 'provisional' "$DIGEST"; then
  incomplete "contains 'provisional' at line $(grep -ni 'provisional' "$DIGEST" | head -1 | cut -d: -f1) — the pass did not finish rewriting it"
fi

# 5. required sections, prefix match on the line
for s in ${SECTIONS[@]+"${SECTIONS[@]}"}; do
  grep -qF -- "$s" "$DIGEST" || incomplete "missing section '$s'"
  # -F above is only the cheap pre-check; the real test is "a line begins with it".
  if ! awk -v want="$s" 'index($0, want) == 1 { found = 1 } END { exit found ? 0 : 1 }' "$DIGEST"; then
    incomplete "missing section '$s' (mentioned, but no line starts with it)"
  fi
done

# 6. ledger row
if [ -n "$LEDGER" ]; then
  [ -f "$LEDGER" ] || incomplete "ledger $LEDGER does not exist"
  grep -Eq -- "$LEDGER_MATCH" "$LEDGER" || incomplete "no row matching '$LEDGER_MATCH' in $LEDGER — the run wrote a digest but no ledger entry"
fi

exit 0
