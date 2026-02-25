#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Create/update PPVS Python environment and verify imports on login+compute.

Usage:
  experiments/bootstrap/install_python_env.sh --profile <cluster.env> [options]

Options:
  --profile PATH          Profile file (required)
  --python PATH           Python interpreter override
  --venv PATH             Venv path override
  --python-module NAME    Optional module name to load first (e.g. python/3.9.19)
  --upgrade-bootstrap     Force upgrade of pip/setuptools/wheel in venv
  --skip-compute-check    Skip import check via srun on compute node
  --no-editable           Skip pip install -e <repo>
  --help                  Show this help
EOF
}

PROFILE=""
PYTHON_OVERRIDE=""
VENV_OVERRIDE=""
PYTHON_MODULE=""
UPGRADE_BOOTSTRAP=0
SKIP_COMPUTE_CHECK=0
EDITABLE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --python) PYTHON_OVERRIDE="${2:-}"; shift 2 ;;
    --venv) VENV_OVERRIDE="${2:-}"; shift 2 ;;
    --python-module) PYTHON_MODULE="${2:-}"; shift 2 ;;
    --upgrade-bootstrap) UPGRADE_BOOTSTRAP=1; shift ;;
    --skip-compute-check) SKIP_COMPUTE_CHECK=1; shift ;;
    --no-editable) EDITABLE=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${PROFILE}" ]]; then
  echo "--profile is required" >&2
  usage
  exit 2
fi
if [[ ! -f "${PROFILE}" ]]; then
  echo "Profile not found: ${PROFILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${PROFILE}"

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Required command not found in PATH: ${cmd}" >&2
    exit 1
  }
}

has_project_metadata() {
  local path="$1"
  [[ -f "${path}/pyproject.toml" || -f "${path}/setup.py" ]]
}

resolve_vessim_root() {
  local root="$1"
  if has_project_metadata "${root}"; then
    echo "${root}"
    return 0
  fi
  if has_project_metadata "${root}/vessim"; then
    echo "${root}/vessim"
    return 0
  fi
  cat >&2 <<EOF
Invalid PPVS_VESSIM_ROOT=${root}
Expected a Python project root containing pyproject.toml or setup.py.
If your checkout is at ${root}/vessim, set PPVS_VESSIM_ROOT to that path.
EOF
  exit 1
}

PPVS_VESSIM_ROOT="${PPVS_VESSIM_ROOT:?PPVS_VESSIM_ROOT missing in profile}"
PPVS_VENV="${VENV_OVERRIDE:-${PPVS_VENV:-$HOME/.venvs/vessim}}"
PPVS_INSTALL_ROOT="$(resolve_vessim_root "${PPVS_VESSIM_ROOT}")"

if [[ -n "${PYTHON_MODULE}" ]]; then
  if [[ -f /etc/profile.d/modules.sh ]]; then
    # shellcheck disable=SC1091
    source /etc/profile.d/modules.sh
  fi
  if command -v module >/dev/null 2>&1; then
    module purge || true
    module load "${PYTHON_MODULE}"
  else
    echo "module command not found; cannot load ${PYTHON_MODULE}" >&2
    exit 1
  fi
fi

if [[ -n "${PYTHON_OVERRIDE}" ]]; then
  BASE_PY="${PYTHON_OVERRIDE}"
elif [[ -n "${PPVS_PYTHON:-}" ]]; then
  BASE_PY="${PPVS_PYTHON}"
elif command -v python3 >/dev/null 2>&1; then
  BASE_PY="$(command -v python3)"
else
  echo "No python3 found. Provide --python or set PPVS_PYTHON." >&2
  exit 1
fi

if [[ ! -x "${BASE_PY}" ]]; then
  echo "Python interpreter is not executable: ${BASE_PY}" >&2
  exit 1
fi

if [[ "${SKIP_COMPUTE_CHECK}" -eq 0 ]]; then
  require_cmd srun
fi

echo "base_python=${BASE_PY}"
echo "venv=${PPVS_VENV}"
echo "vessim_root=${PPVS_INSTALL_ROOT}"

