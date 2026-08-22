#!/usr/bin/env python3
"""Fetch the OSM voltage evidence snapshots for ROADMAP item 24 (stdlib only).

Two subcommands against the public Overpass API. Queries run LIVE (attic
`[date:...]` queries measured ~8x slower on 2026-08-18 and time out on
region-sized tiles); reproducibility comes from (a) the vendored response file
itself, sha256-pinned in data/vendored/PROVENANCE.md, and (b) the
`timestamp_osm_base` of every response recorded in the output metadata — an
attic re-fetch pinned to the oldest of those timestamps reproduces the pull:

  substations   All US voltage-tagged substations (nwr[power=substation][voltage]),
                chunked into 14 tiles (12 CONUS + AK + HI), tags + center only.
                ~56k objects / ~20 MB. Writes data/vendored/osm_substations_<pin>.json

  lines --yards CSV
                power=line / power=minor_line ways WITH a voltage tag passing
                within --radius m (default 120) of each yard in the CSV
                (columns: substation_id,lat,lon). Batched union-of-around
                queries, ~300 yards per request, tags + way geometry, so the
                matcher can attribute ways to yards locally. The queried yard
                list is embedded in the output metadata for reproducibility.
                Writes data/vendored/osm_line_voltages_<pin>.json

Both outputs are merged, deduplicated by (type, id), sorted, and carry the ODbL
attribution in their metadata. OSM data is (c) OpenStreetMap contributors,
ODbL 1.0 — NOT public domain; see the PROVENANCE.md entry.
"""

import argparse
import csv
import hashlib
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Output filename date; the effective data pin is the recorded
# timestamp_osm_base values (see module docstring).
FETCH_DATE = "2026-08-18"

ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]

USER_AGENT = "PowerModel-ingest/1.0 (US grid cascade research; chunked + throttled)"

# (south, west, north, east). 12 CONUS tiles (6 lon bands x 2 lat bands) + AK + HI.
CONUS_LON_EDGES = [-125.0, -115.3, -105.6, -95.9, -86.2, -76.5, -66.8]
CONUS_LAT_EDGES = [24.3, 37.0, 49.5]


def tiles():
    out = []
    for i in range(len(CONUS_LON_EDGES) - 1):
        for j in range(len(CONUS_LAT_EDGES) - 1):
            out.append(
                (
                    CONUS_LAT_EDGES[j],
                    CONUS_LON_EDGES[i],
                    CONUS_LAT_EDGES[j + 1],
                    CONUS_LON_EDGES[i + 1],
                )
            )
    out.append((51.0, -170.0, 71.5, -129.0))  # Alaska
    out.append((18.5, -160.6, 22.5, -154.4))  # Hawaii
    return out


def overpass(query, tries_per_endpoint=3):
    """POST a query, rotating endpoints and backing off on 429/504."""
    last_err = None
    for attempt in range(tries_per_endpoint * len(ENDPOINTS)):
        endpoint = ENDPOINTS[attempt % len(ENDPOINTS)]
        req = urllib.request.Request(
            endpoint,
            data=urllib.parse.urlencode({"data": query}).encode(),
            headers={"User-Agent": USER_AGENT},
        )
        try:
            with urllib.request.urlopen(req, timeout=900) as resp:
                return json.load(resp)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            last_err = e
            wait = 15 * (attempt + 1)
            print(f"  retry: {endpoint} failed ({e}); sleeping {wait}s", file=sys.stderr)
            time.sleep(wait)
    raise RuntimeError(f"Overpass query failed after retries: {last_err}")


