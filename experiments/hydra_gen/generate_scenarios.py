#!/usr/bin/env python3
import hydra
from hydra.core.hydra_config import HydraConfig
from omegaconf import DictConfig, OmegaConf
from pathlib import Path
import yaml


@hydra.main(version_base=None, config_path="conf", config_name="config")
def main(cfg: DictConfig) -> None:
    scenario = OmegaConf.to_container(cfg, resolve=True)
    job_num = HydraConfig.get().job.num
    if not scenario.get("scenario_id"):
        scenario["scenario_id"] = f"job_{job_num:03d}"

    outdir = Path(HydraConfig.get().runtime.output_dir)
    scenario_path = outdir / "scenario.yaml"
    scenario_path.parent.mkdir(parents=True, exist_ok=True)

    with scenario_path.open("w") as f:
        yaml.safe_dump(scenario, f, sort_keys=False)

    print(f"Wrote scenario: {scenario_path}")


if __name__ == "__main__":
    main()
