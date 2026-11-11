#!/usr/bin/env python3
"""Stand-ins for the store tools GameCove drives, for the end-to-end journeys (GPL-3.0).

One script, installed under each tool's name in a private bin folder that the
journey puts first on PATH (tests/e2e/stores_world.gd). It behaves like the real
tool as far as GameCove can see: the same command lines, the same progress lines
(copied from the real tools' logs in tests/fixtures/stores/data/logs), the same
files written where the real tool writes them. Nothing reaches a network.

  legendary   info --json | install | update | repair | uninstall | move --skip-move | auth
  gogdl       info | download | update | repair | auth            (--auth-config-path first)
  nile        install --info --json | install | update | verify | uninstall | auth | register
  steam       appends its argument (a steam:// URI or a flag) to $GAMECOVE_FAKE_STORE/steam.spool:
              the journey's fake Steam client (stores_world.gd) acts on it, as Steam would
  umu-run     records the launch in $GAMECOVE_FAKE_STORE/launches.spool and exits

State lives in $GAMECOVE_FAKE_STORE (a folder under the e2e work folder):
  <id>.progress      percent done of an interrupted download (a resumed install goes on from it)
  fail-<action>      the next <action> fails with the file's text (removed once used)
  slow               seconds per progress step (default 0.12)
  calls.log          every command line, one per line
Downloads stop cleanly on SIGTERM (the download queue's pause and cancel) and keep
their progress file, like legendary keeps its resume file.
"""
from __future__ import annotations

import json
import os
import signal
import sys
import time

STATE = os.environ.get("GAMECOVE_FAKE_STORE", "")
# the fake handheld's home (the journeys' process keeps its own HOME): the real
# tools find their config under $HOME, so these do under the fake one
if os.environ.get("GAMECOVE_FAKE_HOME"):
    os.environ["HOME"] = os.environ["GAMECOVE_FAKE_HOME"]
TOTAL_MIB = 1000.0


def state_path(name: str) -> str:
    return os.path.join(STATE, name)


def log_call(tool: str, argv: list[str]) -> None:
    if not STATE:
        return
    with open(state_path("calls.log"), "a", encoding="utf-8") as f:
        f.write(json.dumps([tool] + argv) + "\n")


def take_fault(action: str) -> str | None:
    p = state_path("fail-" + action)
    if STATE and os.path.exists(p):
        with open(p, encoding="utf-8") as f:
            why = f.read().strip() or "the store refused"
        os.remove(p)
        return why
    return None


def step_s() -> float:
    try:
        with open(state_path("slow"), encoding="utf-8") as f:
            return float(f.read().strip())
    except (OSError, ValueError):
        return 0.12


def read_json(path: str, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path: str, data) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


# Options that take a value, for finding the positional arguments the way argparse does.
VALUED = {"--base-path", "--platform", "--path", "--code", "--auth-config-path", "--client-id",
          "--code-verifier", "--serial", "--lang"}


def positionals(argv: list[str]) -> list[str]:
    """The command's positional arguments: everything after `--` (GameCove puts the store's
    id and a folder there), or the words that aren't options or option values."""
    if "--" in argv:
        i = argv.index("--")
        head = positionals(argv[:i])
        return head + argv[i + 1:]
    out = []
    skip = False
    for a in argv:
        if skip:
            skip = False
            continue
        if a in VALUED:
            skip = True
            continue
        if a.startswith("-"):
            continue
        out.append(a)
    return out


def opt(argv: list[str], name: str, default: str = "") -> str:
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


_stopped = False


def _on_term(_sig, _frm):
    global _stopped
    _stopped = True


def download(game_id: str, style: str) -> bool:
    """Prints progress the way `style` (legendary | gogdl | nile) does; False when stopped."""
    signal.signal(signal.SIGTERM, _on_term)
    prog_file = state_path(game_id + ".progress")
    try:
        with open(prog_file, encoding="utf-8") as f:
            pct = float(f.read().strip())
    except (OSError, ValueError):
        pct = 0.0
    start = time.time()
    while pct < 100.0:
        if _stopped:
            return False
        pct = min(100.0, pct + 10.0)
        with open(prog_file, "w", encoding="utf-8") as f:
            f.write(str(pct))
        done = TOTAL_MIB * pct / 100.0
        run = int(time.time() - start)
        eta = max(0, int((100.0 - pct) / 10.0))
        if style == "legendary":
            print(f"[DLManager] INFO: = Progress: {pct:.2f}% ({int(pct * 10)}/1000), "
                  f"Running for 00:00:{run:02d}, ETA: 00:00:{eta:02d}", flush=True)
            print(f"[DLManager] INFO:  - Downloaded: {done:.2f} MiB, Written: {done:.2f} MiB", flush=True)
            print("[DLManager] INFO:  + Download\t- 21.33 MiB/s (raw) / 30.00 MiB/s (decompressed)", flush=True)
        else:
            total = int(TOTAL_MIB * 1048576)
            print(f"[PROGRESS] INFO: = Progress: {pct:.2f} {int(total * pct / 100.0)}/{total}, "
                  f"Running for: 00:00:{run:02d}, ETA: 00:00:{eta:02d}", flush=True)
            print(f"[PROGRESS] INFO: = Downloaded: {done:.2f} MiB, Written: {done:.2f} MiB", flush=True)
            print("[PROGRESS] INFO:  + Download\t- 10.00 MiB/s", flush=True)
        deadline = time.time() + step_s()
        while time.time() < deadline:
            if _stopped:
                return False
            time.sleep(0.02)
    try:
        os.remove(prog_file)
    except OSError:
        pass
    return True


