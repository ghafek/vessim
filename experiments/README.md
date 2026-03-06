# Portable SLURM Workflow

This workflow runs Vessim sweeps in a cluster-agnostic way:

1. Hydra generates scenario YAMLs (Cartesian product from overrides).
2. A selector CSV maps one scenario per row.
3. SLURM array runs one task per CSV row.

Main entrypoint: `experiments/hydra_gen/run_hybrid.sh`

## Backends

- `main` (default): SAM-based large simulations (wind/solar/battery capacities, paper-style workload).
- `simple`: lightweight static/CSV signal simulations (older behavior).

Switch mode with:

```bash
PPVS_MODE=simple ./experiments/hydra_gen/run_hybrid.sh ...
```

If `PPVS_MODE` is unset, `main` is used.

## Key Files

- `experiments/run_scenario.py`: default `main` backend runner.
- `experiments/simple/run_scenario_simple.py`: `simple` backend runner.
- `experiments/hydra_gen/conf/config.yaml`: default `main` Hydra config.
- `experiments/hydra_gen/conf/config_simple.yaml`: `simple` Hydra config.
- `experiments/sbatch/vessim_sweep_array.sbatch`: array task wrapper.
- `experiments/profiles/main_data_reference_compat.env`: optional reference filename mapping.

## Prerequisites

- SLURM CLI: `sbatch`, `squeue`, `sacct`, `scontrol`, `srun`
- Python 3.9+ and `venv`
- Shared writable filesystem (login + compute nodes)
- Repository checkout available on shared storage

Installed by `experiments/bootstrap/install_python_env.sh` (mode-aware):

- Always: `vessim`, `hydra-core`, `pyyaml`, `pandas`
- `main` mode: `nrel-pysam`
- Optional (`PPVS_REQUIRE_OPTUNA=1`): `optuna`, `optuna-dashboard`

## Required Data (Main Mode)

By default, datasets are expected under `PPVS_DATA_DIR` (defaults to `${PPVS_PARAMS_DIR}/data`).

Default generic filenames:

- `power_data.csv`
- `wind_data.csv`
- `solar_data.csv`
- `solar_config.json`
- `wind_config.json`
- `wind_turbines.csv`
- `carbon_data.csv`

These are profile-driven via:

- `PPVS_MAIN_DATA_PROFILE` (`generic` or `reference`)
- `PPVS_MAIN_POWER_DATA_FILE`
- `PPVS_MAIN_WIND_DATA_FILE`
- `PPVS_MAIN_SOLAR_DATA_FILE`
- `PPVS_MAIN_SOLAR_CONFIG_FILE`
- `PPVS_MAIN_WIND_CONFIG_FILE`
- `PPVS_MAIN_WIND_TURBINES_FILE`
- `PPVS_MAIN_CARBON_DATA_FILE`

`experiments/setup_env.sh` and `experiments/bootstrap/preflight_cluster.sh` validate the resolved file paths in `main` mode.

For reference-compatible names, use exports from:

```bash
cat experiments/profiles/main_data_reference_compat.env
```

## Quick Start

1. Create profile:

```bash
cp experiments/profiles/cluster.template.env experiments/profiles/mycluster.env
```

2. Edit `experiments/profiles/mycluster.env` (`PPVS_ROOT`, SLURM routing, etc.).

Optional (reference-compatible dataset filenames):

```bash
# Copy these exports into your cluster profile:
cat experiments/profiles/main_data_reference_compat.env
# or append directly:
cat experiments/profiles/main_data_reference_compat.env >> experiments/profiles/mycluster.env
```

3. Cluster preflight:

```bash
bash experiments/bootstrap/preflight_cluster.sh --profile experiments/profiles/mycluster.env --strict
```

4. Install/update Python env:

```bash
bash experiments/bootstrap/install_python_env.sh --profile experiments/profiles/mycluster.env
```

5. Validate workflow environment:

```bash
bash experiments/setup_env.sh --profile experiments/profiles/mycluster.env
```

## How `run_hybrid.sh` Works

`run_hybrid.sh` does all steps in one command:

1. Runs Hydra multirun (`generate_scenarios.py`) and writes scenario YAMLs.
2. Builds selector CSV (`build_csv.py`).
3. Submits array job with `sbatch`.
4. In `main` mode, injects `file_paths.*` from profile dataset mapping variables.

Task count:

`N = product of all comma-separated value counts in overrides`

Example:

- `step_size_s=60,300`
- `until_s=3600,7200`
- Result: `2 x 2 = 4` tasks

Use `until_s` (not `untils`).

## Supported Parameter Schema

Short summary:

| Mode | Key groups | Notes |
| --- | --- | --- |
| `main` (default) | top-level timing/id, `policy`, capacity fields, `file_paths` | capacity-driven SAM workflow (`wind/solar/battery`) |
| `simple` | top-level timing/id, `policy`, `battery`, `actors[].signal` | static/csv signal workflow |

Quick key list:

- `main` required keys:
  - `wind_system_capacity`, `solar_system_capacity`, `battery_capacity`
  - `single_cell_capacity`, `wind_turbine_model`
  - `file_paths.power_data`, `file_paths.wind_data`, `file_paths.solar_data`
  - `file_paths.solar_config`, `file_paths.wind_config`, `file_paths.wind_turbines`, `file_paths.carbon_data`
- `main` common optional keys:
  - `scenario_id`, `sim_start`, `step_size_s`, `until_s`, `microgrid_name`
  - `policy.mode`, `policy.charge_power`
