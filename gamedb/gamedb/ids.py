"""Store id checks shared by every source.

A Steam app id ends up inside steam:// URIs in the app (steam://store/<id>,
steam://rungameid/<id>), so only plain ASCII digits are ever kept; anything
else from Wikidata (P1733), IGDB, ProtonDB, AWACY or CheapShark is dropped.
"""

from __future__ import annotations

import re

_STEAM = re.compile(r"[0-9]{1,10}")


def steam_id(value) -> str | None:
    """The Steam app id as a string of ASCII digits, or None when it isn't one."""
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        return None
    s = str(value)
    return s if _STEAM.fullmatch(s) and s.lstrip("0") != "" else None
