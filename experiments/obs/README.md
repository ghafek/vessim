# Observability Bridge (Portable)

This directory provides a cluster-agnostic way to export workflow data and push
it into an existing Elasticsearch/Kibana stack.

Stack provisioning is optional and environment-specific.

- Managed HPC (no Docker privileges): use exporters + push to external Elastic.
- Self-managed hosts (Azure VM, lab server): use
  `experiments/bootstrap/provision_obs_stack.sh`.

## Data Sources

- `collect_sacct.py`: exports SLURM accounting from `sacct`.
- `collect_runs.py`: exports per-task run summaries from `runs/*/*/summary_event.json`.
- `push_ndjson.py`: pushes NDJSON docs to Elasticsearch `_bulk`.

## 1) Export accounting

```bash
python3 experiments/obs/collect_sacct.py \
  --since now-7days \
  --job-ids 315,324 \
  --out results/obs/slurm_accounting.ndjson
```

## 2) Export run summaries

```bash
python3 experiments/obs/collect_runs.py \
  --runs-root runs \
  --job-ids 315,324 \
  --out results/obs/vessim_runs.ndjson
```

## 3) Push to Elasticsearch

```bash
python3 experiments/obs/push_ndjson.py \
  --in results/obs/slurm_accounting.ndjson \
  --elastic-url http://localhost:9200 \
  --index slurm-accounting

python3 experiments/obs/push_ndjson.py \
  --in results/obs/vessim_runs.ndjson \
  --elastic-url http://localhost:9200 \
  --index vessim-runs \
  --id-field event_id
```

For secured Elasticsearch, add `--username` and `--password`.

## Optional local stack (self-managed only)

Render/start local stack via:

```bash
experiments/bootstrap/provision_obs_stack.sh \
  --profile /path/to/cluster.env \
  --start
```

If ports are already in use, set `OBS_ES_PORT`, `OBS_KIBANA_PORT`, and
`OBS_GRAFANA_PORT` in profile before starting, and set `OBS_ELASTIC_URL` to the
matching Elasticsearch endpoint.

## SLURM Accounting Requirement

`sacct` export requires cluster accounting to be configured by admins, usually:

- `AccountingStorageType=accounting_storage/slurmdbd`
- `JobAcctGatherType=jobacct_gather/*`

`experiments/setup_env.sh` now reports these values.
