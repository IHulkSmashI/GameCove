# Releasing GameCove

How a release is made, what protects the signing identity, and the repository settings that must stay as they
are. Every signed file (the release's `SHA256SUMS`, `firmware/firmware.json.gz`, `upscalers/upscalers.json`) is
signed with cosign keyless: the signature names the workflow file and the ref it ran on, and GameCove accepts it
only from exactly that workflow (`packaging/get-gamecove.sh`, `app/scripts/system/firmware_index.gd`,
`packaging/helpers/gamecove_upscale/mirror.py`). So whoever can run those workflows on those refs can sign. Three
things guard that: a tag ruleset, a deployment environment with the owner as required reviewer, and the workflows'
own checks.

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

The nightly firmware and upscaler lists work the same way: their `build` job runs the scrapers and the builder with
a read-only token and no OIDC, and their `publish` job (which signs) runs in the `nightly` environment, which only `main` can deploy to. They run
every night, so they don't wait for an approval. The game database and device photos aren't signed; their `build` jobs are read-only too and only their
`publish` jobs (which run nothing but `gh` and a standard-library check of the files) can write the release.

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

### Environment "release" (owner: create it)

Settings > Environments > New environment, name **`release`** (exactly; the workflows refer to it):

- **Required reviewers:** the owner (IHulkSmashI) only. Leave "Prevent self-review" off, so the owner can approve
  his own runs.
- **Deployment branches and tags:** "Selected branches and tags", with two rules: branch `main` and tag `v*`.
- No environment secrets are needed (signing is keyless).

Job that uses it: `release` in `release.yml`.

### Environment "nightly" (owner: create it)

Settings > Environments > New environment, name **`nightly`**:

- **No required reviewers** (it runs every night).
- **Deployment branches and tags:** "Selected branches and tags", one rule: branch `main`.

Jobs that use it: `publish` in `firmware.yml` and `publish` in `upscalers.yml`.

Until an environment exists, GitHub creates it on the first run **without** protection rules, so create both before
the next run. `packaging/tests/release.sh` checks that every job with `id-token: write` names one of them.

### Branch protection for `main`

`main` should stay protected (pull requests, no force pushes): the signing identity of the nightly lists is
"this workflow on `main`", and the release job's "on `main`" check is only as strong as `main` itself.

## What the workflows check by themselves

- `release.yml`: the tag job runs only on `main`; the release job refuses a tagged commit that isn't on `main` and
  checks its own signature against the identity the installer requires before publishing.
- `firmware.yml`, `upscalers.yml`: the build job is read-only with no OIDC; the publish job runs only pinned cosign,
  `gh` and standard-library checks. `upscalers.yml`'s publish job re-hashes every planned file and re-checks the
  index (official upstream repositories only) with `tools/upscalers/check_plan.py` before signing.
- `gamedb.yml`, `device-photos.yml`: the same build/publish split, without signing.
