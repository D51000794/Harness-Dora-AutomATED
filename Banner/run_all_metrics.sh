#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# All four metrics run for each pipeline before moving to the next, so the batch
# pause in run_all_pipelines.sh (BATCH_SIZE / BATCH_PAUSE_SECONDS) covers all four.
METRIC_SCRIPTS=(
  "lead-time-forchange.sh"
  "deployment-frequency.sh"
  "meantimetorestor.sh"
  "change-failure-rate.sh"
)

SCRIPT_PATHS="$(printf '%s\n' "${METRIC_SCRIPTS[@]/#/${SCRIPT_DIR}/}")"
export SCRIPT_PATHS

if ! "${SCRIPT_DIR}/run_all_pipelines.sh"; then
  echo "Completed with failures (listed above)." >&2
  exit 1
fi
echo "All 4 DORA metrics processed successfully for all pipelines."
