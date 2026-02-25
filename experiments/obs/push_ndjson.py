#!/usr/bin/env python3
import argparse
import base64
import json
import sys
import urllib.request
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--in", dest="in_file", required=True)
    parser.add_argument("--elastic-url", required=True, help="Example: http://localhost:9200")
    parser.add_argument("--index", required=True)
    parser.add_argument("--id-field", default="", help="Use field as _id if present")
    parser.add_argument("--username", default="")
    parser.add_argument("--password", default="")
    args = parser.parse_args()

    in_path = Path(args.in_file)
    if not in_path.exists():
        raise SystemExit(f"Input file not found: {in_path}")

    docs = []
    for line in in_path.read_text(encoding="utf-8").splitlines():
        text = line.strip()
        if not text:
            continue
        docs.append(json.loads(text))

    if not docs:
        print(f"No docs in {in_path}, nothing to push.")
        return

    bulk_lines = []
    for doc in docs:
        action = {"index": {"_index": args.index}}
        if args.id_field and args.id_field in doc:
            action["index"]["_id"] = str(doc[args.id_field])
        bulk_lines.append(json.dumps(action, ensure_ascii=False))
        bulk_lines.append(json.dumps(doc, ensure_ascii=False))

    payload = ("\n".join(bulk_lines) + "\n").encode("utf-8")
    url = args.elastic_url.rstrip("/") + "/_bulk?refresh=true"
    req = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/x-ndjson"},
    )

    if args.username:
        token = base64.b64encode(f"{args.username}:{args.password}".encode()).decode()
        req.add_header("Authorization", f"Basic {token}")

    with urllib.request.urlopen(req, timeout=30) as res:
        body = res.read().decode("utf-8", errors="replace")

    response = json.loads(body)
    if response.get("errors"):
        print("Bulk insert completed with errors.", file=sys.stderr)
        print(body[:2000], file=sys.stderr)
        raise SystemExit(1)

    print(f"Pushed {len(docs)} docs to index {args.index}")


if __name__ == "__main__":
    main()
