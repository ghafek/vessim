# Large Array Simulation Guide (Paper-Compatible with Current Operator)

This document maps the paper workload to the current codebase in `/Users/ghafekalsaho/vessim`.

It is based on:

- PDF: `/Users/ghafekalsaho/VessimCollection/Abgabe/2508.04284v2.pdf`
- Repo: `https://github.com/dos-group/vessim-opt`

## 1) What workload to reproduce

Paper-style exhaustive capacity sweep:

- `wind_system_capacity`: 11 values (`0..30000`, step `3000`)
- `solar_system_capacity`: 11 values (`0..40000`, step `4000`)
- `battery_capacity`: 9 values (`0..60000`, step `7500`)
- Total combinations: `11 x 11 x 9 = 1089`

Simulation baseline:

- `sim_start = 2020-01-01 00:00:00`
- `step_size_s = 60`
- `until_s = 31536000` (365 days)

## 2) How this maps to our code now

Default mode in this repo is the large simulation backend.

- Default runner: `experiments/run_scenario.py`
- Entry command: `experiments/hydra_gen/run_hybrid.sh`
- Default Hydra config: `experiments/hydra_gen/conf/config.yaml`
- Optional lightweight mode: `PPVS_MODE=simple` with `config_simple.yaml`

Main mode behavior:

- uses SAM (PySAM Windpower/Pvwattsv8)
- uses capacity parameters (`wind_system_capacity`, `solar_system_capacity`, `battery_capacity`)
- supports CLC battery path
- writes `results.csv`, `merged_data.csv`, `meta.json`, `summary_event.json`

## 3) Differences vs original paper repo

Same intent:

- same parameter semantics and full 1089 grid
- same high-level simulation structure (renewables + battery + carbon merge)

Different implementation path (intended improvement):

- our workflow is Hydra -> selector CSV -> SLURM array (portable operator path)
- submission/monitoring is automated and cluster-agnostic
- no manual per-run orchestration needed

This is expected for the project goal.

## 4) Required input files for paper-compatible main mode

When using paper-compatible filename mapping, these are expected under
`PPVS_DATA_DIR` (default `${PPVS_PARAMS_DIR}/data`):

- `power_data_ce.csv`
- `wind_data_berkeley.csv`
- `solar_data_berkeley.csv`
- `pvwatts_config.json`
- `windpower_config.json`
- `Wind_Turbines.csv`
- `US-CAL-CISO_2024_hourly.csv`

Practical source:

- copy these files from `dos-group/vessim-opt/data` into `params/data/` of your runtime.

## 5) What still needs to be prepared before full TU run

1. Ensure all required data files exist in `PPVS_DATA_DIR`.
2. Ensure Python env has `nrel-pysam` (handled by install script in main mode).
3. Set realistic array throttle for cluster capacity.
4. Confirm SLURM limits (partition, time, memory, account) in cluster profile.
5. If `MaxArraySize` is below 1089, submission is auto-split into multiple arrays.

No TU action should start before these checks pass.

## 6) Commands with current code

Use your profile path in all commands:

```bash
PROFILE=experiments/profiles/mycluster.env
```

Pre-check and env:

```bash
bash experiments/bootstrap/preflight_cluster.sh --profile "$PROFILE" --strict
bash experiments/bootstrap/install_python_env.sh --profile "$PROFILE"
bash experiments/setup_env.sh --profile "$PROFILE"
```

### A) Smoke run (small)

```bash
ARRAY_THROTTLE=4 ./experiments/hydra_gen/run_hybrid.sh \
  --profile "$PROFILE" \
  wind_system_capacity=0,3000 \
  solar_system_capacity=0,4000 \
  battery_capacity=0,7500 \
  step_size_s=60 \
  until_s=7200
```

Expected tasks: `2 x 2 x 2 = 8`

### B) Medium run

```bash
ARRAY_THROTTLE=8 ./experiments/hydra_gen/run_hybrid.sh \
  --profile "$PROFILE" \
  wind_system_capacity=0,3000,6000 \
  solar_system_capacity=0,4000,8000 \
  battery_capacity=0,7500,15000 \
  step_size_s=60 \
  until_s=86400
```

Expected tasks: `3 x 3 x 3 = 27`

### C) Full 1089 submission

```bash
ARRAY_THROTTLE=32 ./experiments/hydra_gen/run_hybrid.sh \
  --profile "$PROFILE" \
  wind_system_capacity=0,3000,6000,9000,12000,15000,18000,21000,24000,27000,30000 \
  solar_system_capacity=0,4000,8000,12000,16000,20000,24000,28000,32000,36000,40000 \
  battery_capacity=0,7500,15000,22500,30000,37500,45000,52500,60000 \
  step_size_s=60 \
  until_s=31536000
```

