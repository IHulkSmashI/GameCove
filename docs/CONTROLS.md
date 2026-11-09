# Controls

Every adjustable setting is a Control (`app/scripts/controls/control.gd`) registered with the `Controls` autoload by a provider in `app/scripts/controls/providers/`. One section per area below.

## Power (`providers/power.gd`, `scripts/controls/power/`)

Owner: ctl-power. 33 controls, group `power`. Each detects its backend on this exact handheld and gives a plain reason when it can't be used (`controls/power/texts.gd`). Backends are tried prompt-free first: **steamos-manager** (user bus), **PowerStation** (system bus, anyone may call it), **power-profiles-daemon / tuned-ppd**, **Handheld Daemon** (HTTP), then the root helper `gamecove-fix-set power-tune|fan|charge-limit set …` (polkit "yes", no prompt). Everything below the TDP lives in `controls/power/backend.gd`; TDP, profile, charge limit, fan and Auto TDP go through the `Power` service and run on its worker (`Power.run_sync()`).

| id | kind | Backends, in order | Where it shows up |
| --- | --- | --- | --- |
| `power.tdp` | slider W | Handheld Daemon, devices.json `tdp_backends` (steamos-manager, PowerStation) | every row with a TDP range; range per power source |
| `power.profile` | choice | Power (devices.json `profiles` watts) | same; not per game (the TDP is) |
| `power.boost` | slider W | PowerStation `Boost` (PL2-PL1 on Intel RAPL, SPPT/FPPT on ASUS/ryzenadj); max = `boost_max` - TDP | PowerStation TDP rows (Claw 8 EX, OneXPlayer, GPD…) |
| `power.boost_on` | toggle | Handheld Daemon `<driver>.tdp.custom.boost` | hhd with its TDP plugin on |
| `power.sppt`, `power.fppt` | slider W | firmware attributes via helper (asus-armoury, lenovo-wmi-other-0 in custom mode, msi-wmi-platform); range = attribute min/max, ≥ SPL (FPPT ≥ SPPT), ≤ `boost_max` | ROG Ally family, Legion Go family, Claws with steamos-manager TDP; off on the Claw 8 EX (firmware ignores them, ClawDeck §12), under hhd, and where PowerStation keeps them |
| `power.power_mode` | choice | power-profiles-daemon / tuned-ppd `ActiveProfile` | Bazzite, CachyOS |
| `power.platform_profile` | choice | steamos-manager `PerformanceProfile1`, else helper (`/sys/firmware/acpi/platform_profile`) | Steam Deck, ASUS, Lenovo; greyed out when PPD owns it |
| `power.cpu_boost` | toggle | steamos-manager `CpuBoost1`, PowerStation `BoostEnabled` (AMD cpb), helper (intel_pstate `no_turbo`, amd-pstate `policyN/boost`, `cpufreq/boost`) | all |
| `power.smt` | toggle | PowerStation `SmtEnabled`, helper | CPUs with SMT (not the Claw 8 EX) |
| `power.cpu_cores` | slider | PowerStation `CoresEnabled`, helper; 2..all | all with CPU hotplug |
| `power.epp` | choice | helper (every CPU, from the offered words) | intel_pstate / amd-pstate-epp |
| `power.governor` | choice | steamos-manager `CpuScaling1`, helper | all |
| `power.cpu_max` | slider % | helper: intel_pstate `max_perf_pct` (≥ `min_perf_pct`), else `scaling_max_freq`; 30..100 | all |
| `power.gpu_level` | choice | steamos-manager `GpuPerformanceLevel1`, helper (`power_dpm_force_performance_level`) | AMD |
| `power.gpu_clock` | slider MHz | steamos-manager `ManualGpuClock` (manual level) | Steam Deck |
| `power.gpu_min`, `power.gpu_max` | slider MHz | PowerStation clocks (AMD `pp_od_clk_voltage`, i915), helper (xe `tile0/gt0/freq0`, amdgpu); hardware range, min ≤ max kept | AMD, Intel |
| `power.gpu_profile` | choice | helper (xe `power_profile`), steamos-manager `GpuPowerProfile1` | Intel Arc (xe), Steam Deck |
| `power.thermal_limit` | slider °C | PowerStation `ThermalThrottleLimitC`; 60..the first-seen firmware value (kept per handheld) | AMD with ryzenadj |
| `power.charge_limit` | slider % | Power (steamos-manager, charge-limit fix) | rows with `charge_limit` |
| `power.battery_long_life` | toggle | helper (`charge_types` Long_Life = 80 %) | Lenovo Legion Go family (lenovo-wmi-other) |
| `power.fan_mode` | choice | Power (steamos-manager `FanControl1`, fan fix) | rows with a fan driver |
| `power.fan_curve` | curve | fan fix `set curve:` (never quieter than Quiet, never falling) | msi_wmi_platform (6 points), asus_custom_fan_curve (8) |
| `power.battery_saver` | toggle | applies battery profile, power-saver mode, EPP power, boost off, GPU efficiency; puts the old values back | all with any of those |
| `power.battery_saver_at` | slider % | on by itself at this level on battery, off on the charger | all with a battery |
| `power.sleep_mode` | choice | helper (`/sys/power/mem_sleep` s2idle / deep) | firmwares offering both |
| `power.mcu_powersave` | toggle | helper (asus-armoury / asus-nb-wmi `mcu_powersave`) | ROG Ally family |
| `power.autotune_target`, `power.autotune_auto_fps`, `power.autotune_keep`, `power.autotune_floor`, `power.autotune_plugged` | | Power's Auto TDP options (per handheld; target/keep/floor per game through profiles) | all with a TDP |

