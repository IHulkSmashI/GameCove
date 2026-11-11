"""What this GPU can run: the decision table of docs/UPSCALING.md as data (GameCove; the Intel XMX rows are
ClawDeck's tested choices, same author).

The app sends the GPU it detected (app/scripts/device/gpu_caps.gd): {"vendor": intel|amd|nvidia|other, "family",
"arch", "xmx": bool, "chip": name, "tier": one of TIERS}. An older app sends no tier: tier() works it out from the
rest, so both sides always agree (kept in step by test_chips.py and test_gpu_caps.gd over the same fixture).

  tier            chips                                              FSR 4                  frame generation
  intel_xmx       Arc with XMX: Xe2, Xe3, Xe-LPG+, Xe-HPG            4.1.2 / Lite on XMX    XeSS-FG 2x 3x 4x
  intel           Arc without XMX (Meteor Lake)                      no                     XeSS-FG 2x
  amd_rdna4       RX 9000                                            Proton / SDK, default  FSR FG 2x, XeSS-FG 2x
  amd_halo        Ryzen AI Max (8050S / 8060S), RDNA 3 desktop cards  SDK full INT8, default FSR FG 2x, XeSS-FG 2x
  amd_rdna35      880M / 890M: AI 9 HX, Z2 Extreme                   SDK INT8 Lite, default FSR FG 2x, XeSS-FG 2x
  amd_rdna3       780M class: Z1, Z1 Extreme, Z2, 7840U, 8840U       INT8, default          FSR FG 2x, XeSS-FG 2x
  amd_z2a         Ryzen Z2 A                                         Lite, opt-in           FSR FG 2x
  amd_rdna2       Steam Deck, Z2 Go, 6800U                           INT8, opt-in           FSR FG 2x
  amd_old         Vega and older                                     no                     none
  nvidia          GeForce                                            the game's own DLSS    the game's own
  other           unknown                                            no                     none
3x and 4x exist only on Intel Arc with XMX: XeSS multi-frame generation is Intel only (OptiScaler wiki, Frame
Generation Options; xess-xmx-linux README), and AMD has no multi-frame FSR. No other multiplier is ever offered.
"""
from __future__ import annotations

import re

TIERS = ("intel_xmx", "intel", "amd_rdna4", "amd_halo", "amd_rdna35", "amd_rdna3", "amd_z2a", "amd_rdna2", "amd_old",
         "nvidia", "other")
AMD_TIERS = tuple(t for t in TIERS if t.startswith("amd_"))
# what FSR 4 is on each tier: "default" picked by itself, "optin" offered, "" not offered
# RDNA 3 (780M class) is not on AMD's list but runs it well (the owner's ROG Ally Z1 Extreme; GE-Proton's README names
# RDNA 3 for PROTON_FSR4_UPGRADE): the default, with FSR 3.1 as the automatic fallback when it didn't come up.
# RDNA 2 handhelds: about a quarter of the frame rate on a Steam Deck (club386.com, 2025-09-17): offered, never default.
FSR4 = {"amd_rdna4": "default", "amd_halo": "default", "amd_rdna35": "default", "amd_rdna3": "default", "amd_z2a": "optin",
        "amd_rdna2": "optin"}
# AMD's own FSR 4.1.2 list (FSR SDK 2.4, 2026-10-28) has these; the others need OptiScaler's INT8 switch
FSR4_LISTED = ("amd_rdna4", "amd_halo", "amd_rdna35", "amd_z2a")
FSR4_MODEL = {"amd_rdna4": "FP8", "amd_halo": "INT8", "amd_rdna35": "INT8 Lite", "amd_rdna3": "INT8", "amd_z2a": "INT8 Lite",
              "amd_rdna2": "INT8"}
PROTON_FSR4 = ("amd_rdna4", "amd_halo", "amd_rdna35", "amd_rdna3")       # Proton's own FSR 3.1 -> FSR 4 upgrade
XEFG_ON_AMD = ("amd_rdna4", "amd_halo", "amd_rdna35", "amd_rdna3")       # XeSS-FG's DP4a model: not on RDNA 2 (too heavy)
LATENCY = {"intel_xmx": "xell", "intel": "xell", "nvidia": "reflex", "other": "", "amd_old": ""}

