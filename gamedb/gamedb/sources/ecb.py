"""Euro foreign exchange reference rates from the European Central Bank.

Free for any use, commercial or not, as long as the source is credited
("Source: ECB statistics") and the figures aren't modified
(https://www.ecb.europa.eu/stats/ecb_statistics/governance_and_quality_framework/html/usage_policy.en.html).
We publish them exactly as the ECB gives them (EUR base, its own date); the app
does the conversion when it compares a USD price with a regional one.
"""

from __future__ import annotations

import re

from ..net import Client

URL = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
SOURCE = "ECB statistics"


def parse(xml: str) -> dict | None:
    """{"base": "EUR", "date": "YYYY-MM-DD", "rates": {code: rate}, "source": ...} or None."""
    day = re.search(r"<Cube\s+time=['\"](\d{4}-\d{2}-\d{2})['\"]", xml)
    rates = {c: float(r) for c, r in re.findall(r"<Cube\s+currency=['\"]([A-Z]{3})['\"]\s+rate=['\"]([0-9.]+)['\"]", xml)}
    if not day or not rates:
        return None
    return {"base": "EUR", "date": day.group(1), "rates": rates, "source": SOURCE}


def fetch(client: Client) -> dict:
    fx = parse(client.get(URL).decode("utf-8", "replace"))
    if fx is None:
        raise ValueError("ECB reference rates not readable")
    return fx
