#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Initialize PPVS runtime layout and generate a cluster profile.

Usage:
  experiments/bootstrap/init_project.sh --root <runtime_root> [options]

Options:
  --root PATH              Runtime root for params/results/runs (required)
  --profile-out PATH       Output profile file path
  --experiments-dir PATH   Override experiments directory path
  --vessim-root PATH       Override Vessim source root path
  --cluster-name NAME      Cluster label written to metadata (default: cluster)
  --partition NAME         Default SLURM partition (optional)
  --account NAME           Default SLURM account (optional)
  --qos NAME               Default SLURM QoS (optional)
  --constraint EXPR        Default SLURM constraint (optional)
  --venv PATH              Python venv path (default: $HOME/.venvs/vessim)
  --cpus N                 Default cpus per task (default: 1)
  --mem VAL                Default mem per task (default: 2G)
  --time HH:MM:SS          Default walltime (default: 00:30:00)
  --array-throttle VAL     Default array throttle (default: auto)
  --help                   Show this help

Notes:
  - This script does not install SLURM. It assumes cluster SLURM is already running.
  - Code paths are resolved to this repository and kept separate from runtime outputs.
EOF
}

ROOT=""
PROFILE_OUT=""
EXPERIMENTS_DIR_OVERRIDE=""
VESSIM_ROOT_OVERRIDE=""
CLUSTER_NAME="cluster"
SLURM_PARTITION=""
SLURM_ACCOUNT=""
SLURM_QOS=""
SLURM_CONSTRAINT=""
PPVS_VENV=""
SLURM_CPUS_PER_TASK="1"
SLURM_MEM="2G"
SLURM_TIME="00:30:00"
ARRAY_THROTTLE="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --profile-out) PROFILE_OUT="${2:-}"; shift 2 ;;
    --experiments-dir) EXPERIMENTS_DIR_OVERRIDE="${2:-}"; shift 2 ;;
    --vessim-root) VESSIM_ROOT_OVERRIDE="${2:-}"; shift 2 ;;
    --cluster-name) CLUSTER_NAME="${2:-}"; shift 2 ;;
    --partition) SLURM_PARTITION="${2:-}"; shift 2 ;;
    --account) SLURM_ACCOUNT="${2:-}"; shift 2 ;;
    --qos) SLURM_QOS="${2:-}"; shift 2 ;;
    --constraint) SLURM_CONSTRAINT="${2:-}"; shift 2 ;;
    --venv) PPVS_VENV="${2:-}"; shift 2 ;;
    --cpus) SLURM_CPUS_PER_TASK="${2:-}"; shift 2 ;;
    --mem) SLURM_MEM="${2:-}"; shift 2 ;;
    --time) SLURM_TIME="${2:-}"; shift 2 ;;
    --array-throttle) ARRAY_THROTTLE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${ROOT}" ]]; then
  echo "--root is required" >&2
  usage
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

has_project_metadata() {
  local path="$1"
  [[ -f "${path}/pyproject.toml" || -f "${path}/setup.py" ]]
}

normalize_vessim_root() {
  local input_root="$1"
  if has_project_metadata "${input_root}"; then
    echo "${input_root}"
    return 0
  fi
  if has_project_metadata "${input_root}/vessim"; then
    echo "${input_root}/vessim"
    return 0
  fi
  echo "${input_root}"
}

if [[ -n "${EXPERIMENTS_DIR_OVERRIDE}" ]]; then
  EXPERIMENTS_DIR="${EXPERIMENTS_DIR_OVERRIDE}"
else
  EXPERIMENTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

if [[ -n "${VESSIM_ROOT_OVERRIDE}" ]]; then
  VESSIM_ROOT="${VESSIM_ROOT_OVERRIDE}"
elif [[ -d "${REPO_ROOT}/vessim" ]]; then
  VESSIM_ROOT="${REPO_ROOT}"
else
  VESSIM_ROOT="/path/to/vessim/root"
fi

VESSIM_ROOT="$(normalize_vessim_root "${VESSIM_ROOT}")"

TEMPLATE="${EXPERIMENTS_DIR}/profiles/cluster.template.env"

if [[ ! -f "${TEMPLATE}" ]]; then
  echo "Template not found: ${TEMPLATE}" >&2
  exit 1
fi

if [[ -z "${PPVS_VENV}" ]]; then
  PPVS_VENV="${ROOT}/venv/vessim"
fi

mkdir -p "${ROOT}/params/scenarios" "${ROOT}/results" "${ROOT}/runs" "${ROOT}/obs"

if [[ -z "${PROFILE_OUT}" ]]; then
  PROFILE_OUT="${ROOT}/profiles/cluster.env"
fi
mkdir -p "$(dirname "${PROFILE_OUT}")"

cat > "${PROFILE_OUT}" <<EOF
export CLUSTER_NAME="${CLUSTER_NAME}"

export PPVS_ROOT="${ROOT}"
export PPVS_EXPERIMENTS_DIR="${EXPERIMENTS_DIR}"
export PPVS_PARAMS_DIR="\${PPVS_ROOT}/params"
export PPVS_RESULTS_DIR="\${PPVS_ROOT}/results"
export PPVS_RUNS_DIR="\${PPVS_ROOT}/runs"
export PPVS_DATA_DIR="\${PPVS_PARAMS_DIR}/data"
export PPVS_VESSIM_ROOT="${VESSIM_ROOT}"

export PPVS_VENV="${PPVS_VENV}"
# export PPVS_PYTHON="/full/path/to/python3"

export PARAM_FILE=""
export PPVS_MODE="main"
export PPVS_MAIN_DATA_PROFILE="generic"
# For reference-compatible filenames, append exports from:
# experiments/profiles/main_data_reference_compat.env

export SLURM_PARTITION="${SLURM_PARTITION}"
export SLURM_ACCOUNT="${SLURM_ACCOUNT}"
export SLURM_QOS="${SLURM_QOS}"
export SLURM_CONSTRAINT="${SLURM_CONSTRAINT}"

export SLURM_CPUS_PER_TASK="${SLURM_CPUS_PER_TASK}"
export SLURM_MEM="${SLURM_MEM}"
export SLURM_TIME="${SLURM_TIME}"
export ARRAY_THROTTLE="${ARRAY_THROTTLE}"

# export SBATCH_EXTRA_ARGS="--acctg-freq=task=1"
export PPVS_REQUIRE_OPTUNA="0"

export OBS_ENABLE="0"
export OBS_ELASTIC_URL="http://localhost:9200"
export OBS_INDEX_PREFIX="ppvs"
EOF

chmod 600 "${PROFILE_OUT}"

echo "Initialized runtime root: ${ROOT}"
echo "Generated profile: ${PROFILE_OUT}"
if ! has_project_metadata "${VESSIM_ROOT}"; then
  cat >&2 <<EOF
Warning: PPVS_VESSIM_ROOT=${VESSIM_ROOT} does not currently contain pyproject.toml/setup.py.
install_python_env.sh will fail editable install until this path points to a valid Vessim checkout root.
EOF
fi
echo "Next: experiments/bootstrap/preflight_cluster.sh --profile ${PROFILE_OUT}"
