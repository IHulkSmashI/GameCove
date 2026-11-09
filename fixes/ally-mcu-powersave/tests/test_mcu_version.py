"""mcu_version.py against fake sysfs trees (review S1-3). Run: python3 -I tests/test_mcu_version.py"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import mcu_version as mv  # noqa: E402


def hidraw(root, name, hid_id, desc):
    d = os.path.join(root, "class", "hidraw", name, "device")
    os.makedirs(d)
    with open(os.path.join(d, "uevent"), "w") as f:
        f.write("DRIVER=asus\nHID_ID=%s\nHID_NAME=Asus Keyboard\n" % hid_id)
    with open(os.path.join(d, "report_descriptor"), "wb") as f:
        f.write(desc)


class McuVersion(unittest.TestCase):
    def test_parse_kernel_examples(self):
        self.assertEqual(mv.parse_version(b"FGA80100.RC72LA.312_T01\0\0"), 312)
        self.assertEqual(mv.parse_version(b"\x5a\x05\x03\x31\x00\x20FGA80100.RC71LS.318_T01"), 318)
        self.assertEqual(mv.parse_version(b"\x5a" + bytes(63)), -1)
        self.assertEqual(mv.parse_version(b"garbage"), -1)

    def test_ioctl_numbers(self):
        # linux/hidraw.h: HIDIOCSFEATURE(len) _IOC(_IOC_WRITE|_IOC_READ, 'H', 0x06, len)
        self.assertEqual(mv.hidiocsfeature(64), 0xC0404806)
        self.assertEqual(mv.hidiocgfeature(64), 0xC0404807)

    def test_candidates_pick_the_config_interface(self):
        with tempfile.TemporaryDirectory() as t:
            hidraw(t, "hidraw0", "0003:00000B05:00001ABE", b"\x06\x31\xff\x85\x5a\x09\x76")
            hidraw(t, "hidraw1", "0003:00000B05:00001ABE", b"\x05\x01\x09\x06\x85\x01")  # keyboard, no 0x5a
            hidraw(t, "hidraw2", "0003:0000045E:0000028E", b"\x85\x5a")  # not ASUS
            hidraw(t, "hidraw3", "0003:00000B05:00001B4C", b"\x85\x5a")
            self.assertEqual(mv.candidates(t), [("hidraw0", "ally", 319), ("hidraw3", "ally-x", 314)])

    def test_no_mcu(self):
        with tempfile.TemporaryDirectory() as t:
            self.assertEqual(mv.candidates(t), [])
            self.assertEqual(mv.main(["--sys", t, "--dev", t]), 1)


if __name__ == "__main__":
    unittest.main()
