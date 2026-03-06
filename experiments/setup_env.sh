#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROFILE_FILE=""
if [[ "${1:-}" == "--profile" ]]; then
  PROFILE_FILE="${2:-}"
  shift 2
fi

if [[ -n "${PROFILE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${PROFILE_FILE}"
fi

PPVS_ROOT="${PPVS_ROOT:-$REPO_ROOT}"
PPVS_EXPERIMENTS_DIR="${PPVS_EXPERIMENTS_DIR:-${PPVS_ROOT}/experiments}"
PPVS_PARAMS_DIR="${PPVS_PARAMS_DIR:-${PPVS_ROOT}/params}"
PPVS_RESULTS_DIR="${PPVS_RESULTS_DIR:-${PPVS_ROOT}/results}"
PPVS_RUNS_DIR="${PPVS_RUNS_DIR:-${PPVS_ROOT}/runs}"
PPVS_DATA_DIR="${PPVS_DATA_DIR:-${PPVS_PARAMS_DIR}/data}"
PPVS_VENV="${PPVS_VENV:-$HOME/.venvs/vessim}"
PPVS_VESSIM_ROOT="${PPVS_VESSIM_ROOT:-${PPVS_ROOT}}"
CLUSTER_NAME="${CLUSTER_NAME:-unknown-cluster}"
OBS_ENABLE="${OBS_ENABLE:-0}"
OBS_ELASTIC_URL="${OBS_ELASTIC_URL:-http://localhost:9200}"
PPVS_MODE="${PPVS_MODE:-main}"
PPVS_REQUIRE_OPTUNA="${PPVS_REQUIRE_OPTUNA:-0}"
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
export PPVS_REQUIRE_OPTUNA
export PPVS_MODE
export PPVS_MAIN_DATA_PROFILE

if [[ "${PPVS_ROOT}" == "/path/to/ppvs" ]]; then
  echo "PPVS_ROOT is still the template placeholder (/path/to/ppvs)." >&2
  echo "Copy and edit experiments/profiles/cluster.template.env first." >&2
  exit 2
fi

mkdir -p "${PPVS_PARAMS_DIR}/scenarios" "${PPVS_RESULTS_DIR}" "${PPVS_RUNS_DIR}"

check_rw_dir() {
  local dir="$1"
  local probe
  probe="${dir}/.ppvs_rw_test_$$"
  touch "${probe}" 2>/dev/null || {
    echo "Directory is not writable: ${dir}" >&2
    return 1
  }
  rm -f "${probe}"
}

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

echo "== PPVS environment =="
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "PPVS_ROOT=${PPVS_ROOT}"
echo "PPVS_EXPERIMENTS_DIR=${PPVS_EXPERIMENTS_DIR}"
echo "PPVS_PARAMS_DIR=${PPVS_PARAMS_DIR}"
echo "PPVS_RESULTS_DIR=${PPVS_RESULTS_DIR}"
echo "PPVS_RUNS_DIR=${PPVS_RUNS_DIR}"
echo "PPVS_DATA_DIR=${PPVS_DATA_DIR}"
echo "PPVS_VESSIM_ROOT=${PPVS_VESSIM_ROOT}"
echo "PPVS_VENV=${PPVS_VENV}"
echo "PYTHON_BIN=${PYTHON_BIN}"
echo "PPVS_MODE=${PPVS_MODE}"
echo "PPVS_MAIN_DATA_PROFILE=${PPVS_MAIN_DATA_PROFILE}"
echo "OBS_ENABLE=${OBS_ENABLE}"
echo "OBS_ELASTIC_URL=${OBS_ELASTIC_URL}"
echo "PPVS_REQUIRE_OPTUNA=${PPVS_REQUIRE_OPTUNA}"

for d in \
  "${PPVS_ROOT}" \
  "${PPVS_EXPERIMENTS_DIR}" \
  "${PPVS_PARAMS_DIR}" \
  "${PPVS_RESULTS_DIR}" \
  "${PPVS_RUNS_DIR}"
do
  [[ -d "${d}" ]] || { echo "Missing required directory: ${d}" >&2; exit 1; }
done

case "${PPVS_MODE}" in
  main|simple) ;;
  *)
    echo "Invalid PPVS_MODE=${PPVS_MODE}. Use main or simple." >&2
    exit 2
    ;;
