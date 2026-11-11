# Releasing GameCove

How a release is made, what protects the signing identity, and the repository settings that must stay as they
are. Every signed file (the release's `SHA256SUMS`, `firmware/firmware.json.gz`, `upscalers/upscalers.json`) is
signed with cosign keyless: the signature names the workflow file and the ref it ran on, and GameCove accepts it
only from exactly that workflow (`packaging/get-gamecove.sh` for releases; `app/scripts/system/data_repo.gd` and
`packaging/helpers/gamecove_upscale/mirror.py` for the data lists). So whoever can run those workflows on those refs
can sign. Three things guard that: a tag ruleset, a deployment environment with the owner as required reviewer, and
the workflows' own checks.

This repo's Releases page only has the app's own `v*` releases. The data GameCove downloads (game database,
firmware list, upscaler files and list, device photos) is built and published by the workflows of
**[IHulkSmashI/GameCove-data](https://github.com/IHulkSmashI/GameCove-data)** on that repo's own releases (see
"Data releases" below).

## Making a release

1. Bump `Version:` in `packaging/rpm/gamecove.spec` and add `packaging/release-notes/v<version>.md` on `main`.
2. Run the Release workflow on `main` with **publish** on (Actions > Release > Run workflow, or
   `gh workflow run release.yml --ref main -f publish=true -f prerelease=true`).
3. The `tag` job creates `v<version>` on that commit and starts the workflow again on the tag
   (`--ref refs/tags/v<version>`). That run builds everything; its `release` job checks the tagged commit is on
   `main`, then **waits for the owner's approval** (the `release` environment, below).
4. Approve the deployment (the run's page shows "Review deployments"). The job signs `SHA256SUMS`, creates the
   release as a draft, uploads every file, then publishes it.

A re-run of a release that is already published fails without changing it; a release left as a draft by a failed
run is finished by re-running.

## Data releases (IHulkSmashI/GameCove-data)

The `gamedb`, `firmware`, `upscalers` and `device-photos` releases live in the data repo, published by its
`gamedb.yml`, `firmware.yml`, `upscalers.yml` and `device-photos.yml` (a workflow's `GITHUB_TOKEN` can only write
to the repository the workflow is in, and no long-lived token is used). Those workflows run **this** repo's builders
(`gamedb/`, `tools/upscalers/`, `tools/device_photos/`, `packaging/helpers/`), checked out read-only at the commit
the data repo's `gamecove-source.env` pins. So:

- **After merging a change to a builder or its data** (`gamedb/`, `tools/upscalers/`, `tools/device_photos/`,
  `app/data/devices.json`, `app/data/device_photos.json`, `packaging/helpers/`, including a new tested pin in
  `versions.json`, or the cosign pins in `get-gamecove.sh`), bump `GAMECOVE_COMMIT` in the data repo's
  `gamecove-source.env` to that `main` commit, then run the workflow by hand
  (`gh workflow run upscalers.yml -R IHulkSmashI/GameCove-data`). A new pin in `versions.json` must be on the
  mirror before an app release ships it.
- **Identities the app pins:** `https://github.com/IHulkSmashI/GameCove-data/.github/workflows/firmware.yml@refs/heads/main`
  and `.../upscalers.yml@refs/heads/main`, issuer `https://token.actions.githubusercontent.com`
  (`app/scripts/system/data_repo.gd`, `mirror.py`; `packaging/tests/release.sh` keeps them equal).
- The firmware and upscaler lists are signed the way releases are: their `build` job runs the scrapers and the
  builder with a read-only token and no OIDC, and their `publish` job (which signs) runs in the data repo's `nightly`
  environment, which only its `main` can deploy to; the build job refuses to start when that environment is missing
  or lets another branch deploy. They run every night, so they don't wait for an approval. The game database and
  device photos aren't signed (the app checks each photo's sha256 against the manifest); their `build` jobs are
  read-only too and only their `publish` jobs (which run nothing but `gh` and a standard-library check of the files)
  can write the release.
- The data repo's own settings (the `nightly` environment, Actions permissions, the IGDB secrets) are in its
  README, "Owner settings". Its `tests/check_workflows.py` holds the rules this repo's `release.sh` used to apply to
  those workflows.
- **Check the published files with the app's own code:** `sh tools/data_check/run.sh --godot <godot>` downloads
  every data file the app uses from the data repo (game database, calendar, device photos, firmware list, the
  signed upscaler list and every upscaler file, newest and pinned) through the app's and the helper's own download
  and verify code, signatures included, and fails on anything that doesn't check out or that came from upstream
  instead of the mirror. It uses the network, so it isn't one of the gates; run it after the data workflows publish.
- The weekly check of the makers' image links stays here (`maker-links.yml`): it reads this repo's data and files
  its issue here.

## Repository settings (owner)

### Tag ruleset "Release tags" (in place since 2026-11-10)

Settings > Rules > Rulesets > **Release tags**, target: tags matching `v*`.

- **Restrict updates** and **restrict deletions**: a published tag can't be moved to another commit or removed.
- **Block force pushes.**
- Bypass list: **Repository admin** only.
- **Creations are not restricted.** The release workflow's `tag` job creates the tag with `GITHUB_TOKEN`, and on a
  personal repository the GitHub Actions app can't be added as a bypass actor, so restricting creation would stop
  the release workflow itself. What stands in for it: the `tag` job runs only on `main`, the `release` job refuses a
  tag whose commit isn't on `main`, and signing waits for the owner's approval. Anyone who can push a new `v*` tag
  (people with write access) could start a run, but it can't sign without that approval.

### Environment "release" (in place since 2026-11-10)

Settings > Environments > **`release`** (exactly that name; the workflows refer to it). It exists, with the owner
(IHulkSmashI) as required reviewer. What it must stay:

- **Required reviewers:** the owner (IHulkSmashI) only. Leave "Prevent self-review" off, so the owner can approve
  his own runs.
- **Deployment branches and tags:** "Selected branches and tags", with two rules: branch `main` and tag `v*`.
- No environment secrets are needed (signing is keyless).

Job that uses it: `release` in `release.yml`.

**Never delete or rename it.** A job that names an environment GitHub doesn't know gets one created on the spot
**without** protection rules, so the next tag run would sign without approval. `release.yml` guards against that
itself with `tools/ci/check-environment.sh`, which asks GitHub's API for the environment before any job runs in
it: the `tag` job checks `release` before it creates the tag, and the `protected` job checks it again in the tag's
run; `release` (the job that signs) needs `protected`. The check fails when the environment is missing, has no
required reviewer, doesn't have the owner among its reviewers, or lets every branch and tag deploy.

The check can only fail on what GitHub tells it: when the API doesn't answer (a rate limit, or a token that may not
read environments) it prints a warning and the run goes on, and these settings are what stand. It can't see *which*
branches and tags are selected either, so look at that list here after any change. `packaging/tests/release.sh`
runs the script against canned answers and checks that every job with `id-token: write` names `release`.

