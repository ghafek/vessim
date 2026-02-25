# Portable SLURM Workflow

This directory contains a cluster-agnostic sweep workflow for Vessim using:

- Hydra multirun for parameter combinations.
- A CSV selector that maps one scenario per SLURM array task.
- SLURM arrays for scalable execution on any cluster.

No cluster-specific files are required by default. Use one template profile and
adjust values per environment.

## Structure

- `experiments/profiles/cluster.template.env`: generic environment template.
- `experiments/setup_env.sh`: preflight checks.
- `experiments/submit_sweep.sh`: user entry point for sweeps.
- `experiments/hydra_gen/*`: scenario generation and CSV builder.
- `experiments/sbatch/*`: portable batch scripts.
- `experiments/run_scenario.py`: simulation runner used by array tasks.
- `experiments/vessim_smoke.py`: minimal smoke test.

## Prerequisites

Before running any workflow script, ensure these are available on the login node:

- SLURM CLI: `sbatch`, `squeue`, `sacct`, `scontrol`, `srun`
- Python: `python3` (3.9+)
- Standard shell utilities: `bash`, `grep`, `wc`
- A shared writable filesystem visible from login and compute nodes
- This repository (or at least `experiments/` plus `vessim/`) accessible on the cluster

Python dependencies required for the workflow:

- `vessim`
- `hydra-core`
- `pyyaml`
- `pandas`
- `optuna`
- `optuna-dashboard`

Install/update these automatically with:

`experiments/bootstrap/install_python_env.sh --profile <cluster.env>`

Optional tools:

- `docker` + `docker compose` (only for `bootstrap/provision_obs_stack.sh`)
- `curl` (used for optional endpoint checks)

## Guide Layout

This README is the workflow entry point. Specialized guides stay separate:

- `experiments/bootstrap/README.md`: managed-HPC onboarding and runtime bootstrapping
- `experiments/obs/README.md`: observability export/push flow

## Quick Start

1. Copy the template profile:

```bash
cp experiments/profiles/cluster.template.env experiments/profiles/mycluster.env
```

2. Edit your cluster settings in `experiments/profiles/mycluster.env`.

3. Validate setup:

```bash
./experiments/setup_env.sh --profile experiments/profiles/mycluster.env
```

4. Submit a sweep:

```bash
./experiments/submit_sweep.sh \
  --profile experiments/profiles/mycluster.env \
  battery.capacity_wh=0,100,300 \
  actors.1.signal.value=1000,2000 \
  step_size_s=60 \
  until_s=3600
```

For managed HPC onboarding (existing SLURM clusters), use:

`experiments/bootstrap/README.md`

## What `run_hybrid.sh` Does

`experiments/hydra_gen/run_hybrid.sh` is the core one-command path. It performs:

1. Hydra multirun scenario generation via `hydra_gen/generate_scenarios.py`.
2. Selector CSV creation via `hydra_gen/build_csv.py`.
3. SLURM array submission via `sbatch` and `sbatch/vessim_sweep_array.sbatch`.
4. One array task per CSV row, each task calling `run_scenario.py`.

Expected task count:

`N = product_of_all_comma_separated_override_choices`

Example:

`step_size_s=60,300` and `until_s=3600,7200` gives `2 x 2 = 4` tasks.

Important:

- Use `until_s` (not `untils`).
- Paths and outputs are profile-driven (`PPVS_*` variables).

## Running Modes

### A) Hydra overrides on command line

```bash
./experiments/hydra_gen/run_hybrid.sh \
  --profile experiments/profiles/mycluster.env \
  step_size_s=60,300 \
  until_s=3600,7200
```

### B) Hydra overrides from a file

Create an overrides file (one Hydra override per line):

```text
# my_overrides.txt
step_size_s=60,300
until_s=3600,7200
```

If that file contains exactly those two lines, this direct command is equivalent:

```bash
./experiments/hydra_gen/run_hybrid.sh \
  --profile experiments/profiles/mycluster.env \
  step_size_s=60,300 \
  until_s=3600,7200
```

To actually read overrides from `my_overrides.txt` dynamically (ignoring empty
lines and `#` comments), use:

```bash
mapfile -t OVERRIDES < <(grep -v '^[[:space:]]*$' my_overrides.txt | grep -v '^[[:space:]]*#')
./experiments/hydra_gen/run_hybrid.sh \
  --profile experiments/profiles/mycluster.env \
  "${OVERRIDES[@]}"
```

What this does:

- `mapfile -t OVERRIDES` loads each non-empty, non-comment line into a Bash array.
- `"${OVERRIDES[@]}"` passes each line as its own argument to Hydra.
- This is equivalent to typing those override lines directly in the command.

### C) Custom selector CSV (without Hydra generation)

If you already have scenario YAML files and want direct control, submit the array
directly with your own CSV (`scenario_id,scenario_file`):

```bash
source experiments/profiles/mycluster.env
PARAM_FILE=/path/to/custom_selector.csv \
SCENARIO_SCRIPT="${PPVS_EXPERIMENTS_DIR}/run_scenario.py" \
PPVS_RUNS_DIR="${PPVS_RUNS_DIR}" \
PPVS_VENV="${PPVS_VENV}" \
PPVS_VESSIM_ROOT="${PPVS_VESSIM_ROOT}" \
sbatch --array 0-3 "${PPVS_EXPERIMENTS_DIR}/sbatch/vessim_sweep_array.sbatch"
```

## Azure `/shared` Validation Notes

The following was validated on Azure with the flat `/shared` layout:

1. CLI Hydra run produced a 4-task array:

```bash
/shared/experiments/hydra_gen/run_hybrid.sh \
  step_size_s=60,300 \
  until_s=3600,7200
```

2. File-based Hydra overrides also produced a 4-task array.
3. Direct custom CSV submission via `PARAM_FILE=... sbatch --array ...` worked and
   created `runs/<jobid>/<task>_<scenario_id>/` outputs as expected.

## User Controls

Set these in the profile or export them before submission:

- `SLURM_PARTITION`
- `SLURM_ACCOUNT`
- `SLURM_QOS`
- `SLURM_CONSTRAINT`
- `SLURM_TIME`
- `SLURM_MEM`
- `SLURM_CPUS_PER_TASK`
- `ARRAY_THROTTLE` (`auto`, `0`, empty, or positive integer)
- `SBATCH_EXTRA_ARGS`

## Outputs

Each task writes a dedicated run directory:

`runs/<array_job_id>/<task_id>_<scenario_id>/`

Files per task:

- `meta.json`
- `results.csv`
- `summary_event.json`

Typical generated artifacts per hybrid submission:

- `params/scenarios/generated_<timestamp>/...` (Hydra scenario YAMLs)
- `params/scenario_selector_<timestamp>.csv` (portable workflow default)

Some flat `/shared` deployments may intentionally use a fixed selector path such as
`/shared/params/scenario_selector.csv`.

Scheduler logs:

- `results/<job_name>_<array_job_id>_<task_id>.out`
- `results/<job_name>_<array_job_id>_<task_id>.err`

## Observability (Optional)

You can export and push data to an existing Elasticsearch/Kibana stack using:

- `experiments/obs/collect_sacct.py`
- `experiments/obs/collect_runs.py`
- `experiments/obs/push_ndjson.py`

See `experiments/obs/README.md`.

Important: SLURM accounting is cluster-side. This workflow reads it via `sacct`
if admins enabled accounting storage/gathering.