esac

check_rw_dir "${PPVS_PARAMS_DIR}"
check_rw_dir "${PPVS_RESULTS_DIR}"
check_rw_dir "${PPVS_RUNS_DIR}"

[[ -d "${PPVS_VESSIM_ROOT}/vessim" ]] || {
  echo "Missing package directory: ${PPVS_VESSIM_ROOT}/vessim" >&2
  exit 1
}

if [[ ! -f "${PPVS_VESSIM_ROOT}/pyproject.toml" && ! -f "${PPVS_VESSIM_ROOT}/setup.py" ]]; then
  if [[ -f "${PPVS_VESSIM_ROOT}/vessim/pyproject.toml" || -f "${PPVS_VESSIM_ROOT}/vessim/setup.py" ]]; then
    cat >&2 <<EOF
Warning: PPVS_VESSIM_ROOT points to a parent directory (${PPVS_VESSIM_ROOT}).
Editable install expects PPVS_VESSIM_ROOT=${PPVS_VESSIM_ROOT}/vessim.
EOF
  else
    cat >&2 <<EOF
Warning: PPVS_VESSIM_ROOT=${PPVS_VESSIM_ROOT} does not contain pyproject.toml/setup.py.
Editable install may fail in install_python_env.sh.
EOF
  fi
fi

for f in \
  "${PPVS_EXPERIMENTS_DIR}/hydra_gen/generate_scenarios.py" \
  "${PPVS_EXPERIMENTS_DIR}/hydra_gen/build_csv.py" \
  "${PPVS_EXPERIMENTS_DIR}/hydra_gen/run_hybrid.sh" \
  "${PPVS_EXPERIMENTS_DIR}/sbatch/vessim_sweep_array.sbatch" \
  "${PPVS_EXPERIMENTS_DIR}/sbatch/vessim_smoke.sbatch" \
  "${PPVS_EXPERIMENTS_DIR}/sbatch/postprocess_meta.sbatch" \
  "${PPVS_EXPERIMENTS_DIR}/vessim_smoke.py" \
  "${PPVS_EXPERIMENTS_DIR}/run_scenario.py" \
  "${PPVS_EXPERIMENTS_DIR}/simple/run_scenario_simple.py"
do
  [[ -f "${f}" ]] || { echo "Missing required file: ${f}" >&2; exit 1; }
done

"${PYTHON_BIN}" - <<'PY'
import importlib.util
import importlib
import sys
mods = ["hydra", "yaml", "pandas", "vessim"]
import os
if os.environ.get("PPVS_MODE", "main") == "main":
    mods.append("PySAM")
if os.environ.get("PPVS_REQUIRE_OPTUNA", "0") == "1":
    mods.append("optuna")
missing = [m for m in mods if importlib.util.find_spec(m) is None]
if missing:
    raise SystemExit(f"Missing python modules: {missing}")
print("python_deps_ok")
print(f"python_executable={sys.executable}")
for m in mods:
    mod = importlib.import_module(m)
    ver = getattr(mod, "__version__", "unknown")
    print(f"{m}_version={ver}")
PY

