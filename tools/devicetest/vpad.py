#!/usr/bin/env python3
"""vpad: a virtual gamepad for GameCove's device tests (tools/devicetest), GPL-3.0.

Presses buttons the way a player's pad does, so the device runner can drive the
real app on the real handheld. It makes one uinput gamepad (an Xbox 360 style
pad, which SDL and Godot map without a mapping file), sends the presses, and
removes the device when it exits: nothing stays behind, nothing needs root
(SteamOS and Bazzite give the logged-in user /dev/uinput, as Steam needs it).

Backends, first that works ("auto"):
  evdev         python-evdev's UInput (Bazzite ships it with Handheld Daemon)
  uinput        the same through /dev/uinput with the kernel's ioctls (stdlib only)
  inputplumber  InputPlumber's own target device over D-Bus (busctl), for the
                handheld's Guide / Quick Access buttons GameCove intercepts there

  vpad.py seq "guide down down a b"        press each, 0.25 s apart
  vpad.py seq --gap 0.6 "a" --hold-ms 900  hold A 0.9 s
  vpad.py --dry-run seq "a b"              print what would be sent, touch nothing
  vpad.py check                            which backend works here (exit 0 if any)

Names: a b x y lb rb lt rt start select guide up down left right ls rs, and
qam / home (the handheld's buttons: InputPlumber's ui_quick / ui_guide events;
with no InputPlumber, guide on the pad, which opens GameCove's quick menu).
"""
from __future__ import annotations

import argparse
import fcntl
import os
import shutil
import struct
import subprocess
import sys
import time

# linux/input-event-codes.h
EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT = 0
BTN = {"a": 0x130, "b": 0x131, "x": 0x133, "y": 0x134, "lb": 0x136, "rb": 0x137,
       "select": 0x13A, "start": 0x13B, "guide": 0x13C, "ls": 0x13D, "rs": 0x13E}
ABS_X, ABS_Y, ABS_Z, ABS_RX, ABS_RY, ABS_RZ, ABS_HAT0X, ABS_HAT0Y = 0, 1, 2, 3, 4, 5, 0x10, 0x11
HAT = {"up": (ABS_HAT0Y, -1), "down": (ABS_HAT0Y, 1), "left": (ABS_HAT0X, -1), "right": (ABS_HAT0X, 1)}
TRIGGER = {"lt": ABS_Z, "rt": ABS_RZ}
HANDHELD = {"qam": "ui_quick", "home": "ui_guide"}
NAMES = sorted(list(BTN) + list(HAT) + list(TRIGGER) + list(HANDHELD))
DEVICE_NAME = "GameCove device test pad"

# linux/uinput.h
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT = 0x40045564, 0x40045565, 0x40045567
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
UI_DEV_SETUP, UI_ABS_SETUP = 0x405C5503, 0x401C5504
BUS_USB = 0x03


class DryRun:
    name = "dry-run"

    def press(self, key: str, hold: float) -> None:
        print(f"vpad: {key} ({int(hold * 1000)} ms)")

    def close(self) -> None:
        pass


class RawUinput:
    """/dev/uinput through ioctls: no python-evdev needed."""
    name = "uinput"

    def __init__(self, path: str = "/dev/uinput") -> None:
        self.fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        for code in BTN.values():
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_ABS)
        for axis, lo, hi in [(ABS_X, -32768, 32767), (ABS_Y, -32768, 32767), (ABS_RX, -32768, 32767),
                             (ABS_RY, -32768, 32767), (ABS_Z, 0, 255), (ABS_RZ, 0, 255),
                             (ABS_HAT0X, -1, 1), (ABS_HAT0Y, -1, 1)]:
            fcntl.ioctl(self.fd, UI_SET_ABSBIT, axis)
            # struct uinput_abs_setup { __u16 code; struct input_absinfo { value min max fuzz flat res } }
            fcntl.ioctl(self.fd, UI_ABS_SETUP, struct.pack("<Hxx6i", axis, 0, lo, hi, 0, 0, 0))
        # struct uinput_setup { struct input_id {bustype vendor product version}; char name[80]; __u32 ff_effects_max }
        setup = struct.pack("<4H80sI", BUS_USB, 0x045E, 0x028E, 0x0110, DEVICE_NAME.encode(), 0)
        fcntl.ioctl(self.fd, UI_DEV_SETUP, setup)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        time.sleep(1.0)   # udev and the apps see the new pad

    def _emit(self, etype: int, code: int, value: int) -> None:
        now = time.time()
        os.write(self.fd, struct.pack("<qqHHi", int(now), int((now % 1) * 1e6), etype, code, value))

    def _syn(self) -> None:
        self._emit(EV_SYN, SYN_REPORT, 0)

    def press(self, key: str, hold: float) -> None:
        if key in BTN:
            self._emit(EV_KEY, BTN[key], 1)
            self._syn()
            time.sleep(hold)
            self._emit(EV_KEY, BTN[key], 0)
        elif key in HAT:
            axis, v = HAT[key]
            self._emit(EV_ABS, axis, v)
            self._syn()
            time.sleep(hold)
            self._emit(EV_ABS, axis, 0)
        elif key in TRIGGER:
            self._emit(EV_ABS, TRIGGER[key], 255)
            self._syn()
            time.sleep(hold)
            self._emit(EV_ABS, TRIGGER[key], 0)
        self._syn()

    def close(self) -> None:
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        finally:
            os.close(self.fd)