def fail(why: str) -> int:
    print(f"[cli] ERROR: {why}", flush=True)
    return 1


# ---- legendary ------------------------------------------------------------------

def legendary(argv: list[str]) -> int:
    cfg = os.environ.get("LEGENDARY_CONFIG_PATH", os.path.expanduser("~/.config/legendary"))
    installed_path = os.path.join(cfg, "installed.json")
    pos = positionals(argv)
    cmd = pos[0] if pos else ""
    gid = pos[1] if len(pos) > 1 else ""
    why = take_fault(cmd)
    if why:
        return fail(why)
    meta = read_json(os.path.join(cfg, "metadata", gid + ".json"), {})
    title = str(meta.get("app_title", gid))
    if cmd == "info":
        print("[cli] INFO: Getting game metadata...")
        print(json.dumps({"game": {"app_name": gid, "title": title}, "install": None,
                          "manifest": {"disk_size": 1258291200, "download_size": 1048576000}}))
        return 0
    if cmd == "auth":
        if "--delete" in argv:
            try:
                os.remove(os.path.join(cfg, "user.json"))
            except OSError:
                pass
            print("[cli] INFO: User data deleted.")
            return 0
        code = opt(argv, "--code")
        if not code:
            return fail("No code given")
        write_json(os.path.join(cfg, "user.json"), {"displayName": "CovePlayer", "account_id": "e2e"})
        print('[cli] INFO: Successfully logged in as "CovePlayer"')
        return 0
    if cmd == "install":
        base = opt(argv, "--base-path", os.path.expanduser("~/Games/epic"))
        print(f'[cli] INFO: Preparing download for "{title}" (1.0)...')
        print("[cli] INFO: Install size: 1200.00 MiB")
        print("[cli] INFO: Download size: 1000.00 MiB (Compression savings: 16.6%)")
        if not download(gid, "legendary"):
            return 1
        folder = os.path.join(base, title.replace(":", ""))
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, title.replace(" ", "") + ".exe"), "w", encoding="utf-8") as f:
            f.write("e2e\n")
        inst = read_json(installed_path, {})
        inst[gid] = {"app_name": gid, "title": title, "install_path": folder, "executable": "game.exe",
                     "is_dlc": False, "platform": "Windows", "version": "1.0", "install_size": 1258291200,
                     "can_run_offline": True, "launch_parameters": "", "save_path": None}
        write_json(installed_path, inst)
        print("[cli] INFO: Finished installation process in 1.00 seconds.")
        return 0
    if cmd in ("update", "repair"):
        if not download(gid + "-" + cmd, "legendary"):
            return 1
        print(f"[cli] INFO: Finished {cmd} in 1.00 seconds.")
        return 0
    if cmd == "uninstall":
        inst = read_json(installed_path, {})
        entry = inst.pop(gid, None)
        if entry is None:
            return fail(f'Game "{gid}" is not installed')
        write_json(installed_path, inst)
        folder = str(entry.get("install_path", ""))
        if folder and os.path.isdir(folder):
            for root, dirs, files in os.walk(folder, topdown=False):
                for n in files:
                    os.remove(os.path.join(root, n))
                for n in dirs:
                    os.rmdir(os.path.join(root, n))
            os.rmdir(folder)
        print(f'[cli] INFO: Game "{title}" has been uninstalled.')
        return 0
    if cmd == "move":
        dest = pos[2] if len(pos) > 2 else ""
        inst = read_json(installed_path, {})
        if gid not in inst:
            return fail("not installed")
        inst[gid]["install_path"] = os.path.join(dest, os.path.basename(inst[gid]["install_path"]))
        write_json(installed_path, inst)
        print("[cli] INFO: Finished.")
        return 0
    return fail("unknown command " + cmd)


# ---- gogdl -------------------------------------------------------------------------

