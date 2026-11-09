# power-tune

Root fallback for the CPU, GPU and platform power settings GameCove's Power page and quick menu change often, on handhelds where no prompt-free service offers them. GameCove asks **steamos-manager** (user bus) and **PowerStation** (system bus) first; both need no password. Only what neither offers goes through `pkexec /usr/libexec/gamecove/gamecove-fix-set power-tune set <key>:<value>`, which polkit allows without a password in the active session. Because of that, `fix.sh` checks every value against what this machine's kernel offers before writing it.

| Key | Values | Writes |
| --- | --- | --- |
| `boost` | `on`, `off` | `intel_pstate/no_turbo`, else `cpufreq/policyN/boost` (amd-pstate), else `cpufreq/boost` |
| `smt` | `on`, `off` | `cpu/smt/control` (only where it reads `on`/`off`) |
| `cores` | 2..all | `cpuN/online` (cpu0 always on) |
| `epp` | a word from `energy_performance_available_preferences` | every CPU's `energy_performance_preference` |
| `governor` | a word from `scaling_available_governors` | every policy's `scaling_governor` |
| `cpumax` | 30..100 | `intel_pstate/max_perf_pct` (never under `min_perf_pct`), else `scaling_max_freq` |
| `gpulevel` | `auto`, `low`, `high`, `manual` | amdgpu `power_dpm_force_performance_level` |
| `gpumin`, `gpumax` | MHz inside the hardware range | xe `tile0/gt0/freq0/{min,max}_freq`, i915 `gt_{min,max}_freq_mhz`, amdgpu `pp_od_clk_voltage` |
| `gpuprofile` | as offered | xe `power_profile` (`base`, `power_saving`) |
| `sppt`, `fppt` | W inside the attribute's `min_value..max_value`, not under SPL (FPPT not under SPPT) | firmware attributes of asus-armoury, lenovo-wmi-other (switches to `custom` first), msi-wmi-platform; handhelds only |
| `platform` | from `platform_profile_choices` | `/sys/firmware/acpi/platform_profile` |
| `tau` | 1 s .. the firmware's own value, or `restore` | RAPL package PL1 `time_window_us` |
| `thermald` | `hold`, `release` | `systemctl stop/start thermald.service` (never disabled) |
| `sleep` | `s2idle`, `deep` (as offered) | `/sys/power/mem_sleep` |
| `mcu` | `on`, `off` | ROG Ally `mcu_powersave`; handhelds only |
| `battery` | `standard`, `long-life` | `charge_types` (Lenovo: Long Life = 80 %); handhelds only |
| `restore` | | everything recorded back, thermald started again |

The first change of each value records the one before it in `/var/lib/gamecove/fixes/power-tune/orig/`; `set restore` (run by GameCove's session when GameCove exits) and `remove` write them back. Values recorded on another handheld (one drive, several handhelds) are dropped, never written. `status` lists them (`orig_<key>=`) and ends with `state=on` while anything is recorded.

"Handhelds only": the rows of `handhelds.txt`, generated from `app/data/devices.json` by `tests/gen_handhelds.py` (every handheld row; `test.sh` checks it is current). Laptops share these drivers and are refused.

Sources: SimpleDeckyTDP (aarron-lee, `py_modules/cpu_utils.py`, `devices/rog_ally.py`, `devices/lenovo.py`: per-policy AMD boost, Lenovo `-0` attribute folder and custom mode, older `ppt_fppt` name, MCU power saving), PowerStation (`src/performance/cpu`, `gpu`), ClawDeck (thermald, RAPL window: `docs/HARDWARE-FINDINGS.md` §21, §22.2), the kernel's asus-armoury, lenovo-wmi-other and xe drivers.
