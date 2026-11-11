"""Is an OptiScaler package usable? The same checks the nightly runs before it signs an index (tools/upscalers/
smoke.py imports them from here), run again on the device after an update: when the new package fails, upkeep puts
the device back on the one before (rollback) and never tries that version again.

  pe_info      a Windows library's machine type, exports and imports, from its headers
  check_ini    every setting GameCove would write (launchenv.opti_ini, every preset and frame generation choice)
               exists in the package's OptiScaler.ini: a renamed key would silently do nothing in games
  package      both, for an unpacked OptiScaler package folder
"""
from __future__ import annotations

import os
import struct

from . import launchenv

MACHINE_AMD64 = 0x8664


def pe_info(path: str) -> dict:
    """{"machine", "dll": bool, "exports": set, "imports": set of lower-case DLL names}; ValueError when the file
    isn't a PE image. Reads headers and the two tables only."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"MZ" or len(data) < 0x40:
        raise ValueError("not an MZ executable")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("no PE header")
    machine, nsec, _t, _p, _n, optsize, chars = struct.unpack_from("<HHIIIHH", data, pe + 4)
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    if magic != 0x20B:
        raise ValueError("not a 64-bit (PE32+) image")
    dirs = opt + 112
    exp_rva, _ = struct.unpack_from("<II", data, dirs)
    imp_rva, _ = struct.unpack_from("<II", data, dirs + 8)
    secs = []
    for i in range(nsec):
        o = opt + optsize + 40 * i
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", data, o + 8)
        secs.append((vaddr, max(vsize, rsize), raddr))

    def off(rva: int) -> int:
        for vaddr, size, raddr in secs:
            if vaddr <= rva < vaddr + size:
                return rva - vaddr + raddr
        raise ValueError("address outside every section")

    def cstr(o: int) -> str:
        return data[o:data.index(b"\0", o, o + 512)].decode("ascii", "replace")

    exports, imports = set(), set()
    if exp_rva:
        e = off(exp_rva)
        nnames, = struct.unpack_from("<I", data, e + 24)
        names = off(struct.unpack_from("<I", data, e + 32)[0])
        for i in range(min(nnames, 4096)):
            exports.add(cstr(off(struct.unpack_from("<I", data, names + 4 * i)[0])))
    if imp_rva:
        o = off(imp_rva)
        for _ in range(512):
            name_rva = struct.unpack_from("<I", data, o + 12)[0]
            if not name_rva:
                break
            imports.add(cstr(off(name_rva)).lower())
            o += 20
    return {"machine": machine, "dll": bool(chars & 0x2000), "exports": exports, "imports": imports}


def ini_keys(text: str) -> set[str]:
    have, sec = set(), None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            sec = line[1:-1].replace("-", "").replace(".", "")
        elif sec and "=" in line and not line.startswith(";"):
            have.add(f"{sec}_{line.split('=', 1)[0].strip()}")
    return have


def every_setting(v10: bool = False) -> dict[str, set[str]]:
    """What GameCove writes into OptiScaler.ini, per case: {case label: Section_Key names}."""
    cases: dict[str, set[str]] = {}
    for vendor, presets, outs in (("intel", ("xess", "fsr4_xmx", "fsr4_xmx_lite"), ("",)),
                                  ("amd", ("fsr31", "fsr4_amd"), launchenv.FG_OUTS)):
        for opti in presets:
            for fg_src in ("off", "dlssg", "fsrfg", "upscaler"):
                for out in outs:
                    launch = {"opti": opti, "opti_fg": fg_src, "fg": 2 if fg_src != "off" else 0, "opti_overlay": 2,
                              "fsr4_int8": True, **({"fg_out": out} if out else {}), **({"reframework": True} if v10 else {})}
                    cases[f"{vendor} {opti} fg={fg_src} {out}".strip()] = set(launchenv.opti_ini(launch, vendor))
    return cases


def check_ini(ini_text: str, v10: bool = False) -> list[str]:
    have = ini_keys(ini_text)
    if len(have) < 50:
        return ["OptiScaler.ini: fewer than 50 settings found (the file changed shape)"]
    out = []
    for case, keys in every_setting(v10).items():
        gone = sorted(k for k in keys if k not in have)
        if gone:
            out.append(f"OptiScaler.ini has no {', '.join(gone)} (GameCove writes it for: {case})")
    return sorted(set(out))


def package(pkg: str, layout: str = "flat") -> list[str]:
    """Problems with an unpacked OptiScaler package ([] = usable)."""
    out = []
    dll, ini = os.path.join(pkg, "OptiScaler.dll"), os.path.join(pkg, "OptiScaler.ini")
    try:
        info = pe_info(dll)
        if info["machine"] != MACHINE_AMD64 or not info["dll"]:
            out.append("OptiScaler.dll isn't a 64-bit Windows DLL")
    except (ValueError, struct.error, OSError) as e:
        out.append(f"OptiScaler.dll: {e}")
    try:
        with open(ini, encoding="utf-8", errors="replace") as f:
            out += check_ini(f.read(), layout == "subfolder")
    except OSError as e:
        out.append(f"OptiScaler.ini: {e}")
    return out
