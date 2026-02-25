#!/usr/bin/env bash
#SBATCH --job-name=meta_aggregate
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=512M
#SBATCH --time=00:05:00
set -euo pipefail

TARGET_JOBID="${TARGET_JOBID:?TARGET_JOBID is required}"
RUNS_ROOT="${PPVS_RUNS_DIR:-$PWD/runs}"

if [[ -n "${PPVS_PYTHON:-}" ]]; then
  PYTHON_BIN="${PPVS_PYTHON}"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
else
  echo "python3 not found and PPVS_PYTHON not set." >&2
  exit 1
fi

"${PYTHON_BIN}" - <<'PY'
import json
import os
import subprocess
from pathlib import Path

jobid = os.environ["TARGET_JOBID"]
runs = Path(os.environ["RUNS_ROOT"]) / jobid
summary = {"job_id": jobid, "tasks": {}}

fmt = "JobID,State,ExitCode,Elapsed,Start,End,NodeList"
out = subprocess.check_output(
    ["sacct", "-P", "-n", "-j", jobid, "--format", fmt, "-X"],
    text=True,
)

for line in out.strip().splitlines():
    jobid_raw, state, exitcode, elapsed, start, end, nodelist = line.split("|")
    task = jobid_raw.split("_", 1)[1] if "_" in jobid_raw else "batch"
    summary["tasks"].setdefault(task, {})["sacct"] = {
        "JobID": jobid_raw,
        "State": state,
        "ExitCode": exitcode,
        "Elapsed": elapsed,
        "Start": start,
        "End": end,
        "NodeList": nodelist,
    }

if runs.exists():
    for meta in runs.glob("*/meta.json"):
        task = meta.parent.name.split("_", 1)[0]
        summary["tasks"].setdefault(task, {})["meta"] = json.loads(meta.read_text())

outpath = runs / "meta_all.json"
outpath.parent.mkdir(parents=True, exist_ok=True)
outpath.write_text(json.dumps(summary, indent=2))
print(outpath)
PY
