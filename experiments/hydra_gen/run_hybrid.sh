#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PROFILE_FILE=""
OVERRIDES_FILE=""
MODE_OVERRIDE="${PPVS_MODE:-}"

usage() {
  cat <<'EOF' >&2
Usage:
  ./experiments/hydra_gen/run_hybrid.sh [--profile path.env] [--overrides-file path.txt] key=value[,value2] ...

Examples:
  ./experiments/hydra_gen/run_hybrid.sh \
    wind_system_capacity=0,3000 \
    solar_system_capacity=0,4000 \
    battery_capacity=0,7500

  ./experiments/hydra_gen/run_hybrid.sh \
    --profile experiments/profiles/mycluster.env \
    --overrides-file my_overrides.txt
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE_FILE="${2:-}"
      shift 2
      ;;
    --overrides-file)
      OVERRIDES_FILE="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ -n "${PROFILE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${PROFILE_FILE}"
fi
if [[ -n "${MODE_OVERRIDE}" ]]; then
  PPVS_MODE="${MODE_OVERRIDE}"
fi

if [[ -n "${OVERRIDES_FILE}" ]]; then
  if [[ ! -f "${OVERRIDES_FILE}" ]]; then
    echo "Overrides file not found: ${OVERRIDES_FILE}" >&2
    exit 1
  fi
  declare -a FILE_OVERRIDES=()
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "${line}" ]] && continue
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -z "${trimmed}" || "${trimmed:0:1}" == "#" ]] && continue
    FILE_OVERRIDES+=("${line}")
  done < "${OVERRIDES_FILE}"
  set -- "${FILE_OVERRIDES[@]}" "$@"
fi

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

PPVS_ROOT="${PPVS_ROOT:-$REPO_ROOT}"
PPVS_EXPERIMENTS_DIR="${PPVS_EXPERIMENTS_DIR:-${PPVS_ROOT}/experiments}"
PPVS_PARAMS_DIR="${PPVS_PARAMS_DIR:-${PPVS_ROOT}/params}"
PPVS_RESULTS_DIR="${PPVS_RESULTS_DIR:-${PPVS_ROOT}/results}"
PPVS_RUNS_DIR="${PPVS_RUNS_DIR:-${PPVS_ROOT}/runs}"
PPVS_VESSIM_ROOT="${PPVS_VESSIM_ROOT:-${PPVS_ROOT}}"
PPVS_VENV="${PPVS_VENV:-$HOME/.venvs/vessim}"
PPVS_DATA_DIR="${PPVS_DATA_DIR:-${PPVS_PARAMS_DIR}/data}"
CLUSTER_NAME="${CLUSTER_NAME:-unknown-cluster}"
PPVS_MODE="${PPVS_MODE:-main}"
PPVS_MAIN_DATA_PROFILE="${PPVS_MAIN_DATA_PROFILE:-generic}"

case "${PPVS_MAIN_DATA_PROFILE}" in
  generic)
    MAIN_POWER_DEFAULT="power_data.csv"
    MAIN_WIND_DEFAULT="wind_data.csv"
    MAIN_SOLAR_DEFAULT="solar_data.csv"
    MAIN_SOLAR_CONFIG_DEFAULT="solar_config.json"
    MAIN_WIND_CONFIG_DEFAULT="wind_config.json"
    MAIN_WIND_TURBINES_DEFAULT="wind_turbines.csv"
    MAIN_CARBON_DEFAULT="carbon_data.csv"
    ;;
  reference)
    MAIN_POWER_DEFAULT="power_data_ce.csv"
    MAIN_WIND_DEFAULT="wind_data_berkeley.csv"
    MAIN_SOLAR_DEFAULT="solar_data_berkeley.csv"
    MAIN_SOLAR_CONFIG_DEFAULT="pvwatts_config.json"
    MAIN_WIND_CONFIG_DEFAULT="windpower_config.json"
    MAIN_WIND_TURBINES_DEFAULT="Wind_Turbines.csv"
    MAIN_CARBON_DEFAULT="US-CAL-CISO_2024_hourly.csv"
    ;;
  *)
    echo "Invalid PPVS_MAIN_DATA_PROFILE=${PPVS_MAIN_DATA_PROFILE}. Use generic or reference." >&2
    exit 2
    ;;
esac

