#!/usr/bin/env python3
"""Minimal CPU-temperature fan controller with a local Unix-socket API."""

from __future__ import annotations

import argparse
import grp
import json
import os
import signal
import socketserver
import threading
import time
from pathlib import Path


DEFAULT_CONFIG = Path("/etc/omarchy-thermals/config.json")
DEFAULT_STATE = Path("/var/lib/omarchy-thermals/state.json")
DEFAULT_SOCKET = Path("/run/omarchy-thermals/control.sock")


def read_number(path: Path) -> float | None:
    try:
        return float(path.read_text().strip())
    except (OSError, ValueError):
        return None


def hwmon_named(name: str) -> Path | None:
    for directory in sorted(Path("/sys/class/hwmon").glob("hwmon*")):
        try:
            if directory.joinpath("name").read_text().strip() == name:
                return directory
        except OSError:
            pass
    return None


def discover_controller(preferred: str | None) -> Path | None:
    if preferred:
        match = hwmon_named(preferred)
        if match and list(match.glob("pwm[0-9]")):
            return match
    candidates = []
    for directory in sorted(Path("/sys/class/hwmon").glob("hwmon*")):
        if list(directory.glob("pwm[0-9]")):
            candidates.append(directory)
    # Prefer a motherboard controller over a GPU PWM endpoint.
    return next((item for item in candidates if item.joinpath("name").read_text().strip() != "amdgpu"), candidates[0] if candidates else None)


def interpolate(points: list[list[float]], temperature: float) -> int:
    points = sorted(points, key=lambda point: point[0])
    if temperature <= points[0][0]:
        return round(points[0][1])
    for left, right in zip(points, points[1:]):
        if temperature <= right[0]:
            span = right[0] - left[0]
            ratio = 1.0 if span <= 0 else (temperature - left[0]) / span
            return round(left[1] + ratio * (right[1] - left[1]))
    return round(points[-1][1])


