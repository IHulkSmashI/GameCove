# Working on GameCove (read this first)

GameCove is a GPL-3.0, Godot 4.7.2 (GDScript), controller-first home screen for Linux handhelds (Bazzite, SteamOS). The owner wants a finished product: every item done fully, no placeholders, no "coming soon".

**Where we are, and what's next:** `docs/dev/STATE.md`. Read it before anything else, and update it before you stop.

## How a session works (keep it cheap)
1. One milestone per session. Read `docs/dev/STATE.md`, take the top unchecked milestone, and don't start a second one.
2. Plan in a few lines. If the milestone is unclear or costly to redo, ask the owner one question; otherwise go.
3. Build. Locally run only: `--import`, the unit tests, the start check, and the targeted tests for what you touched.
4. Push a branch (never main), and let GitHub CI run the heavy suites (full e2e, layout + focus walk, packaging). Read the run once it's done. Don't poll, and don't run those suites locally.
5. When CI is green: merge to main, tick the milestone in `docs/dev/STATE.md`, and write one short report to the owner: what changed, plus anything he must look at or approve.
- Don't spawn helper agents unless the owner asks. Don't schedule repeating check-ins.

## UI: the rules that stop "UI slop"
- `docs/CONTROLLER-UX.md` is binding. In short: one focus highlight at a time; focus is not selection; A selects and B goes back; the d-pad moves focus in visual order and never changes a value (sliders and steppers excepted); non-actionable things take no focus; focus is always fully on screen; everything is reachable by pad and by touch; no step needs a physical keyboard (use our on-screen keyboard; avoid system password prompts, and ask once when one is unavoidable).
- The focus walk (`app/tests/layout/focus_walk.gd`, run by the layout CI job) enforces this on every screen. A change that breaks it isn't done.
- Before any device test, render pad-only walkthroughs of the changed flows (one image per press, at 1920x1200 and 1280x800) and send them to the owner to approve.
- Follow the existing patterns (`scripts/ui/ui_kit.gd`, settings pages, quick menu); all strings go in `texts_*.gd`, with one plain-words help line per setting.

## Code rules
- Reuse maintained, tested tools (their CLIs or D-Bus) before writing new code. Research first.
- Nothing runs behind a running game unless it's essential, so no polling. Every Timer is listed in `app/tests/test_timer_lint.gd`, and the `suite_perf` budgets must pass. Never slow down sleep/wake or the quick menu.
- Every network call is gated in `scripts/system/privacy.gd` and documented in `docs/PRIVACY.md` and the README table. No secrets in builds.
- Write files through `settings_file.gd`, run processes through `exec_safe.gd`, and read /sys and /proc through `Device.read_all`. Never touch saves without a backup, and never touch Steam's files except through `steam_config.gd`.
- Every feature has a test that fails without it. Tests never read the real /sys or write outside temp dirs, and they pass with a fresh HOME and as a non-root user.
- Copy is casual and uses "we", never "I". Never write "Partial". Never name closed-source competitors or third-party Windows tools in the repo, commits or docs (credits only in `CREDITS.md`).
- One logical change per commit. Update README, `docs/SYSTEM.md`, `docs/PRIVACY.md` and `docs/PERFORMANCE.md` when behaviour changes.

## Gates
```
G=godot-4.7.2   # the pinned editor binary
$G --headless --path app --import
XDG_DATA_HOME=$(mktemp -d) $G --headless --path app -s res://tests/run_tests.gd        # 0 failed, no SCRIPT ERROR
XDG_DATA_HOME=$(mktemp -d) HOME=$(mktemp -d) $G --headless --path app --quit-after 120 # exit 0
GAMECOVE_TEST=<name> ... (targeted)  ·  python3 -I app/tests/e2e/run.py --godot $G --setups claw8ex-bazzite --suites <s>
sh packaging/tests/release.sh   # before merging to main
```
The release gate reads the newest main push run of ci.yml for the tagged commit, so main must be green before tagging. The owner approves the "release" environment in a browser; the GitHub mobile app has no approve button.
