# Parameter Schema (Authoritative)

This document defines the currently supported scenario parameter schema for:

- `main` mode (default): SAM-based large simulations
- `simple` mode: lightweight static/csv signal simulations

Mode selection is done via:

- profile/env: `PPVS_MODE=main|simple`
- command prefix: `PPVS_MODE=simple ...`

## 1) Shared Top-Level Keys

These keys are available in both modes:

| Key | Type | Required | Default | Notes |
| --- | --- | --- | --- | --- |
| `scenario_id` | string/null | no | auto-generated in Hydra (`job_XXX`) | logical scenario label |
| `sim_start` | datetime/string | no | mode-specific config default | simulation start timestamp |
| `step_size_s` | integer | no | mode-specific config default | simulation step size in seconds |
| `until_s` | integer | no | mode-specific config default | simulation duration in seconds |
| `microgrid_name` | string | no | `"datacenter"` | microgrid name used in outputs |
| `policy.mode` | string | no | `"grid-connected"` | passed to `DefaultMicrogridPolicy` |
| `policy.charge_power` | number | no | `0.0` | passed to `DefaultMicrogridPolicy` |

## 2) Main Mode Schema (`PPVS_MODE=main`)

Main mode is validated strictly in `experiments/run_scenario.py` via `validate_main_scenario()`.

### 2.1 Required keys

| Key | Type | Unit | Notes |
| --- | --- | --- | --- |
| `wind_system_capacity` | number | kW | wind system size |
| `solar_system_capacity` | number | kW | solar system size |
| `battery_capacity` | number | kWh | battery capacity |
| `single_cell_capacity` | number | Wh | per-cell capacity for `ClcBattery` parametrization |
| `wind_turbine_model` | string | - | must exist in `file_paths.wind_turbines` CSV |
| `file_paths.power_data` | path | - | load trace CSV |
| `file_paths.wind_data` | path | - | wind weather/resource data |
| `file_paths.solar_data` | path | - | solar weather/resource data |
| `file_paths.solar_config` | path | - | PVWatts SAM config JSON |
| `file_paths.wind_config` | path | - | Windpower SAM config JSON |
| `file_paths.wind_turbines` | path | - | turbine specs CSV |
| `file_paths.carbon_data` | path | - | carbon intensity CSV |

### 2.2 Optional keys (main)

Shared top-level keys (`scenario_id`, `sim_start`, `step_size_s`, `until_s`, `microgrid_name`, `policy.*`) are optional and defaulted if missing.

### 2.3 Path resolution rules

`file_paths.*` entries can be:

- absolute paths
- relative to the scenario YAML directory
- otherwise resolved relative to current working directory

When scenarios are generated through `run_hybrid.sh` in `main` mode, these
`file_paths.*` values are injected from profile variables:

- `PPVS_MAIN_POWER_DATA_FILE`
- `PPVS_MAIN_WIND_DATA_FILE`
- `PPVS_MAIN_SOLAR_DATA_FILE`
- `PPVS_MAIN_SOLAR_CONFIG_FILE`
- `PPVS_MAIN_WIND_CONFIG_FILE`
- `PPVS_MAIN_WIND_TURBINES_FILE`
- `PPVS_MAIN_CARBON_DATA_FILE`

### 2.4 Minimal main-mode example

```yaml
scenario_id: "main_example"
sim_start: "2020-01-01 00:00:00"
step_size_s: 60
until_s: 7200
microgrid_name: "datacenter"

policy:
  mode: "grid-connected"
  charge_power: 0.0

wind_system_capacity: 3000
solar_system_capacity: 4000
wind_turbine_model: "GE 1.5sle"
battery_capacity: 7500
single_cell_capacity: 19.14

file_paths:
  power_data: "params/data/power_data.csv"
  wind_data: "params/data/wind_data.csv"
  solar_data: "params/data/solar_data.csv"
  solar_config: "params/data/solar_config.json"
  wind_config: "params/data/wind_config.json"
  wind_turbines: "params/data/wind_turbines.csv"
  carbon_data: "params/data/carbon_data.csv"
```

## 3) Simple Mode Schema (`PPVS_MODE=simple`)

Simple mode is interpreted in `experiments/simple/run_scenario_simple.py`.
It is flexible and does not enforce a strict required-key validator like main mode.

### 3.1 Battery keys (optional group)

| Key | Type | Required | Default | Notes |
| --- | --- | --- | --- | --- |
| `battery.capacity_wh` | number | no | `0.0` | if no `battery` block, CLI fallback is used |
| `battery.initial_soc` | number | no | `0.0` | [0..1] expected by battery model |
| `battery.min_soc` | number | no | `0.0` | [0..1] |
| `battery.c_rate` | number/null | no | `null` | optional |

### 3.2 Actor keys

| Key | Type | Required | Notes |
| --- | --- | --- | --- |
| `actors[].name` | string | yes (if `actors` block used) | actor label |
| `actors[].signal.mode` | string | yes | `static` or `csv_column` |
| `actors[].signal.value` | number | required for `static` | power value |
| `actors[].signal.path` | path | required for `csv_column` | CSV input path |
| `actors[].signal.column` | string | required for `csv_column` | column name in CSV |
| `actors[].signal.scale` | number | optional for `csv_column` | default `1.0` |

If no `actors` block is provided, internal defaults are used (`server` static load + `solar_panel` static generation from CLI args).

### 3.3 Minimal simple-mode example

```yaml
scenario_id: "simple_example"
sim_start: "2022-06-15"
step_size_s: 300
until_s: 7200
microgrid_name: "datacenter"

policy:
  mode: "grid-connected"
  charge_power: 0.0

actors:
  - name: "server"
    signal: {mode: static, value: -700}
  - name: "solar_panel"
    signal:
      mode: "csv_column"
      path: "datasets/solcast2022_germany_actual.csv"
      column: "Berlin"
      scale: 1.0

battery:
  capacity_wh: 250
  initial_soc: 0.2
  min_soc: 0.1
  c_rate: null
```

## 4) Hydra Override Input Format

Override format (CLI or `--overrides-file`):

- one override token per argument/line
- examples:
  - `wind_system_capacity=0,3000,6000`
  - `battery_capacity=0,7500,15000`
  - `step_size_s=60`

For file input:

```bash
./experiments/hydra_gen/run_hybrid.sh \
  --profile experiments/profiles/mycluster.env \
  --overrides-file my_overrides.txt
```

`my_overrides.txt` and `my_overrides.csv` are both supported if they contain one Hydra override per line.

## 5) Selector CSV Schema

The array selector CSV format is fixed:

```csv
scenario_id,scenario_file
job_000,/path/to/scenario.yaml
job_001,/path/to/scenario.yaml
```

This CSV maps array task index to scenario YAML file. Simulation parameters are defined in YAML, not in selector CSV.
