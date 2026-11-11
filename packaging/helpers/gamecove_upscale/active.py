"""What actually ran: the read-out GameCove shows after a game was started ("Active: FSR 4.1.2 on XMX, XeSS frame
generation 2x, low latency" or why not). Read-only.

Three sources, strongest first:
  1. OptiScaler's own log next to the game's exe (GameCove's OptiScaler writes it at info level: LOG_INI). Its age
     against the launch stamp gamecove-run writes (<runtime>/launch/<appid>.started) says whether OptiScaler loaded in
     the last launch at all; its lines say which upscaler and frame generation it created.
  2. the XeSS XMX driver's proof for the game (xess.xmx_proof) and XeLL's log (xess.game_latency) on Intel.
  3. what is set (the launch settings), when the game hasn't run since.
States: "active" (OptiScaler created the upscaler), "loaded" (OptiScaler started but the game hasn't asked for an
upscaler: its DLSS / FSR isn't switched on in its menu), "not_loaded" (the game ran after the files went in and
OptiScaler never started), "waiting" (not run since it was set up), "own" (nothing of ours in the game), "env"
(nothing in the game's folder: Proton's FSR 4 upgrade or the XMX driver's switches).
The log lines differ between OptiScaler versions, so matching is by words every version uses, never by exact text.
"""
from __future__ import annotations

import os
import re

# written into GameCove's OptiScaler.ini: a small log per launch (Info; Trace is OptiScaler's default and far larger)
LOG_INI = {"Log_LogToFile": "true", "Log_LogLevel": "2", "Log_SingleFile": "true"}
LOG_NAMES = ("OptiScaler.log", os.path.join("OptiScaler", "OptiScaler.log"))
MAX_READ = 2 << 20
LABELS = {"own": "the game's own", "xess": "XeSS 2", "fsr4_xmx": "FSR 4.1.2 on XMX", "fsr4_xmx_lite": "FSR 4.1.2 Lite on XMX",
          "fsr31": "FSR 3.1", "fsr4_amd": "FSR 4.1.2", "fsr": "FSR 4 (Proton's upgrade)"}
GENERATORS = {"xefg": "XeSS frame generation", "fsrfg": "FSR frame generation"}
LATENCY = {"xell": "XeLL low latency", "antilag2": "Anti-Lag 2", "reflex": "Reflex"}
# words in the log that say an upscaler / frame generation / latency backend came up
_UPSCALER = re.compile(r"(creating new .{0,40}upscaler|feature created|upscaler (created|initiali[sz]ed)|"
                       r"(xess|fsr ?[234][0-9.x/ ]*|ffx|dlss)[a-z0-9_ ]{0,24}(init|creat)[a-z]* (ok|success|result: 0\b))", re.I)
_FG = re.compile(r"(xefg|xess[- ]?fg|fsr ?fg|fsrfg|framegen|frame generation).{0,60}(creat|init|activ|enabled)", re.I)
_XEFG = re.compile(r"xefg|xess[_ -]?fg|libxess_fg", re.I)
# an error line that says the picked upscaler itself failed (FSR 4's DLL, FidelityFX, XeSS), not any other error
_UPSCALER_FAIL = re.compile(r"(fsr ?4|fsr4|fidelityfx|ffx|amd_fidelityfx|xess|upscaler)[^\n]{0,120}"
                            r"(fail|error|can'?t|cannot|not found|unsupported|missing)|"
                            r"(fail|error|can'?t|cannot|unsupported|missing)[^\n]{0,120}(fsr ?4|fidelityfx|ffx|xess|upscaler)", re.I)


def upscaler_failed(errors: list) -> bool:
    """One of the log's error lines says the upscaler itself didn't come up."""
    return any(_UPSCALER_FAIL.search(str(e)) for e in errors or [])


_FAIL = re.compile(r"\[(error|critical)\]|\b(failed|can't|cannot|not found|unsupported)\b", re.I)


# Protons that can run FSR 4 on AMD (their READMEs: PROTON_FSR4_UPGRADE, AMD's driver extension): GE-Proton 10 and
# newer, Proton-CachyOS. Valve's numbered releases can't; Experimental and Hotfix move, so they count as unknown.
_GE = re.compile(r"GE-Proton(\d+)", re.I)


def proton_of(launch_log: str | None) -> str:
    """The Proton the game last started on, from the launch log gamecove-run writes ("gamecove: proton <path>");
    "" when unknown (no log, a native game)."""
    try:
        with open(launch_log or "", "r", encoding="utf-8", errors="replace") as f:
            for line in f.read(1 << 16).splitlines():
                if line.startswith("gamecove: proton "):
                    return os.path.basename(line[len("gamecove: proton "):].strip().rstrip("/"))
    except OSError:
        pass
    return ""