class Controller:
    def __init__(self, config_path: Path, state_path: Path):
        self.config_path = config_path
        self.state_path = state_path
        self.lock = threading.RLock()
        self.stop_event = threading.Event()
        self.config = json.loads(config_path.read_text())
        defaults = {
            "modes": {"cpu": "optimized", "case": "optimized"},
            "manual": {"cpu": 25, "case": 40},
            "profiles": self.config["profiles"],
        }
        try:
            loaded = json.loads(state_path.read_text())
            defaults.update({key: loaded[key] for key in defaults if key in loaded})
        except (OSError, ValueError, TypeError):
            pass
        self.state = defaults
        self.last_error = ""
        self.last_temp: float | None = None
        self.last_power: float | None = None
        self.energy_sample: tuple[float, float, float] | None = None
        self.last_duties = {"cpu": 100, "case": 100}
        self.persist()

    def persist(self) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.state, indent=2) + "\n")
        os.chmod(temporary, 0o600)
        temporary.replace(self.state_path)

    def cpu_temperature(self) -> float | None:
        source = self.config.get("cpu_temp", {})
        preferred = source.get("hwmon")
        names = [name for name in (preferred, "k10temp", "coretemp", "zenpower") if name]
        device = next((match for name in dict.fromkeys(names) if (match := hwmon_named(name))), None)
        raw = read_number(device / source.get("input", "temp1_input")) if device else None
        return None if raw is None else raw / 1000.0

    def controller_path(self) -> Path | None:
        return discover_controller(self.config.get("controller"))

    def update_cpu_power(self) -> None:
        package = None
        for path in Path("/sys/class/powercap").glob("*:*"):
            try:
                if path.joinpath("name").read_text().strip() == "package-0":
                    package = path
                    break
            except OSError:
                pass
        if not package:
            return
        energy = read_number(package / "energy_uj")
        maximum = read_number(package / "max_energy_range_uj")
        now = time.monotonic()
        if energy is not None and maximum is not None and self.energy_sample is not None:
            previous_energy, previous_time, _ = self.energy_sample
            delta = energy - previous_energy
            if delta < 0:
                delta += maximum
            elapsed = now - previous_time
            if elapsed > 0:
                self.last_power = round((delta / 1_000_000) / elapsed, 1)
        if energy is not None and maximum is not None:
            self.energy_sample = (energy, now, maximum)

    def apply_duty(self, role: str, duty: int) -> None:
        controller = self.controller_path()
        channel = self.config.get("fans", {}).get(role)
        if not controller or channel is None:
            raise RuntimeError(f"No {role} fan channel is configured")
        pwm = controller / f"pwm{int(channel)}"
        enable = controller / f"pwm{int(channel)}_enable"
        if not pwm.exists():
            raise RuntimeError(f"Missing PWM channel: {pwm}")
        enable.write_text("1\n")
        pwm.write_text(f"{round(max(0, min(100, duty)) * 255 / 100)}\n")

    def control_once(self) -> None:
        with self.lock:
            temperature = self.cpu_temperature()
            self.last_temp = temperature
            self.update_cpu_power()
            if temperature is None:
                duties = {"cpu": 100, "case": 100}
                self.last_error = "CPU temperature unavailable; fans forced to 100%"
            else:
                changed = False
                for role in ("cpu", "case"):
                    if temperature >= 85 and self.state["modes"].get(role) == "manual":
                        self.state["modes"][role] = "optimized"
                        changed = True
                if changed:
                    self.persist()
                duties = {}
                for role in ("cpu", "case"):
                    if self.state["modes"].get(role) == "manual":
                        duties[role] = int(self.state["manual"][role])
                    else:
                        duties[role] = interpolate(self.state["profiles"][role], temperature)
                self.last_error = ""
            for role, duty in duties.items():
                try:
                    self.apply_duty(role, duty)
                    self.last_duties[role] = duty
                except (OSError, RuntimeError) as error:
                    self.last_error = str(error)

    def fan_info(self, role: str) -> dict:
        controller = self.controller_path()
        channel = self.config.get("fans", {}).get(role)
        rpm = read_number(controller / f"fan{channel}_input") if controller and channel is not None else None
        return {
            "duty": self.last_duties.get(role),
            "rpm": None if rpm is None else round(rpm),
            "mode": self.state["modes"].get(role, "unavailable"),
        }

    def command(self, request: dict) -> dict:
        action = request.get("action", "status")
        with self.lock:
            if action == "manual":
                role = request.get("fan")
                if role not in ("cpu", "case"):
                    raise ValueError("fan must be cpu or case")
                value = max(5, min(100, int(request["value"])))
                if self.last_temp is not None and self.last_temp >= 85:
                    raise ValueError("Manual control is locked at 85°C")
                self.state["manual"][role] = value
                self.state["modes"][role] = "manual"
                self.persist()
                self.control_once()
                message = f"{role.title()} fan held at {value}% until restored"
            elif action == "restore":
                self.state["modes"] = {"cpu": "optimized", "case": "optimized"}
                self.persist()
                self.control_once()
                message = "Optimized CPU-temperature profiles restored"
            elif action == "save":
                bases = {"cpu": max(5, min(100, int(request["cpu"]))), "case": max(5, min(100, int(request["case"])))}
                ramps = {"cpu": [[90, 60], [93, 80], [95, 100]], "case": [[90, 65], [93, 82], [95, 100]]}
                for role, base in bases.items():
                    self.state["profiles"][role] = [[0, base], [85, base]] + [[temp, max(base, duty)] for temp, duty in ramps[role]]
                self.state["modes"] = {"cpu": "optimized", "case": "optimized"}
                self.persist()
                self.control_once()
                message = "Optimized profile baselines updated and restored"
            elif action == "status":
                message = ""
            else:
                raise ValueError("Unknown action")
            return {
                "ok": True,
                "backend": "direct",
                "message": message,
                "cpu_temp": self.last_temp,
                "cpu_power": self.last_power,
                "fans": {"cpu": self.fan_info("cpu"), "case": self.fan_info("case")},
                "profiles": self.state["profiles"],
                "error": self.last_error,
            }

    def loop(self) -> None:
        while not self.stop_event.is_set():
            self.control_once()
            self.stop_event.wait(float(self.config.get("poll_interval", 2)))


class ApiHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        try:
            request = json.loads(self.rfile.readline(16384))
            response = self.server.controller.command(request)
        except Exception as error:
            response = {"ok": False, "error": str(error)}
        self.wfile.write((json.dumps(response, separators=(",", ":")) + "\n").encode())


class ApiServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, path: Path, controller: Controller, socket_group: str):
        path.unlink(missing_ok=True)
        super().__init__(str(path), ApiHandler)
        self.controller = controller
        os.chmod(path, 0o660)
        try:
            os.chown(path, 0, grp.getgrnam(socket_group).gr_gid)
        except KeyError:
            pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--socket", type=Path, default=DEFAULT_SOCKET)
    args = parser.parse_args()
    args.socket.parent.mkdir(parents=True, exist_ok=True)
    controller = Controller(args.config, args.state)
    controller.control_once()
    worker = threading.Thread(target=controller.loop, daemon=True)
    worker.start()
    server = ApiServer(args.socket, controller, controller.config.get("socket_group", "wheel"))

    def stop(*_args) -> None:
        controller.stop_event.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        # Leaving a low manual PWM behind after uninstall/service failure is unsafe.
        for role in ("cpu", "case"):
            try:
                controller.apply_duty(role, 100)
            except (OSError, RuntimeError):
                pass
        server.server_close()
        args.socket.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