_HALO = re.compile(r"ai max|8050s|8060s", re.I)
_Z2A = re.compile(r"\bz2 a\b", re.I)
_DESKTOP = re.compile(r"\brx ?(\d)\d{3}", re.I)


def vendor(gpu: dict) -> str:
    v = str(gpu.get("vendor") or "")
    if v in ("intel", "amd", "nvidia"):
        return v
    fam = str(gpu.get("family") or "")
    return "intel" if fam.startswith("intel") else "amd" if fam.startswith("amd") else "nvidia" if fam.startswith("nvidia") else "other"


def tier(gpu: dict) -> str:
    t = str(gpu.get("tier") or "")
    if t in TIERS:
        return t
    v = vendor(gpu)
    arch = str(gpu.get("arch") or "")
    chip = f"{gpu.get('chip') or ''} {gpu.get('gpu') or ''}"
    if v == "intel":
        return "intel_xmx" if gpu.get("xmx") else "intel"
    if v == "nvidia":
        return "nvidia"
    if v != "amd":
        return "other"
    m = _DESKTOP.search(chip)
    if arch == "RDNA4" or (m and m.group(1) == "9"):
        return "amd_rdna4"
    if _HALO.search(chip) or (m and m.group(1) == "7"):
        return "amd_halo"
    if arch == "RDNA3.5":
        return "amd_rdna35"
    if arch == "RDNA3":
        return "amd_rdna3"
    if arch == "RDNA2":
        return "amd_z2a" if _Z2A.search(chip) else "amd_rdna2"
    return "amd_old"


def upscalers(gpu: dict) -> list[str]:
    """The upscaler choices this GPU gets; the first is always the game's own."""
    t = tier(gpu)
    if t == "intel_xmx":
        return ["own", "xess", "fsr4_xmx", "fsr4_xmx_lite"]
    if t == "intel":
        return ["own", "xess"]
    if t in FSR4:
        return ["own", "fsr31", "fsr4_amd"]
    return ["own"]


def frame_gens(gpu: dict) -> list[int]:
    t = tier(gpu)
    if t == "intel_xmx":
        return [0, 2, 3, 4]
    if t == "intel" or t in AMD_TIERS and t != "amd_old":
        return [0, 2]
    return [0]


def generators(gpu: dict) -> list[str]:
    """Frame generators OptiScaler can put out on this GPU, the best first."""
    t = tier(gpu)
    if t in ("intel_xmx", "intel"):
        return ["xefg"]
    if t in XEFG_ON_AMD:
        return ["fsrfg", "xefg"]
    if t in ("amd_z2a", "amd_rdna2"):
        return ["fsrfg"]
    return []


def latency(gpu: dict, generator: str = "") -> str:
    """What keeps input lag down next to frame generation: XeSS-FG always brings XeLL (it needs it); FSR FG on AMD is
    paired with Anti-Lag 2 (low_latency_layer); NVIDIA keeps its own Reflex."""
    t = tier(gpu)
    if generator == "xefg":
        return "xell"
    return LATENCY.get(t, "antilag2")


def capabilities(gpu: dict) -> dict:
    t = tier(gpu)
    return {"tier": t, "vendor": vendor(gpu), "upscalers": upscalers(gpu), "frame_gens": frame_gens(gpu),
            "generators": generators(gpu), "latency": latency(gpu), "fsr4": FSR4.get(t, "xmx" if t == "intel_xmx" else ""),
            "fsr4_model": FSR4_MODEL.get(t, ""), "fsr4_listed": t in FSR4_LISTED, "proton_fsr4": t in PROTON_FSR4,
            "max_fg": max(frame_gens(gpu))}


def default_upscaler(gpu: dict, dx12: bool, fsr4_xmx_ready: bool = False) -> str:
    """The OptiScaler output "Best for your handheld" picks for a game whose own upscaler is taken over."""
    t = tier(gpu)
    if t == "intel_xmx":
        return "fsr4_xmx" if dx12 and fsr4_xmx_ready else "xess"
    if t == "intel":
        return "xess"
    if FSR4.get(t) == "default" and dx12:
        return "fsr4_amd"
    if t in AMD_TIERS and t != "amd_old":
        return "fsr31"
    return "own"
