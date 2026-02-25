#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Provision optional local observability stack (Elasticsearch, Kibana, Grafana, Fluent Bit).

Usage:
  experiments/bootstrap/provision_obs_stack.sh --profile <cluster.env> [options]

Options:
  --profile PATH      Profile file (required)
  --stack-dir PATH    Target stack directory (default: $PPVS_ROOT/obs/stack)
  --start             Start containers after rendering config
  --help              Show this help

Requirements:
  - Docker + Docker Compose installed
  - Permission to run docker commands
  - Suitable for self-managed hosts (e.g., Azure controller VM)

For managed HPC without Docker privileges, skip this script and use:
  experiments/obs/collect_*.py + push_ndjson.py against external Elastic.
EOF
}

PROFILE=""
STACK_DIR=""
START=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --stack-dir) STACK_DIR="${2:-}"; shift 2 ;;
    --start) START=1; shift ;;
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

PPVS_ROOT="${PPVS_ROOT:?PPVS_ROOT missing in profile}"
PPVS_RESULTS_DIR="${PPVS_RESULTS_DIR:?PPVS_RESULTS_DIR missing in profile}"
CLUSTER_NAME="${CLUSTER_NAME:-cluster}"
OBS_INDEX_PREFIX="${OBS_INDEX_PREFIX:-ppvs}"
OBS_BIND_ADDRESS="${OBS_BIND_ADDRESS:-127.0.0.1}"
OBS_ES_PORT="${OBS_ES_PORT:-9200}"
OBS_KIBANA_PORT="${OBS_KIBANA_PORT:-5601}"
OBS_GRAFANA_PORT="${OBS_GRAFANA_PORT:-3000}"

if [[ -z "${STACK_DIR}" ]]; then
  STACK_DIR="${PPVS_ROOT}/obs/stack"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_TEMPLATE_DIR="${SCRIPT_DIR}/../obs/stack"

command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose not available" >&2; exit 1; }

mkdir -p "${STACK_DIR}"
cp -f "${STACK_TEMPLATE_DIR}/docker-compose.yml" "${STACK_DIR}/docker-compose.yml"
cp -f "${STACK_TEMPLATE_DIR}/fluent-bit.conf" "${STACK_DIR}/fluent-bit.conf"
cp -f "${STACK_TEMPLATE_DIR}/parsers.conf" "${STACK_DIR}/parsers.conf"

cat > "${STACK_DIR}/.env" <<EOF
CLUSTER_NAME=${CLUSTER_NAME}
PPVS_RESULTS_DIR=${PPVS_RESULTS_DIR}
OBS_INDEX_PREFIX=${OBS_INDEX_PREFIX}
OBS_BIND_ADDRESS=${OBS_BIND_ADDRESS}
OBS_ES_PORT=${OBS_ES_PORT}
OBS_KIBANA_PORT=${OBS_KIBANA_PORT}
OBS_GRAFANA_PORT=${OBS_GRAFANA_PORT}
EOF

echo "Rendered stack in: ${STACK_DIR}"
echo "Results source path: ${PPVS_RESULTS_DIR}"

if [[ "${START}" -eq 1 ]]; then
  port_busy() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
      ss -ltn "( sport = :${port} )" | awk 'NR>1 {print $0}' | grep -q .
      return $?
    fi
    return 1
  }

  for p in "${OBS_ES_PORT}" "${OBS_KIBANA_PORT}" "${OBS_GRAFANA_PORT}"; do
    if port_busy "${p}"; then
      cat >&2 <<EOF
Port ${p} is already in use.
Set OBS_ES_PORT / OBS_KIBANA_PORT / OBS_GRAFANA_PORT in your profile to free ports, then re-run.
EOF
      exit 2
    fi
  done

  if command -v sudo >/dev/null 2>&1; then
    sudo sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true
  fi

  (cd "${STACK_DIR}" && docker compose up -d)
  echo "Stack started."
  for u in "${OBS_BIND_ADDRESS}:${OBS_ES_PORT}" "${OBS_BIND_ADDRESS}:${OBS_KIBANA_PORT}" "${OBS_BIND_ADDRESS}:${OBS_GRAFANA_PORT}"; do
    code=""
    for _ in $(seq 1 30); do
      code="$(curl -sS -o /dev/null -w "%{http_code}" "http://${u}" || true)"
      if [[ "${code}" != "000" && -n "${code}" ]]; then
        break
      fi
      sleep 1
    done
    echo "${u} -> ${code:-ERR}"
  done
else
  echo "Start skipped. Run manually:"
  echo "  cd ${STACK_DIR} && docker compose up -d"
fi