Expected tasks: `1089`

If the cluster array limit is lower than 1089, output shows multiple job IDs and
array specs with offsets (automatic chunking).

Use all returned JOBIDs for monitoring and validation commands.

If you store this grid in a file (one override per line), the equivalent simple call is:

```bash
ARRAY_THROTTLE=32 ./experiments/hydra_gen/run_hybrid.sh \
  --profile "$PROFILE" \
  --overrides-file paper_1089_overrides.txt
```

## 7) Expected output layout

Per submission:

- `params/scenarios/generated_<timestamp>/...`
- `params/scenario_selector_<timestamp>.csv`

Per task:

- `runs/<JOBID>/<TASK>_<scenario_id>/results.csv`
- `runs/<JOBID>/<TASK>_<scenario_id>/merged_data.csv`
- `runs/<JOBID>/<TASK>_<scenario_id>/meta.json`
- `runs/<JOBID>/<TASK>_<scenario_id>/summary_event.json`

Scheduler logs:

- `results/vessim_sweep_<JOBID>_<TASK>.out`
- `results/vessim_sweep_<JOBID>_<TASK>.err`

## 8) Validation checklist

1. Selector row count is correct (`8`, `27`, `1089` depending on run).
2. `squeue/sacct` show expected task progression and no systemic failures.
3. For completed tasks, all four files exist (`results.csv`, `merged_data.csv`, `meta.json`, `summary_event.json`).
4. `meta.json` contains expected capacities and runtime fields.
5. `summary_event.json` contains backend and key metrics fields.

Quick checks:

```bash
JOB1=12345
JOB2=12346
JOBS="$JOB1,$JOB2"
sacct -j "$JOBS" --format=JobID,State,Elapsed,ExitCode
find runs/"$JOB1" runs/"$JOB2" -name meta.json | wc -l
find runs/"$JOB1" runs/"$JOB2" -name results.csv | wc -l
find runs/"$JOB1" runs/"$JOB2" -name merged_data.csv | wc -l
find runs/"$JOB1" runs/"$JOB2" -name summary_event.json | wc -l
```

## 9) Why this satisfies the project objective

The parameters and simulation semantics are aligned with the paper workload, while orchestration is improved:

- one command from SLURM head node
- reproducible Hydra Cartesian generation
- robust array submission and traceable outputs
- no manual run-by-run handling

## 10) Paper-like data inventory (compatibility mapping)

This section is a single source of truth for reference-compatible data mapping in `experiments/`.
If you need to reproduce the paper-style runs later, use this checklist directly.

### 10.1 Exact reference-compatible filename mapping

Main mode now uses generic defaults (`power_data.csv`, `wind_data.csv`, ...), but
you can switch to reference-compatible names via profile variables:

- `power_data_ce.csv`
- `wind_data_berkeley.csv`
- `solar_data_berkeley.csv`
- `pvwatts_config.json`
- `windpower_config.json`
- `Wind_Turbines.csv`
- `US-CAL-CISO_2024_hourly.csv`

Convenience source file (copy exports into your cluster profile):

- `experiments/profiles/main_data_reference_compat.env`

### 10.2 Where this mapping is used

- Mapping variables are defined in profile/env:
  - `PPVS_MAIN_DATA_PROFILE` (`generic|reference`)
  - `PPVS_MAIN_POWER_DATA_FILE`
  - `PPVS_MAIN_WIND_DATA_FILE`
  - `PPVS_MAIN_SOLAR_DATA_FILE`
  - `PPVS_MAIN_SOLAR_CONFIG_FILE`
  - `PPVS_MAIN_WIND_CONFIG_FILE`
  - `PPVS_MAIN_WIND_TURBINES_FILE`
  - `PPVS_MAIN_CARBON_DATA_FILE`
- `run_hybrid.sh` injects these into Hydra `file_paths.*`.
- `preflight_cluster.sh` and `setup_env.sh` validate files using these mappings.
- `run_scenario.py` validates required `file_paths.*` keys and file existence.

### 10.3 Minimal format contract per input file

`power_data_ce.csv`
- Parsed by `file_to_trace()` with `skiprows=1`, then columns are treated as `time,power`.
- Time is parsed with `%a %d %b %Y %H:%M:%S GMT`.
- Values interpreted as `MW`, then converted to `W`; sign is inverted for load.