### Environment "nightly" (no longer used here)

This repo's `nightly` environment was for the data workflows, which run in IHulkSmashI/GameCove-data now (with
that repo's own `nightly` environment, which its signing workflows check the same way before they run). Once the
old data releases here are deleted, this repo's `nightly` can be deleted in Settings > Environments.

### Branch protection for `main`

`main` should stay protected (pull requests, no force pushes): the data repo builds from a commit of `main`, and
the release job's "on `main`" check is only as strong as `main` itself. The data repo's `main` signs the nightly
lists, so protect it the same way.

## What the workflows check by themselves

- `release.yml`: the tag job runs only on `main`; the release job refuses a tagged commit that isn't on `main` and
  checks its own signature against the identity the installer requires before publishing.
- `release.yml`, version: the tag must be `v<spec Version>`, the export stamps that Version into the app, and the
  exported app is asked (`gamecove.x86_64 --headless -- --version`) and must answer the same number. The repository's
  `app/project.godot` carries no version, so the spec is the only place to bump.
- `release.yml`, files: `SHA256SUMS` lists every file except itself. Before signing, the release job checks the
  downloaded files against it again (every listed file present and matching, nothing unlisted, the tag's tarball,
  RPM, sysext and installer script all listed, and `get-gamecove.sh` identical to the tagged commit's).
- Before the first release from a changed `release.yml`, do a dry run: `gh workflow run release.yml --ref main`
  (publish off) builds everything and runs every check except tagging, signing and publishing.
- In the data repo, `firmware.yml`, `upscalers.yml`: the build job checks its `nightly` environment exists and only
  `main` can deploy to it, is read-only with no OIDC and checks it got exactly the pinned commit; the publish job
  runs only pinned cosign, `gh` and standard-library checks. `upscalers.yml`'s publish job re-hashes every planned
  file and re-checks the index (official upstream repositories only, builds at least 72 hours old) with
  `tools/upscalers/check_plan.py` before signing. The nightly's
  newer steps live in the data repo's `upscalers.yml` (GameCove-data, branch `upscalers-smoke-watch` until it is
  merged there): the per-game list from OptiScaler's sources as they were 72 hours ago (`tools/upscalers/gen_games.py`),
  `tools/upscalers/smoke.py` over what is new (its publish job only runs when it passed, so devices keep last night's
  signed index otherwise), `tools/upscalers/watch.py` over the upstreams a person has to look at, and a `report` job
  with `issues: write` and no code that opens or updates one issue when something moved or a check failed.
  `tools/upscalers/withdrawn.json` is the kill switch: a component named there rides in the signed index and every
  device stops using its files.
- In the data repo, `gamedb.yml`, `device-photos.yml`: the same build/publish split, without signing.
