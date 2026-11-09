"""SPARQL over Wikidata (CC0), from the fastest endpoint that answers.

QLever (University of Freiburg) serves the same Wikidata data and returns
large result sets in seconds; the public Wikidata Query Service stops at 60 s
per query and is often rate-limited. We try QLever first and fall back to
WDQS. QLever doesn't predefine prefixes, so every query carries them.
"""

from __future__ import annotations

import json
import urllib.parse

from ..net import Client

QLEVER = "https://qlever.dev/api/wikidata"
WDQS = "https://query.wikidata.org/sparql"
ENDPOINTS = [QLEVER, WDQS]

PREFIXES = """PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX wdt: <http://www.wikidata.org/prop/direct/>
PREFIX p: <http://www.wikidata.org/prop/>
PREFIX psv: <http://www.wikidata.org/prop/statement/value/>
PREFIX wikibase: <http://wikiba.se/ontology#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
"""


def run_at(client: Client, endpoint: str, query: str) -> dict:
    """One query at one endpoint. Raises on network errors or an answer that
    isn't complete JSON (WDQS cuts answers off at its time limit)."""
    url = endpoint + "?" + urllib.parse.urlencode({"query": PREFIXES + query, "format": "json"})
    return json.loads(client.get(url, headers={"Accept": "application/sparql-results+json"}))


def run(client: Client, query: str) -> dict:
    """First endpoint that answers wins; the last error is raised if none do."""
    err: Exception | None = None
    for ep in ENDPOINTS:
        try:
            return run_at(client, ep, query)
        except Exception as e:  # noqa: BLE001 - any failure means "try the next endpoint"
            err = e
    assert err is not None
    raise err