if [[ "${PPVS_MODE}" == "main" ]]; then
  [[ -d "${PPVS_DATA_DIR}" ]] || {
    echo "Missing PPVS_DATA_DIR for main mode: ${PPVS_DATA_DIR}" >&2
    exit 1
  }
  echo "main_power_file=${PPVS_MAIN_POWER_DATA_FILE}"
  echo "main_wind_file=${PPVS_MAIN_WIND_DATA_FILE}"
  echo "main_solar_file=${PPVS_MAIN_SOLAR_DATA_FILE}"
  echo "main_solar_config_file=${PPVS_MAIN_SOLAR_CONFIG_FILE}"
  echo "main_wind_config_file=${PPVS_MAIN_WIND_CONFIG_FILE}"
  echo "main_wind_turbines_file=${PPVS_MAIN_WIND_TURBINES_FILE}"
  echo "main_carbon_file=${PPVS_MAIN_CARBON_DATA_FILE}"
  for f in \
    "${PPVS_DATA_DIR}/${PPVS_MAIN_POWER_DATA_FILE}" \
    "${PPVS_DATA_DIR}/${PPVS_MAIN_WIND_DATA_FILE}" \
    "${PPVS_DATA_DIR}/${PPVS_MAIN_SOLAR_DATA_FILE}" \
    "${PPVS_DATA_DIR}/${PPVS_MAIN_SOLAR_CONFIG_FILE}" \
    "${PPVS_DATA_DIR}/${PPVS_MAIN_WIND_CONFIG_FILE}" \
    "${PPVS_DATA_DIR}/${PPVS_MAIN_WIND_TURBINES_FILE}" \
    "${PPVS_DATA_DIR}/${PPVS_MAIN_CARBON_DATA_FILE}"
  do
    [[ -f "${f}" ]] || { echo "Missing main-mode dataset file: ${f}" >&2; exit 1; }
  done
  echo "main_mode_data_ok"
fi

for cmd in sbatch squeue sacct scontrol; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required SLURM command in PATH: ${cmd}" >&2
    exit 1
  }
done
echo "slurm_cli_ok (sbatch/squeue/sacct/scontrol found)"

SLURM_CONFIG="$(scontrol show config 2>/dev/null || true)"
if [[ -n "${SLURM_CONFIG}" ]]; then
  ACCT_TYPE="$(echo "${SLURM_CONFIG}" | awk -F= '/^AccountingStorageType/{print $2}' | xargs)"
  JG_TYPE="$(echo "${SLURM_CONFIG}" | awk -F= '/^JobAcctGatherType/{print $2}' | xargs)"
  JG_FREQ="$(echo "${SLURM_CONFIG}" | awk -F= '/^JobAcctGatherFrequency/{print $2}' | xargs)"

  echo "AccountingStorageType=${ACCT_TYPE:-unknown}"
  echo "JobAcctGatherType=${JG_TYPE:-unknown}"
  echo "JobAcctGatherFrequency=${JG_FREQ:-unknown}"

  if [[ "${ACCT_TYPE:-}" == "accounting_storage/none" || -z "${ACCT_TYPE:-}" ]]; then
    echo "Warning: SLURM accounting storage appears disabled; sacct history may be unavailable." >&2
    if [[ "${OBS_ENABLE}" == "1" ]]; then
      echo "OBS_ENABLE=1 requires accounting_storage/slurmdbd (or equivalent) on the cluster." >&2
      exit 1
    fi
  fi
else
  echo "Warning: unable to read SLURM config via scontrol show config." >&2
fi

if [[ "${OBS_ENABLE}" == "1" ]]; then
  if command -v curl >/dev/null 2>&1; then
    HTTP_CODE="$(curl -sS -o /dev/null -w "%{http_code}" "${OBS_ELASTIC_URL}" || true)"
    if [[ "${HTTP_CODE}" =~ ^2|3|4 ]]; then
      echo "obs_endpoint_check=${HTTP_CODE} (${OBS_ELASTIC_URL})"
    else
      echo "Warning: observability endpoint not reachable now (${OBS_ELASTIC_URL}, code=${HTTP_CODE:-ERR})." >&2
    fi
  else
    echo "Warning: curl not found; skipping OBS endpoint check." >&2
  fi
fi

echo "Environment setup check completed."
