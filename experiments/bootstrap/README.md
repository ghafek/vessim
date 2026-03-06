# Bootstrap Guide (Managed SLURM Clusters)

This folder targets the realistic HPC model:

- SLURM already installed and managed by admins
- shared filesystem already available
- user has no root privileges on compute/login nodes

It supports small and large clusters (10+ / 100+ nodes) because all execution is
SLURM array-based and scheduler-driven.

If only `experiments/` is staged (without full repo), pass `--vessim-root` to
the Vessim checkout root (the directory that contains `pyproject.toml`).

`init_project.sh` defaults the venv to `PPVS_ROOT/venv/vessim` so the same
environment is visible on login and compute nodes via shared storage.

## Prerequisites

- existing SLURM deployment managed by cluster admins
- shared project path visible from login and compute nodes
- `python3` (3.9+) available directly or via environment modules
- SLURM commands in PATH: `scontrol`, `sinfo`, `sbatch`, `srun`, `sacct`
- checkout root for editable install must contain `pyproject.toml` (or `setup.py`)

## 1) Initialize project runtime

Create runtime paths and generate profile:

```bash
experiments/bootstrap/init_project.sh \
  --root /beegfs/$USER/ppvs_runtime \
  --cluster-name tu-hpc \
  --partition standard \
  --account cit \
  --vessim-root /beegfs/$USER/ppvs_repo
```

Main-mode dataset filenames are profile-driven and default to generic names
(`power_data.csv`, `wind_data.csv`, ...). Set `PPVS_MAIN_DATA_PROFILE=reference`
or copy reference exports from:

```bash
cat experiments/profiles/main_data_reference_compat.env
```

Typical usage:

```bash
cat experiments/profiles/main_data_reference_compat.env >> /beegfs/$USER/ppvs_runtime/profiles/cluster.env
```

## 2) Run preflight checks

```bash
experiments/bootstrap/preflight_cluster.sh \
  --profile /beegfs/$USER/ppvs_runtime/profiles/cluster.env \
  --strict
```

Checks include:

- SLURM CLI and controller availability
- accounting config visibility (`scontrol show config`)
- runtime path read/write checks
- compute-node visibility of shared runtime path

## 3) Install Python env (mode-aware dependencies)

```bash
experiments/bootstrap/install_python_env.sh \
  --profile /beegfs/$USER/ppvs_runtime/profiles/cluster.env
```

Default behavior:

- installs workflow dependencies (`vessim`, Hydra, YAML, pandas)
- in `main` mode also installs `nrel-pysam`
- installs Optuna only if `PPVS_REQUIRE_OPTUNA=1`

Optional module-based Python:

```bash
experiments/bootstrap/install_python_env.sh \
  --profile /beegfs/$USER/ppvs_runtime/profiles/cluster.env \
  --python-module python/3.9.19
```

By default, bootstrap packages (`pip`, `setuptools`, `wheel`) are only installed
if missing. To force upgrade them on an existing venv:

```bash
experiments/bootstrap/install_python_env.sh \
  --profile /beegfs/$USER/ppvs_runtime/profiles/cluster.env \
  --upgrade-bootstrap
```

If compute resources are temporarily unavailable and you only want login-node
validation, you can skip the compute import probe:

```bash
experiments/bootstrap/install_python_env.sh \
  --profile /beegfs/$USER/ppvs_runtime/profiles/cluster.env \
  --skip-compute-check
```

## 4) Run workflow

```bash
experiments/setup_env.sh \
  --profile /beegfs/$USER/ppvs_runtime/profiles/cluster.env

experiments/submit_sweep.sh \
  --profile /beegfs/$USER/ppvs_runtime/profiles/cluster.env \
  wind_system_capacity=0,3000,6000 \
  solar_system_capacity=0,4000,8000 \
  battery_capacity=0,7500,15000 \
  step_size_s=60 \
  until_s=1800
```

To run lightweight legacy scenarios instead:

```bash
PPVS_MODE=simple experiments/submit_sweep.sh \
  --profile /beegfs/$USER/ppvs_runtime/profiles/cluster.env \
  battery.capacity_wh=0,100,300 \
  actors.1.signal.value=1000,2000 \
  step_size_s=60 \
  until_s=3600
```

If you keep overrides in a file (one override per line), use:

```bash
experiments/submit_sweep.sh \
  --profile /beegfs/$USER/ppvs_runtime/profiles/cluster.env \
  --overrides-file my_overrides.txt
```

## Optional observability stack (self-managed clusters only)

For environments where Docker is allowed (for example Azure controller VM):

```bash
experiments/bootstrap/provision_obs_stack.sh \
  --profile /shared/ppvs_runtime/profiles/cluster.env \
  --start
```

If default ports are occupied, set these in your profile first:

- `OBS_ES_PORT` (default `9200`)
- `OBS_KIBANA_PORT` (default `5601`)
- `OBS_GRAFANA_PORT` (default `3000`)
- `OBS_BIND_ADDRESS` (default `127.0.0.1`)
- `OBS_ELASTIC_URL` (set to `http://localhost:<OBS_ES_PORT>` for exporters)

For managed HPC without Docker privileges:

- skip local stack provisioning
- use `experiments/obs/collect_*.py` and push to external Elasticsearch

## Scope Clarification

These scripts do not install or reconfigure SLURM daemons (`slurmctld/slurmd`)
or storage backends. They provision PPVS project runtime on top of existing
cluster infrastructure.
