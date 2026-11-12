"""The documents and the in-app list say the same thing (review of 56f5255): PRIVACY.md's row ids are unique, the
Network and privacy page lists the destinations PRIVACY.md does, and SYSTEM.md's root-write table names every
place the fixes write."""
import re
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]


def test_privacy_row_ids_are_unique():
    ids = re.findall(r"^\| (\d+[a-z]?) \|", (REPO / "docs" / "PRIVACY.md").read_text(), re.M)
    assert ids
    assert [i for i, n in Counter(ids).items() if n > 1] == []


def test_the_in_app_list_has_every_destination_privacy_md_names():
    gd = (REPO / "app" / "scripts" / "system" / "privacy.gd").read_text()
    for host in ("builds.lsfg-vk.dev", "tuf-repo-cdn.sigstore.dev", "raw.githubusercontent.com"):
        assert host in gd, host
        assert host in (REPO / "docs" / "PRIVACY.md").read_text(), host


def test_system_md_names_the_places_root_writes():
    text = (REPO / "docs" / "SYSTEM.md").read_text()
    for path in ("gamecove-gyro-keepalive.service", "steamos-manager.service.d", "/etc/firmware/",
                 "/var/lib/ish-gyro-bias", "/efi/EFI/SteamOS/grub.cfg"):
        assert path in text, path