Per game (`per_game` true) unless noted: profile, charge limit, battery care, fan curve, battery saver, sleep mode, MCU power saving and Auto TDP when plugged are device settings, kept per handheld in `user://power_controls.cfg` (`set@<device id>`) and put back at start. Every value written is re-applied after a resume (`Power.resumed`). A manual change of a lever Auto TDP moves pauses Auto TDP for that game. `power.tdp` re-detects on `Power.source_changed` (its range differs on battery and plugged in).

### Auto TDP

`app/scripts/device/autotune.gd` is ClawDeck's `autotune.py` (commit cf349a6, 2026-11-08) ported rule for rule, constants unchanged: measure the most frames the set TDP gives (median of three 10 s windows), balance CPU/GPU one lever at a time (kept only for +2 %), lower while within 5 % or 2 fps (3 W steps on a plateau, knee and flat-step rules), hold (re-measure on a 15 % shift, a frame-generation change or every 20 min), heavy scenes get watts back within seconds, loading screens are skipped, an 8 s PL1 window while learning, optional target fps (DeckyTDPTuner's governor, Auto FPS, fast to move then locked), thermal step. Power adds ClawDeck's main.py plumbing: the ceiling is the user's TDP, the floor the device minimum (or the user's), battery only unless "Auto TDP when plugged in", learned results per game and power source (`autotune@<device>` in `user://power.cfg`, only settled ones), every lever restored at game exit, thermald held on Intel with ClawDeck's temperature guard.

Levers (`controls/power/levers.gd`), wherever the handheld allows: TDP (hhd / steamos-manager / PowerStation), GPU floor (PowerStation on AMD and i915, helper on xe and amdgpu), GPU efficiency mode (xe, steamos-manager), CPU boost, CPU ceiling, RAPL window. Two GameCove additions: an EPP lever for CPU-bound games (balance_power/power → balance_performance, kept only if it adds 2 %, same rule as boost), and a frame-limit "can't reach" signal for the UI (never changes the TDP rule).

### Root verbs (`fixes/power-tune`, `fixes/fan`)

`gamecove-fix-set power-tune set <key>:<value>`: `boost on|off`, `smt on|off`, `cores N`, `epp W`, `governor W`, `cpumax 30-100`, `gpulevel auto|low|high|manual`, `gpumin N`, `gpumax N`, `gpuprofile W`, `sppt N`, `fppt N`, `platform W`, `tau N|restore`, `thermald hold|release`, `sleep s2idle|deep`, `mcu on|off`, `battery standard|long-life`, and `restore` (the session runs it when GameCove exits). `gamecove-fix-set fan set curve:d1,d2,…`. Every value is checked by `fix.sh` against what the kernel offers; firmware limits and battery modes only on handhelds in `fixes/power-tune/handhelds.txt` (all devices.json rows). Originals are recorded per handheld and put back by `restore`.

### Needs real hardware

See the report in the merge request: firmware acceptance of the RAPL 8 s window, amdgpu clock read-back, xe `power_profile` and `mcu_powersave` writes, Lenovo custom mode timing, deep sleep on each model.
