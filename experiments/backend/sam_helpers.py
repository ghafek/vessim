#!/usr/bin/env python3
"""Helpers for renewable/battery simulation backend."""

from __future__ import annotations

import json
import math
import warnings
from pathlib import Path
from typing import Any

import pandas as pd
from vessim.signal import Trace


def _import_pysam_modules():
    try:
        import PySAM.Pvwattsv8 as pvwattsv8  # type: ignore
        import PySAM.Windpower as windpower  # type: ignore
    except Exception as exc:
        raise RuntimeError(
            "PySAM import failed. Install nrel-pysam in the runtime environment."
        ) from exc
    return windpower, pvwattsv8


def automatic_farm_layout(
    desired_farm_size_kw: float,
    wind_turbine_kw_rating: float,
    wind_turbine_rotor_diameter_m: float,
) -> dict[str, list[float]]:
    """Compute a simple rectangular wind farm layout like in the paper repo."""
    num_turbines = math.floor(desired_farm_size_kw / wind_turbine_kw_rating)
    if num_turbines <= 1:
        num_turbines = 1

    x = [0.0] * num_turbines
    y = [0.0] * num_turbines

    rows = math.floor(math.sqrt(num_turbines))
    if rows <= 0:
        rows = 1

    cols = num_turbines / rows
    while rows > 1 and rows * math.floor(cols) != num_turbines:
        rows -= 1
        cols = num_turbines / rows

    spacing_x = 8 * wind_turbine_rotor_diameter_m
    spacing_y = 8 * wind_turbine_rotor_diameter_m

    for i in range(1, num_turbines):
        x[i] = (i - cols * math.floor(i / cols)) * spacing_x
        y[i] = math.floor(i / cols) * spacing_y

    return {
        "wind_farm_xCoordinates": x,
        "wind_farm_yCoordinates": y,
    }


def load_wind_turbine_specs(wind_turbines_csv: str | Path, turbine_model: str) -> dict[str, Any]:
    """Load turbine parameters from the configured wind turbine specs CSV."""
    all_turbines = pd.read_csv(
        wind_turbines_csv,
        header=0,
        skiprows=[1, 2],
        on_bad_lines="warn",
    )
    rows = all_turbines[all_turbines["Name"] == turbine_model]
    if rows.empty:
        raise ValueError(f"Wind turbine model not found: {turbine_model}")

    row = rows.iloc[0]
    return {
        "kw_rating": float(row["kW Rating"]),
        "rotor_diameter": float(row["Rotor Diameter"]),
        "power_curve": [float(v) for v in str(row["Power Curve Array"]).split("|")],
        "wind_speeds": [float(v) for v in str(row["Wind Speed Array"]).split("|")],
    }


def build_wind_config(
    wind_config_path: str | Path,
    wind_turbines_csv: str | Path,
    wind_turbine_model: str,
    wind_system_capacity_kw: float,
) -> dict[str, Any]:
    """Build Windpower SAM config object from base config + turbine/model params."""
    with open(wind_config_path, "r", encoding="utf-8", errors="replace") as f:
        wind_config = json.load(f)

    specs = load_wind_turbine_specs(wind_turbines_csv, wind_turbine_model)
    num_turbines = math.floor(wind_system_capacity_kw / specs["kw_rating"])
    if num_turbines <= 1:
        num_turbines = 1
    realized_capacity_kw = num_turbines * specs["kw_rating"] if wind_system_capacity_kw > 0 else 0.0
    if wind_system_capacity_kw > 0 and not math.isclose(
        realized_capacity_kw,
        wind_system_capacity_kw,
        rel_tol=0.0,
        abs_tol=1e-9,
    ):
        warnings.warn(
            (
                f"Requested wind_system_capacity={wind_system_capacity_kw} kW is not an exact multiple "
                f"of turbine '{wind_turbine_model}' rating {specs['kw_rating']} kW. "
                f"Layout uses {num_turbines} turbine(s) for a realized turbine capacity of "
                f"{realized_capacity_kw} kW while SAM system_capacity remains "
                f"{wind_system_capacity_kw} kW for compatibility."
            ),
            RuntimeWarning,
            stacklevel=2,
        )
    layout = automatic_farm_layout(
        desired_farm_size_kw=wind_system_capacity_kw,
        wind_turbine_kw_rating=specs["kw_rating"],
        wind_turbine_rotor_diameter_m=specs["rotor_diameter"],
    )

    wind_config = {
        **wind_config,
        **layout,
        "system_capacity": wind_system_capacity_kw,
        "wind_turbine_powercurve_windspeeds": specs["wind_speeds"],
        "wind_turbine_powercurve_powerout": specs["power_curve"],
        "wind_turbine_rotor_diameter": specs["rotor_diameter"],
    }
    return wind_config


