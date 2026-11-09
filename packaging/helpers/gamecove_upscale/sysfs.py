"""The two helpers of ClawDeck's sysfs.py the ported modules use (read a small file, a clean environment for tools).
GameCove's helper never writes sysfs, so the write/revert half is not ported."""
from __future__ import annotations

import os


def read(path: str, default: str | None = None) -> str | None:
    """Trimmed contents of a file, or default when it cannot be read."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return default


def clean_env() -> dict[str, str]:
    """The environment for tools the helper runs, without loader or Python variables that would leak into them."""
    drop = ("LD_LIBRARY_PATH", "LD_PRELOAD", "PYTHONPATH", "PYTHONHOME", "_MEIPASS", "_MEIPASS2")
    env = {k: v for k, v in os.environ.items() if k not in drop and not k.startswith("_PYI_")}
    env.setdefault("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    return env
