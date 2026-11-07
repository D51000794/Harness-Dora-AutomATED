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

ORG_ID="${ORG_ID:-Banner}"
PROJECT_ID="${PROJECT_ID:-Build_Deploy}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

# One time window for the whole run, so all four metric scripts ask the API for
# the same window and it can serve them from one Harness fetch per pipeline.
END_TIME="${END_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
START_TIME="${START_TIME:-$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)}"
export START_TIME END_TIME
PIPELINE_LIST_FILE="${PIPELINE_LIST_FILE:-${SCRIPT_DIR}/banner_ids.txt}"

# Pacing: after every BATCH_SIZE pipelines, wait BATCH_PAUSE_SECONDS so the Harness
# calls (and the GitHub reads behind them) are spread out. BATCH_SIZE=0 turns it off.
BATCH_SIZE="${BATCH_SIZE:-0}"
BATCH_PAUSE_SECONDS="${BATCH_PAUSE_SECONDS:-300}"

# Resume: START_AT=131 skips the first 130 pipelines in the list (use the [n/total]
# number of the first pipeline that did not finish). Default 1 = start at the top.
START_AT="${START_AT:-1}"

# Metric scripts to run for each pipeline, one path per line. run_all_metrics.sh sets
# all four; on its own this runs SCRIPT_PATH (default: change failure rate).
SCRIPT_PATHS="${SCRIPT_PATHS:-${SCRIPT_PATH:-${SCRIPT_DIR}/change-failure-rate.sh}}"
mapfile -t SCRIPTS <<< "$SCRIPT_PATHS"

if [[ ! "$BATCH_SIZE" =~ ^[0-9]+$ || ! "$BATCH_PAUSE_SECONDS" =~ ^[0-9]+$ || ! "$START_AT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: BATCH_SIZE, BATCH_PAUSE_SECONDS and START_AT must be whole numbers (START_AT >= 1)" >&2
  exit 1
fi

if [[ ! -f "$PIPELINE_LIST_FILE" ]]; then
  echo "Error: pipeline list file not found at $PIPELINE_LIST_FILE" >&2
  exit 1
fi

for s in "${SCRIPTS[@]}"; do
  if [[ ! -x "$s" ]]; then
    echo "Error: worker script not found or not executable at $s" >&2
    exit 1
  fi
done

TOTAL="$(grep -cvE '^[[:space:]]*(#|$)' "$PIPELINE_LIST_FILE" || true)"
if (( BATCH_SIZE > 0 && TOTAL > BATCH_SIZE )); then
  PAUSES=$(( (TOTAL - 1) / BATCH_SIZE ))
  echo "Pacing: ${TOTAL} pipelines in batches of ${BATCH_SIZE}, ${BATCH_PAUSE_SECONDS}s pause between batches" \
       "(${PAUSES} pauses, about $(( PAUSES * BATCH_PAUSE_SECONDS / 60 )) min of waiting)."
fi

FAILED=()
DONE=0
RAN=0
if (( START_AT > 1 )); then
  echo "Resuming at pipeline ${START_AT}/${TOTAL} (skipping the first $(( START_AT - 1 )))."
fi
# Each line: <pipeline_id> or <pipeline_id>,<institution>. The institution form is for a
# shared pipeline run by several institutions' input sets (see banner_ids.txt).
while IFS=, read -r PIPELINE_ID INSTITUTION || [[ -n "${PIPELINE_ID:-}" ]]; do
  PIPELINE_ID="$(echo "$PIPELINE_ID" | tr -d '\r' | xargs)"
  INSTITUTION="$(echo "${INSTITUTION:-}" | tr -d '\r' | xargs)"
  [[ -z "$PIPELINE_ID" || "$PIPELINE_ID" == \#* ]] && continue

  DONE=$((DONE + 1))
  if (( DONE < START_AT )); then
    continue
  fi

  if (( BATCH_SIZE > 0 && RAN > 0 && RAN % BATCH_SIZE == 0 )); then
    echo "=== Batch done ($(( DONE - 1 ))/${TOTAL} pipelines). Pausing ${BATCH_PAUSE_SECONDS}s for API rate limits (deliberate, not a hang)..."
    sleep "$BATCH_PAUSE_SECONDS"
  fi
  RAN=$((RAN + 1))

  LABEL="${PIPELINE_ID}${INSTITUTION:+ (institution=${INSTITUTION})}"
  echo ">>> [${DONE}/${TOTAL}] Running metrics for pipeline: ${LABEL}"
  for s in "${SCRIPTS[@]}"; do
    if ! ORG_ID="$ORG_ID" PROJECT_ID="$PROJECT_ID" PIPELINE_ID="$PIPELINE_ID" \
         INSTITUTION="$INSTITUTION" ENVIRONMENT="$ENVIRONMENT" "$s" < /dev/null; then
      echo "!!! Failed for pipeline: ${LABEL} ($(basename "$s"))" >&2
      FAILED+=("${LABEL} ($(basename "$s"))")
    fi
  done
  echo "---"
done < "$PIPELINE_LIST_FILE"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Completed with failures:" >&2
  printf '  %s\n' "${FAILED[@]}" >&2
  exit 1
fi
echo "All pipelines processed successfully."
