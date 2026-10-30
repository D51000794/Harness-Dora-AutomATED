#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

METRIC_SCRIPTS=(
  "lead-time-forchange.sh"
  "deployment-frequency.sh"
  "meantimetorestor.sh"
  "change-failure-rate.sh"
)

FAILED_METRICS=()
for metric_script in "${METRIC_SCRIPTS[@]}"; do
  echo "=========================================="
  echo "=== Running metric: $metric_script ==="
  echo "=========================================="
  if ! SCRIPT_PATH="${SCRIPT_DIR}/${metric_script}" "${SCRIPT_DIR}/run_all_pipelines.sh"; then
    echo "!!! Metric run failed: $metric_script" >&2
    FAILED_METRICS+=("$metric_script")
  fi
  echo
done

if [[ ${#FAILED_METRICS[@]} -gt 0 ]]; then
  echo "Completed with failing metrics: ${FAILED_METRICS[*]}" >&2
  exit 1
fi
echo "All 4 DORA metrics processed successfully for all pipelines."
