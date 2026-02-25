#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

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
  ./experiments/hydra_gen/run_hybrid.sh [--profile path.env] key=value[,value2] ...

Example:
  ./experiments/hydra_gen/run_hybrid.sh \
    battery.capacity_wh=0,100,300 \
    actors.1.signal.value=1000,2000 \
    step_size_s=60 \
    until_s=3600
EOF
  exit 2
fi

PPVS_ROOT="${PPVS_ROOT:-$REPO_ROOT}"
PPVS_EXPERIMENTS_DIR="${PPVS_EXPERIMENTS_DIR:-${PPVS_ROOT}/experiments}"
PPVS_PARAMS_DIR="${PPVS_PARAMS_DIR:-${PPVS_ROOT}/params}"
PPVS_RESULTS_DIR="${PPVS_RESULTS_DIR:-${PPVS_ROOT}/results}"
PPVS_RUNS_DIR="${PPVS_RUNS_DIR:-${PPVS_ROOT}/runs}"
PPVS_VESSIM_ROOT="${PPVS_VESSIM_ROOT:-${PPVS_ROOT}}"
PPVS_VENV="${PPVS_VENV:-$HOME/.venvs/vessim}"
CLUSTER_NAME="${CLUSTER_NAME:-unknown-cluster}"

mkdir -p "${PPVS_PARAMS_DIR}/scenarios" "${PPVS_RESULTS_DIR}" "${PPVS_RUNS_DIR}"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
GEN_DIR="${GEN_DIR:-${PPVS_PARAMS_DIR}/scenarios/generated_${RUN_TAG}}"
PARAM_FILE="${PARAM_FILE:-${PPVS_PARAMS_DIR}/scenario_selector_${RUN_TAG}.csv}"
ARRAY_THROTTLE="${ARRAY_THROTTLE:-auto}"

SCENARIO_SCRIPT="${SCENARIO_SCRIPT:-${PPVS_EXPERIMENTS_DIR}/run_scenario.py}"
SBATCH_SCRIPT="${SBATCH_SCRIPT:-${PPVS_EXPERIMENTS_DIR}/sbatch/vessim_sweep_array.sbatch}"

if [[ -n "${PPVS_PYTHON:-}" ]]; then
  PYTHON_BIN="${PPVS_PYTHON}"
elif [[ -x "${PPVS_VENV}/bin/python" ]]; then
  PYTHON_BIN="${PPVS_VENV}/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
else
  echo "No python runtime found. Install python3 or set PPVS_PYTHON." >&2
  exit 1
fi

ACTIVATED=0
if [[ -z "${PPVS_PYTHON:-}" && -f "${PPVS_VENV}/bin/activate" ]]; then
  # shellcheck disable=SC1090
  source "${PPVS_VENV}/bin/activate"
  ACTIVATED=1
fi

"${PYTHON_BIN}" "${PPVS_EXPERIMENTS_DIR}/hydra_gen/generate_scenarios.py" \
  -m "$@" hydra.sweep.dir="${GEN_DIR}"

"${PYTHON_BIN}" "${PPVS_EXPERIMENTS_DIR}/hydra_gen/build_csv.py" \
  --sweep-dir "${GEN_DIR}" \
  --out "${PARAM_FILE}"

N=$(( $(wc -l < "${PARAM_FILE}") - 1 ))
if [[ "${N}" -le 0 ]]; then
  echo "No scenarios found in ${PARAM_FILE}. Nothing to submit." >&2
  if [[ "${ACTIVATED}" -eq 1 ]]; then
    deactivate || true
  fi
  exit 1
fi

ARRAY_SPEC="0-$((N-1))"
if [[ "${ARRAY_THROTTLE}" =~ ^[1-9][0-9]*$ ]]; then
  ARRAY_SPEC="${ARRAY_SPEC}%${ARRAY_THROTTLE}"
elif [[ "${ARRAY_THROTTLE}" == "auto" || "${ARRAY_THROTTLE}" == "0" || -z "${ARRAY_THROTTLE}" ]]; then
  :
else
  echo "Invalid ARRAY_THROTTLE=${ARRAY_THROTTLE}. Use auto, 0, empty, or positive integer." >&2
  if [[ "${ACTIVATED}" -eq 1 ]]; then
    deactivate || true
  fi
  exit 2
fi

SBATCH_ARGS=(--parsable --array "${ARRAY_SPEC}")

if [[ -n "${PPVS_RESULTS_DIR:-}" ]]; then
  SBATCH_ARGS+=(--output "${PPVS_RESULTS_DIR}/%x_%A_%a.out")
  SBATCH_ARGS+=(--error "${PPVS_RESULTS_DIR}/%x_%A_%a.err")
fi
if [[ -n "${SLURM_PARTITION:-}" ]]; then SBATCH_ARGS+=(--partition "${SLURM_PARTITION}"); fi
if [[ -n "${SLURM_ACCOUNT:-}" ]]; then SBATCH_ARGS+=(--account "${SLURM_ACCOUNT}"); fi
if [[ -n "${SLURM_QOS:-}" ]]; then SBATCH_ARGS+=(--qos "${SLURM_QOS}"); fi
if [[ -n "${SLURM_CONSTRAINT:-}" ]]; then SBATCH_ARGS+=(--constraint "${SLURM_CONSTRAINT}"); fi
if [[ -n "${SLURM_TIME:-}" ]]; then SBATCH_ARGS+=(--time "${SLURM_TIME}"); fi
if [[ -n "${SLURM_MEM:-}" ]]; then SBATCH_ARGS+=(--mem "${SLURM_MEM}"); fi
if [[ -n "${SLURM_CPUS_PER_TASK:-}" ]]; then SBATCH_ARGS+=(--cpus-per-task "${SLURM_CPUS_PER_TASK}"); fi

if [[ -n "${SBATCH_EXTRA_ARGS:-}" ]]; then
  read -r -a EXTRA_ARGS <<< "${SBATCH_EXTRA_ARGS}"
  SBATCH_ARGS+=("${EXTRA_ARGS[@]}")
fi

JOBID=$(
  PARAM_FILE="${PARAM_FILE}" \
  SCENARIO_SCRIPT="${SCENARIO_SCRIPT}" \
  PPVS_RUNS_DIR="${PPVS_RUNS_DIR}" \
  PPVS_VENV="${PPVS_VENV}" \
  PPVS_PYTHON="${PYTHON_BIN}" \
  PPVS_VESSIM_ROOT="${PPVS_VESSIM_ROOT}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  sbatch "${SBATCH_ARGS[@]}" "${SBATCH_SCRIPT}"
)

echo "Generated scenarios in: ${GEN_DIR}"
echo "CSV selector: ${PARAM_FILE}"
echo "Array spec: ${ARRAY_SPEC}"
echo "Submitted array JOBID=${JOBID} with N=${N} tasks"

if [[ "${ACTIVATED}" -eq 1 ]]; then
  deactivate || true
fi
