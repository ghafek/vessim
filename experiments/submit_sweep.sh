#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE_FILE=""
if [[ "${1:-}" == "--profile" ]]; then
  PROFILE_FILE="${2:-}"
  shift 2
fi

if [[ -n "${PROFILE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${PROFILE_FILE}"
fi

if [[ $# -eq 0 ]]; then
  cat <<'EOF' >&2
Usage:
  ./experiments/submit_sweep.sh [--profile experiments/profiles/mycluster.env] [--overrides-file path.txt] key=value[,value2] ...

Example:
  ./experiments/submit_sweep.sh --profile experiments/profiles/mycluster.env \
    battery.capacity_wh=0,100 \
    actors.1.signal.value=1000,2000 \
    step_size_s=60 \
    until_s=3600

  ./experiments/submit_sweep.sh --profile experiments/profiles/mycluster.env \
    --overrides-file my_overrides.txt
EOF
  exit 2
fi

if [[ -n "${PROFILE_FILE}" ]]; then
  "${SCRIPT_DIR}/hydra_gen/run_hybrid.sh" --profile "${PROFILE_FILE}" "$@"
else
  "${SCRIPT_DIR}/hydra_gen/run_hybrid.sh" "$@"
fi