PPVS_MAIN_POWER_DATA_FILE="${PPVS_MAIN_POWER_DATA_FILE:-${MAIN_POWER_DEFAULT}}"
PPVS_MAIN_WIND_DATA_FILE="${PPVS_MAIN_WIND_DATA_FILE:-${MAIN_WIND_DEFAULT}}"
PPVS_MAIN_SOLAR_DATA_FILE="${PPVS_MAIN_SOLAR_DATA_FILE:-${MAIN_SOLAR_DEFAULT}}"
PPVS_MAIN_SOLAR_CONFIG_FILE="${PPVS_MAIN_SOLAR_CONFIG_FILE:-${MAIN_SOLAR_CONFIG_DEFAULT}}"
PPVS_MAIN_WIND_CONFIG_FILE="${PPVS_MAIN_WIND_CONFIG_FILE:-${MAIN_WIND_CONFIG_DEFAULT}}"
PPVS_MAIN_WIND_TURBINES_FILE="${PPVS_MAIN_WIND_TURBINES_FILE:-${MAIN_WIND_TURBINES_DEFAULT}}"
PPVS_MAIN_CARBON_DATA_FILE="${PPVS_MAIN_CARBON_DATA_FILE:-${MAIN_CARBON_DEFAULT}}"

mkdir -p "${PPVS_PARAMS_DIR}/scenarios" "${PPVS_RESULTS_DIR}" "${PPVS_RUNS_DIR}"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
GEN_DIR="${GEN_DIR:-${PPVS_PARAMS_DIR}/scenarios/generated_${RUN_TAG}}"
PARAM_FILE="${PARAM_FILE:-${PPVS_PARAMS_DIR}/scenario_selector_${RUN_TAG}.csv}"
ARRAY_THROTTLE="${ARRAY_THROTTLE:-auto}"
SBATCH_SCRIPT="${SBATCH_SCRIPT:-${PPVS_EXPERIMENTS_DIR}/sbatch/vessim_sweep_array.sbatch}"

HYDRA_CONFIG_NAME="config"
case "${PPVS_MODE}" in
  main)
    SCENARIO_SCRIPT_DEFAULT="${PPVS_EXPERIMENTS_DIR}/run_scenario.py"
    HYDRA_CONFIG_NAME="config"
    ;;
  simple)
    SCENARIO_SCRIPT_DEFAULT="${PPVS_EXPERIMENTS_DIR}/simple/run_scenario_simple.py"
    HYDRA_CONFIG_NAME="config_simple"
    ;;
  *)
    echo "Unsupported PPVS_MODE=${PPVS_MODE}. Use 'main' or 'simple'." >&2
    exit 2
    ;;
esac
SCENARIO_SCRIPT="${SCENARIO_SCRIPT:-${SCENARIO_SCRIPT_DEFAULT}}"

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

HYDRA_ARGS=(--config-name "${HYDRA_CONFIG_NAME}" -m hydra.sweep.dir="${GEN_DIR}")
if [[ "${PPVS_MODE}" == "main" ]]; then
  HYDRA_ARGS+=(
    data_root="${PPVS_DATA_DIR}"
    file_paths.power_data="${PPVS_DATA_DIR}/${PPVS_MAIN_POWER_DATA_FILE}"
    file_paths.wind_data="${PPVS_DATA_DIR}/${PPVS_MAIN_WIND_DATA_FILE}"
    file_paths.solar_data="${PPVS_DATA_DIR}/${PPVS_MAIN_SOLAR_DATA_FILE}"
    file_paths.solar_config="${PPVS_DATA_DIR}/${PPVS_MAIN_SOLAR_CONFIG_FILE}"
    file_paths.wind_config="${PPVS_DATA_DIR}/${PPVS_MAIN_WIND_CONFIG_FILE}"
    file_paths.wind_turbines="${PPVS_DATA_DIR}/${PPVS_MAIN_WIND_TURBINES_FILE}"
    file_paths.carbon_data="${PPVS_DATA_DIR}/${PPVS_MAIN_CARBON_DATA_FILE}"
  )
fi
HYDRA_ARGS+=("$@")

"${PYTHON_BIN}" "${PPVS_EXPERIMENTS_DIR}/hydra_gen/generate_scenarios.py" "${HYDRA_ARGS[@]}"

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

THROTTLE_SUFFIX=""
if [[ "${ARRAY_THROTTLE}" =~ ^[1-9][0-9]*$ ]]; then
  THROTTLE_SUFFIX="%${ARRAY_THROTTLE}"
elif [[ "${ARRAY_THROTTLE}" == "auto" || "${ARRAY_THROTTLE}" == "0" || -z "${ARRAY_THROTTLE}" ]]; then
  :
