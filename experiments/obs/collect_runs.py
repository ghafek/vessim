#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs-root", required=True)
    parser.add_argument("--job-ids", default="", help="Comma-separated array IDs to include (optional)")
    parser.add_argument("--cluster", default=os.environ.get("CLUSTER_NAME", "unknown-cluster"))
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    allowed = {x.strip() for x in args.job_ids.split(",") if x.strip()}
    runs_root = Path(args.runs_root)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    count = 0
    with out_path.open("w", encoding="utf-8") as out:
        if not runs_root.exists():
            print(f"Wrote 0 run docs to {out_path} (runs root not found)")
            return

        for job_dir in sorted(runs_root.iterdir()):
            if not job_dir.is_dir():
                continue
            if allowed and job_dir.name not in allowed:
                continue
            for task_dir in sorted(job_dir.iterdir()):
                if not task_dir.is_dir():
                    continue
                summary_file = task_dir / "summary_event.json"
                if not summary_file.exists():
                    continue
                try:
                    doc = json.loads(summary_file.read_text(encoding="utf-8"))
                except Exception:
                    continue
                doc.setdefault("cluster", args.cluster)
                doc.setdefault("array_job_id", job_dir.name)
                out.write(json.dumps(doc, ensure_ascii=False) + "\n")
                count += 1

    print(f"Wrote {count} run docs to {out_path}")


if __name__ == "__main__":
    main()
