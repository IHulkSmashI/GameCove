#!/usr/bin/env python3
"""ROG Ally / Ally X controller MCU firmware version, read the way the kernel does.

The kernel's hid-asus (Luke D. Jones, "hid-asus: check ROG Ally MCU version and warn", in Linux 6.15)
asks the MCU for its version at probe with feature report 0x5a {5a 05 03 31 00 20}, reads the 64-byte
answer ("FGA80100.RC71LS.318_T01") and takes the three digits after the second ".". It only warns
("The MCU firmware version must be %d or greater to avoid issues with suspend") and exposes nothing to
userspace, so this does the same request over hidraw. Needs root (hidraw nodes are root-only).

Minimums: hid-asus ROG_ALLY_MIN_MCU 319 (Ally, 0b05:1abe) and ROG_ALLY_X_MIN_MCU 313 (Ally X,
0b05:1b4c); SimpleDeckyTDP asks for Ally X 314, so the stricter 314 is used here.

    python3 -I mcu_version.py [--sys /sys] [--dev /dev]
prints "model=ally|ally-x", "version=<n>", "min=<n>" (exit 0), or "error=<reason>" (exit 1).
"""
import argparse
import fcntl
import os
import re
import sys

ASUS = 0x0B05
MODELS = {0x1ABE: ("ally", 319), 0x1B4C: ("ally-x", 314)}
REPORT_ID = 0x5A
REQUEST = bytes([0x5A, 0x05, 0x03, 0x31, 0x00, 0x20])
REPORT_SIZE = 64


def _ioc(direction, nr, size):
    return (direction << 30) | (size << 16) | (ord("H") << 8) | nr


def hidiocsfeature(size):
    return _ioc(3, 0x06, size)


def hidiocgfeature(size):
    return _ioc(3, 0x07, size)


def parse_version(data):
    """Three digits after the second "." of the MCU's answer ("FGA80100.RC71LS.318_T01" -> 318).

    Like hid-asus mcu_parse_version_string: scans the raw bytes (the answer starts with a header
    that holds NULs), counts two dots, takes the next three characters as a decimal number."""
    raw = bytes(data)
    dots = 0
    i = 0
    while i < len(raw) and dots < 2:
        if raw[i] == 0x2E:
            dots += 1
        i += 1
    digits = raw[i:i + 3]
    if dots < 2 or len(digits) != 3 or not all(0x30 <= b <= 0x39 for b in digits):
        return -1
    return int(digits.decode("ascii"))


def candidates(sys_root="/sys"):
    """(hidraw name, model, minimum) for every Ally MCU hidraw node with feature report 0x5a."""
    out = []
    base = os.path.join(sys_root, "class", "hidraw")
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return out
    for name in names:
        dev = os.path.join(base, name, "device")
        try:
            with open(os.path.join(dev, "uevent")) as f:
                uevent = f.read()
        except OSError:
            continue
        m = re.search(r"^HID_ID=([0-9A-Fa-f]+):([0-9A-Fa-f]+):([0-9A-Fa-f]+)$", uevent, re.M)
        if not m or int(m.group(2), 16) != ASUS or int(m.group(3), 16) not in MODELS:
            continue
        try:
            with open(os.path.join(dev, "report_descriptor"), "rb") as f:
                desc = f.read()
        except OSError:
            desc = b""
        if desc and bytes([0x85, REPORT_ID]) not in desc:
            continue  # not the interface with the 0x5a config report
        model, minimum = MODELS[int(m.group(3), 16)]
        out.append((name, model, minimum))
    return out


def query(path):
    fd = os.open(path, os.O_RDWR)
    try:
        req = bytearray(REQUEST + bytes(REPORT_SIZE - len(REQUEST)))
        fcntl.ioctl(fd, hidiocsfeature(len(req)), req)
        buf = bytearray(REPORT_SIZE)
        buf[0] = REPORT_ID
        fcntl.ioctl(fd, hidiocgfeature(len(buf)), buf)
        return parse_version(buf)
    finally:
        os.close(fd)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--sys", default="/sys")
    ap.add_argument("--dev", default="/dev")
    a = ap.parse_args(argv)
    found = candidates(a.sys)
    if not found:
        print("error=no ROG Ally controller MCU found")
        return 1
    last = "the MCU didn't answer"
    for name, model, minimum in found:
        try:
            v = query(os.path.join(a.dev, name))
        except OSError as e:
            last = "couldn't ask the MCU (%s)" % e.strerror
            continue
        if v > 0:
            print("model=%s" % model)
            print("version=%d" % v)
            print("min=%d" % minimum)
            return 0
        last = "couldn't read the MCU's version"
    print("error=%s" % last)
    return 1


if __name__ == "__main__":
    sys.exit(main())