- `simple` common keys:
  - `scenario_id`, `sim_start`, `step_size_s`, `until_s`, `microgrid_name`
  - `policy.mode`, `policy.charge_power`
  - `battery.capacity_wh`, `battery.initial_soc`, `battery.min_soc`, `battery.c_rate`
  - `actors[].name`
  - `actors[].signal.mode` (`static` or `csv_column`)
  - `actors[].signal.value` (for `static`)
  - `actors[].signal.path`, `actors[].signal.column`, `actors[].signal.scale` (for `csv_column`)

Full authoritative schema (types, required/optional, examples):

- `experiments/PARAMETER_SCHEMA.md`

## Run Commands

### A) Main mode (default), CLI overrides

```bash
./experiments/hydra_gen/run_hybrid.sh \
  --profile experiments/profiles/mycluster.env \
  wind_system_capacity=0,3000,6000 \
  solar_system_capacity=0,4000,8000 \
  battery_capacity=0,7500,15000 \
  step_size_s=60 \
  until_s=86400
```

### B) Main mode, overrides from file

`my_overrides.txt`:

```text
wind_system_capacity=0,3000,6000
solar_system_capacity=0,4000,8000
battery_capacity=0,7500,15000
step_size_s=60
until_s=86400
```

Run:

```bash
./experiments/hydra_gen/run_hybrid.sh \
  --profile experiments/profiles/mycluster.env \
  --overrides-file my_overrides.txt
```

`--overrides-file` also works with `my_overrides.csv` if each line is one Hydra
override (same content format).

### C) Simple mode

```bash
PPVS_MODE=simple ./experiments/hydra_gen/run_hybrid.sh \
  --profile experiments/profiles/mycluster.env \
  battery.capacity_wh=0,100,300 \
  actors.1.signal.value=1000,2000 \
  step_size_s=60 \
  until_s=3600
```

### D) Custom selector CSV (no Hydra generation)

CSV header must be `scenario_id,scenario_file`.

```bash
source experiments/profiles/mycluster.env
PARAM_FILE=/path/to/custom_selector.csv \
SCENARIO_SCRIPT="${PPVS_EXPERIMENTS_DIR}/run_scenario.py" \
PPVS_RUNS_DIR="${PPVS_RUNS_DIR}" \
PPVS_VENV="${PPVS_VENV}" \
PPVS_VESSIM_ROOT="${PPVS_VESSIM_ROOT}" \
sbatch --array 0-3 "${PPVS_EXPERIMENTS_DIR}/sbatch/vessim_sweep_array.sbatch"
```

## Large Array Example (1089)

Paper-like exhaustive grid:

- wind: `0..30000` step `3000` (11 values)
- solar: `0..40000` step `4000` (11 values)
- battery: `0..60000` step `7500` (9 values)
- total: `11 x 11 x 9 = 1089`

Command pattern:

```bash
ARRAY_THROTTLE=32 ./experiments/hydra_gen/run_hybrid.sh \
  --profile experiments/profiles/mycluster.env \
  wind_system_capacity=0,3000,6000,9000,12000,15000,18000,21000,24000,27000,30000 \
  solar_system_capacity=0,4000,8000,12000,16000,20000,24000,28000,32000,36000,40000 \
  battery_capacity=0,7500,15000,22500,30000,37500,45000,52500,60000
```

Use throttle for stability on small clusters.

If cluster `MaxArraySize` is smaller than required task count, `run_hybrid.sh`
automatically splits submission into multiple array jobs and keeps correct CSV
row mapping internally.

In that case, submission output contains multiple JOBIDs. Use all returned IDs
for monitoring and accounting queries (comma-separated in `squeue`/`sacct`).

## Outputs

Generated per submission:

- `params/scenarios/generated_<timestamp>/...` (Hydra scenarios)
- `params/scenario_selector_<timestamp>.csv` (selector)

Generated per task:

- `runs/<array_job_id>/<task_id>_<scenario_id>/meta.json`
- `runs/<array_job_id>/<task_id>_<scenario_id>/results.csv`
- `runs/<array_job_id>/<task_id>_<scenario_id>/summary_event.json`
- `runs/<array_job_id>/<task_id>_<scenario_id>/merged_data.csv` (`main` mode)

Scheduler logs:

- `results/<job_name>_<array_job_id>_<task_id>.out`
- `results/<job_name>_<array_job_id>_<task_id>.err`

## Monitoring and Validation

```bash
squeue -u "$USER"
sacct -j <JOBID> --format=JobID,State,Elapsed,ExitCode
find runs/<JOBID> -name meta.json | wc -l
find runs/<JOBID> -name results.csv | wc -l
find runs/<JOBID> -name summary_event.json | wc -l
```

If submission was chunked and returned multiple IDs:

```bash
JOBS="12345,12346"
squeue -j "$JOBS"
sacct -j "$JOBS" --format=JobID,State,Elapsed,ExitCode
for J in ${JOBS//,/ }; do
  find runs/"$J" -name meta.json | wc -l
done
```

Selector row count:

```bash
python3 - <<'PY'
import csv
path = "params/scenario_selector_<timestamp>.csv"
with open(path, newline="") as f:
    print(sum(1 for _ in csv.DictReader(f)))
PY
```

## Additional Guides

- `experiments/PARAMETER_SCHEMA.md`: full supported parameter schema
- `experiments/bootstrap/README.md`: onboarding + managed-HPC bootstrap
- `experiments/obs/README.md`: observability export/push workflow
