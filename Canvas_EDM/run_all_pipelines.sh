#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

ORG_ID="${ORG_ID:-Canvas_EDM}"
PROJECT_ID="${PROJECT_ID:-Build_Deploy}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
SCRIPT_PATH="${SCRIPT_PATH:-${SCRIPT_DIR}/change-failure-rate.sh}"
PIPELINE_LIST_FILE="${PIPELINE_LIST_FILE:-${SCRIPT_DIR}/canvas_edm.txt}"

if [[ ! -f "$PIPELINE_LIST_FILE" ]]; then
  echo "Error: pipeline list file not found at $PIPELINE_LIST_FILE" >&2
  exit 1
fi

if [[ ! -x "$SCRIPT_PATH" ]]; then
  echo "Error: worker script not found or not executable at $SCRIPT_PATH" >&2
  exit 1
fi

FAILED=()
# Each line: <pipeline_id> or <pipeline_id>,<institution>. The institution form is for a
# shared pipeline run by several institutions' input sets (see banner_ids.txt).
while IFS=, read -r PIPELINE_ID INSTITUTION || [[ -n "${PIPELINE_ID:-}" ]]; do
  PIPELINE_ID="$(echo "$PIPELINE_ID" | tr -d '\r' | xargs)"
  INSTITUTION="$(echo "${INSTITUTION:-}" | tr -d '\r' | xargs)"
  [[ -z "$PIPELINE_ID" || "$PIPELINE_ID" == \#* ]] && continue

  LABEL="${PIPELINE_ID}${INSTITUTION:+ (institution=${INSTITUTION})}"
  echo ">>> Running metrics for pipeline: ${LABEL}"
  if ! ORG_ID="$ORG_ID" PROJECT_ID="$PROJECT_ID" PIPELINE_ID="$PIPELINE_ID" \
       INSTITUTION="$INSTITUTION" ENVIRONMENT="$ENVIRONMENT" "$SCRIPT_PATH" < /dev/null; then
    echo "!!! Failed for pipeline: ${LABEL}" >&2
    FAILED+=("$LABEL")
  fi
  echo "---"
done < "$PIPELINE_LIST_FILE"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Completed with failures: ${FAILED[*]}" >&2
  exit 1
fi
echo "All pipelines processed successfully."