def fsr4_proton(name: str) -> bool | None:
    """True: this Proton runs FSR 4 on AMD; False: it can't; None: can't tell."""
    if not name:
        return None
    m = _GE.search(name)
    if m:
        return int(m.group(1)) >= 10
    low = name.lower()
    if "cachyos" in low:
        return True
    if "experimental" in low or "hotfix" in low or "bleeding" in low:
        return None
    if re.match(r"^proton[ -]?\d", low):
        return False
    return None


def log_path(folder: str | None) -> str | None:
    if not folder:
        return None
    for n in LOG_NAMES:
        p = os.path.join(folder, n)
        if os.path.isfile(p):
            return p
    return None


def read_log(path: str | None) -> dict:
    """{"lines": int, "upscaler": bool, "fg": bool, "xefg": bool, "errors": [first three error lines]}."""
    out = {"lines": 0, "upscaler": False, "fg": False, "xefg": False, "errors": []}
    if not path:
        return out
    try:
        with open(path, "rb") as f:
            text = f.read(MAX_READ).decode("utf-8", "replace")
    except OSError:
        return out
    for line in text.splitlines():
        out["lines"] += 1
        if _UPSCALER.search(line) and not _FAIL.search(line):
            out["upscaler"] = True
        if _FG.search(line) and not _FAIL.search(line):
            out["fg"] = True
            out["xefg"] = out["xefg"] or bool(_XEFG.search(line))
        if len(out["errors"]) < 3 and re.search(r"\[(error|critical)\]", line, re.I):
            out["errors"].append(line.strip()[-160:])
    return out


def _mtime(path: str | None) -> float:
    try:
        return os.path.getmtime(path) if path else 0.0
    except OSError:
        return 0.0


def describe(upscaler: str, fg: int, generator: str, latency: str) -> str:
    parts = [LABELS.get(upscaler, upscaler)]
    if fg:
        parts.append(f"{GENERATORS.get(generator, 'frame generation')} {fg}x")
        if latency in LATENCY:
            parts.append(LATENCY[latency])
    return ", ".join(parts)


NEEDS_PROTON = "FSR 4 needs GE-Proton or Proton-CachyOS: pick one for this game under Compatibility."


def state(folder: str | None, owner: str, upscaler: str, fg: int, generator: str, latency: str,
          started: float = 0.0, installed: float = 0.0, env_only: bool = False, xmx: dict | None = None,
          proton: str = "") -> dict:
    """The read-out. started: when the game last started through GameCove's wrapper (0 = never); installed: when
    GameCove's files went into the folder; xmx: xess.xmx_proof() on Intel XMX, else None; proton: the Proton of the
    last start (proton_of), "" when unknown."""
    what = describe(upscaler, fg, generator, latency)
    cant = started and upscaler in ("fsr", "fsr4_amd") and fsr4_proton(proton) is False
    if env_only:
        if not started:
            return {"state": "waiting", "line": f"Set: {what}. Start the game to use it.", "what": what}
        if cant:
            return {"state": "env_off", "what": what, "line": f"Not active: the last start ran on {proton}, which can't turn "
                    f"the game's FSR 3.1 into FSR 4. {NEEDS_PROTON} The game's own FSR still works."}
        return {"state": "env", "line": f"Set for the last start: {what}. Nothing was added to the game's files.", "what": what}
    if owner != "gamecove" or upscaler == "own":
        return {"state": "own", "line": "Using the game's own upscaler. Nothing of ours is in this game.", "what": ""}
    log = log_path(folder)
    seen = read_log(log) if log and _mtime(log) >= max(started - 5.0, installed) and started else None
    if not started or started < installed:
        return {"state": "waiting", "line": f"Ready: {what}. Start the game, then pick DLSS or FSR in its graphics menu.", "what": what}
    if seen is None:
        return {"state": "not_loaded", "what": what, "line": "Not active: the game started but our upscaler didn't load. "
                "The game may use another start-up file here; pick Remove, then set it up again, or tell us the game."}
    if xmx and xmx.get("state") in ("stale", "failed") and upscaler.startswith("fsr4_xmx"):
        return {"state": "loaded", "what": what, "line": "Not active: the XMX cores weren't used in the last start. "
                "Start the game once with XeSS 2, then FSR 4.1.2 works again.", "errors": seen["errors"]}
    if not seen["upscaler"]:
        return {"state": "loaded", "what": what, "errors": seen["errors"],
                "line": f"Loaded, waiting for the game: switch on DLSS or FSR in its graphics menu to get {LABELS.get(upscaler, upscaler)}."}
    if cant and seen["errors"]:
        return {"state": "loaded", "what": what, "errors": seen["errors"],
                "line": f"Not active: FSR 4 didn't start on {proton}. {NEEDS_PROTON}"}
    line = f"Active: {what}"
    if fg and not seen["fg"]:
        line = (f"Active: {LABELS.get(upscaler, upscaler)}. Frame generation hasn't started: switch on the game's own "
                "frame generation, or restart the game once.")
    return {"state": "active", "line": line, "what": what, "errors": seen["errors"]}
