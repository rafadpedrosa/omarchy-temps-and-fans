#!/usr/bin/env python3
"""Minimal CPU-temperature fan controller with a local Unix-socket API."""

from __future__ import annotations

import argparse
import grp
import json
import os
import re
import signal
import socketserver
import threading
import time
from pathlib import Path


DEFAULT_CONFIG = Path("/etc/omarchy-thermals/config.json")
DEFAULT_STATE = Path("/var/lib/omarchy-thermals/state.json")
DEFAULT_SOCKET = Path("/run/omarchy-thermals/control.sock")


# EC access over the Tongfang/Uniwill WMI interface (AcpiTest_MULong), via acpi_call.
# The daemon runs as root, so /proc/acpi/call needs no sudo. Verified empirically on
# an Avell A40 LIV (Tongfang chassis): control byte 1873 accepts Normal=0, Boost=64
# and the five fixed levels 0x81..0x85 (EC duty 60..100 on the 0-200 scale).
# Arbitrary PWM/curve writes are accepted by the EC registers but the trigger byte
# used to apply them turns boost on instead, so they are not used.
WMI_ACPI_CLASS = "\\_SB.AMW0.WMBC"
EC_MAFAN_CONTROL = 1873
EC_FAN_SPEED = 0x1804

EC_NORMAL = 0
EC_BOOST = 64


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
        base_profiles = self.config["profiles"]
        default_presets = {
            "default": {
                "name": "Auto (EC)",
                "cpu": [[0, 30], [60, 30], [75, 50], [85, 70], [95, 100]],
                "case": [[0, 30], [60, 30], [75, 50], [85, 70], [95, 100]],
            },
            "full": {
                "name": "Full boost",
                "cpu": [[0, 100], [60, 100], [75, 100], [85, 100], [95, 100]],
                "case": [[0, 100], [60, 100], [75, 100], [85, 100], [95, 100]],
            },
            "silent": {"name": "Silent", "cpu": base_profiles["cpu"], "case": base_profiles["case"]},
            "custom": {"name": "Custom curve", "cpu": base_profiles["cpu"], "case": base_profiles["case"]},
        }
        defaults = {
            "modes": {"cpu": "optimized", "case": "optimized"},
            "manual": {"cpu": 25, "case": 40},
            "presets": default_presets,
            "active_preset": "silent",
        }
        try:
            loaded = json.loads(state_path.read_text())
            if "presets" in loaded:
                defaults["presets"] = loaded["presets"]
            elif "profiles" in loaded:  # migrate the original two-curve state
                defaults["presets"]["silent"]["cpu"] = loaded["profiles"].get("cpu", base_profiles["cpu"])
                defaults["presets"]["silent"]["case"] = loaded["profiles"].get("case", base_profiles["case"])
                defaults["presets"]["custom"]["cpu"] = defaults["presets"]["silent"]["cpu"]
                defaults["presets"]["custom"]["case"] = defaults["presets"]["silent"]["case"]
            defaults.update({key: loaded[key] for key in ("modes", "manual", "active_preset") if key in loaded})
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

    @staticmethod
    def _wmi_call(value: int) -> int:
        call_path = Path("/proc/acpi/call")
        call_path.write_text(f"{WMI_ACPI_CLASS} 0 4 {value}\n")
        response = call_path.read_text().strip()
        try:
            return int(response.strip().split("\x00")[0], 16)
        except ValueError:
            # "{0xa0, 0x6c, ...}" buffer: little-endian, take the low byte below
            pass
        bytes_hex = re.findall(r"0x[0-9a-fA-F]+", response)
        data = bytes(int(item, 16) for item in bytes_hex)
        return int.from_bytes(data, "little")

    @staticmethod
    def read_ecram(address: int) -> int:
        return Controller._wmi_call(0x10000000000 + address) & 255

    @staticmethod
    def write_ecram(address: int, value: int) -> None:
        Controller._wmi_call((value << 16) + address)

    def apply_duty(self, role: str, duty: int) -> None:
        # Single-fan notebook: both roles share the same EC control byte, so only
        # one write is ever issued per control cycle (role "cpu").
        if role != "cpu":
            return 0
        duty = max(0, min(100, int(duty)))
        if duty >= 90:
            # Near 100% duty, use the EC's native boost instead of the levels.
            self.write_ecram(EC_MAFAN_CONTROL, EC_BOOST)
            return 100
        # The EC only honors its 5 fixed fan levels here (duty 60/70/80/90/100 on
        # the 0-200 scale). Writing the PWM curve + trigger byte does NOT apply
        # arbitrary duty: trigger value 4 turns boost on and oscillates the fan.
        level = min(5, max(1, round(duty / 10)))
        self.write_ecram(EC_MAFAN_CONTROL, 128 + level)
        return level * 10

    def restore_auto(self) -> None:
        self.write_ecram(EC_MAFAN_CONTROL, EC_NORMAL)

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
                        preset = self.state["presets"].get(self.state.get("active_preset", "silent"), self.state["presets"]["silent"])
                        duties[role] = interpolate(preset[role], temperature)
                self.last_error = ""
            # Single EC channel: drive it once per cycle, and let the EC's own
            # intelligent mode run when the Auto profile is selected.
            with_mode = self.state["modes"].get("cpu", "optimized")
            preset_id = self.state.get("active_preset", "silent")
            if with_mode == "optimized" and preset_id == "default" and temperature is not None and temperature < 85:
                self.restore_auto()
                self.last_duties = {"cpu": None, "case": None}
                return
            duty = duties.get("cpu", 100)
            try:
                effective = self.apply_duty("cpu", duty)
                self.last_duties = {"cpu": effective, "case": effective}
            except (OSError, ValueError, RuntimeError) as error:
                self.last_error = str(error)

    def fan_info(self, role: str) -> dict:
        try:
            speed = self.read_ecram(EC_FAN_SPEED)
        except (OSError, ValueError):
            speed = None
        duty = self.last_duties.get("cpu")
        if duty is None and speed is not None:
            duty = round(speed / 2)  # auto mode: show the EC's effective duty (0-200 scale)
        return {
            "duty": duty,
            "rpm": None if speed is None else round(speed),
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
                preset = self.state["presets"][self.state.get("active_preset", "silent")]
                for role, base in bases.items():
                    preset[role] = [[0, base], [85, base]] + [[temp, max(base, duty)] for temp, duty in ramps[role]]
                self.state["modes"] = {"cpu": "optimized", "case": "optimized"}
                self.persist()
                self.control_once()
                message = "Optimized profile baselines updated and restored"
            elif action == "select":
                preset_id = str(request.get("preset", ""))
                if preset_id not in self.state["presets"]:
                    raise ValueError("Unknown preset")
                self.state["active_preset"] = preset_id
                self.state["modes"] = {"cpu": "optimized", "case": "optimized"}
                self.persist()
                self.control_once()
                message = f"{self.state['presets'][preset_id]['name']} profile applied"
            elif action == "preset_save":
                preset_id = str(request.get("preset", ""))
                if preset_id not in self.state["presets"]:
                    raise ValueError("Unknown preset")
                name = str(request.get("name", "")).strip()[:32]
                if not name:
                    raise ValueError("Preset name cannot be empty")
                curves = {}
                for role in ("cpu", "case"):
                    points = request.get(role)
                    if not isinstance(points, list) or len(points) < 2 or len(points) > 8:
                        raise ValueError(f"{role} curve needs 2–8 points")
                    normalized = []
                    previous_temp = -1
                    for point in points:
                        if not isinstance(point, list) or len(point) != 2:
                            raise ValueError("Curve points must be [temperature, duty]")
                        temperature, duty = int(point[0]), int(point[1])
                        if temperature < 0 or temperature > 100 or temperature <= previous_temp:
                            raise ValueError("Curve temperatures must be strictly increasing")
                        if duty < 5 or duty > 100:
                            raise ValueError("Curve duties must be between 5% and 100%")
                        previous_temp = temperature
                        normalized.append([temperature, duty])
                    if normalized[0][0] != 0:
                        raise ValueError("The first curve point must start at 0°C")
                    curves[role] = normalized
                self.state["presets"][preset_id] = {"name": name, "cpu": curves["cpu"], "case": curves["case"]}
                self.state["active_preset"] = preset_id
                self.state["modes"] = {"cpu": "optimized", "case": "optimized"}
                self.persist()
                self.control_once()
                message = f"{name} profile saved and applied"
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
                "active_preset": self.state.get("active_preset", "silent"),
                "presets": self.state["presets"],
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
        # Leaving the fans in a forced manual state after service failure is unsafe.
        try:
            controller.restore_auto()
        except (OSError, ValueError):
            try:
                controller.apply_duty("cpu", 100)
            except (OSError, ValueError):
                pass
        server.server_close()
        args.socket.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