`wind_data_berkeley.csv`
- Parsed by SAM helper with `skiprows=1`.
- Must provide at least: `Year, Month, Day, Hour, Minute`.
- Used as weather/resource input for `PySAM.Windpower`.

`solar_data_berkeley.csv`
- Parsed by SAM helper with `skiprows=2`.
- Must provide at least: `Year, Month, Day, Hour, Minute`.
- Used as weather/resource input for `PySAM.Pvwattsv8`.

`pvwatts_config.json`
- JSON object loaded and passed into `PySAM.Pvwattsv8`.
- `system_capacity` is overwritten at runtime from `solar_system_capacity`.

`windpower_config.json`
- JSON object loaded and passed into `PySAM.Windpower`.
- `system_capacity` and turbine/layout values are overwritten at runtime.

`Wind_Turbines.csv`
- Parsed with `header=0`, `skiprows=[1,2]`.
- Required columns:
  - `Name`
  - `kW Rating`
  - `Rotor Diameter`
  - `Power Curve Array` (pipe-separated values)
  - `Wind Speed Array` (pipe-separated values)
- Must include row for `wind_turbine_model` (default: `GE 1.5sle`).

`US-CAL-CISO_2024_hourly.csv`
- Must include timestamp column exactly: `Datetime (UTC)`.
- Must include one carbon-intensity column that either:
  - exactly matches `Carbon Intensity gCO₂eq/kWh (LCA)`, or
  - contains `carbon`, `intensity`, and `lca` (case-insensitive fallback).

### 10.4 Reproduction-ready data package (what to archive)

For future reproducibility, archive these together in one folder (or tarball):

1. The 7 dataset files above (unchanged names).
2. The exact overrides file used for the run (e.g., `paper_1089_overrides.txt`).
3. Generated selector CSV: `params/scenario_selector_<timestamp>.csv`.
4. Generated scenario folder: `params/scenarios/generated_<timestamp>/`.
5. Output folder(s): `runs/<JOBID>/` and logs in `results/`.

Recommended archive command after a run:

```bash
TS=$(date +%Y%m%d_%H%M%S)
mkdir -p export_bundle_"$TS"
cp params/scenario_selector_<timestamp>.csv export_bundle_"$TS"/
cp -r params/scenarios/generated_<timestamp> export_bundle_"$TS"/
cp -r runs/<JOBID> export_bundle_"$TS"/
cp results/vessim_sweep_<JOBID>_*.out results/vessim_sweep_<JOBID>_*.err export_bundle_"$TS"/
cp params/data/power_data_ce.csv \
   params/data/wind_data_berkeley.csv \
   params/data/solar_data_berkeley.csv \
   params/data/pvwatts_config.json \
   params/data/windpower_config.json \
   params/data/Wind_Turbines.csv \
   params/data/US-CAL-CISO_2024_hourly.csv \
   export_bundle_"$TS"/
tar -czf export_bundle_"$TS".tar.gz export_bundle_"$TS"
```

### 10.5 Quick data sanity check before submitting 1089 jobs

```bash
python3 - <<'PY'
from pathlib import Path
import pandas as pd

root = Path("params/data")
required = [
    "power_data_ce.csv",
    "wind_data_berkeley.csv",
    "solar_data_berkeley.csv",
    "pvwatts_config.json",
    "windpower_config.json",
    "Wind_Turbines.csv",
    "US-CAL-CISO_2024_hourly.csv",
]
missing = [f for f in required if not (root / f).exists()]
if missing:
    raise SystemExit(f"Missing files: {missing}")

df_t = pd.read_csv(root / "Wind_Turbines.csv", header=0, skiprows=[1,2], on_bad_lines="warn")
for c in ["Name", "kW Rating", "Rotor Diameter", "Power Curve Array", "Wind Speed Array"]:
    if c not in df_t.columns:
        raise SystemExit(f"Wind_Turbines.csv missing column: {c}")
if "GE 1.5sle" not in set(df_t["Name"].astype(str)):
    raise SystemExit("Wind_Turbines.csv missing default turbine model GE 1.5sle")

df_c = pd.read_csv(root / "US-CAL-CISO_2024_hourly.csv", nrows=5)
if "Datetime (UTC)" not in df_c.columns:
    raise SystemExit("Carbon file missing 'Datetime (UTC)'")
carbon_cols = [c for c in df_c.columns if ("carbon" in c.lower() and "intensity" in c.lower())]
if not carbon_cols:
    raise SystemExit("Carbon file missing carbon intensity column")

print("paper_data_sanity_ok")
PY
```
