#!/usr/bin/env python3
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


_DATA_CACHE = {}


def load_scenario(path: str) -> dict:
    if not path:
        return {}
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def resolve_input_path(path: str, scenario_file: str = "") -> str:
    candidate = Path(path)
    if candidate.is_absolute() or not scenario_file:
        return str(candidate)
    return str((Path(scenario_file).resolve().parent / candidate).resolve())


def get_cached_csv(path: str):
    resolved = str(Path(path))
    if resolved not in _DATA_CACHE:
        _DATA_CACHE[resolved] = pd.read_csv(resolved, index_col=0, parse_dates=True)
    return _DATA_CACHE[resolved]


def build_signal(sig_conf: dict, *, scenario_file: str = ""):
    mode = sig_conf.get("mode", "static")

    if mode == "static":
        return vs.StaticSignal(value=float(sig_conf["value"]))

    if mode == "csv_column":
        csv_path = resolve_input_path(sig_conf["path"], scenario_file)
        column = sig_conf["column"]
        scale = float(sig_conf.get("scale", 1.0))

        df = get_cached_csv(csv_path)
        if column not in df.columns:
            raise ValueError(f"Column '{column}' not found in {csv_path}")

        series = df[column] * scale
        return vs.Trace(actual=series, fill_method="ffill")

    raise ValueError(f"Unsupported signal mode: {mode}")


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


