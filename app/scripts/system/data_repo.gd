extends RefCounted
## Where GameCove's downloadable data lives: the rolling releases of github.com/IHulkSmashI/GameCove-data
## (gamedb, firmware, upscalers, device-photos), built there by that repo's own workflows. The app's own releases
## (v*) stay on github.com/IHulkSmashI/GameCove, so its Releases page only lists real app versions.
##
## The one place the app names that repo: every download URL and every pinned signing identity comes from here
## (packaging/helpers/gamecove_upscale/mirror.py holds the same values for the Python helper, and
## packaging/tests/release.sh checks the two agree).

const REPO := "IHulkSmashI/GameCove-data"
const RELEASES := "https://github.com/IHulkSmashI/GameCove-data/releases/download/"
## GitHub's OIDC issuer: the data workflows sign with cosign keyless.
const OIDC_ISSUER := "https://token.actions.githubusercontent.com"
## The signing identity cosign must see: exactly that workflow, in the data repo, on its main branch.
const FIRMWARE_SIGNER := "(?i)^https://github\\.com/IHulkSmashI/GameCove-data/\\.github/workflows/firmware\\.yml@refs/heads/main$"
const UPSCALERS_SIGNER := "(?i)^https://github\\.com/IHulkSmashI/GameCove-data/\\.github/workflows/upscalers\\.yml@refs/heads/main$"

const GAMEDB_URL := RELEASES + "gamedb/gamedb.json.gz"
const UPCOMING_URL := RELEASES + "gamedb/upcoming.json.gz"
const FIRMWARE_URL := RELEASES + "firmware/firmware.json.gz"
const UPSCALERS_URL := RELEASES + "upscalers/upscalers.json"
const PHOTOS := RELEASES + "device-photos/"
