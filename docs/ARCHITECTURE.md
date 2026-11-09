# Architecture

GameCove is one Godot 4 app that runs as gamescope's main client, plus small helpers. It ships no root daemon of its own for power: it talks to the system services that already exist.

```
 ┌──────────────── gamescope session ────────────────┐
 │  GameCove (Godot 4, Compatibility renderer)       │
 │   home · library · quick menu · settings          │
 │        │ D-Bus                 │ launch            │
 │        ▼                       ▼                   │
 │  PowerStation / steamos-manager   steam://, umu-run, legendary/gogdl/nile
 │  InputPlumber                                      │
 └────────────────────────────────────────────────────┘
          ▲ nightly download
   gamedb release (Wikidata + AreWeAntiCheatYet + ProtonDB + IGDB)
```

## Decisions

| Decision | Why |
| --- | --- |
| Own session, not an add-on to Steam's | Full control of the home screen and the quick-menu button; Steam's terms forbid modifying its UI |
| Godot 4, Compatibility renderer | Lightest Godot renderer, good gamepad focus handling, same toolkit as OpenGamepadUI so we can learn from its gamescope code |
| Steam launched via `steam://rungameid/` | Steam handles its own games; we read the library from local files |
| Power through PowerStation / steamos-manager | Already the standard on Bazzite; we add missing devices upstream |
| Game data built nightly on GitHub | Free, no server, no API keys on players' devices |
| PC streaming drives Moonlight's CLI against a Vibepollo host | Moonlight decodes and pairs; GameCove only discovers, shows apps, wakes and follows the session ([STREAMING.md](STREAMING.md)) |
| Packaging: RPM on Bazzite first, sysext on SteamOS, native on CachyOS | Flatpak can't start Steam or reach system D-Bus the way we need |

## Running programs

Everything that waits on a program and reads its output goes through `app/scripts/system/exec_safe.gd` (`ExecSafe.run(program, args, merge_stderr)` -> `{code, out}`), usually via a runner (`system/proc.gd`, `device/command_runner.gd`, `gamescope/command_runner.gd`, `ui/bg_command.gd`) that tests swap for a fake. Godot 4.7's `OS.execute()` with an output array rebuilds the arguments into a shell command line and loses double quotes (`{"a":"b c"}` arrives as `{a:b` and `c}`), which broke every JSON argument (InputPlumber over busctl) on real hardware. `ExecSafe` uses `OS.execute_with_pipe()`, which passes argv untouched, with a `sh -c 'exec 2>&1; exec "$0" "$@"'` wrapper (or `2>/dev/null`) so only one pipe is read and nothing can deadlock. It blocks: call it from worker threads. `tests/test_exec_safe.gd` runs real processes through every runner and fails if anything in `app/scripts` calls `OS.execute(` directly. Fire-and-forget starts keep using `OS.create_process()` (argv is passed intact).

## Open items

- How Steam's overlay, on-screen keyboard and Steam Input behave outside Steam's own session. Test first on the Claw 8 EX.
- Overlay and focus properties: read OpenGamepadUI's gamescope code before writing ours.
- Measured RAM and idle power of the app on the Claw.
