# Vendored data snapshots — provenance

Pinned 2026-08-15 per ROADMAP.md "Decisions needed now" (HIFLD Open was shut down by DHS
2025-08-26; every public copy is a frozen snapshot and the mirrors themselves can vanish).
Files in this directory are NOT committed (see .gitignore); this record makes them
re-fetchable and verifiable.

## hifld_next_transmission_lines_v1.parquet
- Source: HIFLD Next (Public Environmental Data Partners), the Data Rescue Project's
  final pre-shutdown snapshot. Direct URL:
  https://hifld.publicenvirodata.org/storage/transmission-lines-1/transmission-lines-1/v1.0.0/geoparquet/transmission-lines-1.parquet
- Fetched: 2026-08-15. Size: 46,431,637 bytes. Features: 94,619.
- sha256: cbdd1c892ae73748a8241fbc28374465ec289a2906ee2214d796085e6a5cba4e
- License: US Government work, public domain.
- Note: this is ~1.8x the 52,244-feature cut served by the GeoPlatform ArcGIS org that
  `ingestion/hifld/api.ex` queries (a user upload from Sept 2023, NOT an authoritative
  HIFLD service). Ingestion switched to this file 2026-08-15 (ROADMAP Phase 2); the API
  path remains as a documented fallback behind `--api`.

## hifld_next_transmission_lines_v1.geojsonl (derived)
- Produced from the parquet above by `python3 scripts/convert_vendored_hifld.py`
  (needs pyarrow; WKB is decoded in the script, so no geopandas/shapely).
- 94,619 features, one GeoJSON Feature per line, 138,693,793 bytes. Geometry types:
  23,710 LineString + 70,909 MultiLineString. The script verifies the written feature
  count against the parquet row count and fails if they disagree.
- Newline-delimited rather than one FeatureCollection: as a single document these
  geometries are ~500 MB and must be decoded whole.
- Read by `PowerModel.Ingestion.HIFLD.TransmissionLines.ingest_geojson/1`; regenerate
  after any re-fetch. `test/fixtures/hifld/transmission_lines_mini.geojsonl` is the
  first 25 features of this file (`--limit 25`), committed as the conversion contract.

## hifld_substations_mirror_2021vintage.geojson
- Source: third-party ArcGIS mirror of the LAST public cut of the HIFLD Electric
  Substations layer (pulled from public HIFLD ~2022; absent from every official archive
  — HIFLD Next, SeerAI, DataLumos all lack it). Mirror:
  https://services6.arcgis.com/OO2s4OoyCZkYJ6oE/arcgis/rest/services/Substations/FeatureServer/0
  (personal AGOL account, item license "None (Public Use)" — fetched via 39 paginated
  GeoJSON queries, resultRecordCount=2000).
- Fetched: 2026-08-15. Size: 58,243,905 bytes. Features: 77,946 (matches mirror count).
- sha256: 15fe32c179e5c41e1a2b2b47c95ad32e6252cf228b69e463230c3a8060c9fdfd
- Vintage: max SOURCEDATE/VAL_DATE 2021-06-01. Schema includes NAME, TYPE, STATUS,
  LINES, MAX_VOLT, MIN_VOLT, MAX_INFER, MIN_INFER. Known quality: -999999 sentinels on
  MAX_VOLT for 18,589 rows, MIN_VOLT 24,365, LINES 6,732; 72,365 IN SERVICE; OSM
  reviewers estimate 40-60% ground-truth failure rate — treat as a prior, not truth.
- License: underlying data US Government work, public domain.
- This layer feeds the native-substations path
  (`PowerModel.Ingestion.HIFLD.Substations.ingest_geojson/1`, live since 2026-08-15) and
  ROADMAP Phase 2 connectivity work: line endpoints are keyed to these yards by NAME.
  Nothing newer will ever be public (updates live in HIFLD Secure only).
- Measured against the line snapshot: 86% of the 189,238 line endpoints carry a
  `SUB_1`/`SUB_2` name that resolves to a substation here. HIFLD writes the yard's own
  record id into unnamed rows, so `UNKNOWN<id>` (37,625 distinct) and `TAP<id>` (20,567)
  are per-yard keys, not placeholders — see `PowerModel.Ingestion.HIFLD.Names`.
- `test/fixtures/hifld/substations_mini.geojson` is the 51 yards named by the committed
  25-line fixture, plus two all-sentinel-voltage rows.
