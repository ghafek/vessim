#!/usr/bin/env python3
import vessim as vs


def main() -> None:
    environment = vs.Environment(sim_start="2022-06-15", step_size=300)

    microgrid = environment.add_microgrid(
        name="datacenter",
        actors=[
            vs.Actor(name="server", signal=vs.StaticSignal(value=-700)),
            vs.Actor(name="solar_panel", signal=vs.StaticSignal(value=500)),
        ],
        storage=vs.SimpleBattery(capacity=100),
    )

    monitor = vs.Monitor([microgrid], outfile="./results.csv")
    environment.add_controller(monitor)
    environment.run(until=2 * 3600)


if __name__ == "__main__":
    main()