def write_snapshot(path, meta, elements):
    elements = list({(e["type"], e["id"]): e for e in elements}.values())
    elements.sort(key=lambda e: (e["type"], e["id"]))
    meta["element_count"] = len(elements)
    meta["license"] = "ODbL 1.0, (c) OpenStreetMap contributors"
    stamps = [t for t in meta.get("osm_base_timestamps", []) if t]
    meta["date_pin"] = min(stamps) if stamps else FETCH_DATE
    meta["reproduce"] = (
        "re-run each query with [date:\"%s\"] (attic) to reproduce" % meta["date_pin"]
    )
    doc = {"metadata": meta, "elements": elements}
    with open(path, "w") as f:
        json.dump(doc, f, separators=(",", ":"), sort_keys=True)
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    size = len(open(path, "rb").read())
    print(f"wrote {path}: {len(elements)} elements, {size} bytes")
    print(f"sha256: {digest}")


def fetch_substations(out_path):
    all_elements = []
    timestamps = []
    for n, (s, w, nn, e) in enumerate(tiles(), 1):
        query = (
            f'[out:json][timeout:600];'
            f'nwr["power"="substation"]["voltage"]({s},{w},{nn},{e});'
            "out tags center qt;"
        )
        print(f"tile {n}/14 ({s},{w},{nn},{e})...", file=sys.stderr)
        doc = overpass(query)
        timestamps.append(doc.get("osm3s", {}).get("timestamp_osm_base"))
        all_elements.extend(doc.get("elements", []))
        print(f"  {len(doc.get('elements', []))} elements", file=sys.stderr)
        time.sleep(3)
    meta = {
        "query": 'nwr["power"="substation"]["voltage"], tags+center, 14 tiles (12 CONUS + AK + HI)',
        "tiles": tiles(),
        "osm_base_timestamps": timestamps,
    }
    write_snapshot(out_path, meta, all_elements)


def fetch_lines(out_path, yards_csv, radius_m, batch_size):
    yards = []
    with open(yards_csv) as f:
        for row in csv.DictReader(f):
            yards.append(
                (int(row["substation_id"]), float(row["lat"]), float(row["lon"]))
            )
    print(f"{len(yards)} yards, {radius_m} m radius, batches of {batch_size}", file=sys.stderr)

    all_elements = []
    timestamps = []
    batches = [yards[i : i + batch_size] for i in range(0, len(yards), batch_size)]
    for n, batch in enumerate(batches, 1):
        clauses = "".join(
            f'way(around:{radius_m},{lat:.6f},{lon:.6f})["power"~"^(line|minor_line)$"]["voltage"];'
            for (_id, lat, lon) in batch
        )
        query = f"[out:json][timeout:600];({clauses});out tags geom qt;"
        print(f"batch {n}/{len(batches)} ({len(batch)} yards)...", file=sys.stderr)
        doc = overpass(query)
        timestamps.append(doc.get("osm3s", {}).get("timestamp_osm_base"))
        all_elements.extend(doc.get("elements", []))
        print(f"  {len(doc.get('elements', []))} ways", file=sys.stderr)
        time.sleep(2)

    meta = {
        "query": f'way(around:{radius_m},yard)["power"~"^(line|minor_line)$"]["voltage"], tags+geom',
        "radius_m": radius_m,
        "yards": [{"substation_id": i, "lat": lat, "lon": lon} for (i, lat, lon) in yards],
        "osm_base_timestamps": timestamps,
    }
    write_snapshot(out_path, meta, all_elements)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_subs = sub.add_parser("substations")
    p_subs.add_argument("--out", default=f"data/vendored/osm_substations_{FETCH_DATE}.json")

    p_lines = sub.add_parser("lines")
    p_lines.add_argument("--yards", required=True, help="CSV: substation_id,lat,lon")
    p_lines.add_argument("--radius", type=int, default=120)
    p_lines.add_argument("--batch-size", type=int, default=300)
    p_lines.add_argument("--out", default=f"data/vendored/osm_line_voltages_{FETCH_DATE}.json")

    args = parser.parse_args()
    if args.cmd == "substations":
        fetch_substations(args.out)
    else:
        fetch_lines(args.out, args.yards, args.radius, args.batch_size)


if __name__ == "__main__":
    main()
