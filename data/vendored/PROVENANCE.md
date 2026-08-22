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

# OpenStreetMap snapshots — © OpenStreetMap contributors, ODbL 1.0

NOT public domain, unlike everything above. OSM data is licensed under the Open
Database License 1.0 (https://opendatacommons.org/licenses/odbl/1-0/). Voltage
attributes derived from these files and written into the database make the database a
derivative under ODbL: if the database or a database-substantial product of it is
publicly distributed, share-alike and attribution obligations attach to the
OSM-derived portion. That portion is kept extractable by construction — every
OSM-sourced row carries `voltage_source` ('osm_corridor', 'osm_matched',
'osm_line_inferred', 'osm_rederived') and the `osm_substation_matches` table holds the
per-yard evidence; nulling those markers removes every OSM-derived datum while
`source` (HIFLD) remains the provenance of rows, geometry and endpoints.

## osm_corridor_{nm,ut,tx}_2026-08-18.json + osm_corridor_corrections_2026-08-18.json
- Source: Overpass API, https://overpass-api.de/api/interpreter, date-pinned attic
  query `[date:"2026-08-18T00:00:00Z"]` — exactly re-runnable. Query shape:
  `(way[power=line]; way[power=minor_line]; node/way/relation[power=substation];
  node/way[power=plant];) out tags geom;` over three corridor bboxes (S,W,N,E):
  NM 33.55,-103.9,34.4,-103.05; UT 37.05,-113.85,37.85,-112.85;
  TX 32.15,-102.15,33.3,-100.75.
- osm_corridor_nm: 473,731 B, sha256 3320c350663dfae7483e38547978b260b5d4e77e8fe650a9289120960f4a664f
- osm_corridor_ut: 905,324 B, sha256 852735c326311e899a5da66b521b73c072edac8816457d3a5507ef25efe1dd56
- osm_corridor_tx: 1,306,302 B, sha256 2d7c3ebf677da2b8468c490ea8fa51dde2af8b36f9b0f82cf5111f069ff4fe78
- osm_corridor_corrections: 19,128 B, sha256
  0be205717cd4d9e2cf35269ef749482fbef67b7363669dc574226ac7241a605c. This file IS
  committed (gitignore exception): it records the 17 corrected `transmission_lines`
  rows (prior voltage/impedance values, OSM way ids, per-row reasons) and is the
  attribution + reversibility record; the three raw pulls are re-fetchable from the
  date pin and stay unversioned like the HIFLD snapshots.
- Written to DB 2026-08-19: 17 voltage-class corrections, `voltage_source='osm_corridor'`.

## osm_substations_2026-08-18.json
- Source: Overpass API, full-US pull in 14 regional tiles, power=substation with
  voltage tags. 58,766 elements, 14.4 MB.
- sha256: 8c79f5fa84434c3a0b1329a5d14f4700cd4d82266bd8e05e3257e8dad54a5109
- Fetched 2026-08-18 (ET evening); oldest per-tile `timestamp_osm_base`:
  2026-06-01T08:52:28Z — the attic pin that reproduces the pull.
- Deviation from the scoped attic plan: attic queries measured ~8x slower on
  2026-08-18 and timed out on region tiles, so this pull ran LIVE with each
  response's `timestamp_osm_base` recorded in the file metadata; an attic re-fetch
  pinned to the oldest recorded timestamp reproduces it, and the sha256 above is the
  primary pin (same convention as the HIFLD snapshots). Transient 429/504s recovered
  by retry + mirror rotation.
- Feeds `PowerModel.Ingestion.OSM.Substations` → matcher → voltage backfill of
  voltage-blind yards (`voltage_source='osm_matched'`).

## osm_line_voltages_2026-08-18.json
- Source: Overpass API, per-yard around-queries on the 6,066 yards left unmatched by
  the substation pass; power=line/minor_line ways with voltage tags within 120 m.
  3,844 ways, 9.9 MB. Queried-yard list embedded in file metadata.
- sha256: 511c4a1d8c57be8df7ff7a2fd76c074b016aa135c3494abc6194e07a117d32a4
- Fetched 2026-08-18 (ET evening); oldest per-batch `timestamp_osm_base`:
  2026-06-24T06:53:00Z — the attic pin that reproduces the pull.
- Feeds the line-inference fallback (`voltage_source='osm_line_inferred'`) and the
  restored-circuit class re-derivation (`voltage_source='osm_rederived'`).
