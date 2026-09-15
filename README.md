# Omarchy Thermals & Fans

An Omarchy bar widget for direct Linux `hwmon` telemetry and optional CPU-temperature fan control. It displays CPU state, GPU temperatures and fan RPM, memory-module temperatures, NVMe temperatures, motherboard sensors, and CPU/case fan state.

The widget is useful immediately after installation: read-only telemetry needs no daemon, account, network access, or elevated privileges. Fan controls become available when the small companion service is installed.

## Install the plugin

```bash
omarchy plugin add https://github.com/stevemcqueenz/omarchy-temps-and-fans.git --enable
omarchy bar move stevemcqueen.thermals --after omarchy.agents
```

Omarchy deliberately does not execute plugin install hooks or privileged commands. Review the companion service, then install it explicitly if fan control is wanted:

```bash
cd ~/.config/omarchy/plugins/stevemcqueen.thermals
sudo ./install-service
```

If CoolerControl is already managing the same fans, use the explicit handover option so two controllers never write the same PWM channels:

```bash
sudo ./install-service --replace-coolercontrol
```

## Configuration

The service discovers changing `/sys/class/hwmon/hwmon*` numbers by driver name on every update. Copy and edit `config.example.json` as `/etc/omarchy-thermals/config.json` when the defaults do not match the motherboard. `fans.cpu` and `fans.case` are the numeric portions of `pwmN`/`fanN_input`.

Manual duties range from 5–100% and persist until **Restore selected** is selected. At 85°C, manual mode is cancelled and the selected CPU-temperature curves take over. If the CPU sensor disappears, both configured fans are forced to 100%.

## Fan profiles

The panel exposes four editable presets: **Default**, **Full speed**, **Silent**, and **Custom**. The names are labels rather than fixed policies—rename any preset to match your system. Select a profile, adjust the temperature/duty points for the CPU and case fans, and save it. Between points the daemon interpolates a smooth ramp, so you can make a flat quiet base and add gradual or stepped cooling above it. The selected profile is also the one used automatically after the 85°C safety hand-off.

The profile editor is stored in `/var/lib/omarchy-thermals/state.json`, allowing each machine to tune its own curves without changing the plugin. The GPU is monitored (temperatures, load, and any exposed fan RPM/duty), but GPU fan control is intentionally not attempted.

## Remove

```bash
cd ~/.config/omarchy/plugins/stevemcqueen.thermals
sudo ./uninstall-service
omarchy plugin remove stevemcqueen.thermals --yes
```

The removal script deliberately retains `/etc/omarchy-thermals/config.json` and `/var/lib/omarchy-thermals/state.json` so local tuning is not destroyed accidentally.

## Compatibility

- CPU sensors: `k10temp`, `coretemp`, or `zenpower`
- GPU details: DRM-linked `amdgpu` hwmon devices
- Memory: `spd5118`
- Storage: NVMe hwmon
- Fan control: motherboard hwmon drivers exposing writable `pwmN` and `pwmN_enable`

The kernel hardware driver remains a prerequisite. This plugin does not install out-of-tree motherboard drivers automatically.
