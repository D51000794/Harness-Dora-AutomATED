#!/bin/bash
set -euo pipefail

command -v curl >/dev/null 2>&1 || { echo >&2 "curl is required but not installed."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo >&2 "jq is required but not installed."; exit 1; }
command -v gcloud >/dev/null 2>&1 || { echo >&2 "gcloud CLI is required but not installed."; exit 1; }

METRICS_NAME="${METRICS_NAME:-LeadTimeForChanges}"
APP_NAME="${APP_NAME:-Harness}"
ORG_ID="${ORG_ID:-Faculty_impact_Hub}"
PROJECT_ID="${PROJECT_ID:-Build_Deploy}"
PIPELINE_ID="${PIPELINE_ID:-wuimpacthubdataflowreleaseprod}"
INSTITUTION="${INSTITUTION:-}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

END_TIME="${END_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
START_TIME="${START_TIME:-$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) ORG_ID="$2"; shift 2 ;;
    --project) PROJECT_ID="$2"; shift 2 ;;
    --pipeline) PIPELINE_ID="$2"; shift 2 ;;
    --institution) INSTITUTION="$2"; shift 2 ;;
    --start) START_TIME="$2"; shift 2 ;;
    --end) END_TIME="$2"; shift 2 ;;
    --metrics-name) METRICS_NAME="$2"; shift 2 ;;
    --env) ENVIRONMENT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

DEV_SA_KEY="${DEV_SA_KEY:-/home/peservices/gcp/keys/atge-dev-sa.json}"
PROD_SA_KEY="${PROD_SA_KEY:-/home/peservices/gcp/keys/atge-prod-sa.json}"

case "$ENVIRONMENT" in
  dev)  GCS_BUCKET="gs://gcp-atge-inbound-extracts-dev/harness/Faculty_Impact_Hub/lead_time_for_change/";  SA_KEY="$DEV_SA_KEY" ;;
  prod) GCS_BUCKET="gs://gcp-atge-inbound-extracts-prod/harness/Faculty_Impact_Hub/lead_time_for_change/"; SA_KEY="$PROD_SA_KEY" ;;
  *) echo "Error: ENVIRONMENT must be 'dev' or 'prod', got '$ENVIRONMENT'" >&2; exit 1 ;;
esac

PREVIOUS_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
echo "Activating ${ENVIRONMENT} service account for GCS upload..."
if [[ ! -f "$SA_KEY" ]]; then
  echo "Error: service account key not found at $SA_KEY" >&2
  exit 1
fi
gcloud auth activate-service-account --key-file="$SA_KEY"

API_URL="http://10.100.6.201:8000/api/harness/lead-time"
OUTPUT_FILE="$(mktemp /tmp/api_response.XXXXXX.json)"
FINAL_FILE="${PIPELINE_ID}${INSTITUTION:+_${INSTITUTION}}_${METRICS_NAME}_$(date -u +%Y%m%d%H%M%S).ndjson"

echo "Calling API for ${ORG_ID}/${PROJECT_ID}/${PIPELINE_ID}${INSTITUTION:+ (institution=${INSTITUTION})} (${START_TIME} -> ${END_TIME})..."
if ! curl -s -f -G "${API_URL}" \
  --data-urlencode "project_id=${PROJECT_ID}" \
  --data-urlencode "pipeline_id=${PIPELINE_ID}" \
  --data-urlencode "org_id=${ORG_ID}" \
  --data-urlencode "start_ts=${START_TIME}" \
  --data-urlencode "end_ts=${END_TIME}" \
  ${INSTITUTION:+--data-urlencode "institution=${INSTITUTION}"} \
  -H "accept: application/json" \
  -o "$OUTPUT_FILE"; then
  echo "Error: API call failed for pipeline ${PIPELINE_ID}." >&2
  rm -f "$OUTPUT_FILE"; exit 1
fi

if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  echo "Error: API response is not valid JSON." >&2
  cat "$OUTPUT_FILE" >&2
  rm -f "$OUTPUT_FILE"; exit 1
fi

# UNVERIFIED: field names below assume the same response shape as
# change-failure-rate. Confirm against real output before trusting this data.
jq -c '{
  avg_lead_time_seconds:    .lead_time.average_lead_time_seconds,
  avg_lead_time_hours:      .lead_time.average_lead_time_hours,
  avg_lead_time_days:       .lead_time.average_lead_time_days,
  min_lead_time_hours:      .lead_time.min_lead_time_hours,
  max_lead_time_hours:      .lead_time.max_lead_time_hours,
  total_measured:           .lead_time.total_measured,
  data_quality:             .lead_time.data_quality,
  git_timestamp_count:      .lead_time.data_quality_detail.git_timestamp_count,
  fallback_timestamp_count: .lead_time.data_quality_detail.fallback_timestamp_count,
  warning:                  .lead_time.warning,
  total_executions:         .total_executions,
  pipeline_id:              .pipeline_id,
  pipeline_name:            .pipeline_name,
  institution:              (.institution // ((.tags // {}) | to_entries | map(select(.key | ascii_downcase == "institution")) | .[0].value)),
  tags:                     ((.tags // {}) | tojson),
  time_range_start:         .time_range.start,
  time_range_end:           .time_range.end,
  account_id:               .metadata.account_id,
  org_id:                   .metadata.org_id,
  project_id:               .metadata.project_id,
  start_time_iso:           .metadata.start_time_iso,
  end_time_iso:             .metadata.end_time_iso,
  start_time_ms:            .metadata.start_time_ms,
  end_time_ms:              .metadata.end_time_ms,
  total_pages:              .metadata.total_pages,
  total_items:              .metadata.total_items,
  page_size:                .metadata.page_size
}' "$OUTPUT_FILE" > "$FINAL_FILE"

if [[ ! -s "$FINAL_FILE" ]]; then
  echo "Error: NDJSON output is empty for pipeline ${PIPELINE_ID}." >&2
  rm -f "$OUTPUT_FILE" "$FINAL_FILE"; exit 1
fi
echo "NDJSON saved to $FINAL_FILE"
cat "$FINAL_FILE"

echo "Uploading $FINAL_FILE to ${GCS_BUCKET} (${ENVIRONMENT})..."
if ! gcloud storage cp "$FINAL_FILE" "$GCS_BUCKET"; then
  echo "Error: Failed to upload $FINAL_FILE to $GCS_BUCKET" >&2
  rm -f "$OUTPUT_FILE" "$FINAL_FILE"; exit 1
fi
echo "Successfully uploaded to $GCS_BUCKET"

if [[ -n "$PREVIOUS_ACCOUNT" ]]; then
  gcloud config set account "$PREVIOUS_ACCOUNT" >/dev/null 2>&1 || true
fi

rm -f "$OUTPUT_FILE" "$FINAL_FILE"
echo "Done."