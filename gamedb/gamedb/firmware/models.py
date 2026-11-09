"""Which maker listing answers for each devices.json row.

Keys are devices.json ids. Rows that share one listing (siblings with the same board) are
fetched once. Rows not listed here get a link-only entry from MAKER_LINKS by their "maker".
Checked by hand against each maker's site on 2026-11-09 (ASUS and Lenovo answered from the
build sandbox; MSI, GPD, ZOTAC and Acer refused it, so their entries come from ClawDeck's
msibios.py, checked on msi.com 2026-11-07, and from the makers' published support URLs).
"""

# ASUS support web API (the JSON rog.asus.com's own support page loads), by board model.
ASUS = {
    "asus-rog-ally": "RC71L",
    "asus-rog-ally-x": "RC72LA",
    "asus-rog-xbox-ally": "RC73YA",
    "asus-rog-xbox-ally-x": "RC73XA",
    "asus-rog-xbox-ally-x20": "RC74XA",
}

# Lenovo PC Support, by machine type (DMI product_name).
LENOVO = {
    "lenovo-legion-go": "83E1",
    "lenovo-legion-go-2": "83N0",
    "lenovo-legion-go-2-z2": "83N1",
    "lenovo-legion-go-s-z2go": "83L3",
    "lenovo-legion-go-s-z1e": "83N6",
}

# MSI support panel API, by support page name (ClawDeck msibios.PAGES). The BIOS board part
# ("E1T91IMS" in "E1T91IMS.10E") is matched in the app against the running BIOS, not guessed here.
MSI = {
    "msi-claw-8-ex": "Claw-8-EX-AI-Plus-CG3EMX",
    "msi-claw-8-ai-plus": "Claw-8-AI-plus-A2VM",
    "msi-claw-7-ai-plus": "Claw-7-AI-plus-A2VM",
    "msi-claw-a1m": "Claw-A1M",
    "msi-claw-a8": "Claw-A8-BZ2EM",
}

# Valve: the BIOS map inside jupiter-biosupdate (jupiter-hw-support), by DMI board_name.
VALVE = {
    "steam-deck-lcd": "Jupiter",
    "steam-deck-oled": "Galileo",
}

# Link-only makers: no machine-readable listing we can rely on. url = the maker's own
# download page; flash = how the maker says to install (all Windows tools today).
MAKER_LINKS = {
    "ONE-NETBOOK": {"url": "https://onexplayerstore.com/pages/download", "flash": "windows"},
    "OneXPlayer": {"url": "https://onexplayerstore.com/pages/download", "flash": "windows"},
    "AOKZOE": {"url": "https://aokzoestore.com/", "flash": "windows"},
    "AYANEO": {"url": "https://www.ayaneo.com/support/download", "flash": "windows"},
    "GPD": {"url": "https://gpd.hk/", "flash": "windows"},
    "ZOTAC": {"url": "https://www.zotac.com/us/product/gaming_pc/zotac-gaming-zone", "flash": "windows"},
    "Acer": {"url": "https://www.acer.com/us-en/support/drivers-and-manuals", "flash": "windows"},
    "Orange Pi": {"url": "http://www.orangepi.org/", "flash": "windows"},
    "OrangePi": {"url": "http://www.orangepi.org/", "flash": "windows"},
}

# GPD publishes one firmware/driver page per model.
GPD_PAGES = {
    "gpd-win-4": "https://gpd.hk/gpdwin4firmwaredriver",
    "gpd-win-mini": "https://gpd.hk/gpdwinmini2024firmwaredriver",
    "gpd-win-max-2": "https://gpd.hk/gpdwinmax2firmwaredriver",
    "gpd-win-5": "https://gpd.hk/gpdwin5firmwaredriver",
}

# Upstream projects of the Linux driver stack: name -> where its newest version comes from.
SOFTWARE = {
    "kernel": {"kind": "kernel_org"},
    "mesa": {"kind": "gitlab_tags", "base": "https://gitlab.freedesktop.org", "project": "mesa/mesa",
             "pattern": r"^mesa-(\d+\.\d+\.\d+)$", "notes": "https://docs.mesa3d.org/relnotes.html"},
    "linux-firmware": {"kind": "cgit_tags",
                       "url": "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/refs/tags",
                       "pattern": r"tag/\?h=(\d{8})'", "notes": "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/log/"},
    "inputplumber": {"kind": "github", "repo": "ShadowBlip/InputPlumber"},
    "powerstation": {"kind": "github", "repo": "ShadowBlip/PowerStation"},
    "hhd": {"kind": "github", "repo": "hhd-dev/hhd"},
    "decky": {"kind": "github", "repo": "SteamDeckHomebrew/decky-loader"},
    "optiscaler": {"kind": "github", "repo": "optiscaler/OptiScaler"},
    "xess-xmx": {"kind": "github", "repo": "HHHHanasak1/xess-xmx-linux"},
}
