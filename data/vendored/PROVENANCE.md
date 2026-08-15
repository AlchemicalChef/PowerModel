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
  `ingestion/hifld/api.ex` currently queries (a user upload from Sept 2023, NOT an
  authoritative HIFLD service). ROADMAP Phase 2 should switch ingestion to this file.

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
- This layer feeds the native-substations path (`ingestion/hifld/substations.ex`
  shapefile branch) and ROADMAP Phase 2 connectivity work. Nothing newer will ever be
  public (updates live in HIFLD Secure only).
