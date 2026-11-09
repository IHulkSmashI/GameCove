#!/usr/bin/env python3
"""Device matrix fixture generator (GPL-3.0, part of GameCove).

Builds a fake system for EVERY row of app/data/devices.json, plus an unlisted
AMD handheld and an unlisted Intel handheld, so every Controls provider can be
loaded against every handheld without the hardware:

  OUT/manifest.json                    what was built (read by the GDScript test)
  OUT/<id>/root/                       the fake filesystem (Controls ctx.sys_root)
      sys/class/dmi/id/*               DMI ids taken from the row's "match"
      proc/cpuinfo, proc/sys/kernel/osrelease, etc/os-release
      sys/class/drm/cardN/...          amdgpu (pp_* files, power_dpm_force_performance_level)
                                       or Intel xe (tile0/gt0/freq0/*) / i915 (gt_*_freq_mhz)
      sys/class/power_supply/          AC adapter (offline) + battery, charge limit files where
                                       the row says the kernel has them
      sys/class/backlight/<name>/      brightness / max_brightness
      sys/class/hwmon/hwmonN/          CPU temp, GPU, and the row's fan driver (pwm tables)
      sys/class/leds/<name>/           RGB rings where a kernel driver exposes them (names from
                                       expectations.json "facts", cited to HueSync / hhd)
      sys/class/firmware-attributes/   asus-armoury / lenovo-wmi-other / msi-wmi-platform PPT limits
      sys/class/powercap/intel-rapl*:0 package power limits (Intel), energy only (AMD)
      sys/devices/system/cpu/          cpuN/cpufreq (governor, EPP), smt, intel_pstate / boost
      sys/bus/iio/devices/iio:deviceN  the IMU named in the row
      usr/bin/<tool>                   empty stand-ins for the programs this stack has installed
      usr/libexec/gamecove/gamecove-fix{,-set}
      tmp/hhd/token                    when Handheld Daemon is the controller service
      home/                            Controls ctx.home
  OUT/<id>/backends.json               what the fake runner and fake hhd answer:
      {"dbus": {"props": {"<bus> <service> <path> <iface> <prop>": {"type", "data"}},
                "methods": {"<bus> <service> <path> <iface> <method>": {"type", "data"}}},
       "commands": [{"argv": [glob, ...], "code": 0, "out": "...", "write": bool}],
                     first match wins, "**" matches the rest; "write" rules fail in the
                     test's "failing" scenario
       "hhd": state dict or null, "xprop_root": {atom: "values"} (gamescope's root window),
       "stack": [...], "tools": [...]}

Values come from devices.json (TDP ranges, fan driver, charge limit, RGB, IMU,
panel) and from the tables below for facts devices.json doesn't carry (CPU
model string, thread counts, sysfs names). Names that are best guesses are
marked "stand-in" below; overrides.json next to this file corrects a single
device without touching code: {"<device id>": {"cpu_model": "...", "threads": 16,
"leds": ["name"], "backlight": "name", "files": {"/sys/...": "value"},
"controller": "inputplumber" | "hhd" (the stack's controller service), "stack_add": ["steamos-manager"],
"battery": "BAT1", "sm_charge": 0 (steamos-manager MaxChargeLevel), "stack_remove": ["powerstation"],
"charge_threshold": 0, "os": "steamos-3.10", "ip_version": "0.78.0", "ip_targets": ["deck-uhid", ...],
"led_abi": "hid-asus-ally", "sm_gpu_profiles": [], "hwmon_extra": {"asus": {"pwm1_enable": 2}}}}.
A key "<row id>@<variant>" with "base": "<row id>" builds one more fixture of that row as it was
seen on a real setup (expect_row is the base row), so a live finding gets its own fixture.

Generic rules (from tested sources, so siblings get them through devices.json):
  * LED nodes whose expectations fact says "abi": "hid-msi" get hid-msi's attribute set
    (drivers/hid/hid-msi.c: effect/effect_index, enabled/enabled_index, speed/speed_range 0-20,
    channels 0-100) with effect, multi_intensity and brightness 0666 as on Bazzite.
  * msi_wmi_platform fans carry the EC's own Claw table (pwm 153..214, 47..78 C, read live
    on a Claw 8 EX); steamos-manager's FanControl1 is answered (state 0) on fan_via "fix"
    rows, as Bazzite does on every handheld.
  * msi-wmi-platform batteries (traits.ec) read charge_control_end_threshold 0 (EC limit
    never set); steamos-manager has acpi_sb configs for the Claws (data/devices/msi-claw-*.toml),
    so MaxChargeLevel answers 0 there.
  * xe: tile0/gt0/freq0 with rpa_freq and throttle/ as the kernel lays it out; Intel rows on
    steamos-manager get its Intel GpuPerformanceLevel1 (auto/manual, ManualGpuClock = min_freq).

Usage: python3 -I tools/devicematrix/gen.py OUT [--devices app/data/devices.json] [--only id,id]
Stdlib only. Deterministic: the same devices.json gives the same tree.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MARKER = ".devicematrix"

SM = "com.steampowered.SteamOSManager1"
SM_PATH = "/com/steampowered/SteamOSManager1"
PS = "org.shadowblip.PowerStation"
PS_GPU = "/org/shadowblip/Performance/GPU"
PS_CPU = "/org/shadowblip/Performance/CPU"
IP = "org.shadowblip.InputPlumber"
IP_ROOT = "/org/shadowblip/InputPlumber"

GENERIC = [
    {"id": "generic-amd", "vendor": "amd", "dmi": {"sys_vendor": "Generic Handheld Co.", "product_name": "GH-1 AMD",
     "board_name": "GH1A", "board_vendor": "Generic Handheld Co.", "product_family": "GH"},
     "cpu_model": "AMD Ryzen 7 8840U w/ Radeon 780M Graphics"},
    {"id": "generic-intel", "vendor": "intel", "dmi": {"sys_vendor": "Generic Handheld Co.", "product_name": "GH-1 Intel",
     "board_name": "GH1I", "board_vendor": "Generic Handheld Co.", "product_family": "GH"},
     "cpu_model": "Intel(R) Core(TM) Ultra 7 155H"},
]

# CPU model strings (as /proc/cpuinfo prints them) -> (cores, threads, max kHz, GPU PCI id).
CPUS = [
    ("Custom APU 0405", "AMD Custom APU 0405", 4, 8, 3500000, "1002:163F"),
    ("Custom APU 0932", "AMD Custom APU 0932", 4, 8, 3500000, "1002:1435"),
    ("Z2 Extreme", "AMD Ryzen AI Z2 Extreme w/ Radeon 890M Graphics", 8, 16, 5000000, "1002:150E"),
    ("Z2 Go", "AMD Ryzen Z2 Go", 4, 8, 4300000, "1002:15E7"),
    ("Z2 A", "AMD Ryzen Z2 A", 4, 8, 3800000, "1002:1435"),
    ("Ryzen Z2", "AMD Ryzen Z2", 8, 16, 5100000, "1002:15BF"),
    ("Z1 Extreme", "AMD Ryzen Z1 Extreme", 8, 16, 5100000, "1002:15BF"),
    ("Ryzen Z1", "AMD Ryzen Z1", 6, 12, 4900000, "1002:15BF"),
    ("AI Max", "AMD RYZEN AI MAX+ 395 w/ Radeon 8060S", 16, 32, 5100000, "1002:1586"),
    ("HX 370", "AMD Ryzen AI 9 HX 370 w/ Radeon 890M", 12, 24, 5100000, "1002:150E"),
    ("365", "AMD Ryzen AI 9 365 w/ Radeon 880M", 10, 20, 5000000, "1002:150E"),
    ("8840HS", "AMD Ryzen 7 8840HS w/ Radeon 780M Graphics", 8, 16, 5100000, "1002:1900"),
    ("8840U", "AMD Ryzen 7 8840U w/ Radeon 780M Graphics", 8, 16, 5100000, "1002:1900"),
    ("7840U", "AMD Ryzen 7 7840U w/ Radeon 780M Graphics", 8, 16, 5100000, "1002:15BF"),
    ("6800U", "AMD Ryzen 7 6800U with Radeon Graphics", 8, 16, 4700000, "1002:1681"),
    ("7320U", "AMD Ryzen 3 7320U with Radeon Graphics", 4, 8, 4100000, "1002:1506"),
    ("Panther Lake", "Intel(R) Core(TM) Ultra X7 358H", 16, 16, 4800000, "8086:B080"),
    ("Lunar Lake", "Intel(R) Core(TM) Ultra 7 258V", 8, 8, 4800000, "8086:64A0"),
    ("Arrow Lake", "Intel(R) Core(TM) Ultra 7 255H", 16, 16, 5100000, "8086:7D51"),
    ("Meteor Lake", "Intel(R) Core(TM) Ultra 7 155H", 16, 22, 4800000, "8086:7D55"),
    ("Ultra 7 155H", "Intel(R) Core(TM) Ultra 7 155H", 16, 22, 4800000, "8086:7D55"),
]

# Intel hybrid layouts: (P-core threads, E/LPE cores) so cpu_atom/cpus is right.
INTEL_ATOM = {"Panther Lake": 12, "Lunar Lake": 4, "Arrow Lake": 10, "Meteor Lake": 10}

# RGB LED class names come from expectations.json "facts" (HueSync / hhd, cited
# there): rgb.sysfs_leds is what a kernel driver exposes; rgb.present false or no
# sysfs_leds means HID/EC only, so no /sys/class/leds node is created.

FAN_TABLES = {"msi_wmi_platform": (2, 6), "asus_custom_fan_curve": (2, 8)}
FAN_MANUAL = {"oxp_ec": "oxpec", "ayaneo_ec": "ayaneo_ec", "gpdfan": "gpdfan", "zotac_zone_platform": "zotac_zone_platform",
              "lenovo_wmi_other": "lenovo_wmi_other", "steamdeck_hwmon": "steamdeck_hwmon"}

COMMON_TOOLS = ["busctl", "pkexec", "xprop", "wpctl", "pactl", "nmcli", "rfkill", "bluetoothctl", "gamescope",
                "mangohud", "mangohudctl", "systemctl", "loginctl", "brightnessctl", "python3", "sh"]


def concretize(pattern: str) -> str:
    """A string a DMI glob matches: '*Blaze 7*' -> 'Nitro Blaze 7', 'MS-1T*' -> 'MS-1T00'."""
    s = pattern
    if s.startswith("*"):
        s = "Nitro " + s[1:] if "Blaze" in s else s[1:]
    s = s.replace("*", "00").replace("?", "0")
    return s


def dmi_for(row: dict, devices: list) -> dict:
    m = row["match"]
    alt = m[0] if isinstance(m, list) else m
    dmi = {k: concretize(v[0]) for k, v in alt.items()}
    if row.get("tier") == "family":
        # a model in the family that no specific row knows
        for k in ("product_name", "board_name"):
            if k in dmi and ("00" in dmi[k] or k == "product_name"):
                dmi[k] = dmi[k].replace("00", "ZZ") if "00" in dmi[k] else "Future Model"
        if "product_name" not in dmi:
            dmi["product_name"] = "Future Model"
    maker = row.get("maker", "")
    dmi.setdefault("sys_vendor", "Micro-Star International Co., Ltd." if maker == "MSI" else maker)
    dmi.setdefault("board_vendor", dmi["sys_vendor"])
    dmi.setdefault("product_name", row["name"])
    dmi.setdefault("board_name", "DM-" + row["id"][:12].upper())
    dmi.setdefault("product_family", row.get("family", "") or row["maker"])
    return dmi


def score(row: dict, dmi: dict) -> int:
    """device.gd match_score(), so the generator can check its own DMI picks."""
    tiers = {"specific": 2, "family": 1, "generic": 0}
    m = row.get("match", {})
    best = -1
    for alt in (m if isinstance(m, list) else [m]):
        compared = exact = 0
        ok = True
        for key, pats in alt.items():
            if key not in dmi:
                continue
            hit = next((p for p in pats if dmi[key] and fnmatch.fnmatchcase(dmi[key].lower(), p.lower())), "")
            if not hit:
                ok = False
                break
            compared += 1
            exact += 0 if ("*" in hit or "?" in hit) else 1
        if ok and compared:
            best = max(best, tiers.get(row.get("tier", "specific"), 2) * 1000 + compared * 10 + exact)
    return best


def cpu_for(row: dict, override: dict) -> tuple:
    chip = row.get("chip", "")
    model = override.get("cpu_model", "")
    if not model:
        if "Van Gogh" in chip:
            key = "Custom APU 0405"
        elif "Sephiroth" in chip:
            key = "Custom APU 0932"
        elif row.get("cpu_vendor") == "intel":
            key = next((k for k in INTEL_ATOM if k in chip), "Meteor Lake")
        else:
            first = re.split(r" / |, or ", chip)[0]
            key = next((c[0] for c in CPUS if c[0].lower() in first.lower()), "8840U")
        entry = next(c for c in CPUS if c[0] == key)
    else:
        entry = next((c for c in CPUS if c[0].lower() in model.lower()), ("", model, 8, 16, 4800000,
                     "8086:7D55" if "intel" in model.lower() else "1002:15BF"))
        entry = (entry[0], model) + tuple(entry[2:])
    _, model, cores, threads, khz, pci = entry
    cores = int(override.get("cores", cores))
    threads = int(override.get("threads", threads))
    return model, cores, threads, khz, pci, entry[0]


class Tree:
    def __init__(self, root: str):
        self.root = root
        self.count = 0

    def w(self, path: str, value) -> None:
        p = os.path.join(self.root, path.lstrip("/"))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(str(value) if not isinstance(value, bool) else ("1" if value else "0"))
            if not str(value).endswith("\n"):
                f.write("\n")
        self.count += 1

    def d(self, path: str) -> None:
        os.makedirs(os.path.join(self.root, path.lstrip("/")), exist_ok=True)


def tdp_of(row: dict) -> dict:
    t = dict(row.get("tdp") or {})
    t.setdefault("min", 5)
    t.setdefault("battery_max", 20)
    t.setdefault("plugged_max", t["battery_max"])
    t.setdefault("boost_max", t["plugged_max"])
    return t


def build(row: dict, out: str, override: dict, generic: dict | None, devices: list, facts: dict) -> dict:
    did = generic["id"] if generic else row["id"]
    base = os.path.join(out, did)
    root = os.path.join(base, "root")
    t = Tree(root)
    vendor = generic["vendor"] if generic else row.get("cpu_vendor", "amd") or "amd"
    if generic:
        dmi = dict(generic["dmi"])
        override = dict(override, cpu_model=override.get("cpu_model", generic["cpu_model"]))
        row = {"id": did, "name": dmi["product_name"], "maker": dmi["sys_vendor"], "cpu_vendor": vendor,
               "gpu_family": "", "chip": generic["cpu_model"], "tdp": None, "fan": None, "rgb": None, "imu": None,
               "charge_limit": False, "charge_limit_via": None, "panel": None, "panel_hz": [], "gyro": "unknown",
               "tdp_backends": ["steamos-manager", "powerstation"]}
    else:
        dmi = dmi_for(row, devices)
    model, cores, threads, khz, pci, chip_key = cpu_for(row, override)
    gpu_family = row.get("gpu_family", "") or ""
    intel = vendor == "intel"
    maker = (row.get("maker") or "").lower()

    # DMI, OS
    for k, v in dmi.items():
        t.w(f"/sys/class/dmi/id/{k}", v)
    t.w("/sys/class/dmi/id/bios_vendor", dmi["sys_vendor"])
    t.w("/sys/class/dmi/id/bios_version", "DM1.00")
    t.w("/sys/class/dmi/id/chassis_type", "31")
    if override.get("os") == "steamos-3.10":
        t.w("/proc/sys/kernel/osrelease", "7.2.4-valve1-1-neptune")
        t.w("/etc/os-release", 'NAME="SteamOS"\nID=steamos\nID_LIKE=arch\nVERSION_ID=3.10\nBUILD_ID=20260924.1000\n'
            'PRETTY_NAME="SteamOS"\nVARIANT_ID=steamdeck')
    else:
        t.w("/proc/sys/kernel/osrelease", "6.17.7-ba14.fc43.x86_64")
        t.w("/etc/os-release", 'NAME="Bazzite"\nID=bazzite\nID_LIKE="fedora"\nVERSION_ID=43\nVARIANT_ID=bazzite-deck\n'
            'PRETTY_NAME="Bazzite 43 (FROM Fedora Kinoite)"')

    # CPU
    lines = []
    for n in range(threads):
        lines += [f"processor\t: {n}", f"vendor_id\t: {'GenuineIntel' if intel else 'AuthenticAMD'}",
                  f"model name\t: {model}", "physical id\t: 0", f"core id\t\t: {n % cores}",
                  f"cpu cores\t: {cores}", f"siblings\t: {threads}", ""]
    t.w("/proc/cpuinfo", "\n".join(lines))
    cpu = "/sys/devices/system/cpu"
    t.w(f"{cpu}/online", f"0-{threads - 1}")
    t.w(f"{cpu}/present", f"0-{threads - 1}")
    t.w(f"{cpu}/possible", f"0-{threads - 1}")
    smt = threads > cores
    t.w(f"{cpu}/smt/control", "on" if smt else "notsupported")
    t.w(f"{cpu}/smt/active", "1" if smt else "0")
    prefs = "default performance balance_performance balance_power power"
    for n in range(threads):
        c = f"{cpu}/cpu{n}"
        if n > 0:
            t.w(f"{c}/online", "1")
        f = f"{c}/cpufreq"
        t.w(f"{f}/scaling_driver", "intel_pstate" if intel else "amd-pstate-epp")
        t.w(f"{f}/scaling_governor", "powersave")
        t.w(f"{f}/scaling_available_governors", "performance powersave")
        t.w(f"{f}/energy_performance_preference", "balance_performance")
        t.w(f"{f}/energy_performance_available_preferences", prefs)
        t.w(f"{f}/cpuinfo_min_freq", 400000)
        t.w(f"{f}/cpuinfo_max_freq", khz)
        t.w(f"{f}/scaling_min_freq", 400000)
        t.w(f"{f}/scaling_max_freq", khz)
        t.w(f"{f}/scaling_cur_freq", 1400000)
    if intel:
        for k, v in {"status": "active", "no_turbo": 0, "max_perf_pct": 100, "min_perf_pct": 8,
                     "hwp_dynamic_boost": 0, "turbo_pct": 40, "num_pstates": 44}.items():
            t.w(f"{cpu}/intel_pstate/{k}", v)
        atoms = INTEL_ATOM.get(chip_key, 0)
        if atoms:
            t.w("/sys/devices/cpu_atom/cpus", f"{threads - atoms}-{threads - 1}")
            t.w("/sys/devices/cpu_core/cpus", f"0-{threads - atoms - 1}")
    else:
        t.w(f"{cpu}/cpufreq/boost", 1)
        t.w(f"{cpu}/amd_pstate/status", "active")

    # GPU
    if intel:
        driver = "xe" if gpu_family in ("intel-xe2", "intel-xe3") or (not gpu_family and pci in ("8086:B080", "8086:64A0")) else "i915"
        card = "card0"
    else:
        driver = "amdgpu"
        card = "card1"
    dev = f"/sys/class/drm/{card}/device"
    t.w(f"{dev}/uevent", f"DRIVER={driver}\nPCI_CLASS=30000\nPCI_ID={pci}\nPCI_SUBSYS_ID={pci}\nPCI_SLOT_NAME=0000:00:02.0")
    t.w(f"{dev}/vendor", "0x" + pci.split(":")[0].lower())
    t.w(f"{dev}/device", "0x" + pci.split(":")[1].lower())
    hw = 0
    if driver == "amdgpu":
        t.w(f"{dev}/power_dpm_force_performance_level", "auto")
        t.w(f"{dev}/pp_dpm_sclk", "0: 800Mhz\n1: 1600Mhz *\n2: 2700Mhz")
        t.w(f"{dev}/pp_od_clk_voltage", "OD_SCLK:\n0:        800Mhz\n1:       2700Mhz\nOD_RANGE:\nSCLK:     800Mhz       2700Mhz")
        t.w(f"{dev}/pp_power_profile_mode", "  0 BOOTUP_DEFAULT*\n  1 3D_FULL_SCREEN\n  2 POWER_SAVING\n  3 VIDEO\n  4 VR\n  5 COMPUTE\n  6 CUSTOM")
        t.w(f"{dev}/gpu_busy_percent", 3)
        t.w(f"{dev}/mem_info_vram_total", 4294967296)
        t.w(f"{dev}/mem_info_vram_used", 805306368)
        hwmon = f"/sys/class/hwmon/hwmon{hw}"
        t.w(f"{hwmon}/name", "amdgpu")
        t.w(f"{hwmon}/power1_average", 6000000)
        t.w(f"{hwmon}/temp1_input", 45000)
        t.w(f"{hwmon}/freq1_input", 1600000000)
        hw += 1
    elif driver == "xe":
        freq = f"{dev}/tile0/gt0/freq0"
        for k, v in {"min_freq": 400, "max_freq": 2500, "cur_freq": 900, "act_freq": 900, "rp0_freq": 2500,
                     "rpe_freq": 1300, "rpn_freq": 400}.items():
            t.w(f"{freq}/{k}", v)
        t.w(f"{freq}/power_profile", "[base] power_saving")
        t.w(f"{freq}/rpa_freq", 1300)
        t.w(f"{freq}/throttle/status", 0)
        t.w(f"{dev}/tile0/gt1/freq0/min_freq", 400)   # media GT: never to be touched
        t.w(f"{dev}/tile0/gt1/freq0/max_freq", 1400)
        hwmon = f"/sys/class/hwmon/hwmon{hw}"
        t.w(f"{hwmon}/name", "xe")
        t.w(f"{hwmon}/energy1_input", 123456789)
        hw += 1
    else:
        c = f"/sys/class/drm/{card}"
        for k, v in {"gt_min_freq_mhz": 300, "gt_max_freq_mhz": 2250, "gt_cur_freq_mhz": 800, "gt_act_freq_mhz": 800,
                     "gt_boost_freq_mhz": 2250, "gt_RP0_freq_mhz": 2250, "gt_RP1_freq_mhz": 1000,
                     "gt_RPn_freq_mhz": 300}.items():
            t.w(f"{c}/{k}", v)
    panel = row.get("panel") or {}
    res = panel.get("resolution") or [1920, 1080]
    conn = f"/sys/class/drm/{card}-eDP-1"
    t.w(f"{conn}/status", "connected")
    t.w(f"{conn}/enabled", "enabled")
    t.w(f"{conn}/modes", f"{res[0]}x{res[1]}")
    t.w(f"{conn}/dpms", "On")

    # CPU temperature
    hwmon = f"/sys/class/hwmon/hwmon{hw}"
    t.w(f"{hwmon}/name", "coretemp" if intel else "k10temp")
    t.w(f"{hwmon}/temp1_input", 52000)
    t.w(f"{hwmon}/temp1_label", "Package id 0" if intel else "Tctl")
    hw += 1

    # Fan
    fan = row.get("fan") or ""
    if fan in FAN_TABLES:
        n_fans, points = FAN_TABLES[fan]
        hwmon = f"/sys/class/hwmon/hwmon{hw}"
        t.w(f"{hwmon}/name", fan)
        for n in range(1, n_fans + 1):
            t.w(f"{hwmon}/pwm{n}_enable", 2)
            t.w(f"{hwmon}/fan{n}_input", 2900)
            for p in range(1, points + 1):
                if fan == "msi_wmi_platform":   # the EC's own table, read live on a Claw 8 EX
                    t.w(f"{hwmon}/pwm{n}_auto_point{p}_pwm", [153, 163, 173, 188, 204, 214][p - 1])
                    t.w(f"{hwmon}/pwm{n}_auto_point{p}_temp", [47, 50, 57, 64, 71, 78][p - 1])
                else:
                    t.w(f"{hwmon}/pwm{n}_auto_point{p}_pwm", min(255, p * 40))
                    t.w(f"{hwmon}/pwm{n}_auto_point{p}_temp", 30000 + p * 10000)
        hw += 1
    elif fan in FAN_MANUAL:
        hwmon = f"/sys/class/hwmon/hwmon{hw}"
        name = FAN_MANUAL[fan]
        t.w(f"{hwmon}/name", name)
        t.w(f"{hwmon}/fan1_input", 3100)
        if fan == "steamdeck_hwmon":
            t.w(f"{hwmon}/fan1_target", 3000)
            t.w(f"{hwmon}/recalculate", 0)
        else:
            t.w(f"{hwmon}/pwm1", 128)
            t.w(f"{hwmon}/pwm1_enable", "0" if name == "oxpec" else "2")
        hw += 1

    for hname, files in (override.get("hwmon_extra") or {}).items():
        hwmon = f"/sys/class/hwmon/hwmon{hw}"
        t.w(f"{hwmon}/name", hname)
        for k, v in files.items():
            t.w(f"{hwmon}/{k}", v)
        hw += 1

    # Power supply
    ac = "ACAD" if row["id"].startswith("steam-deck") else ("AC0" if maker.startswith("asus") else "ADP1")
    bat = override.get("battery") or ("BAT1" if row["id"].startswith("steam-deck") else "BAT0")
    ps = "/sys/class/power_supply"
    t.w(f"{ps}/{ac}/type", "Mains")
    t.w(f"{ps}/{ac}/online", 0)
    t.w(f"{ps}/ucsi-source-psy-USBC000:001/type", "USB")
    t.w(f"{ps}/ucsi-source-psy-USBC000:001/online", 0)
    if bat == "BAT1" and not row["id"].startswith("steam-deck"):
        t.w(f"{ps}/ucsi-source-psy-USBC000:002/type", "USB")
        t.w(f"{ps}/ucsi-source-psy-USBC000:002/online", 0)
    b = f"{ps}/{bat}"
    for k, v in {"type": "Battery", "status": "Discharging", "present": 1, "capacity": 76, "energy_now": 45600000,
                 "energy_full": 60000000, "energy_full_design": 64000000, "power_now": 9500000,
                 "voltage_now": 15400000, "cycle_count": 42, "technology": "Li-poly"}.items():
        t.w(f"{b}/{k}", v)
    via = row.get("charge_limit_via")
    behaviour = via == "sysfs" and maker.startswith("ayaneo")
    msi_ec = "msi-wmi-platform" in ((row.get("traits") or {}).get("ec") or [])
    if "charge_threshold" in override:
        t.w(f"{b}/charge_control_end_threshold", override["charge_threshold"])
    elif row.get("charge_limit") and (via in ("sysfs", "fix") or msi_ec) and not behaviour:
        t.w(f"{b}/charge_control_end_threshold", 0 if msi_ec else 100)
    if behaviour or (via == "sysfs" and fan == "oxp_ec"):
        t.w(f"{b}/charge_behaviour", "[auto] inhibit-charge")

    # Backlight
    bl = override.get("backlight") or ("intel_backlight" if intel else ("amdgpu_bl0" if row["id"].startswith("steam-deck") else "amdgpu_bl1"))
    bmax = 96000 if intel else 255
    t.w(f"/sys/class/backlight/{bl}/max_brightness", bmax)
    t.w(f"/sys/class/backlight/{bl}/brightness", bmax // 2)
    t.w(f"/sys/class/backlight/{bl}/actual_brightness", bmax // 2)
    t.w(f"/sys/class/backlight/{bl}/type", "raw")
    t.w(f"/sys/class/backlight/{bl}/bl_power", 0)

    # LEDs (kernel class only; HID/EC RGB has no sysfs node)
    rgb = row.get("rgb") or {}
    leds = override.get("leds")
    fact = facts.get(did, {}).get("rgb") or {}
    abi = override.get("led_abi") or fact.get("abi", "")
    if leds is None:
        fact = facts.get(did, {}).get("rgb")
        if fact is not None:
            leds = list(fact.get("sysfs_leds", [])) if fact.get("present") else []
        else:
            leds = ["ayaneo:rgb:joystick_rings"] if rgb.get("via") == "ayaneo-ec" else []
    for name in leds:
        lp = f"/sys/class/leds/{name}"
        t.w(f"{lp}/brightness", 128)
        t.w(f"{lp}/max_brightness", 255)
        t.w(f"{lp}/multi_index", "red green blue")
        t.w(f"{lp}/multi_intensity", "255 255 255")
        t.w(f"{lp}/trigger", "[none]")
        if abi == "hid-asus-ally":   # packed 0xRRGGBB per zone, 0644 root (SteamOS 3.10, original Ally)
            t.w(f"{lp}/multi_index", "rgb rgb rgb rgb")
            t.w(f"{lp}/multi_intensity", "16744448 16744448 16744448 16744448")
            t.w(f"{lp}/sleep_animation", 0)
            t.w(f"{lp}/sleep_animation_index", "0 1")
        if abi == "hid-msi":   # drivers/hid/hid-msi.c, values as read live on a Claw 8 EX
            for k, v in {"brightness": 21, "max_brightness": 100, "multi_intensity": "1 90 100",
                         "multi_max_intensity": "100 100 100", "effect": "monocolor",
                         "effect_index": "monocolor breathe chroma rainbow frostfire", "enabled": "false",
                         "enabled_index": "true false", "speed": 10, "speed_range": "0-20"}.items():
                t.w(f"{lp}/{k}", v)
            for k in ("effect", "multi_intensity", "brightness"):
                os.chmod(os.path.join(root, lp.lstrip("/"), k), 0o666)

    # Firmware attributes (PPT limits)
    tdp = tdp_of(row) if row.get("tdp") else None
    fw = None
    if maker.startswith("asus"):
        fw = "asus-armoury"
    elif maker == "lenovo":
        fw = "lenovo-wmi-other-0"     # SimpleDeckyTDP py_modules/devices/lenovo.py
    elif fan == "msi_wmi_platform" and row.get("tier") != "family":
        fw = "msi-wmi-platform"
    if fw and tdp:
        for attr, hi in (("ppt_pl1_spl", tdp["plugged_max"]), ("ppt_pl2_sppt", tdp["boost_max"]),
                         ("ppt_pl3_fppt", tdp["boost_max"])):
            a = f"/sys/class/firmware-attributes/{fw}/attributes/{attr}"
            t.w(f"{a}/type", "integer")
            t.w(f"{a}/min_value", tdp["min"])
            t.w(f"{a}/max_value", hi)
            t.w(f"{a}/scalar_increment", 1)
            t.w(f"{a}/default_value", min(hi, tdp["battery_max"]))
            t.w(f"{a}/current_value", min(hi, tdp["battery_max"]))
            t.w(f"{a}/display_name", attr)

    # RAPL
    if intel:
        tt = tdp or {"min": 8, "battery_max": 25, "plugged_max": 28, "boost_max": 30}
        for dom in ("intel-rapl:0", "intel-rapl-mmio:0"):
            r = f"/sys/class/powercap/{dom}"
            t.w(f"{r}/name", "package-0")
            t.w(f"{r}/enabled", 1)
            t.w(f"{r}/energy_uj", 987654321)
            t.w(f"{r}/max_energy_range_uj", 262143328850)
            t.w(f"{r}/constraint_0_name", "long_term")
            t.w(f"{r}/constraint_0_power_limit_uw", tt["battery_max"] * 1000000)
            t.w(f"{r}/constraint_0_max_power_uw", tt["plugged_max"] * 1000000)
            t.w(f"{r}/constraint_0_time_window_us", 28000000)
            t.w(f"{r}/constraint_1_name", "short_term")
            t.w(f"{r}/constraint_1_power_limit_uw", tt.get("boost_max", tt["plugged_max"]) * 1000000)
            t.w(f"{r}/constraint_1_time_window_us", 2440)
    else:
        t.w("/sys/class/powercap/intel-rapl:0/name", "package-0")
        t.w("/sys/class/powercap/intel-rapl:0/energy_uj", 123456789)

    # radios and sleep states
    t.w("/sys/class/ieee80211/phy0/name", "phy0")
    t.w("/sys/class/bluetooth/hci0/name", "hci0")
    for i, (kind, name) in enumerate((("wlan", "phy0"), ("bluetooth", "hci0"))):
        t.w(f"/sys/class/rfkill/rfkill{i}/type", kind)
        t.w(f"/sys/class/rfkill/rfkill{i}/name", name)
        t.w(f"/sys/class/rfkill/rfkill{i}/soft", 0)
        t.w(f"/sys/class/rfkill/rfkill{i}/hard", 0)
        t.w(f"/sys/class/rfkill/rfkill{i}/state", 1)
    t.w("/sys/power/state", "freeze mem disk")
    t.w("/sys/power/mem_sleep", "s2idle [deep]" if not intel else "[s2idle]")

    # IMU
    imu = (row.get("imu") or "").lower()
    names = []
    if "bmi260" in imu:
        names = ["bmi260"]
    elif "bmi323" in imu:
        names = ["bmi323-imu"]
    elif "accel_3d" in imu or "sensor hub" in imu:
        names = ["accel_3d", "gyro_3d"] if row.get("gyro") != "fix" else ["accel_3d"]
    for i, n in enumerate(names):
        p = f"/sys/bus/iio/devices/iio:device{i}"
        t.w(f"{p}/name", n)
        t.w(f"{p}/in_accel_x_raw" if "gyro" not in n else f"{p}/in_anglvel_x_raw", 12)
        t.w(f"{p}/in_accel_scale" if "gyro" not in n else f"{p}/in_anglvel_scale", "0.000598")
        t.w(f"{p}/mount_matrix", "1, 0, 0; 0, 1, 0; 0, 0, 1")

    # Stack (what's installed and running)
    stack = []
    order = row.get("tdp_backends") or ["steamos-manager", "powerstation"]
    for s in order:
        stack.append(s)
    for s_rm in override.get("stack_remove") or []:
        if s_rm in stack:
            stack.remove(s_rm)
    for s_add in override.get("stack_add") or []:
        if s_add not in stack:
            stack.append(s_add)
    controller = override.get("controller") or ("hhd" if rgb.get("via") == "hhd" else "inputplumber")
    stack.append(controller)
    stack += ["gamescope", "pipewire", "networkmanager", "bluez"]
    tools = list(COMMON_TOOLS) + [{"steamos-manager": "steamos-manager", "powerstation": "powerstation",
                                   "inputplumber": "inputplumber", "hhd": "hhd"}[s] for s in stack
                                  if s in ("steamos-manager", "powerstation", "inputplumber", "hhd")]
    for tool in tools:
        t.w(f"/usr/bin/{tool}", "#!/bin/sh\n# devicematrix stand-in\nexit 0")
    t.w("/usr/share/gamescope-session-plus/gamescope-session-plus", "#!/bin/sh\n# devicematrix stand-in")
    t.d("/home/.config/environment.d")
    t.d("/home/.config/gamecove")
    t.w("/usr/libexec/gamecove/gamecove-fix", "#!/bin/sh\n# devicematrix stand-in\nexit 0")
    t.w("/usr/libexec/gamecove/gamecove-fix-set", "#!/bin/sh\n# devicematrix stand-in\nexit 0")
    t.w("/run/dbus/system_bus_socket", "")
    t.w("/run/user/1000/bus", "")
    t.d("/home/.config")
    t.d("/home/.local/share/Steam/steamapps")
    if controller == "hhd":
        t.w("/tmp/hhd/token", "devicematrix-token")
        t.d("/run/hhd")   # hhd creates its runtime folder at start (hhd_client.present())

    for path, value in (override.get("files") or {}).items():
        t.w(path, value)

    backends = backends_for(row, tdp, stack, controller, vendor, gpu_family, maker, threads, cores, smt, override)
    with open(os.path.join(base, "backends.json"), "w", encoding="utf-8") as f:
        json.dump(backends, f, indent=1, sort_keys=True)

    return {"id": did, "expect_row": "unknown" if generic else row["id"], "generic": bool(generic),
            "vendor": vendor, "root": root, "home": os.path.join(root, "home"),
            "backends": os.path.join(base, "backends.json"),
            "ac_online_file": f"/sys/class/power_supply/{ac}/online", "battery": f"/sys/class/power_supply/{bat}",
            "backlight": bl, "leds": leds, "gpu_driver": driver, "gpu_card": card, "cpu_model": model,
            "threads": threads, "cores": cores, "stack": stack, "files": t.count,
            "tdp": tdp, "dmi": dmi}


def backends_for(row, tdp, stack, controller, vendor, gpu_family, maker, threads, cores, smt, override=None) -> dict:
    override = override or {}
    props: dict = {}
    methods: dict = {}

    def prop(bus, svc, path, iface, name, typ, data):
        props[f"{bus} {svc} {path} {iface} {name}"] = {"type": typ, "data": data}

    t = tdp or {"min": 5, "battery_max": 20, "plugged_max": 25, "boost_max": 25}
    cur = int(round((t["min"] + t["battery_max"]) / 2))
    if "steamos-manager" in stack:
        prop("--user", SM, SM_PATH, f"{SM}.TdpLimit1", "TdpLimit", "u", cur)
        prop("--user", SM, SM_PATH, f"{SM}.TdpLimit1", "TdpLimitMin", "u", int(t["min"]))
        prop("--user", SM, SM_PATH, f"{SM}.TdpLimit1", "TdpLimitMax", "u", int(t["plugged_max"]))
        level = 80 if row.get("charge_limit_via") == "steamos-manager" else -1
        if "sm_charge" in override:
            level = int(override["sm_charge"])
        prop("--user", SM, SM_PATH, f"{SM}.BatteryChargeLimit1", "MaxChargeLevel", "i", level)
        prop("--user", SM, SM_PATH, f"{SM}.BatteryChargeLimit1", "SuggestedMinimumLimit", "i", 10)
        if row.get("fan_via") == "steamos-manager":
            prop("--user", SM, SM_PATH, f"{SM}.FanControl1", "FanControlState", "u", 1)
        elif row.get("fan_via") == "fix":   # Bazzite answers it on every handheld (jupiter-fan-control)
            prop("--user", SM, SM_PATH, f"{SM}.FanControl1", "FanControlState", "u", 0)
        if "sm_gpu_profiles" in override:
            prop("--user", SM, SM_PATH, f"{SM}.GpuPowerProfile1", "GpuPowerProfile", "s", "")
            prop("--user", SM, SM_PATH, f"{SM}.GpuPowerProfile1", "AvailableGpuPowerProfiles", "as", override["sm_gpu_profiles"])
        prop("--user", SM, SM_PATH, f"{SM}.PerformanceProfile1", "PerformanceProfile", "s", "balanced")
        prop("--user", SM, SM_PATH, f"{SM}.PerformanceProfile1", "AvailablePerformanceProfiles", "as",
             ["low-power", "balanced", "performance"])
        prop("--user", SM, SM_PATH, f"{SM}.CpuScaling1", "CpuScalingGovernor", "s", "powersave")
        prop("--user", SM, SM_PATH, f"{SM}.CpuScaling1", "AvailableCpuScalingGovernors", "as", ["performance", "powersave"])
        if vendor == "intel" and "msi-wmi-platform" in ((row.get("traits") or {}).get("ec") or []):
            # steamos-manager's Intel driver (data/devices/msi-claw-*.toml gpu_performance intel)
            prop("--user", SM, SM_PATH, f"{SM}.GpuPerformanceLevel1", "GpuPerformanceLevel", "s", "auto")
            prop("--user", SM, SM_PATH, f"{SM}.GpuPerformanceLevel1", "AvailableGpuPerformanceLevels", "as", ["auto", "manual"])
            prop("--user", SM, SM_PATH, f"{SM}.GpuPerformanceLevel1", "ManualGpuClock", "u", 400)
            prop("--user", SM, SM_PATH, f"{SM}.GpuPerformanceLevel1", "ManualGpuClockMin", "u", 1300)
            prop("--user", SM, SM_PATH, f"{SM}.GpuPerformanceLevel1", "ManualGpuClockMax", "u", 1300)
        if vendor == "amd":
            prop("--user", SM, SM_PATH, f"{SM}.GpuPerformanceLevel1", "GpuPerformanceLevel", "s", "auto")
            prop("--user", SM, SM_PATH, f"{SM}.GpuPerformanceLevel1", "AvailableGpuPerformanceLevels", "as",
                 ["auto", "low", "high", "manual", "peak_performance"])
            prop("--user", SM, SM_PATH, f"{SM}.GpuPerformanceLevel1", "ManualGpuClock", "u", 1600)
            prop("--user", SM, SM_PATH, f"{SM}.GpuPerformanceLevel1", "ManualGpuClockMin", "u", 800)
            prop("--user", SM, SM_PATH, f"{SM}.GpuPerformanceLevel1", "ManualGpuClockMax", "u", 2700)
    if "powerstation" in stack:
        card = f"{PS_GPU}/card0" if vendor == "intel" else f"{PS_GPU}/card1"
        methods[f"--system {PS} {PS_GPU} org.shadowblip.GPU EnumerateCards"] = {"type": "ao", "data": [[card]]}
        xe3 = gpu_family == "intel-xe3"   # PowerStation has no Panther Lake limits yet: 0/0 (power.gd)
        prop("--system", PS, card, "org.shadowblip.GPU.Card.TDP", "TDP", "d", float(cur))
        prop("--system", PS, card, "org.shadowblip.GPU.Card.TDP", "MinTdp", "d", 0.0 if xe3 else float(t["min"]))
        prop("--system", PS, card, "org.shadowblip.GPU.Card.TDP", "MaxTdp", "d", 0.0 if xe3 else float(t["plugged_max"]))
        prop("--system", PS, card, "org.shadowblip.GPU.Card.TDP", "Boost", "d", float(t["boost_max"] - t["plugged_max"]))
        prop("--system", PS, card, "org.shadowblip.GPU.Card.TDP", "MaxBoost", "d", float(t["boost_max"] - t["min"]))
        prop("--system", PS, card, "org.shadowblip.GPU.Card", "ManualClock", "b", False)
        prop("--system", PS, card, "org.shadowblip.GPU.Card", "ClockLimitMin", "d", 400.0 if vendor == "intel" else 800.0)
        prop("--system", PS, card, "org.shadowblip.GPU.Card", "ClockLimitMax", "d", 2500.0 if vendor == "intel" else 2700.0)
        prop("--system", PS, card, "org.shadowblip.GPU.Card", "ClockValueMin", "d", 400.0 if vendor == "intel" else 800.0)
        prop("--system", PS, card, "org.shadowblip.GPU.Card", "ClockValueMax", "d", 2500.0 if vendor == "intel" else 2700.0)
        prop("--system", PS, PS_CPU, "org.shadowblip.CPU", "BoostEnabled", "b", True)
        prop("--system", PS, PS_CPU, "org.shadowblip.CPU", "SmtEnabled", "b", smt)
        prop("--system", PS, PS_CPU, "org.shadowblip.CPU", "CoresCount", "u", threads)
        prop("--system", PS, PS_CPU, "org.shadowblip.CPU", "CoresEnabled", "u", threads)
        prop("--system", PS, PS_CPU, "org.shadowblip.CPU", "Features", "as", ["boost"] + (["smt"] if smt else []))
    prop("--system", "org.bluez", "/org/bluez/hci0", "org.bluez.Adapter1", "Powered", "b", True)
    prop("--system", "org.bluez", "/org/bluez/hci0", "org.bluez.Adapter1", "Name", "s", "devicematrix")
    hhd = None
    if controller == "inputplumber":
        dev_path = f"{IP_ROOT}/CompositeDevice0"
        caps = ["Gamepad:Button:South", "Gamepad:Button:East", "Gamepad:Button:North", "Gamepad:Button:West",
                "Gamepad:Button:Guide", "Gamepad:Button:QuickAccess", "Gamepad:Axis:LeftStick", "Gamepad:Axis:RightStick",
                "Gamepad:Trigger:LeftTrigger", "Gamepad:Trigger:RightTrigger"]
        if row.get("gyro") in ("yes", "fix"):
            caps += ["Gamepad:Accelerometer", "Gamepad:Gyro"]
        if row.get("buttons") not in (None, "generic"):
            caps += ["Gamepad:Button:LeftPaddle1", "Gamepad:Button:RightPaddle1"]
        outs = ["ForceFeedback"] + (["LED:Color", "LED:Brightness"] if row.get("rgb") else [])
        name = f"{row.get('name', 'Handheld')} Controller"
        iface = "org.shadowblip.Input.CompositeDevice"
        prop("--system", IP, f"{IP_ROOT}/Manager", "org.shadowblip.InputManager", "Version", "s", override.get("ip_version", "0.62.0"))
        prop("--system", IP, f"{IP_ROOT}/Manager", "org.shadowblip.InputManager", "GamepadOrder", "ao", [dev_path])
        prop("--system", IP, dev_path, iface, "Name", "s", name)
        prop("--system", IP, dev_path, iface, "ProfileName", "s", "Default")
        prop("--system", IP, dev_path, iface, "ProfilePath", "s", "/usr/share/inputplumber/profiles/default.yaml")
        prop("--system", IP, dev_path, iface, "Capabilities", "as", caps)
        prop("--system", IP, dev_path, iface, "OutputCapabilities", "as", outs)
        prop("--system", IP, dev_path, iface, "InterceptMode", "u", 0)
        prop("--system", IP, dev_path, "org.shadowblip.Output.ForceFeedback", "Enabled", "b", True)
        objs = {dev_path: {
                iface: {"Name": {"type": "s", "data": name}, "ProfileName": {"type": "s", "data": "Default"},
                        "Capabilities": {"type": "as", "data": caps}, "OutputCapabilities": {"type": "as", "data": outs}},
                "org.shadowblip.Output.ForceFeedback": {"Enabled": {"type": "b", "data": True}}}}
        if override.get("ip_targets"):
            tpaths = []
            for i, kind in enumerate(override["ip_targets"]):
                tp = f"{IP_ROOT}/devices/target/{kind.replace('-', '_')}{i}"
                tpaths.append(tp)
                objs[tp] = {"org.shadowblip.Input.Target": {"DeviceType": {"type": "s", "data": kind}}}
                prop("--system", IP, tp, "org.shadowblip.Input.Target", "DeviceType", "s", kind)
            objs[dev_path][iface]["TargetDevices"] = {"type": "as", "data": tpaths}
            prop("--system", IP, dev_path, iface, "TargetDevices", "as", tpaths)
        methods[f"--system {IP} {IP_ROOT} org.freedesktop.DBus.ObjectManager GetManagedObjects"] = {
            "type": "a{oa{sa{sv}}}", "data": [objs]}
    else:
        key = {"lenovo": "legion_go", "micro-star international co., ltd.": "claw", "msi": "claw"}.get(maker, "handheld")
        driver = "lenovo" if maker == "lenovo" else ("msi" if key == "claw" else "smu")
        tdp_node = {"tdp": {"mode": "custom", "custom": {"tdp": cur}}} if driver != "smu" else {"tdp": cur}
        hhd = {"version": 5,
               "controllers": {key: {"imu": row.get("gyro") in ("yes", "fix"),
                                     "controller_mode": {"mode": "dualsense", "dualsense": {"paddles_as": "steam_input"}},
                                     "limits": {"mode": "default"}}},
               "rgb": {"handheld": {"mode": {"mode": "solid", "solid": {"hue": 30, "saturation": 100, "brightness": 50}}}},
               "tdp": {driver if driver != "smu" else "qam": tdp_node},
               "hhd": {"settings": {"tdp_enable": True}, "http": {"enable": True, "token": True}},
               "info": {"device": row.get("name", "")}}
    commands = [
        {"argv": ["xprop", "-id", "*", "-f", "**"], "code": 0, "out": "", "write": True},
        {"argv": ["xprop", "-id", "**"], "code": 0, "out": ""},
        {"argv": ["wpctl", "status"], "code": 0, "out": "Audio\n ├─ Sinks:\n │  *   50. Speaker                    [vol: 0.50]\n │      51. HDMI / DisplayPort        [vol: 1.00]\n ├─ Sources:\n │  *   60. Digital Microphone        [vol: 0.80]\n"},
        {"argv": ["wpctl", "get-volume", "**"], "code": 0, "out": "Volume: 0.50"},
        {"argv": ["wpctl", "set-volume", "**"], "code": 0, "out": "", "write": True},
        {"argv": ["wpctl", "set-mute", "**"], "code": 0, "out": "", "write": True},
        {"argv": ["wpctl", "set-default", "**"], "code": 0, "out": "", "write": True},
        {"argv": ["nmcli", "-t", "-f", "WIFI", "radio"], "code": 0, "out": "enabled"},
        {"argv": ["nmcli", "radio", "wifi"], "code": 0, "out": "enabled"},
        {"argv": ["nmcli", "radio", "**"], "code": 0, "out": "", "write": True},
        {"argv": ["nmcli", "**"], "code": 0, "out": ""},
        {"argv": ["rfkill", "--json"], "code": 0, "out": '{"rfkilldevices":[{"id":0,"type":"wlan","device":"phy0","soft":"unblocked","hard":"unblocked"},{"id":1,"type":"bluetooth","device":"hci0","soft":"unblocked","hard":"unblocked"}]}'},
        {"argv": ["rfkill", "**"], "code": 0, "out": "", "write": True},
        {"argv": ["bluetoothctl", "show"], "code": 0, "out": "Controller 00:11:22:33:44:55 (public)\n\tPowered: yes"},
        {"argv": ["bluetoothctl", "**"], "code": 0, "out": "", "write": True},
        {"argv": ["mangohudctl", "**"], "code": 0, "out": "", "write": True},
        {"argv": ["/usr/libexec/gamecove/gamecove-fix", "*", "status"], "code": 0, "out": "installed=yes"},
        {"argv": ["/usr/libexec/gamecove/gamecove-fix", "--list"], "code": 0, "out": ""},
        {"argv": ["pkexec", "/usr/libexec/gamecove/gamecove-fix-set", "**"], "code": 0, "out": "", "write": True},
        {"argv": ["systemctl", "is-active", "**"], "code": 0, "out": "active"},
        {"argv": ["grep", "-q", "-a", "-F", "*", "*/usr/bin/gamescope"], "code": 0, "out": ""},
        {"argv": ["sh", "-c", "command -v *"], "code": 0, "out": "/usr/bin/tool"},
    ]
    # gamescope root-window atoms (xprop -root): the fake runner keeps them as
    # state, so reads after writes see the new value (names: gamescope steamcompmgr.cpp)
    panel = row.get("panel") or {}
    xprop_root = {
        "GAMESCOPE_FOCUSABLE_APPS": "769", "GAMESCOPE_FOCUSED_APP": "769", "GAMESCOPE_FPS_LIMIT": "0",
        "GAMESCOPE_DYNAMIC_REFRESH": "0", "GAMESCOPE_VRR_CAPABLE": "1" if row.get("vrr_range") else "0",
        "GAMESCOPE_VRR_ENABLED": "0", "GAMESCOPE_ALLOW_TEARING": "0", "GAMESCOPE_NEW_SCALING_FILTER": "0",
        "GAMESCOPE_NEW_SCALING_SCALER": "0", "GAMESCOPE_SHARPNESS": "2",
        "GAMESCOPE_DISPLAY_SUPPORTS_HDR": "1" if panel.get("type") == "OLED" else "0",
        "GAMESCOPE_DISPLAY_HDR_ENABLED": "0", "GAMESCOPE_HDR_OUTPUT_FEEDBACK": "0",
    }
    return {"dbus": {"props": props, "methods": methods}, "commands": commands, "hhd": hhd, "xprop_root": xprop_root,
            "stack": stack, "tools": sorted(set(COMMON_TOOLS))}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("out")
    ap.add_argument("--devices", default=os.path.join(REPO, "app", "data", "devices.json"))
    ap.add_argument("--overrides", default=os.path.join(HERE, "overrides.json"))
    ap.add_argument("--only", default="")
    a = ap.parse_args(argv)
    with open(a.devices, "rb") as f:
        raw = f.read()
    doc = json.loads(raw)
    devices = doc["devices"]
    overrides = {}
    if os.path.exists(a.overrides):
        with open(a.overrides, encoding="utf-8") as f:
            overrides = {k: v for k, v in json.load(f).items() if not k.startswith("_")}
    facts = {}
    exp_path = os.path.join(HERE, "expectations.json")
    if os.path.exists(exp_path):
        with open(exp_path, encoding="utf-8") as f:
            facts = json.load(f).get("facts", {})
    out = os.path.abspath(a.out)
    if os.path.isdir(out) and os.listdir(out):
        if not os.path.exists(os.path.join(out, MARKER)):
            print(f"refusing to clear {out}: not a devicematrix folder", file=sys.stderr)
            return 2
        shutil.rmtree(out)
    os.makedirs(out)
    with open(os.path.join(out, MARKER), "w") as f:
        f.write("generated by tools/devicematrix/gen.py\n")
    only = set(filter(None, a.only.split(",")))
    built = []
    problems = []
    for row in devices:
        if only and row["id"] not in only:
            continue
        info = build(row, out, overrides.get(row["id"], {}), None, devices, facts)
        best = max(devices, key=lambda r: score(r, info["dmi"]))
        if score(best, info["dmi"]) < 0 or best["id"] != row["id"]:
            problems.append(f"{row['id']}: generated DMI resolves to {best['id'] if score(best, info['dmi']) >= 0 else 'nothing'}")
        built.append(info)
    by_id = {r["id"]: r for r in devices}
    for vid, ov in overrides.items():
        if "@" not in vid:
            continue
        base = by_id.get(str(ov.get("base", "")))
        if base is None:
            problems.append(f"{vid}: base row {ov.get('base')!r} not in devices.json")
            continue
        if only and vid not in only and base["id"] not in only:
            continue
        facts.setdefault(vid, facts.get(base["id"], {}))
        info = build(dict(base, id=vid), out, ov, None, devices, facts)
        info["expect_row"] = base["id"]
        best = max(devices, key=lambda r: score(r, info["dmi"]))
        if best["id"] != base["id"]:
            problems.append(f"{vid}: generated DMI resolves to {best['id']}")
        built.append(info)
    for g in GENERIC:
        if only and g["id"] not in only:
            continue
        info = build({"id": g["id"]}, out, overrides.get(g["id"], {}), g, devices, facts)
        if any(score(r, info["dmi"]) >= 0 for r in devices):
            problems.append(f"{g['id']}: generic DMI matches a devices.json row")
        built.append(info)
    manifest = {"generator": "tools/devicematrix/gen.py", "devices_json_sha256": hashlib.sha256(raw).hexdigest(),
                "devices": built, "problems": problems}
    with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
    files = sum(d["files"] for d in built)
    print(f"devicematrix: {len(built)} fixtures, {files} files in {out}")
    for p in problems:
        print("problem: " + p, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
