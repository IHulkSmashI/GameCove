# claw8ex-gyro: gyro on the MSI Claw 8 EX AI+

Makes the Claw 8 EX's gyro work in Steam (as a Steam Deck gyro) through InputPlumber. Board `MS-1T91` only; Bazzite only for now.

The method was found and tested on a Claw 8 EX by **Kisenir (r/MSIClaw)**. His files are used with his permission (2026-11-08). GameCove's version is ported from ClawDeck's.

```
gamecove-fix claw8ex-gyro install        # then shut down fully and power on (cold boot)
gamecove-fix claw8ex-gyro status
gamecove-fix claw8ex-gyro set accel-on  # optional: accelerometer as well (off by default); accel-off undoes it
gamecove-fix claw8ex-gyro remove         # then restart
```

## What it changes

| What | Where | Why |
| --- | --- | --- |
| MSI's ISH firmware | `/etc/firmware/intel/ish/ish_ptl.bin` | Panther Lake's sensor hub loads its firmware from the host. MSI's build isn't in linux-firmware and may not be redistributed, so it's downloaded from MSI on the device (`ISH_Kit_5.8.1.7782`). The file is extracted from the kit, and its size (432640) and sha256 (`8194475367978c473d17e7e777fe196d99383f80f51b433927ea9afd0e9e661b`) are checked **before** anything is written. A wrong image can make the hub stop answering until a full power-off. |
| Initramfs | `rpm-ostree initramfs-etc --track=/etc/firmware/intel/ish/ish_ptl.bin` | Bazzite's generic initramfs includes the HID drivers (`intel_ish_ipc` among them), so the hub can request its firmware before the root filesystem is mounted; tracking puts a copy in the initramfs, as the VRR fix does for its EDID. Untracked on remove. Only done when this fix wrote the file. |
| Kernel argument | `firmware_class.path=/etc/firmware` (rpm-ostree kargs) | Makes the kernel look in /etc before /usr/lib/firmware. Only adds a search path, so it does nothing on other handhelds booting the same drive. Held through `/var/lib/gamecove/kargs/` and removed when no fix holds it any more; if it was already set before, it stays. |
| HID-BPF program | `/etc/udev-hid-bpf/MSI__Claw-ISH-IMU.bpf.o` | The hub declares the IMU as two custom HID sensors that no Linux driver binds. The program relabels them as a standard Accelerometer 3D and Gyrometer 3D (same length, only on the known 2247-byte descriptor), so the kernel creates `gyro_3d`. It also subtracts a per-axis gyro bias. Source: `bpf/MSI__Claw-ISH-IMU.bpf.c` (GPL-2.0-only). Packaging builds the object with `bpf/build-bpf.sh` (the RPM's `%build`, the release workflow for the sysext). It isn't in git: from a plain checkout, run `sh bpf/build-bpf.sh` (clang, llvm, libbpf headers) or install a release package. |
| Helpers | `/etc/gamecove/claw8ex-gyro/*.py` | `ish_imu_keepalive.py` writes the standard HID-sensor config (power, 10 ms report interval) when InputPlumber opens the gyro. It never sends vendor commands. `ish_gyro_bias.py` keeps the resting reading at 0. `ish_sensor_probe.py` is a library they share and a diagnostic tool. |
| Services | `gamecove-gyro-keepalive.service`, `gamecove-gyro-bias.service` in `/etc/systemd/system` | Run the two helpers, only on board MS-1T91: `ExecCondition=/usr/bin/grep -qx MS-1T91 /sys/class/dmi/id/board_name` makes systemd skip them cleanly on other handhelds booting the same drive (installs from before get this line on the next `install` or root `status`). The bias service keeps its offsets in `StateDirectory=ish-gyro-bias` (`/var/lib/ish-gyro-bias`). |
| InputPlumber | `/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml` | Adds an `imu` source (`gyro_3d`) to the board's device config. It's gyro only because Steam's fusion with the accelerometer made gyro aim worse; `set accel-on` adds `accel_3d` (`set accel-off` takes it out). One token, because `gamecove-fix` values can't hold spaces; it's also one of the few changes the app may make without a password (`gamecove-fix-set claw8ex-gyro set accel-on`), and only once the fix is installed. The file is shared with `claw8ex-buttons` and rebuilt from the stock file plus whichever features are on. |

Every change is recorded in `/var/lib/gamecove/fixes/claw8ex-gyro/manifest`, and `remove` undoes it in reverse order. A file that existed before is backed up and put back. Remove never deletes a firmware file it didn't write. If the kernel argument or the initramfs entry can't be taken out (rpm-ostree fails), remove leaves the firmware file and its initramfs tracking in place and recorded, so the boot configuration never points at a missing file; running remove again retries.

## Status

`status` prints `key=value` lines:

- `firmware_file`: the verified firmware is installed
- `kernel_arg`: the kernel argument is in the running kernel
- `firmware_loaded`: the hub's HID device (8087:0AC2) appeared, which only happens with MSI's firmware running
- `gyro_iio`: the kernel created `gyro_3d`
- `inputplumber_imu` and `inputplumber_reading`: the override has the imu source, and the gyro's IIO buffer is enabled
- `services`: state of the two helper services
- `state`: `off`, `restart` (cold boot needed), `partial` or `on`

## Tests

`sh fixes/claw8ex-gyro/tests/test.sh` runs against a fake root (`GAMECOVE_ROOT`) with stub `rpm-ostree`, `systemctl`, `curl`, `unzip` and `sha256sum` on PATH. It covers the install/status/remove roundtrip, a wrong sha256 or size aborting before any write, an rpm-ostree failure undoing everything, coexistence with `claw8ex-buttons`, the kernel argument shared with `claw8ex-vrr`, a failed kernel-argument removal keeping the firmware for the retry, and `set accel-on|accel-off` through `gamecove-fix` and `gamecove-fix-set` (not just fix.sh).

## Licenses

- `bpf/MSI__Claw-ISH-IMU.bpf.c` (and the `.bpf.o` built from it): GPL-2.0-only, © Kisenir (r/MSIClaw). Text: `LICENSES/GPL-2.0-only.txt` at the top of the repository.
- `helpers/*.py`: by Kisenir (r/MSIClaw). Licensed GPL-2.0-or-later pending his confirmation.
- `fix.sh`: GPL-3.0-or-later, like the rest of GameCove
