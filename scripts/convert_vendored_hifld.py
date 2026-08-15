#!/usr/bin/env python3
"""Convert the vendored HIFLD Next transmission-line GeoParquet to GeoJSON Lines.

The pinned snapshot (data/vendored/hifld_next_transmission_lines_v1.parquet,
94,619 features -- see data/vendored/PROVENANCE.md) is GeoParquet 1.1 with WKB
geometry.  `PowerModel.Ingestion.HIFLD.TransmissionLines.ingest/1` reads the
output of this script.

Output format is GeoJSON Lines (`.geojsonl`): one complete GeoJSON Feature per
line, no enclosing FeatureCollection.  A single-document FeatureCollection of
these 94,619 line geometries is ~500 MB and has to be held in memory whole to
be decoded; newline-delimited features stream in constant memory on both sides.
Pass --feature-collection if you need a conventional .geojson instead (the
Elixir reader accepts both).

Dependencies: pyarrow only.  WKB is decoded here rather than via
geopandas/shapely so the conversion needs no compiled geo stack:

    uv venv .venv && uv pip install --python .venv/bin/python pyarrow
    # or: python3 -m pip install pyarrow

Usage:

    python3 scripts/convert_vendored_hifld.py                     # defaults below
    python3 scripts/convert_vendored_hifld.py --limit 25 \
        --output test/fixtures/hifld/transmission_lines_mini.geojsonl
    python3 scripts/convert_vendored_hifld.py --verify-only       # counts, no write

Defaults: data/vendored/hifld_next_transmission_lines_v1.parquet ->
data/vendored/hifld_next_transmission_lines_v1.geojsonl
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_INPUT = REPO_ROOT / "data" / "vendored" / "hifld_next_transmission_lines_v1.parquet"

# Fields the ingester reads. VOLTAGE/VOLT_CLASS drive voltage, TYPE marks HVDC,
# STATUS drives in/out of service, SUB_1/SUB_2 are the connectivity keys, and
# INFERRED records HIFLD's own geometry-provenance flag (65% of rows are Y).
REQUIRED_FIELDS = [
    "source_ID",
    "TYPE",
    "STATUS",
    "VOLTAGE",
    "VOLT_CLASS",
    "INFERRED",
    "SUB_1",
    "SUB_2",
    "OWNER",
    "NAICS_CODE",
    "NAICS_DESC",
]

# Columns that exist in the parquet but carry nothing the model reads.
DROPPED_FIELDS = {"bbox", "Shape__Length"}

WKB_LINESTRING = 2
WKB_MULTILINESTRING = 5


class WKBError(ValueError):
    pass


def _read_geometry(buf: memoryview, offset: int) -> tuple[str, list, int]:
    """Decode one WKB geometry at `offset`; returns (geojson_type, coords, next_offset)."""
    if offset + 5 > len(buf):
        raise WKBError("truncated WKB header")

    byte_order = buf[offset]
    endian = "<" if byte_order == 1 else ">"
    (raw_type,) = struct.unpack_from(endian + "I", buf, offset + 1)
    offset += 5

    # ISO WKB encodes Z/M in the thousands digit (1002 = LineStringZ); EWKB uses
    # high bits (0x80000000 Z, 0x40000000 M, 0x20000000 SRID). Handle both so an
    # upstream re-export with elevation does not silently scramble coordinates.
    has_srid = bool(raw_type & 0x20000000)
    ewkb_z = bool(raw_type & 0x80000000)
    ewkb_m = bool(raw_type & 0x40000000)
    base_type = raw_type & 0xFF
    iso_dim = (raw_type & 0x0FFFFFFF) // 1000
    extra_ords = (1 if ewkb_z else 0) + (1 if ewkb_m else 0)
    if iso_dim == 1 or iso_dim == 2:  # Z or M
        extra_ords += 1
    elif iso_dim == 3:  # ZM
        extra_ords += 2

    if has_srid:
        offset += 4

    if base_type == WKB_LINESTRING:
        coords, offset = _read_points(buf, offset, endian, extra_ords)
        return "LineString", coords, offset

    if base_type == WKB_MULTILINESTRING:
        (n_parts,) = struct.unpack_from(endian + "I", buf, offset)
        offset += 4
        parts = []
        for _ in range(n_parts):
            _type, part, offset = _read_geometry(buf, offset)
            parts.append(part)
        return "MultiLineString", parts, offset

    raise WKBError(f"unsupported WKB geometry type {raw_type}")


def _read_points(buf: memoryview, offset: int, endian: str, extra_ords: int) -> tuple[list, int]:
    (n_points,) = struct.unpack_from(endian + "I", buf, offset)
    offset += 4
    stride = 8 * (2 + extra_ords)
    coords = []
    for _ in range(n_points):
        x, y = struct.unpack_from(endian + "dd", buf, offset)
        # Z/M ordinates are dropped: the model is planar and a stray third
        # ordinate reaching Geo.LineString would be read as another point.
        coords.append([x, y])
        offset += stride
    return coords, offset


def wkb_to_geojson(blob: bytes) -> dict | None:
    if blob is None:
        return None
    geom_type, coords, _ = _read_geometry(memoryview(blob), 0)
    return {"type": geom_type, "coordinates": coords}


def clean(value):
    """Normalize a parquet cell for JSON: NaN/empty-string -> None."""
    if value is None:
        return None
    if isinstance(value, float) and value != value:  # NaN
        return None
    if isinstance(value, str):
        stripped = value.strip()
        return stripped or None
    return value


def convert(
    input_path: Path,
    output_path: Path | None,
    limit: int | None,
    feature_collection: bool,
) -> dict:
    import pyarrow.parquet as pq

    parquet = pq.ParquetFile(input_path)
    schema_names = set(parquet.schema_arrow.names)
    missing = [f for f in REQUIRED_FIELDS if f not in schema_names]
    if missing:
        raise SystemExit(f"ERROR: {input_path} is missing required field(s): {missing}")

    property_names = [
        name
        for name in parquet.schema_arrow.names
        if name != "geometry" and name not in DROPPED_FIELDS
    ]

    stats = {
        "parquet_rows": parquet.metadata.num_rows,
        "features_written": 0,
        "geometry_null": 0,
        "geometry_failed": 0,
        "geometry_types": {},
        "field_present": {name: 0 for name in REQUIRED_FIELDS},
        "dc_lines": 0,
    }

    out = None
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        out = output_path.open("w", encoding="utf-8")
        if feature_collection:
            out.write('{"type": "FeatureCollection", "features": [\n')

    first = True
    try:
        for batch in parquet.iter_batches(batch_size=2048):
            columns = {name: batch.column(name).to_pylist() for name in property_names}
            geometries = batch.column("geometry").to_pylist()

            for i in range(batch.num_rows):
                if limit is not None and stats["features_written"] >= limit:
                    break

                blob = geometries[i]
                if blob is None:
                    stats["geometry_null"] += 1
                    continue
                try:
                    geometry = wkb_to_geojson(blob)
                except WKBError as err:
                    stats["geometry_failed"] += 1
                    print(f"  WKB decode failed on row {i}: {err}", file=sys.stderr)
                    continue

                gtype = geometry["type"]
                stats["geometry_types"][gtype] = stats["geometry_types"].get(gtype, 0) + 1

                properties = {name: clean(columns[name][i]) for name in property_names}
                for name in REQUIRED_FIELDS:
                    if properties.get(name) is not None:
                        stats["field_present"][name] += 1

                type_value = (properties.get("TYPE") or "").upper()
                volt_class = (properties.get("VOLT_CLASS") or "").upper()
                if type_value.startswith("DC") or volt_class == "DC":
                    stats["dc_lines"] += 1

                if out is not None:
                    feature = {
                        "type": "Feature",
                        "geometry": geometry,
                        "properties": properties,
                    }
                    if feature_collection and not first:
                        out.write(",\n")
                    json.dump(feature, out, separators=(",", ":"))
                    if not feature_collection:
                        out.write("\n")
                    first = False

                stats["features_written"] += 1

            if limit is not None and stats["features_written"] >= limit:
                break
    finally:
        if out is not None:
            if feature_collection:
                out.write("\n]}\n")
            out.close()

    return stats


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="output path (default: <input>.geojsonl next to the parquet)",
    )
    parser.add_argument("--limit", type=int, default=None, help="convert only the first N features")
    parser.add_argument("--verify-only", action="store_true", help="report counts, write nothing")
    parser.add_argument(
        "--feature-collection",
        action="store_true",
        help="emit one .geojson FeatureCollection instead of newline-delimited features",
    )
    args = parser.parse_args(argv)

    if not args.input.exists():
        raise SystemExit(f"ERROR: input not found: {args.input}\nSee data/vendored/PROVENANCE.md for the fetch URL.")

    if args.verify_only:
        output_path = None
    elif args.output is not None:
        output_path = args.output
    else:
        suffix = ".geojson" if args.feature_collection else ".geojsonl"
        output_path = args.input.with_suffix(suffix)

    print(f"Reading {args.input}")
    stats = convert(args.input, output_path, args.limit, args.feature_collection)

    print(f"  parquet rows:      {stats['parquet_rows']}")
    print(f"  features written:  {stats['features_written']}")
    print(f"  null geometry:     {stats['geometry_null']}")
    print(f"  failed geometry:   {stats['geometry_failed']}")
    print(f"  geometry types:    {stats['geometry_types']}")
    print(f"  DC-flagged lines:  {stats['dc_lines']}")
    print("  required-field coverage:")
    for name in REQUIRED_FIELDS:
        present = stats["field_present"][name]
        pct = 100.0 * present / stats["features_written"] if stats["features_written"] else 0.0
        print(f"    {name:<12} {present:>7} ({pct:5.1f}%)")

    expected = stats["parquet_rows"] if args.limit is None else min(args.limit, stats["parquet_rows"])
    accounted = stats["features_written"] + stats["geometry_null"] + stats["geometry_failed"]
    if args.limit is None and accounted != stats["parquet_rows"]:
        raise SystemExit(
            f"ERROR: {accounted} features accounted for, parquet holds {stats['parquet_rows']}"
        )
    if stats["geometry_failed"]:
        raise SystemExit(f"ERROR: {stats['geometry_failed']} geometries failed to decode")
    if stats["features_written"] != expected - stats["geometry_null"]:
        raise SystemExit("ERROR: feature count does not match the parquet row count")

    if output_path is not None:
        size_mb = output_path.stat().st_size / 1e6
        print(f"Wrote {output_path} ({size_mb:.1f} MB)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
