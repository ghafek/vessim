#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def to_mb(value: str):
    if not value:
        return None
    match = re.match(r"^\s*([0-9.]+)\s*([KMGT]?)\s*$", value)
    if not match:
        return None
    amount = float(match.group(1))
    unit = match.group(2)
    factor = {"": 1 / 1024, "K": 1 / 1024, "M": 1, "G": 1024, "T": 1024 * 1024}[unit]
    return amount * factor


def to_int(value: str):
    try:
        return int(value)
    except Exception:
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--since", default="now-7days")
    parser.add_argument("--job-ids", default="", help="Comma-separated job IDs (optional)")
    parser.add_argument("--cluster", default=os.environ.get("CLUSTER_NAME", "unknown-cluster"))
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    cmd = [
        "sacct",
        "-n",
        "-P",
        "-S",
        args.since,
        "--format=JobID,JobName,Partition,State,ExitCode,ElapsedRaw,AllocCPUS,ReqMem,MaxRSS,AveRSS,NodeList,User",
    ]
    if args.job_ids.strip():
        cmd.extend(["-j", args.job_ids.strip()])

    raw = subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT)
    ts = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with out_path.open("w", encoding="utf-8") as f:
        for line in raw.strip().splitlines():
            parts = line.split("|")
            if len(parts) < 12:
                continue
            (
                job_id,
                job_name,
                partition,
                state,
                exit_code,
                elapsed_raw,
                alloc_cpus,
                req_mem,
                max_rss,
                ave_rss,
                node,
                user,
            ) = parts[:12]

            doc = {
                "@timestamp": ts,
                "cluster": args.cluster,
                "job_id": job_id,
                "job_name": job_name,
                "partition": partition,
                "state": state,
                "exit_code": exit_code,
                "elapsed_raw_s": to_int(elapsed_raw),
                "alloc_cpus": to_int(alloc_cpus),
                "req_mem": req_mem,
                "max_rss": max_rss,
                "max_rss_mb": to_mb(max_rss),
                "ave_rss": ave_rss,
                "ave_rss_mb": to_mb(ave_rss),
                "node": node,
                "user": user,
            }
            f.write(json.dumps(doc, ensure_ascii=False) + "\n")
            count += 1

    print(f"Wrote {count} accounting docs to {out_path}")


if __name__ == "__main__":
    main()
