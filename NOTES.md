# Adapting this plugin to a Tongfang/Uniwill-EC laptop (Avell A40 LIV)

This fork makes the Thermals & Fans plugin work on a laptop whose fan(s) are
driven by a Tongfang/Uniwill embedded controller (EC) exposed over WMI, instead
of a motherboard Super-I/O chip with standard `pwmN` hwmon files.

Tested hardware: **Avell A40 LIV** (AMD Ryzen, Tongfang chassis, single fan).
The approach should apply to other Tongfang/Uniwill-based laptops (Clevo,
Mechrevo, XMG, Eluktronics, Sager…) that expose the `AcpiTest_MULong` WMI
class (GUID `ABBC0F6F-8EA1-11D1-00A0-C90629100000` / `ABBC0F72-…`).

## Why the original plugin could not work here

The stock daemon (`thermalsd.py`) drives fans through `/sys/class/hwmon/*/pwmN`.
On this hardware there is **no** hwmon device with pwm/fan files at all — only
temperature sensors (`k10temp`, `amdgpu`, `nvme`, `acpitz`). The panel showed
"READ ONLY", 0% duty, 0 RPM, and `[Errno 2] No such file or directory` (the
daemon socket was also missing because `install-service` had never been run —
`omarchy plugin add` only clones the files).

## What we tried and discarded

1. **`uniwill-laptop` kernel module with `force=1`** — loads, binds the WMI
   device, but never registers a hwmon with fans on this unit.
2. **`tuxedo-drivers-dkms` + TUXEDO Control Center** — `tuxedo_io` loads but
   `tccd` logs "No fans found" forever. Worse: `tccd` keeps retrying and
   writing the EC every second, **fighting any other fan controller and
   causing constant fan-speed oscillation**. It must be disabled
   (`sudo systemctl disable --now tccd tccd-sleep`) or uninstalled.
3. **EC PWM curve writes (L1–L5 @ 1859–1863) + trigger byte** — the EC accepts
   and stores the values, but they have **no effect** on fan speed. The
   trigger value 4 is a *fan-boost trigger*: each write toggles boost on, so
   combining curve writes with the trigger makes the fan oscillate between
   boost and the custom mode. This was the hardest bug to find: it looked like
   an intermittent hardware/EC problem.

## What actually works (and is now implemented)

All control goes through `acpi_call` (`\_SB.AMW0.WMBC 0 4 <value>`,
GetSetULong with the address encoded as `0x10000000000 + addr` for reads and
`(value << 16) + addr` for writes). The daemon runs as root (systemd service),
so no sudo is needed at runtime.

EC protocol discovered by experiment:

| Address | Meaning |
|---|---|
| 1873 | Fan control byte: `0x00` = auto (EC intelligent), `0x40` = boost, `0x81..0x85` = fixed levels 1–5 |
| 1885 | Trigger byte; value `4` = fan-boost trigger (**do not use for applying duty**) |
| 0x1804 | Current fan speed/duty, 0–200 scale |

Level byte `n` maps to effective duty `20% + 10*n` on the EC's 0–200 scale:
levels give **30 / 40 / 50 / 60 / 70%**, boost gives **100%**. The EC does not
honor arbitrary duty. It also ignores a level write while boost (or another
mode) is active — the daemon passes through `Normal` first and skips
redundant writes, which is what finally killed the oscillation.

The EC reports fan speed on the 0–200 scale (boost = 200). It is duty, not
real RPM, and the fan has a physical floor (~30%) — 0% is not possible.

## UI design

Single fan (one slider + gear buttons): the EC has one control byte, so
having separate CPU/case sliders was meaningless and caused them to fight.

- **Gears**: 30% · 40% · 50% · 60% · 70% · Boost — one EC write each.
- **Slider**: snaps to the nearest gear; the panel always shows the *effective*
  duty, never a value the EC can't do.
- **Profiles**: `Auto (EC)` = byte 0, EC does its own thing (safety boost above
  85°C is still enforced by the daemon); `Full boost` = 0x40; `Silent` and
  `Custom curve` interpolate their curve and snap to the nearest gear.
- Safety behavior preserved: manual mode is cancelled at 85°C, duty ≥ 90%
  maps to the EC's native boost, and stopping the service restores byte 0.

## Installation on this hardware

```bash
yay -S acpi-call-dkms          # kernel module (also: echo acpi_call | sudo tee /etc/modules-load.d/acpi_call.conf)
omarchy plugin add https://github.com/rafadpedrosa/omarchy-temps-and-fans.git --enable
cd ~/.config/omarchy/plugins/thermals.fans
sudo ./install-service         # copies thermalsd.py to /usr/local/libexec — RE-RUN after every daemon change
sudo systemctl restart omarchy-thermals
```

## Caveats

- **`install-service` copies the daemon**: editing `thermalsd.py` in the plugin
  dir does nothing until you re-run it. This cost us a long debugging session.
- The EC control byte is shared: only **one** write per control cycle, or the
  fan oscillates.
- Do not run `tccd` (TUXEDO Control Center daemon) alongside this; it fights
  for the same EC.
- Concurrent WMI calls (e.g. monitoring scripts while the daemon writes)
  produce corrupted reads (`0xfe`, speed 254) — not a real state, just WMI
  resource contention.
- Readings labeled "RPM" in the panel are EC duty units (0–200), not RPM.
- The `uniwill-laptop` module with `force=1` also grabs keyboard FN-key
  handling; it was removed from the final setup (not needed).

## Debugging notes (for the next person)

The EC byte/state monitor that proved the trigger-boost oscillation:

```python
# sudo python3 — read control byte, speed and pwm1 every second
from tongfang_control.acpi import BaseAcpiController  # or inline the acpi_call
```

`tongfang-control-git` (AUR) was the reference implementation used to map the
protocol (`ecspec.py` / `fan.py`); this daemon reimplements only what it needs
so it stays self-contained. `tongfang-control --monitor` remains a handy
fallback CLI.
