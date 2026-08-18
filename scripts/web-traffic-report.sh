#!/bin/bash

# Website traffic report for whispershortcut.com — from Cloud Run request logs.
#
# Closes instrumentation gap #1 without adding an analytics provider. The marketing site runs as
# a Cloud Run service (`whisper-web`, project `whisper-shortcut`), and Cloud Run already logs every
# HTTP request with URL, referrer and user agent. Reading those logs gives visits, referrers and
# entry pages with:
#   - no third-party service and no new account,
#   - no script tag, no cookies, no consent banner,
#   - nothing that contradicts the product's "no account, no backend" positioning.
#
# The tradeoff versus a real analytics product: no client-side events (no scroll depth, no outbound
# click tracking), IP-based visitor counting (a household NAT counts once, a roaming laptop twice),
# and Cloud Logging's default 30-day retention — so a window longer than 30 days returns nothing.
# For the growth loop's question ("does the site send anyone to the store page?") that is enough.
#
# Usage: web-traffic-report.sh [--days N] [--raw]
#   --days N   window in days (default 14, max useful 30 — see retention above)
#   --raw      also print the unfiltered request count, to show how much was bots
set -uo pipefail
# google-cloud-sdk is not on a launchd job's default PATH, and this script is meant to be callable
# from the growth-review job as well as a terminal.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/google-cloud-sdk/google-cloud-sdk/bin:$HOME/google-cloud-sdk/bin"

DAYS=14
RAW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) shift; DAYS="${1:-14}" ;;
    --raw) RAW=1 ;;
    *) echo "unknown flag: $1"; exit 2 ;;
  esac
  shift
done

PROJECT="${WEB_TRAFFIC_PROJECT:-whisper-shortcut}"
SERVICE="${WEB_TRAFFIC_SERVICE:-whisper-web}"

command -v gcloud >/dev/null 2>&1 || { echo "ERROR: gcloud not installed."; exit 1; }

# Pull more than we need and filter locally: the log filter language cannot express "is this a
# human", and a bad server-side regex silently drops real traffic, which is the failure this
# report exists to prevent.
LOG_FILTER="resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE\" AND httpRequest.requestUrl!=\"\""

echo "=== whispershortcut.com traffic — last ${DAYS}d (Cloud Run logs, project $PROJECT) ==="

gcloud logging read "$LOG_FILTER" \
  --project "$PROJECT" \
  --freshness "${DAYS}d" \
  --limit 20000 \
  --format="csv[no-heading](httpRequest.requestUrl,httpRequest.referer,httpRequest.userAgent,httpRequest.remoteIp,httpRequest.status)" \
  2>/dev/null | RAW_FLAG="$RAW" DAYS="$DAYS" python3 -c '
import sys, csv, os, re
from collections import Counter

rows = list(csv.reader(sys.stdin))
raw_total = len(rows)

# Bots announce themselves in the user agent far more reliably than they hide, and the ones that
# do not announce themselves probe paths no human visits (wp-admin, .env, phpmyadmin). Both are
# filtered; anything ambiguous is KEPT, because undercounting real traffic is the worse error here.
BOT_UA = re.compile(
    r"bot|crawler|spider|scanner|slurp|prefetch proxy|headless|curl|wget|python-requests|"
    r"semrush|ahrefs|mj12|dotbot|petal|bingpreview|facebookexternalhit|feedfetcher|"
    r"monitoring|uptime|pingdom|censys|expanse|paloalto|zgrab",
    re.I,
)
PROBE_PATH = re.compile(
    r"/wp-|/wordpress|/\.env|/\.git|/phpmyadmin|/xmlrpc|/feed/?$|/readme(\.html)?$|"
    r"/administrator|/vendor/|/cgi-bin|/\.well-known/|/autodiscover|"
    # The site is a Next.js static export. It has never served PHP, so every .php request is a
    # scanner looking for a webshell — and those arrive without a bot user agent by design.
    r"\.php$|\.asp x?$|\.cgi$",
    re.I,
)
# Only count things a person would look at — not the assets their browser fetches afterwards.
ASSET = re.compile(r"\.(png|jpg|jpeg|gif|svg|webp|ico|css|js|mjs|map|woff2?|ttf|xml|txt|json)$", re.I)

def path_of(url):
    p = re.sub(r"^https?://[^/]+", "", url)
    return (p.split("?")[0] or "/")

def host_of(url):
    m = re.match(r"^https?://([^/]+)", url or "")
    return m.group(1).lower() if m else ""

pages, refs, ips, statuses = Counter(), Counter(), set(), Counter()
kept = 0
for r in rows:
    if len(r) < 5:
        continue
    url, ref, ua, ip, status = r[0], r[1], r[2], r[3], r[4]
    if BOT_UA.search(ua or ""):
        continue
    path = path_of(url)
    if PROBE_PATH.search(path) or ASSET.search(path):
        continue
    # Count only requests that actually returned a page. A 404 is a probe for something that does
    # not exist, and a 302 is the http->https / www->apex hop that precedes the real request —
    # counting either would inflate visits with the same visit twice or with pure noise.
    if status not in ("200", "304"):
        statuses[status] += 1
        continue
    kept += 1
    pages[path] += 1
    ips.add(ip)
    statuses[status] += 1
    rh = host_of(ref)
    # Self-referrals are internal navigation, not acquisition — they answer a different question.
    if rh and "whispershortcut.com" not in rh:
        refs[rh] += 1

days = os.environ.get("DAYS", "?")
print()
print(f"Page requests (bots filtered): {kept}")
print(f"Unique IPs:                    {len(ips)}   <- the closest thing to \"visitors\"")
if os.environ.get("RAW_FLAG") == "1":
    print(f"Raw requests before filtering: {raw_total}  ({raw_total - kept} dropped as bots/assets/probes)")
if raw_total >= 20000:
    print("WARNING: hit the 20000-row fetch limit — numbers are a floor, not a total.")

print()
print("Top entry paths:")
for p, c in pages.most_common(12):
    print(f"  {c:>5}  {p}")

print()
print("External referrers (acquisition):")
if refs:
    for h, c in refs.most_common(15):
        print(f"  {c:>5}  {h}")
else:
    print("  (none — every visit arrived with no referrer: direct, bookmark, or a stripped referrer)")

print()
print("HTTP status mix (non-200 are counted but excluded from visits):", dict(statuses.most_common(6)))

# Undeclared crawlers walk every route exactly once, which shows up as near-identical counts across
# unrelated pages. Saying so beats silently reporting them as visitors.
subpages = [c for p, c in pages.most_common() if p not in ("/", "")][:6]
if len(subpages) >= 4:
    lo, hi = min(subpages), max(subpages)
    if hi and (hi - lo) / hi < 0.2:
        print()
        print(f"CAVEAT: sub-page counts are nearly uniform ({lo}-{hi}) — that is the signature of")
        print("        undeclared crawlers sweeping every route, so unique IPs OVERSTATE humans.")
        print("        The referrer table above is the trustworthy part of this report.")
'

echo
echo "Note: Cloud Logging keeps ~30 days by default — a longer window returns nothing, not zero traffic."
