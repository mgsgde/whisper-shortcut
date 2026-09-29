#!/bin/bash
# Deploys the opt-in usage statistics endpoint and its storage. Idempotent — safe to re-run.
#
#   1. Cloud Run service `whisper-telemetry` (this directory).
#   2. Log exclusion: the Cloud Run request log for this service (which records client IPs) is
#      never stored in the _Default bucket.
#   3. BigQuery dataset `telemetry` (tables expire after 400 days) and a log sink that moves the
#      service's `jsonPayload.telemetry` lines into it.
#   4. Domain mapping t.whispershortcut.com → the service. DNS needs a CNAME
#      `t` → `ghs.googlehosted.com.` at the registrar (printed at the end).
set -euo pipefail

PROJECT_ID="${GCP_PROJECT:-whisper-shortcut}"
REGION="${GCP_REGION:-europe-west1}"
SERVICE_NAME="whisper-telemetry"
DATASET="telemetry"
SINK_NAME="telemetry-to-bigquery"
EXCLUSION_NAME="telemetry-request-logs"
DOMAIN="t.whispershortcut.com"
TABLE_EXPIRATION_SECONDS=$((400 * 24 * 3600))
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step() { printf '\033[0;34m📋 %s\033[0m\n' "$1"; }
ok() { printf '\033[0;32m✅ %s\033[0m\n' "$1"; }

cd "$SCRIPT_DIR"

step "Running tests"
npm test --silent
ok "Tests passed"

step "Enabling APIs"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  logging.googleapis.com bigquery.googleapis.com --project="$PROJECT_ID" --quiet

step "Deploying $SERVICE_NAME to Cloud Run ($REGION)"
gcloud run deploy "$SERVICE_NAME" \
  --source . \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --platform=managed \
  --min-instances=0 \
  --max-instances=1 \
  --memory=128Mi \
  --cpu=1 \
  --concurrency=80 \
  --allow-unauthenticated \
  --quiet
ok "Service deployed"

step "Excluding the service's request log (client IPs) from the _Default bucket"
EXCLUSION_FILTER="resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE_NAME\" AND log_id(\"run.googleapis.com/requests\")"
if gcloud logging sinks describe _Default --project="$PROJECT_ID" --format='value(exclusions[].name)' | tr ';' '\n' | grep -qx "$EXCLUSION_NAME"; then
  ok "Exclusion already present"
else
  gcloud logging sinks update _Default --project="$PROJECT_ID" \
    --add-exclusion="name=$EXCLUSION_NAME,filter=$EXCLUSION_FILTER"
  ok "Exclusion added"
fi

step "BigQuery dataset $DATASET"
if bq --project_id="$PROJECT_ID" show --dataset "$PROJECT_ID:$DATASET" >/dev/null 2>&1; then
  ok "Dataset exists"
else
  bq --project_id="$PROJECT_ID" mk --dataset --location=EU \
    --default_table_expiration="$TABLE_EXPIRATION_SECONDS" \
    --description="WhisperShortcut opt-in anonymous usage statistics" "$PROJECT_ID:$DATASET"
  ok "Dataset created"
fi

step "Log sink $SINK_NAME → BigQuery"
SINK_FILTER="resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE_NAME\" AND jsonPayload.telemetry:*"
SINK_DEST="bigquery.googleapis.com/projects/$PROJECT_ID/datasets/$DATASET"
if gcloud logging sinks describe "$SINK_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud logging sinks update "$SINK_NAME" "$SINK_DEST" --project="$PROJECT_ID" \
    --log-filter="$SINK_FILTER" --use-partitioned-tables --quiet
else
  gcloud logging sinks create "$SINK_NAME" "$SINK_DEST" --project="$PROJECT_ID" \
    --log-filter="$SINK_FILTER" --use-partitioned-tables --quiet
fi
WRITER=$(gcloud logging sinks describe "$SINK_NAME" --project="$PROJECT_ID" --format='value(writerIdentity)')
TMP_JSON="$(mktemp)"
# Dataset-level grant for the sink's writer identity (bq has no idempotent add; re-adding is harmless).
bq --project_id="$PROJECT_ID" show --format=prettyjson "$PROJECT_ID:$DATASET" >"$TMP_JSON"
if ! grep -q "${WRITER#serviceAccount:}" "$TMP_JSON"; then
  python3 - "$TMP_JSON" "${WRITER#serviceAccount:}" <<'PY'
import json, sys
path, email = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d.setdefault("access", []).append({"role": "WRITER", "userByEmail": email})
json.dump({"access": d["access"]}, open(path, "w"))
PY
  bq --project_id="$PROJECT_ID" update --source "$TMP_JSON" "$PROJECT_ID:$DATASET"
fi
ok "Sink ready ($WRITER)"

step "Domain mapping $DOMAIN"
if gcloud beta run domain-mappings describe --domain="$DOMAIN" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  ok "Mapping exists"
else
  gcloud beta run domain-mappings create --service="$SERVICE_NAME" --domain="$DOMAIN" \
    --region="$REGION" --project="$PROJECT_ID" --quiet || echo "⚠️  Domain mapping failed — create it manually."
fi

URL=$(gcloud run services describe "$SERVICE_NAME" --region="$REGION" --project="$PROJECT_ID" --format='value(status.url)')
ok "Done. Service URL: $URL"
echo "DNS: $DOMAIN must be a CNAME to ghs.googlehosted.com. — the app posts to https://$DOMAIN/v1/ping"