def write_summary_event(outdir: Path, meta: dict) -> Path:
    scenario = meta.get("scenario_loaded", {}) if isinstance(meta, dict) else {}
    actors = scenario.get("actors", []) if isinstance(scenario, dict) else []

    csv_actors_n = 0
    for actor in actors if isinstance(actors, list) else []:
        if isinstance(actor, dict):
            signal = actor.get("signal", {})
            if isinstance(signal, dict) and signal.get("mode") == "csv_column":
                csv_actors_n += 1

    step_size_s = to_number(scenario.get("step_size_s")) if isinstance(scenario, dict) else None
    until_s = to_number(scenario.get("until_s")) if isinstance(scenario, dict) else None
    sim_steps = None
    if isinstance(step_size_s, (int, float)) and isinstance(until_s, (int, float)) and step_size_s:
        sim_steps = int(until_s / step_size_s)

    battery = scenario.get("battery", {}) if isinstance(scenario, dict) else {}
    battery_capacity_wh = to_number(meta.get("battery_capacity_wh"))
    if battery_capacity_wh is None and isinstance(battery, dict):
        battery_capacity_wh = to_number(battery.get("capacity_wh"))

    results_path = outdir / "results.csv"
    meta_path = outdir / "meta.json"
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
        "meta_path": str(meta_path),
        "results_path": str(results_path) if results_path.exists() else None,
        "results_rows": rows,
        "has_results": rows > 0,
        "results_last_row": last,
        "meta": meta,
        "array_job_id": slurm_meta.get("SLURM_ARRAY_JOB_ID", "") or "",
        "array_job_id_n": to_number(slurm_meta.get("SLURM_ARRAY_JOB_ID", "")),
        "array_task_id_n": to_number(slurm_meta.get("SLURM_ARRAY_TASK_ID", "")),
        "scenario_id": meta.get("scenario_id", ""),
        "backend_mode": "simple",
        "microgrid_name": scenario.get("microgrid_name") if isinstance(scenario, dict) else "",
        "step_size_s": step_size_s,
        "until_s": until_s,
        "sim_steps": sim_steps,
        "actors_n": len(actors) if isinstance(actors, list) else 0,
        "csv_actors_n": csv_actors_n,
        "battery_capacity_wh": battery_capacity_wh,
        "battery_source": meta.get("battery_source", ""),
        "slurm_job_id": slurm_meta.get("SLURM_JOB_ID", ""),
        "slurm_array_job_id": slurm_meta.get("SLURM_ARRAY_JOB_ID", ""),
        "slurm_array_task_id": slurm_meta.get("SLURM_ARRAY_TASK_ID", ""),
        "slurm_job_name": slurm_meta.get("SLURM_JOB_NAME", ""),
        "slurm_nodelist": slurm_meta.get("SLURM_NODELIST", ""),
        "slurm_cpus_per_task": to_number(slurm_meta.get("SLURM_CPUS_PER_TASK", "")),
    }

    flat_meta = {}
    flatten_scalars("meta", meta, flat_meta)
    for key, value in flat_meta.items():
        if key not in doc:
            doc[key] = value

    result_cols = []
    for col, value in (last or {}).items():
        col_key = sanitize_key(col)
        result_cols.append(col_key)
        doc[f"result_{col_key}"] = to_number(value)
    doc["result_cols_n"] = len(result_cols)
    doc["result_cols"] = sorted(set(result_cols))

    out = outdir / "summary_event.json"
    out.write_text(json.dumps(doc, ensure_ascii=False) + "\n")
    return out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario-id", default="")
    parser.add_argument("--scenario-file", default="")
    parser.add_argument("--solar-scale-w", type=float, default=0.0)
    parser.add_argument("--battery-wh", type=float, default=0.0)
    parser.add_argument("--server-w", type=float, default=-700.0)
    parser.add_argument("--step-size-s", type=int, default=300)
    parser.add_argument("--until-s", type=int, default=2 * 3600)
    parser.add_argument("--sim-start", default="2022-06-15")
    parser.add_argument("--outdir", required=True)
    args = parser.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    scenario = load_scenario(args.scenario_file)

    sim_start = scenario.get("sim_start", args.sim_start)
    step_size_s = scenario.get("step_size_s", args.step_size_s)
    until_s = scenario.get("until_s", args.until_s)

    microgrid_name = scenario.get("microgrid_name", "datacenter")

    policy_cfg = scenario.get("policy", {})
    policy = DefaultMicrogridPolicy(
        mode=policy_cfg.get("mode", "grid-connected"),
        charge_power=policy_cfg.get("charge_power", 0.0),
    )

    if "actors" in scenario:
        actors = []
        for actor in scenario["actors"]:
            signal = build_signal(actor["signal"], scenario_file=args.scenario_file)
            actors.append(vs.Actor(name=actor["name"], signal=signal))
    else:
        actors = [
            vs.Actor(name="server", signal=vs.StaticSignal(value=args.server_w)),
            vs.Actor(name="solar_panel", signal=vs.StaticSignal(value=args.solar_scale_w)),
        ]

    if "battery" in scenario:
        battery_cfg = scenario.get("battery", {})
        battery_wh = max(float(battery_cfg.get("capacity_wh", 0.0)), 0.0)
        initial_soc = float(battery_cfg.get("initial_soc", 0.0))
        min_soc = float(battery_cfg.get("min_soc", 0.0))
        c_rate = battery_cfg.get("c_rate", None)
        battery_source = "scenario"
        storage = vs.SimpleBattery(
            capacity=battery_wh,
            initial_soc=initial_soc,
            min_soc=min_soc,
            c_rate=c_rate,
        )
    else:
        battery_wh = max(args.battery_wh, 0.0)
        battery_source = "cli_fallback"
        storage = vs.SimpleBattery(capacity=battery_wh)

    meta = {
        "scenario_id": args.scenario_id,
        "scenario_file": args.scenario_file,
        "sim_start": sim_start,
        "step_size_s": step_size_s,
        "until_s": until_s,
        "microgrid_name": microgrid_name,
        "policy": policy_cfg,
        "battery_capacity_wh": battery_wh,
        "battery_source": battery_source,
        "scenario_loaded": scenario,
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

    start = time.perf_counter()
    env = vs.Environment(sim_start=sim_start, step_size=step_size_s)

    microgrid = env.add_microgrid(
        name=microgrid_name,
        actors=actors,
        storage=storage,
        policy=policy,
    )
    monitor = vs.Monitor([microgrid], outfile=str(outdir / "results.csv"))
    env.add_controller(monitor)

    env.run(until=until_s)
    summary_path = write_summary_event(outdir, meta)
    print(
        f"done walltime_s={time.perf_counter()-start:.3f} "
        f"outdir={outdir} summary={summary_path}"
    )


if __name__ == "__main__":
    main()
