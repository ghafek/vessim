#!/usr/bin/env bash
#SBATCH --job-name=vessim_sweep
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=00:30:00
set -euo pipefail

PARAM_FILE="${PARAM_FILE:?PARAM_FILE is required}"
SCENARIO_SCRIPT="${SCENARIO_SCRIPT:?SCENARIO_SCRIPT is required}"
ARRAY_OFFSET="${ARRAY_OFFSET:-0}"

PPVS_RUNS_DIR="${PPVS_RUNS_DIR:-$PWD/runs}"
PPVS_VESSIM_ROOT="${PPVS_VESSIM_ROOT:-$PWD}"

ACTIVATED=0
if [[ -z "${PPVS_PYTHON:-}" && -n "${PPVS_VENV:-}" && -f "${PPVS_VENV}/bin/activate" ]]; then
  # shellcheck disable=SC1090
  source "${PPVS_VENV}/bin/activate"
  ACTIVATED=1
fi

if [[ -n "${PPVS_PYTHON:-}" ]]; then
  PYTHON_BIN="${PPVS_PYTHON}"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
else
  echo "python3 not found and PPVS_PYTHON not set." >&2
  exit 1
fi

IFS=',' read -r scenario_id scenario_file < <(
  "${PYTHON_BIN}" - <<'PY'
import csv
import os
import sys

path = os.environ["PARAM_FILE"]
idx = int(os.environ["SLURM_ARRAY_TASK_ID"])
offset = int(os.environ.get("ARRAY_OFFSET", "0"))
idx = idx + offset

with open(path, newline="") as f:
    rows = list(csv.DictReader(f))

if idx < 0 or idx >= len(rows):
    sys.exit(f"SLURM_ARRAY_TASK_ID={idx} out of range for {path} (rows={len(rows)})")

row = rows[idx]
print(f'{row["scenario_id"]},{row["scenario_file"]}')
PY
)

base_id="${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}"
work="${PPVS_RUNS_DIR}/${base_id}/${SLURM_ARRAY_TASK_ID}_${scenario_id}"
mkdir -p "${work}"

"${PYTHON_BIN}" "${SCENARIO_SCRIPT}" \
  --scenario-id "${scenario_id}" \
  --scenario-file "${scenario_file}" \
  --solar-scale-w "${SOLAR_SCALE_W:-0}" \
  --battery-wh "${BATTERY_WH:-0}" \
  --outdir "${work}"

if [[ "${ACTIVATED}" -eq 1 ]]; then
  deactivate || true
fi
