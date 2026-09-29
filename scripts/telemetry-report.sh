#!/bin/bash
# Reads the opt-in anonymous usage statistics from BigQuery (plans/active/opt-in-telemetry.md).
#
#   bash scripts/telemetry-report.sh            # last 30 days
#   bash scripts/telemetry-report.sh -d 90      # last 90 days
#
# Data: dataset `telemetry` in GCP project whisper-shortcut, fed by the log sink that
# server/telemetry/deploy.sh sets up. Test pings carry app "0.0" and are excluded.
#
# Reading rules (self-selected sample — only users who opted in):
# - Trust ratios inside the sample (which onboarding step loses people, which error class dominates)
#   more than absolute numbers.
# - Cohort size = `telemetry.enabled` milestones: every opted-in install sends exactly one.
# - A daily ping exists only for a day with activity, and is sent the next time the app runs, so
#   the most recent day or two are always incomplete.
set -euo pipefail

DAYS=30
while getopts "d:" opt; do
  case "$opt" in
    d) DAYS="$OPTARG" ;;
    *) echo "usage: $0 [-d days]" >&2; exit 2 ;;
  esac
done
[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "days must be a number" >&2; exit 2; }

PROJECT="${GCP_PROJECT:-whisper-shortcut}"
TABLE="\`$PROJECT.telemetry.run_googleapis_com_stdout\`"
# INCLUDE_TEST=1 keeps the app "0.0" test pings — for checking the queries themselves.
TEST_FILTER="AND JSON_VALUE(j, '$.app') != '0.0'"
[[ "${INCLUDE_TEST:-0}" == "1" ]] && TEST_FILTER=""

# The log sink adds a column only once some row carried that field, so a query naming a field that
# has not appeared yet fails. Everything reads through JSON functions instead. The sink also
# lowercases field names (cohortWeek → cohortweek).
BASE="SELECT * FROM (
  SELECT timestamp, j,
    JSON_VALUE(j, '$.kind') AS kind,
    JSON_VALUE(j, '$.build') AS build,
    JSON_VALUE(j, '$.milestone') AS milestone,
    JSON_VALUE(j, '$.errorclass') AS errorclass,
    JSON_VALUE(j, '$.cohortweek') AS week,
    CAST(CAST(JSON_VALUE(j, '$.dayindex') AS FLOAT64) AS INT64) AS day
  FROM (SELECT timestamp, TO_JSON_STRING(jsonPayload.telemetry) AS j FROM $TABLE
        WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL $DAYS DAY))
) WHERE TRUE $TEST_FILTER"
# Unnests one of the stored row arrays (counts / errors / models).
rows() { echo "UNNEST(JSON_QUERY_ARRAY(j, '\$.$1'))"; }
num() { echo "CAST(CAST(JSON_VALUE($1, '\$.n') AS FLOAT64) AS INT64)"; }

q() {
  echo ""
  echo "== $1"
  bq query --project_id="$PROJECT" --use_legacy_sql=false --format=pretty --max_rows=200 --quiet "$2"
}

echo "WhisperShortcut usage statistics — last $DAYS days (opted-in installs only)"

q "Pings by kind and build" "
WITH p AS ($BASE)
SELECT kind, build, COUNT(*) AS pings, MIN(DATE(timestamp)) AS first, MAX(DATE(timestamp)) AS last
FROM p GROUP BY 1, 2 ORDER BY 1, 2"

q "Onboarding and activation funnel (installs that reached each milestone, new cohorts only)" "
WITH p AS ($BASE)
SELECT milestone, COUNT(*) AS installs
FROM p WHERE kind = 'milestone' AND week != 'pre-telemetry'
GROUP BY milestone
ORDER BY CASE milestone
  WHEN 'telemetry.enabled' THEN 0 WHEN 'onboarding.step.intro' THEN 1 WHEN 'onboarding.step.privacy' THEN 2
  WHEN 'onboarding.step.apiKeys' THEN 3 WHEN 'onboarding.step.permissions' THEN 4
  WHEN 'onboarding.step.tryIt' THEN 5 WHEN 'onboarding.step.autoPaste' THEN 6
  WHEN 'onboarding.step.smartImprovement' THEN 7 WHEN 'onboarding.step.done' THEN 8
  WHEN 'onboarding.completed' THEN 9 WHEN 'activation.firstDictationFailed' THEN 10
  WHEN 'activation.firstDictation' THEN 11 WHEN 'activation.firstPrompt' THEN 12
  WHEN 'activation.firstChat' THEN 13 ELSE 99 END"

q "First dictation failures by error class" "
WITH p AS ($BASE)
SELECT errorclass, COUNT(*) AS installs
FROM p WHERE milestone = 'activation.firstDictationFailed'
GROUP BY 1 ORDER BY 2 DESC"

q "Retention by cohort week (share of opted-in installs active on day N)" "
WITH p AS ($BASE),
cohort AS (SELECT week, COUNT(*) AS size FROM p WHERE milestone = 'telemetry.enabled' GROUP BY 1),
daily AS (SELECT week, day FROM p WHERE kind = 'daily')
SELECT c.week, c.size,
  ROUND(100 * COUNTIF(d.day = 0) / c.size) AS d0_pct,
  ROUND(100 * COUNTIF(d.day = 1) / c.size) AS d1_pct,
  ROUND(100 * COUNTIF(d.day BETWEEN 7 AND 13) / (7 * c.size)) AS wk2_avg_daily_pct,
  ROUND(100 * COUNTIF(d.day BETWEEN 28 AND 34) / (7 * c.size)) AS wk5_avg_daily_pct
FROM cohort c LEFT JOIN daily d USING (week)
GROUP BY 1, 2 ORDER BY 1"

q "Feature usage (sum of counts; active_days = daily pings that contain the key)" "
WITH p AS ($BASE)
SELECT JSON_VALUE(c, '\$.key') AS key, SUM($(num c)) AS total, COUNT(*) AS active_days
FROM p, $(rows counts) AS c WHERE kind = 'daily'
GROUP BY 1 ORDER BY 2 DESC"

q "Failures by area and error class" "
WITH p AS ($BASE)
SELECT JSON_VALUE(e, '\$.key') AS key, SUM($(num e)) AS total, COUNT(*) AS days
FROM p, $(rows errors) AS e WHERE kind = 'daily'
GROUP BY 1 ORDER BY 2 DESC"

q "Models" "
WITH p AS ($BASE)
SELECT JSON_VALUE(m, '\$.kind') AS kind, JSON_VALUE(m, '\$.id') AS model, SUM($(num m)) AS uses
FROM p, $(rows models) AS m WHERE kind = 'daily'
GROUP BY 1, 2 ORDER BY 1, 3 DESC"

q "Configured providers (daily pings that had a key for each)" "
WITH p AS ($BASE)
SELECT provider, COUNT(*) AS daily_pings
FROM p, UNNEST(JSON_VALUE_ARRAY(j, '\$.setup.providers')) AS provider WHERE kind = 'daily'
GROUP BY 1 ORDER BY 2 DESC"
