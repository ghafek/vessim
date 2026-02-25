#!/usr/bin/env python3
import argparse
import csv
from pathlib import Path

import yaml


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sweep-dir", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    sweep_dir = Path(args.sweep_dir)
    if not sweep_dir.exists():
        raise SystemExit(f"Sweep directory does not exist: {sweep_dir}")
    rows = []

    for run_dir in sorted(sweep_dir.iterdir()):
        if not run_dir.is_dir():
            continue
        scenario_path = run_dir / "scenario.yaml"
        if scenario_path.exists():
            with scenario_path.open() as f:
                data = yaml.safe_load(f) or {}
            scenario_id = data.get("scenario_id", run_dir.name)
            rows.append((scenario_id, str(scenario_path)))

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["scenario_id", "scenario_file"])
        writer.writerows(rows)

    print(f"Wrote CSV: {out}")


if __name__ == "__main__":
    main()