def gogdl(argv: list[str]) -> int:
    auth = opt(argv, "--auth-config-path")
    rest = [a for i, a in enumerate(argv) if a != "--auth-config-path" and (i == 0 or argv[i - 1] != "--auth-config-path")]
    rpos = positionals(rest)
    cmd = rpos[0] if rpos else ""
    gid = rpos[1] if len(rpos) > 1 else ""
    why = take_fault(cmd)
    if why:
        return fail(why)
    if cmd == "auth":
        code = opt(rest, "--code")
        if not code:
            return fail("No code given")
        write_json(auth, {"46899977096215655": {"access_token": "e2e", "refresh_token": "e2e", "user_id": "1"}})
        print(json.dumps({"access_token": "e2e"}))
        return 0
    if cmd == "info":
        print(json.dumps({"size": {"*": {"download_size": 1048576000, "disk_size": 1258291200}}, "builds": [], "dlcs": []}))
        return 0
    if cmd == "download":
        base = opt(rest, "--path")
        title = "GOG Game " + gid
        lib = read_json(os.path.join(os.path.dirname(os.path.dirname(auth)), "store_cache", "gog_library.json"), {})
        for g in lib.get("games", []):
            if str(g.get("app_name")) == gid:
                title = str(g.get("title", title))
        print(f"[DOWNLOAD] INFO: Downloading game {title}", flush=True)
        if not download("gog-" + gid, "gogdl"):
            return 1
        folder = os.path.join(base, title.replace(":", ""))
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, f"goggame-{gid}.info"), "w", encoding="utf-8") as f:
            json.dump({"gameId": gid, "name": title}, f)
        return 0
    if cmd in ("update", "repair"):
        return 0 if download("gog-" + gid + "-" + cmd, "gogdl") else 1
    return fail("unknown command " + cmd)


# ---- nile ---------------------------------------------------------------------------

def nile(argv: list[str]) -> int:
    base_cfg = os.environ.get("NILE_CONFIG_PATH", os.path.expanduser("~/.config"))
    cfg = os.path.join(base_cfg, "nile")
    pos = positionals(argv)
    cmd = pos[0] if pos else ""
    gid = pos[1] if len(pos) > 1 else ""
    why = take_fault(cmd)
    if why:
        return fail(why)
    if cmd == "auth":
        if "--login" in argv:
            print(json.dumps({"client_id": "e2e", "code_verifier": "v", "serial": "s",
                              "url": "https://www.amazon.com/ap/signin?e2e=1"}))
            return 0
        return 0
    if cmd == "register":
        write_json(os.path.join(cfg, "current_user.json"), {"user_id": "e2e", "name": "CovePlayer"})
        return 0
    if cmd == "install" and "--info" in argv:
        print(json.dumps({"download_size": 1048576000}))
        return 0
    if cmd == "install":
        base = opt(argv, "--base-path", os.path.expanduser("~/Games/nile"))
        title = gid
        for g in read_json(os.path.join(cfg, "library.json"), []):
            if str(g.get("product", {}).get("id")) == gid:
                title = str(g["product"].get("title", gid))
        print(f"[DOWNLOAD] INFO: Downloading game {title}", flush=True)
        if not download("amazon-" + gid, "nile"):
            return 1
        folder = os.path.join(base, title.replace(":", ""))
        os.makedirs(folder, exist_ok=True)
        inst = [i for i in read_json(os.path.join(cfg, "installed.json"), []) if str(i.get("id")) != gid]
        inst.append({"id": gid, "path": folder, "version": "1", "size": 1258291200})
        write_json(os.path.join(cfg, "installed.json"), inst)
        return 0
    if cmd in ("update", "verify"):
        return 0 if download("amazon-" + gid + "-" + cmd, "nile") else 1
    if cmd == "uninstall":
        inst = read_json(os.path.join(cfg, "installed.json"), [])
        write_json(os.path.join(cfg, "installed.json"), [i for i in inst if str(i.get("id")) != gid])
        return 0
    return fail("unknown command " + cmd)


def spool(name: str, argv: list[str]) -> int:
    if STATE:
        with open(state_path(name), "a", encoding="utf-8") as f:
            f.write(json.dumps(argv) + "\n")
    return 0


def main() -> int:
    tool = os.path.basename(sys.argv[0])
    argv = sys.argv[1:]
    log_call(tool, argv)
    if tool == "legendary":
        return legendary(argv)
    if tool == "gogdl":
        return gogdl(argv)
    if tool == "nile":
        return nile(argv)
    if tool == "steam":
        return spool("steam.spool", argv)
    if tool == "umu-run":
        return spool("launches.spool", argv + ["env:GAMEID=" + os.environ.get("GAMEID", ""),
                                               "env:STORE=" + os.environ.get("STORE", "")])
    print(f"fakestore: unknown tool {tool}", file=sys.stderr)
    return 127


if __name__ == "__main__":
    sys.exit(main())
