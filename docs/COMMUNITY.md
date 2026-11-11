# Community

GameCove is built in the open, and it gets better fastest when people with
different handhelds tell us what works and what doesn't.

## Report a bug

Open a [bug report](https://github.com/IHulkSmashI/GameCove/issues/new?template=bug_report.yml).
The form asks for your handheld, OS and GameCove version (Settings > About
GameCove), and where to find the logs:

| What | Where |
| --- | --- |
| GameCove's log | `~/.local/share/godot/app_userdata/GameCove/logs/godot.log` |
| The GameCove session | `journalctl --user -b -u gamescope-session-plus@gamecove` |
| Device fixes (fan, charge limit, Claw fixes) | `/var/lib/gamecove/changes.log` |
| Controller devices | `busctl --system tree org.shadowblip.InputPlumber` |

One problem per report. If it's already reported, a thumbs-up and your device
details on the existing issue help just as much.

## Tell us how a game runs

Open a [game report](https://github.com/IHulkSmashI/GameCove/issues/new?template=game_report.yml),
one per game. Good results help as much as problems: they tell other owners of
your handheld what works. The form asks for the game and its store, your
handheld and OS, the upscaler and frame generation you picked, and how it runs.
For a problem, attach the game's launch log
(`~/.local/share/gamecove/launch/<appid>.log`).

## Ask a question or share an idea

- [Q&A](https://github.com/IHulkSmashI/GameCove/discussions/categories/q-a): setup, "how do I", help with your handheld.
- [Ideas](https://github.com/IHulkSmashI/GameCove/discussions/categories/ideas): talk an idea through before it becomes a [feature request](https://github.com/IHulkSmashI/GameCove/issues/new?template=feature_request.yml).
- [Discord](https://discord.gg/tuUsn6sSZH): chat with other players and testers (#help, #bug-reports, #ideas, device channels, and private testing channels for testers).
- [r/GameCoveLinux](https://www.reddit.com/r/GameCoveLinux/): news, device tips and community posts.

## Test builds

We need testers on every handheld brand, most of all the ones we don't own.
Sign up with the [tester form](https://github.com/IHulkSmashI/GameCove/issues/new?template=tester_signup.yml).
Testers get early builds and a short checklist each round (about 20 minutes),
and can stop any time. You should be comfortable getting back to Steam's Gaming
Mode (`gamecove-session-select steam`, or pick Steam at the login screen).

Things worth checking on any device:

- Guide / Quick Access buttons open home and the quick menu, in and out of games.
- TDP, fan and charge limit controls do what they say (and nothing on a laptop).
- Installs, updates and uninstalls for each store you use.
- Exit game closes the game and nothing else.

## Code and docs

See [CONTRIBUTING.md](../CONTRIBUTING.md). Device support starts in
`app/data/devices.json` ([DEVICES.md](DEVICES.md)); a new row with the DMI ids
and what works is a great first contribution.

## Support the project

GameCove is free and stays free. Sponsorship links will show on the repo page
once they're set up (`.github/FUNDING.yml`). Until then, the best support is a
good bug report, a test round on your handheld, or telling a friend.