else
  echo "Invalid ARRAY_THROTTLE=${ARRAY_THROTTLE}. Use auto, 0, empty, or positive integer." >&2
  if [[ "${ACTIVATED}" -eq 1 ]]; then
    deactivate || true
  fi
  exit 2
fi

resolve_max_array_tasks() {
  local raw=""
  if [[ -n "${SLURM_MAX_ARRAY_SIZE:-}" ]]; then
    raw="${SLURM_MAX_ARRAY_SIZE}"
  elif command -v scontrol >/dev/null 2>&1; then
    raw="$(scontrol show config 2>/dev/null | awk -F= '/^MaxArraySize/{print $2}' | xargs || true)"
  fi

  if [[ "${raw}" =~ ^[1-9][0-9]*$ ]]; then
    echo "${raw}"
  fi
}

MAX_ARRAY_TASKS="$(resolve_max_array_tasks || true)"
if [[ -n "${MAX_ARRAY_TASKS}" && "${MAX_ARRAY_TASKS}" -lt 1 ]]; then
  MAX_ARRAY_TASKS=""
fi

SBATCH_ARGS=(--parsable)

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

submit_chunk() {
  local chunk_spec="$1"
  local chunk_offset="$2"
  PARAM_FILE="${PARAM_FILE}" \
  ARRAY_OFFSET="${chunk_offset}" \
  SCENARIO_SCRIPT="${SCENARIO_SCRIPT}" \
  PPVS_RUNS_DIR="${PPVS_RUNS_DIR}" \
  PPVS_VENV="${PPVS_VENV}" \
  PPVS_PYTHON="${PYTHON_BIN}" \
  PPVS_VESSIM_ROOT="${PPVS_VESSIM_ROOT}" \
  CLUSTER_NAME="${CLUSTER_NAME}" \
  sbatch "${SBATCH_ARGS[@]}" --array "${chunk_spec}" "${SBATCH_SCRIPT}"
}

declare -a JOB_IDS=()
declare -a ARRAY_SPECS=()

if [[ -n "${MAX_ARRAY_TASKS}" && "${N}" -gt "${MAX_ARRAY_TASKS}" ]]; then
  start=0
  while [[ "${start}" -lt "${N}" ]]; do
    end=$(( start + MAX_ARRAY_TASKS - 1 ))
    if [[ "${end}" -ge $((N-1)) ]]; then
      end=$((N-1))
    fi
    chunk_size=$(( end - start + 1 ))
    spec="0-$((chunk_size-1))${THROTTLE_SUFFIX}"
    ARRAY_SPECS+=("${spec} (offset=${start})")
    JOB_IDS+=("$(submit_chunk "${spec}" "${start}")")
    start=$(( end + 1 ))
  done
else
  spec="0-$((N-1))${THROTTLE_SUFFIX}"
  ARRAY_SPECS+=("${spec} (offset=0)")
  JOB_IDS+=("$(submit_chunk "${spec}" "0")")
fi

echo "Generated scenarios in: ${GEN_DIR}"
echo "CSV selector: ${PARAM_FILE}"
echo "Mode: ${PPVS_MODE} (config=${HYDRA_CONFIG_NAME}, runner=${SCENARIO_SCRIPT})"
if [[ "${PPVS_MODE}" == "main" ]]; then
  echo "Main data profile: ${PPVS_MAIN_DATA_PROFILE}"
  echo "Main data files: ${PPVS_MAIN_POWER_DATA_FILE}, ${PPVS_MAIN_WIND_DATA_FILE}, ${PPVS_MAIN_SOLAR_DATA_FILE}, ${PPVS_MAIN_SOLAR_CONFIG_FILE}, ${PPVS_MAIN_WIND_CONFIG_FILE}, ${PPVS_MAIN_WIND_TURBINES_FILE}, ${PPVS_MAIN_CARBON_DATA_FILE}"
fi
if [[ -n "${MAX_ARRAY_TASKS}" ]]; then
  echo "Detected MaxArraySize=${MAX_ARRAY_TASKS}"
fi
echo "Array spec(s): ${ARRAY_SPECS[*]}"
if [[ "${#JOB_IDS[@]}" -eq 1 ]]; then
  echo "Submitted array JOBID=${JOB_IDS[0]} with N=${N} tasks"
else
  echo "Submitted ${#JOB_IDS[@]} array jobs for N=${N} tasks: ${JOB_IDS[*]}"
fi

if [[ "${ACTIVATED}" -eq 1 ]]; then
  deactivate || true
fi