def build_solar_config(solar_config_path: str | Path, solar_system_capacity_kw: float) -> dict[str, Any]:
    """Build PVWatts SAM config object from base config + capacity."""
    with open(solar_config_path, "r", encoding="utf-8", errors="replace") as f:
        solar_config = json.load(f)
    solar_config["system_capacity"] = solar_system_capacity_kw
    return solar_config


def sam_to_trace(
    model: str,
    weather_file: str | Path,
    *,
    config_object: dict[str, Any],
    column_name: str = "power_W",
) -> Trace:
    """Run a SAM model and expose generation as Vessim trace."""
    windpower, pvwattsv8 = _import_pysam_modules()

    skiprows = 1
    if model == "Windpower":
        sam = windpower.default("WindPowerNone")
        sam.Resource.wind_resource_filename = str(weather_file)
    elif model == "Pvwattsv8":
        sam = pvwattsv8.default("PVWattsNone")
        sam.SolarResource.solar_resource_file = str(weather_file)
        skiprows = 2
    else:
        raise ValueError(f"Unsupported SAM model: {model}")

    df_weather = pd.read_csv(weather_file, skiprows=skiprows)
    df_weather["Datetime"] = pd.to_datetime(df_weather[["Year", "Month", "Day", "Hour", "Minute"]])
    df_weather.set_index("Datetime", inplace=True)

    ignored_keys: list[tuple[str, str]] = []
    for key, value in config_object.items():
        if key in {"number_inputs", "wind_resource_filename", "solar_resource_file"}:
            continue
        try:
            sam.value(key, value)
        except Exception as exc:
            ignored_keys.append((key, str(exc)))

    if ignored_keys:
        preview = ", ".join(f"{key} ({reason})" for key, reason in ignored_keys[:5])
        more = "" if len(ignored_keys) <= 5 else f", +{len(ignored_keys) - 5} more"
        warnings.warn(
            f"Ignored unsupported SAM config key(s) for {model}: {preview}{more}",
            RuntimeWarning,
            stacklevel=2,
        )

    sam.execute()

    try:
        cap = sam.value("system_capacity")
    except Exception:
        cap = None

    if cap == 0:
        actual = pd.DataFrame({column_name: 0.0}, index=df_weather.index)
        return Trace(actual=actual, fill_method="ffill", column=column_name)

    if not hasattr(sam.Outputs, "gen"):
        raise RuntimeError("SAM Outputs.gen not found for model output extraction")

    vals = list(sam.Outputs.gen)
    if len(vals) != len(df_weather.index):
        warnings.warn(
            (
                f"{model} output length mismatch for {weather_file}: "
                f"SAM returned {len(vals)} points, weather file provides {len(df_weather.index)} "
                f"timestamps. Truncating to {min(len(vals), len(df_weather.index))} points."
            ),
            RuntimeWarning,
            stacklevel=2,
        )
    n = min(len(vals), len(df_weather.index))
    # SAM gen output is kW; convert to W.
    series = pd.Series(vals[:n], index=df_weather.index[:n], name=column_name) * 1000.0

    actual = series.to_frame()
    return Trace(actual=actual, fill_method="ffill", column=column_name)


def file_to_trace(
    file_path: str | Path,
    *,
    unit: str = "W",
    date_format: str | None = None,
    name: str | None = None,
    invert: bool = False,
    column_name: str = "power_W",
) -> Trace:
    """Convert load trace CSV to Vessim trace."""
    file_path = Path(file_path)

    df = pd.read_csv(file_path, names=["time", "power"], skiprows=1)

    if date_format:
        df["time"] = pd.to_datetime(df["time"], format=date_format)
    else:
        df["time"] = pd.to_datetime(df["time"])

    df.set_index("time", inplace=True)
    df.sort_index(inplace=True)

    if not df.index.is_unique:
        raise ValueError(f"Time index must be unique in {file_path}")
    if not df.index.is_monotonic_increasing:
        raise ValueError(f"Time index must be increasing in {file_path}")

    def to_watts(power: float, unit_name: str) -> float:
        if unit_name == "W":
            return float(power)
        if unit_name == "kW":
            return float(power) * 1e3
        if unit_name == "MW":
            return float(power) * 1e6
        raise ValueError(f"Unknown unit: {unit_name}")

    df[column_name] = df["power"].astype(float).map(lambda x: to_watts(x, unit))
    if invert:
        df[column_name] = -df[column_name]

    actual = df[[column_name]]
    return Trace(actual=actual, fill_method="ffill", column=column_name, repr_=name)