class Evdev(RawUinput):
    """python-evdev's UInput, where it's installed."""
    name = "evdev"

    def __init__(self) -> None:  # noqa: D401 - same API as RawUinput
        from evdev import AbsInfo, UInput, ecodes  # type: ignore[import-not-found]
        caps = {ecodes.EV_KEY: list(BTN.values()),
                ecodes.EV_ABS: [(ABS_X, AbsInfo(0, -32768, 32767, 16, 128, 0)), (ABS_Y, AbsInfo(0, -32768, 32767, 16, 128, 0)),
                                (ABS_RX, AbsInfo(0, -32768, 32767, 16, 128, 0)), (ABS_RY, AbsInfo(0, -32768, 32767, 16, 128, 0)),
                                (ABS_Z, AbsInfo(0, 0, 255, 0, 0, 0)), (ABS_RZ, AbsInfo(0, 0, 255, 0, 0, 0)),
                                (ABS_HAT0X, AbsInfo(0, -1, 1, 0, 0, 0)), (ABS_HAT0Y, AbsInfo(0, -1, 1, 0, 0, 0))]}
        self.ui = UInput(caps, name=DEVICE_NAME, vendor=0x045E, product=0x028E, version=0x0110, bustype=BUS_USB)
        time.sleep(1.0)

    def _emit(self, etype: int, code: int, value: int) -> None:
        self.ui.write(etype, code, value)

    def _syn(self) -> None:
        self.ui.syn()

    def close(self) -> None:
        self.ui.close()


class InputPlumber:
    """InputPlumber's composite device takes events over D-Bus (SendEvent), the path
    the handheld's own Guide / Quick Access buttons take into GameCove's intercept."""
    name = "inputplumber"
    SERVICE = "org.shadowblip.InputPlumber"
    IFACE = "org.shadowblip.Input.CompositeDevice"

    def __init__(self, busctl: str = "busctl") -> None:
        self.busctl = busctl
        out = subprocess.run([busctl, "--system", "tree", "--list", self.SERVICE], capture_output=True, text=True, timeout=10)
        paths = [p.strip() for p in out.stdout.splitlines() if "/CompositeDevice" in p and p.strip().count("/") == 4]
        if out.returncode != 0 or not paths:
            raise OSError("no InputPlumber composite device")
        self.path = paths[0]

    def _send(self, event: str, down: bool) -> None:
        r = subprocess.run([self.busctl, "--system", "call", self.SERVICE, self.path, self.IFACE, "SendEvent", "sv", event, "b",
                            "true" if down else "false"], capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            raise OSError(r.stderr.strip() or "SendEvent failed")

    def press(self, key: str, hold: float) -> None:
        event = HANDHELD.get(key, {"a": "ui_accept", "b": "ui_back", "x": "ui_action", "y": "ui_context", "up": "ui_up",
                                   "down": "ui_down", "left": "ui_left", "right": "ui_right", "guide": "ui_guide",
                                   "lb": "ui_l1", "rb": "ui_r1", "start": "ui_start", "select": "ui_select"}.get(key, ""))
        if event == "":
            raise OSError(f"{key}: no InputPlumber event")
        self._send(event, True)
        time.sleep(hold)
        self._send(event, False)

    def close(self) -> None:
        pass


def open_backend(want: str, dry: bool):
    if dry:
        return DryRun()
    tried = []
    order = ["evdev", "uinput", "inputplumber"] if want == "auto" else [want]
    for b in order:
        try:
            if b == "evdev":
                return Evdev()
            if b == "uinput":
                return RawUinput()
            if b == "inputplumber" and shutil.which("busctl"):
                return InputPlumber()
        except (OSError, ImportError) as e:
            tried.append(f"{b}: {e}")
    raise SystemExit("vpad: no backend works here (" + "; ".join(tried or ["none tried"]) + ")")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--backend", default="auto", choices=["auto", "evdev", "uinput", "inputplumber"])
    ap.add_argument("--dry-run", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("seq")
    s.add_argument("keys")
    s.add_argument("--gap", type=float, default=0.25)
    s.add_argument("--hold-ms", type=int, default=80)
    sub.add_parser("check")
    a = ap.parse_args(argv)
    if a.cmd == "check":
        dev = open_backend(a.backend, a.dry_run)
        print(f"vpad: {dev.name}")
        dev.close()
        return 0
    keys = a.keys.split()
    bad = [k for k in keys if k not in NAMES]
    if bad:
        print(f"vpad: unknown {bad}; names: {' '.join(NAMES)}", file=sys.stderr)
        return 2
    dev = open_backend(a.backend, a.dry_run)
    handheld = None
    try:
        for k in keys:
            if k in HANDHELD and dev.name != "inputplumber" and not a.dry_run:
                # the handheld's own buttons go through InputPlumber; without it, the pad's guide
                try:
                    handheld = handheld or InputPlumber()
                    handheld.press(k, a.hold_ms / 1000.0)
                except OSError:
                    dev.press("guide", a.hold_ms / 1000.0)
            else:
                dev.press(k, a.hold_ms / 1000.0)
            time.sleep(a.gap)
    finally:
        dev.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
