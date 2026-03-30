#!/usr/bin/env python3
"""Default scenario runner: large real-world backend with SAM + CLC battery."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import vessim as vs
import yaml
from vessim.policy import DefaultMicrogridPolicy

from backend.sam_helpers import (
    build_solar_config,
    build_wind_config,
    file_to_trace,
    sam_to_trace,
)


def load_scenario(path: str) -> dict:
    if not path:
        return {}
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def to_number(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value
    if not isinstance(value, str):
        return value
    text = value.strip()
    if not text:
        return value
    if re.match(r"^-?\d+$", text):
        try:
            return int(text)
        except Exception:
            return value
    if re.match(r"^-?\d+\.\d+$", text):
        try:
            return float(text)
        except Exception:
            return value
    return value


def sanitize_key(key):
    key = str(key or "").strip()
    key = re.sub(r"[^A-Za-z0-9_]+", "_", key)
    key = re.sub(r"_+", "_", key).strip("_")
    return key.lower() or "field"


def flatten_scalars(prefix, value, out):
    if isinstance(value, dict):
        for key, sub in value.items():
            sub_key = sanitize_key(key)
            next_prefix = f"{prefix}_{sub_key}" if prefix else sub_key
            flatten_scalars(next_prefix, sub, out)
        return
    if isinstance(value, list):
        out[f"{prefix}_count"] = len(value)
        if value and all(not isinstance(item, (dict, list)) for item in value):
            out[prefix] = [to_number(item) for item in value]
        return
    out[prefix] = to_number(value)


def read_results_tail(results_path: Path):
    rows = 0
    last = {}
    if not results_path.exists():
        return rows, last
    try:
        with results_path.open(newline="", encoding="utf-8", errors="replace") as f:
            for row in csv.DictReader(f):
                rows += 1
                last = row
    except Exception:
        return rows, last
    return rows, last


def find_carbon_intensity_col(df: pd.DataFrame) -> str:
    preferred = "Carbon Intensity gCO₂eq/kWh (LCA)"
    if preferred in df.columns:
        return preferred
    # Fallback for accidental capitalization differences.
    for c in df.columns:
        if "carbon" in c.lower() and "intensity" in c.lower() and "lca" in c.lower():
            return c
    raise ValueError(
        f"No LCA carbon intensity column found. Available columns: {list(df.columns)}"
    )


def _resolve_data_path(path_val: str, scenario_file: str) -> str:
    p = Path(path_val).expanduser()
    if p.is_absolute():
        return str(p)
    if scenario_file:
        scen_dir = Path(scenario_file).resolve().parent
        cand = (scen_dir / p).resolve()
        if cand.exists():
            return str(cand)
    return str((Path.cwd() / p).resolve())


def compute_metrics_and_merge(df: pd.DataFrame, scenario: dict, outdir: Path) -> dict:
    step_size_s = int(scenario.get("step_size_s", 60))
    if step_size_s <= 0:
        raise ValueError(f"Invalid step_size_s for postprocessing: {step_size_s}")

    file_paths = scenario.get("file_paths", {})
    carbon_data_path = _resolve_data_path(file_paths.get("carbon_data", ""), scenario.get("scenario_file", ""))
    carbon_data = pd.read_csv(carbon_data_path, parse_dates=["Datetime (UTC)"])
    carbon_data["Datetime (UTC)"] = pd.to_datetime(carbon_data["Datetime (UTC)"])
    carbon_data.set_index("Datetime (UTC)", inplace=True)
    carbon_data.index = carbon_data.index.tz_localize(None)

    carbon_col = find_carbon_intensity_col(carbon_data)
    carbon_data = carbon_data[[carbon_col]].rename(columns={carbon_col: "carbon_intensity"})

    carbon_data_resampled = carbon_data.resample(f"{step_size_s}s").ffill()
    carbon_data_filtered = carbon_data_resampled.loc[df.index.min() : df.index.max()]

    merged_data = df.merge(carbon_data_filtered, left_index=True, right_index=True, how="left")

    dt_h = step_size_s / 3600.0

    merged_data["total_consumption"] = merged_data["actor_states.ComputingSystem.p"]
    merged_data["total_renewable_power"] = (
        merged_data["actor_states.Wind.p"] + merged_data["actor_states.Solar.p"]
    )

    e_load = merged_data["total_consumption"].abs() * dt_h
    e_renew = merged_data["total_renewable_power"] * dt_h

    if "storage_state.charge_level" in merged_data.columns:
        dsoc_wh = merged_data["storage_state.charge_level"].diff().fillna(0)
        e_batt = (-dsoc_wh).clip(lower=0)
    else:
        e_batt = pd.Series(0.0, index=merged_data.index)

    e_nonren = (e_load - (e_renew + e_batt)).clip(lower=0)
    merged_data["carbon_emissions"] = (e_nonren / 1000.0) * merged_data["carbon_intensity"]

    cov = (e_renew + e_batt) / e_load.replace({0: pd.NA})
    merged_data["coverage"] = cov.clip(0, 1) * 100

    merged_data.to_csv(outdir / "merged_data.csv")

    wind_cap = float(scenario.get("wind_system_capacity", 0.0))
    solar_cap = float(scenario.get("solar_system_capacity", 0.0))
    batt_cap = float(scenario.get("battery_capacity", 0.0))

    total_embodied_carbon_intensity = {
        "wind": 349,  # kgCO2/kWp over lifetime
        "solar": 412,  # kgCO2/kWp over lifetime
        "battery": 74,  # kgCO2/kWh capacity
    }

    initial_embodied_gco2 = (
        wind_cap * total_embodied_carbon_intensity["wind"]
        + solar_cap * total_embodied_carbon_intensity["solar"]
        + batt_cap * total_embodied_carbon_intensity["battery"]
    ) * 1000.0

    op_emissions_g = float(merged_data["carbon_emissions"].sum())
    coverage_pct = float(merged_data["coverage"].mean())

    return {
        "paper_initial_embodied_gco2": initial_embodied_gco2,
        "paper_operational_emissions_total_gco2": op_emissions_g,
        "paper_coverage_mean_pct": coverage_pct,
        "paper_rows": int(len(merged_data)),
    }


def write_summary_event(outdir: Path, meta: dict) -> Path:
    scenario = meta.get("scenario_loaded", {}) if isinstance(meta, dict) else {}
    results_path = outdir / "results.csv"
    rows, last = read_results_tail(results_path)

    slurm_meta = meta.get("slurm", {}) if isinstance(meta, dict) else {}
    event_id = hashlib.sha1(str(outdir).encode()).hexdigest()

    doc = {
        "@timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "event_id": event_id,
        "cluster": os.environ.get("CLUSTER_NAME", "unknown-cluster"),
        "source": "run_scenario",
        "run_dir": str(outdir),
        "run_leaf": outdir.name,
        "meta_path": str(outdir / "meta.json"),
        "results_path": str(results_path) if results_path.exists() else None,
        "results_rows": rows,
        "has_results": rows > 0,
        "results_last_row": last,
        "meta": meta,
        "array_job_id": slurm_meta.get("SLURM_ARRAY_JOB_ID", "") or "",
        "array_job_id_n": to_number(slurm_meta.get("SLURM_ARRAY_JOB_ID", "")),
        "array_task_id_n": to_number(slurm_meta.get("SLURM_ARRAY_TASK_ID", "")),
        "scenario_id": meta.get("scenario_id", ""),
        "sim_start": scenario.get("sim_start", ""),
        "step_size_s": to_number(scenario.get("step_size_s", "")),
        "until_s": to_number(scenario.get("until_s", "")),
        "wind_system_capacity": to_number(scenario.get("wind_system_capacity", "")),
        "solar_system_capacity": to_number(scenario.get("solar_system_capacity", "")),
        "battery_capacity": to_number(scenario.get("battery_capacity", "")),
        "battery_initial_soc": to_number(scenario.get("battery_initial_soc", "")),
        "backend_mode": "main",
    }

    flat_meta = {}
    flatten_scalars("meta", meta, flat_meta)
    for key, value in flat_meta.items():
        if key not in doc:
            doc[key] = value

    for col, value in (last or {}).items():
        col_key = sanitize_key(col)
        doc[f"result_{col_key}"] = to_number(value)

    out = outdir / "summary_event.json"
    out.write_text(json.dumps(doc, ensure_ascii=False) + "\n")
    return out


def validate_main_scenario(scenario: dict) -> None:
    missing = []
    for key in [
        "wind_system_capacity",
        "solar_system_capacity",
        "battery_capacity",
        "single_cell_capacity",
        "wind_turbine_model",
        "file_paths",
    ]:
        if key not in scenario:
            missing.append(key)

    file_paths = scenario.get("file_paths", {})
    for k in [
        "power_data",
        "wind_data",
        "solar_data",
        "solar_config",
        "wind_config",
        "wind_turbines",
        "carbon_data",
    ]:
        if k not in file_paths:
            missing.append(f"file_paths.{k}")

    if missing:
        raise ValueError(
            "Scenario is not compatible with default backend. Missing: " + ", ".join(missing)
        )

    battery_initial_soc = scenario.get("battery_initial_soc", 0.0)
    try:
        battery_initial_soc = float(battery_initial_soc)
    except (TypeError, ValueError) as exc:
        raise ValueError(
            f"Invalid battery_initial_soc={battery_initial_soc!r}. Expected a number in [0, 1]."
        ) from exc
    if not 0.0 <= battery_initial_soc <= 1.0:
        raise ValueError(
            f"Invalid battery_initial_soc={battery_initial_soc}. Expected a number in [0, 1]."
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario-id", default="")
    parser.add_argument("--scenario-file", default="")
    parser.add_argument("--step-size-s", type=int, default=60)
    parser.add_argument("--until-s", type=int, default=24 * 3600)
    parser.add_argument("--sim-start", default="2020-01-01 00:00:00")
    parser.add_argument("--outdir", required=True)
    args = parser.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    scenario = load_scenario(args.scenario_file)
    validate_main_scenario(scenario)

    # Keep scenario file path available for path resolution in helpers.
    scenario["scenario_file"] = args.scenario_file

    sim_start = scenario.get("sim_start", args.sim_start)
    step_size_s = int(scenario.get("step_size_s", args.step_size_s))
    until_s = int(scenario.get("until_s", args.until_s))
    microgrid_name = scenario.get("microgrid_name", "datacenter")

    file_paths = scenario["file_paths"]
    power_data = _resolve_data_path(file_paths["power_data"], args.scenario_file)
    wind_data = _resolve_data_path(file_paths["wind_data"], args.scenario_file)
    solar_data = _resolve_data_path(file_paths["solar_data"], args.scenario_file)
    solar_config_path = _resolve_data_path(file_paths["solar_config"], args.scenario_file)
    wind_config_path = _resolve_data_path(file_paths["wind_config"], args.scenario_file)
    wind_turbines_path = _resolve_data_path(file_paths["wind_turbines"], args.scenario_file)

    for p in [
        power_data,
        wind_data,
        solar_data,
        solar_config_path,
        wind_config_path,
        wind_turbines_path,
        _resolve_data_path(file_paths["carbon_data"], args.scenario_file),
    ]:
        if not Path(p).exists():
            raise FileNotFoundError(f"Required input file not found: {p}")

    wind_system_capacity = float(scenario.get("wind_system_capacity", 0.0))
    solar_system_capacity = float(scenario.get("solar_system_capacity", 0.0))
    battery_capacity_kwh = float(scenario.get("battery_capacity", 0.0))
    battery_initial_soc = float(scenario.get("battery_initial_soc", 0.0))
    single_cell_capacity_wh = float(scenario.get("single_cell_capacity", 19.14))
    wind_turbine_model = str(scenario.get("wind_turbine_model", "GE 1.5sle"))

    wind_config = build_wind_config(
        wind_config_path=wind_config_path,
        wind_turbines_csv=wind_turbines_path,
        wind_turbine_model=wind_turbine_model,
        wind_system_capacity_kw=wind_system_capacity,
    )
    solar_config = build_solar_config(
        solar_config_path=solar_config_path,
        solar_system_capacity_kw=solar_system_capacity,
    )

    policy_cfg = scenario.get("policy", {})
    policy = DefaultMicrogridPolicy(
        mode=policy_cfg.get("mode", "grid-connected"),
        charge_power=policy_cfg.get("charge_power", 0.0),
    )

    num_cells = int((battery_capacity_kwh * 1000) / single_cell_capacity_wh) if battery_capacity_kwh > 0 else 0

    actors = [
        vs.Actor(
            name="ComputingSystem",
            signal=file_to_trace(
                file_path=power_data,
                unit="MW",
                date_format="%a %d %b %Y %H:%M:%S GMT",
                name="Perlmutter",
                invert=True,
            ),
        ),
        vs.Actor(
            name="Wind",
            signal=sam_to_trace(
                model="Windpower",
                weather_file=wind_data,
                config_object=wind_config,
            ),
        ),
        vs.Actor(
            name="Solar",
            signal=sam_to_trace(
                model="Pvwattsv8",
                weather_file=solar_data,
                config_object=solar_config,
            ),
        ),
    ]

    start = time.perf_counter()
    env = vs.Environment(sim_start=sim_start, step_size=step_size_s)

    if battery_capacity_kwh > 0 and num_cells > 0:
        storage = vs.ClcBattery(
            number_of_cells=num_cells,
            initial_soc=battery_initial_soc,
            nom_voltage=3.63,
            min_soc=0.0,
            v_1=0.0,
            v_2=single_cell_capacity_wh,
            u_1=-0.087,
            u_2=-1.326,
            eta_c=0.95,
            eta_d=1.05,
            alpha_c=0.5,
            alpha_d=-0.5,
        )
    else:
        # Keep a storage simulator present even for zero capacity because
        # monitor/controller paths expect storage_state in outputs.
        storage = vs.SimpleBattery(capacity=0.0, initial_soc=0.0, min_soc=0.0)

    microgrid = env.add_microgrid(
        name=microgrid_name,
        actors=actors,
        storage=storage,
        policy=policy,
    )

    monitor = vs.Monitor([microgrid], outfile=str(outdir / "results.csv"))
    env.add_controller(monitor)
    env.run(until=until_s)

    df = pd.read_csv(outdir / "results.csv", parse_dates=["time"], index_col="time")
    metrics = compute_metrics_and_merge(df=df, scenario=scenario, outdir=outdir)

    meta = {
        "backend_mode": "main",
        "scenario_id": args.scenario_id,
        "scenario_file": args.scenario_file,
        "sim_start": sim_start,
        "step_size_s": step_size_s,
        "until_s": until_s,
        "microgrid_name": microgrid_name,
        "scenario_loaded": scenario,
        "paper_metrics": metrics,
        "slurm": {
            key: os.environ.get(key)
            for key in [
                "SLURM_JOB_ID",
                "SLURM_ARRAY_JOB_ID",
                "SLURM_ARRAY_TASK_ID",
                "SLURM_JOB_NAME",
                "SLURM_NODELIST",
                "SLURM_CPUS_PER_TASK",
            ]
        },
    }
    (outdir / "meta.json").write_text(json.dumps(meta, indent=2))

    summary_path = write_summary_event(outdir, meta)
    print(
        f"done backend=main walltime_s={time.perf_counter()-start:.3f} "
        f"outdir={outdir} summary={summary_path}"
    )


if __name__ == "__main__":
    main()
