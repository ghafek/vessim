#!/usr/bin/env bash
#SBATCH --job-name=vessim_smoke
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=00:10:00
set -euo pipefail

PPVS_EXPERIMENTS_DIR="${PPVS_EXPERIMENTS_DIR:-$PWD/experiments}"
PPVS_RUNS_DIR="${PPVS_RUNS_DIR:-$PWD/runs}"
SMOKE_SCRIPT="${SMOKE_SCRIPT:-${PPVS_EXPERIMENTS_DIR}/vessim_smoke.py}"

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

work="${PPVS_RUNS_DIR}/${SLURM_JOB_ID}"
mkdir -p "${work}"
cd "${work}"

"${PYTHON_BIN}" "${SMOKE_SCRIPT}"

if [[ "${ACTIVATED}" -eq 1 ]]; then
  deactivate || true
fi