mkdir -p "$(dirname "${PPVS_VENV}")"
if [[ ! -x "${PPVS_VENV}/bin/python" ]]; then
  "${BASE_PY}" -m venv "${PPVS_VENV}"
fi

MISSING_BOOTSTRAP="$("${PPVS_VENV}/bin/python" - <<'PY'
import importlib.util

mods = ["pip", "setuptools", "wheel"]
missing = [m for m in mods if importlib.util.find_spec(m) is None]
print(" ".join(missing))
PY
)"

if [[ "${UPGRADE_BOOTSTRAP}" -eq 1 || -n "${MISSING_BOOTSTRAP}" ]]; then
  if [[ "${UPGRADE_BOOTSTRAP}" -eq 1 ]]; then
    echo "Upgrading venv bootstrap packages (pip/setuptools/wheel)."
  else
    echo "Installing missing venv bootstrap packages: ${MISSING_BOOTSTRAP}"
  fi
  "${PPVS_VENV}/bin/python" -m pip install -U pip setuptools wheel
else
  echo "Venv bootstrap packages already available; skipping pip/setuptools/wheel upgrade."
fi

MISSING_DEPS="$("${PPVS_VENV}/bin/python" - <<'PY'
import importlib.util

mods = ["hydra", "yaml", "pandas", "optuna", "optuna_dashboard"]
missing = [m for m in mods if importlib.util.find_spec(m) is None]
print(" ".join(missing))
PY
)"

if [[ -n "${MISSING_DEPS}" ]]; then
  echo "Installing missing Python dependencies: ${MISSING_DEPS}"
  "${PPVS_VENV}/bin/python" -m pip install hydra-core pyyaml pandas optuna optuna-dashboard
else
  echo "Python dependencies already installed (hydra/yaml/pandas/optuna/optuna_dashboard)."
fi

if [[ "${EDITABLE}" -eq 1 ]]; then
  if [[ -d "${PPVS_INSTALL_ROOT}/.git" ]]; then
    "${PPVS_VENV}/bin/python" -m pip install -e "${PPVS_INSTALL_ROOT}"
  else
    # Tar/zip staged code often omits VCS metadata; provide deterministic fallback.
    SCM_FALLBACK_VERSION="${PPVS_SCM_FALLBACK_VERSION:-0.0.dev0}"
    echo "No .git found in install root (${PPVS_INSTALL_ROOT}); using setuptools-scm fallback version: ${SCM_FALLBACK_VERSION}"
    SETUPTOOLS_SCM_PRETEND_VERSION="${SCM_FALLBACK_VERSION}" \
      SETUPTOOLS_SCM_PRETEND_VERSION_FOR_VESSIM="${SCM_FALLBACK_VERSION}" \
      "${PPVS_VENV}/bin/python" -m pip install -e "${PPVS_INSTALL_ROOT}"
  fi
fi

"${PPVS_VENV}/bin/python" - <<'PY'
import sys
mods = ["hydra", "yaml", "pandas", "vessim", "optuna"]
for m in mods:
    __import__(m)
print("python_imports_ok", sys.executable)
PY

SRUN_ARGS=()
if [[ -n "${SLURM_PARTITION:-}" ]]; then
  SRUN_ARGS+=(--partition "${SLURM_PARTITION}")
fi

if [[ "${SKIP_COMPUTE_CHECK}" -eq 0 ]]; then
  if ! srun "${SRUN_ARGS[@]}" -N1 -n1 bash -lc "
    set -e
    '${PPVS_VENV}/bin/python' - <<'PY'
mods = ['hydra', 'yaml', 'pandas', 'vessim', 'optuna']
for m in mods:
    __import__(m)
print('compute_python_imports_ok')
PY
"
  then
    cat >&2 <<EOF
Compute-node import check failed.
Common cause: PPVS_VENV is not on shared storage.
Current PPVS_VENV=${PPVS_VENV}
Recommendation: use a shared path, e.g. PPVS_ROOT/venv/vessim.
EOF
    exit 1
  fi
else
  echo "Compute-node import check skipped (--skip-compute-check)."
fi

echo "Python environment ready."
