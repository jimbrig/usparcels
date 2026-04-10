<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# help me crystalize/formalize the over-arching goals of this endeavor, and in turn plan out the various sub-systems/projects involved:

current prompt from space (informal text i wrote from my phone):

```plaintext
Space dedicated to a project dedicated to modern geospatial data engineering and analysis work using a large, nationwide US parcels ~100GB gpkg as the initial core data source. 

The primary goals are to leverage modern advanced geospatial tooling and tactics to a) extract and process the parcel data into modern cloud native (geo)parquet formats partitioned by state and b) create modern PMTiles MLT encoded vector tile containers for use with maplibre maps for nice visuals. Two related artifacts from the initial source. This work is incremental and should leverage modern GDAL/OGR and vector tile tooling to derive the artifacts in as performant, efficient, and robust manner as possible.

However; this is just the start - in order to provide full real estate context around the parcels - additional data sources will be integrated with and served in a similar fashion as the parcels, namely TIGER and FEMA NFHL to start with additional sources possibly added later for other public sources (ie USGS, NWI, OSM, Overture, SSURGO/gSSURGO, etc)
```

throughout this conversation, be sure to a) provide insights and feedback and anything relevant that I should be aware of around these topics b) validate or verify my proposed architectures or decisions and also think about optimal implementation details c) stick to modern geospatial technology and standards etc.

the e2e idea is as follows:

## STORAGE

setup tigris blob storage account for future use and this is the planned tool to be used for S3 compatible blob storage and other features (a side goal of the project is experimentation with new tools/tech etc.). have not been able to migrate the gpkg there yet.

designed an initial rough plan for how to process the data out and how to organize and host it, specifically:

- stage 0: gpkg (original, slightly altered, raw)
- stage 1: extract per-state FGB as "intermediate" modernized, easier to work with, cloud native formats
- stage 2: using FGBs, create hive partitioned by statefp and countyfp FIPS codes geoparquet
- stage 3: using parquet's or FGBs create some initial state/AOI specific PMTiles for map layers/visualization using freestiler R package and MLT encoding
- stage 4: design interfaces for both the data specific aspects (i.e. metadata / browsing interface around the parquets) and a maplibre web app map client frontend using maplibre-components TS library and custom styling TS library similar to protomaps
- stage 5: incorporate additional data sources into the system, to start off TIGER and FEMA NFHL zips > parquet + pmtiles etc. later may add more (USGS, SSURGO/gSSURGO, NWI, Overture, OSM, etc.)


## GPKG

start off with nothing but a single, large, hard to work with geopackage downloaded from kaggle (https://www.kaggle.com/datasets/landrecordsus/us-parcel-layer?select=LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg) which is supposed to be roughly inline with the docs at [Land Records](https://landrecords.us/documentation) but is likely a less complete version of it from what i can tell (not sure about this though) - download was initially compressed zip archive and has been unzipped to a specific location on my C drive, i.e. C:/GEODATA/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg to ensure its on my most performant possible SSD NVMe drive (C:) for better performance (originally had it on an external HDD)

DATA WORK

1. perform analysis on the gpkg locally using GDAL/OGR, SQLite tooling, etc. to get a general idea of things (already done, but want to formalize into some R package functions for working with gpkg and sqlite in this geospatial context). determined that while a spatial (R-tree) index existed, no attribute based B indexes existed for the main data.

ran some optimization SQL queries against the gpkg to help with performance (PRAGMA stuff), i.e. for a persistent change I ran this from CLI (could have been from R):

```pwsh
sqlite3 LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL"
```

examined key ID fields, namely `geoid`, `statefp`, and `countyfp` - all check out and are correct (2/3/5 character FIPS codes, no missing or NULLs);

decided to create b indexes for these fields via:

```R
parcels_path <- "C:/GEODATA/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"
conn <- DBI::dbConnect(RSQLite::SQLite(), parcels_path)
DBI::dbExecute(conn, "PRAGMA journal_mode = WAL;")
DBI::dbExecute(conn, "PRAGMA synchronous = OFF;")
DBI::dbExecute(conn, "PRAGMA cache_size = -4000000;")
DBI::dbExecute(conn, "PRAGMA temp_store = MEMORY;")
DBI::dbExecute(conn, "PRAGMA mmap_size = 8589934592;")

pre_indexes <- DBI::dbGetQuery(conn, "
  SELECT name, tbl_name, sql
  FROM sqlite_master
  WHERE type = 'index' AND tbl_name = 'lr_parcel_us'
")

system.time({
  DBI::dbExecute(conn, "
    CREATE INDEX IF NOT EXISTS idx_parcel_state_county
    ON lr_parcel_us (statefp, countyfp, geoid)
  ")
})

system.time({
  DBI::dbExecute(conn, "ANALYZE idx_parcel_state_county;")
})

# verify
DBI::dbGetQuery(conn, "
  SELECT name, tbl_name, sql
  FROM sqlite_master
  WHERE type = 'index' AND tbl_name = 'lr_parcel_us'
")

# explain
DBI::dbGetQuery(conn, "
  EXPLAIN QUERY PLAN
  SELECT statefp, countyfp, COUNT(*)
  FROM lr_parcel_us
  GROUP BY statefp, countyfp
")

# sanity checks
system.time({
  states <- DBI::dbGetQuery(conn, "
    SELECT COUNT(DISTINCT statefp) AS n_states,
           COUNT(DISTINCT countyfp) AS n_counties,
           COUNT(DISTINCT statefp || countyfp) AS n_state_county
    FROM lr_parcel_us
  ")
})

DBI::dbDisconnect(conn)
```

determine the optimal schema/fields to drop etc. for the initial per-state FGB extraction and creations, using GDAL OGR (ogr2ogr or gdal vector pipeline approach).

did this for Georgia and North Carolina, i.e.:

```sh
# NOTE: at this phase I was working in WSL due to GDAL + libarrow deps, but have since figured this out for windows, but just FYI why the paths, etc. are different:
#!/usr/bin/env bash
# ---- gpkg to flatgeobuf extraction -----------------------------------------
# extracts a single state from the monolithic GPKG into a FlatGeoBuf file
# with Hilbert-packed spatial index and cleaned schema (drops: parcelstate,
# lrversion, halfbaths, fullbaths).
#
# usage:
#   ./scripts/gpkg_fgb_extraction.sh <state_fips> <min_x> <min_y> <max_x> <max_y>
#
# examples:
#   ./scripts/gpkg_fgb_extraction.sh 13 -85.61 30.36 -80.84 35.00   # georgia
#   ./scripts/gpkg_fgb_extraction.sh 37 -84.32 33.84 -75.46 36.59   # north carolina
#
# requires: pixi environment with gdal >= 3.12.3
# gpkg path: /mnt/c/GEODATA/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg (NVMe)
# output:    data/output/flatgeobuf/state=<fips>/parcels.fgb
# -------------------------------------------------------------------------

set -euo pipefail

STATE_FIPS="${1:?usage: $0 <state_fips> <min_x> <min_y> <max_x> <max_y>}"
MIN_X="${2:?missing min_x}"
MIN_Y="${3:?missing min_y}"
MAX_X="${4:?missing max_x}"
MAX_Y="${5:?missing max_y}"

GPKG_PATH="/mnt/c/GEODATA/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"
OUT_DIR="data/output/flatgeobuf/state=${STATE_FIPS}"
OUT_FILE="${OUT_DIR}/parcels.fgb"
LOG_FILE="/tmp/fgb_state${STATE_FIPS}.log"

# sqlite read performance pragmas
export OGR_SQLITE_PRAGMA="cache_size=-4194304,temp_store=MEMORY,journal_mode=WAL"
export OGR_GPKG_NUM_THREADS="ALL_CPUS"
export GDAL_CACHEMAX="2048"

mkdir -p "${OUT_DIR}"

echo "[$(date +%Y-%m-%dT%H:%M:%S)] starting FGB extraction for state=${STATE_FIPS}" | tee "${LOG_FILE}"
echo "[$(date +%Y-%m-%dT%H:%M:%S)] gpkg: ${GPKG_PATH}" | tee -a "${LOG_FILE}"
echo "[$(date +%Y-%m-%dT%H:%M:%S)] output: ${OUT_FILE}" | tee -a "${LOG_FILE}"
echo "[$(date +%Y-%m-%dT%H:%M:%S)] bbox: ${MIN_X} ${MIN_Y} ${MAX_X} ${MAX_Y}" | tee -a "${LOG_FILE}"

# column-select SQL: drops parcelstate, lrversion, halfbaths, fullbaths
SQL="SELECT
  lrid, parcelid, parcelid2, geoid, statefp, countyfp,
  taxacctnum, taxyear, usecode, usedesc, zoningcode, zoningdesc,
  numbldgs, numunits, yearbuilt, numfloors, bldgsqft,
  bedrooms,
  imprvalue, landvalue, agvalue, totalvalue, assdacres,
  saleamt, saledate,
  ownername, owneraddr, ownercity, ownerstate, ownerzip,
  parceladdr, parcelcity, parcelzip,
  legaldesc, township, section, qtrsection, range,
  plssdesc, book, page, block, lot, updated,
  centroidx, centroidy, surfpointx, surfpointy,
  geom
FROM lr_parcel_us
WHERE statefp = '${STATE_FIPS}'"

START_TIME=$(date +%s)

pixi run ogr2ogr \
  -f FlatGeoBuf \
  -lco SPATIAL_INDEX=YES \
  -sql "${SQL}" \
  -spat "${MIN_X}" "${MIN_Y}" "${MAX_X}" "${MAX_Y}" \
  -nln parcels \
  -overwrite \
  "${OUT_FILE}" \
  "${GPKG_PATH}" \
  2>&1 | tee -a "${LOG_FILE}"

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo "[$(date +%Y-%m-%dT%H:%M:%S)] done in ${ELAPSED}s, exit code: $?" | tee -a "${LOG_FILE}"
ls -lh "${OUT_FILE}" | tee -a "${LOG_FILE}"

# quick validation via ogrinfo
echo "[$(date +%Y-%m-%dT%H:%M:%S)] validating output..." | tee -a "${LOG_FILE}"
pixi run ogrinfo -so "${OUT_FILE}" parcels 2>&1 | tee -a "${LOG_FILE}"

```

This is a well-conceived, modern geospatial data engineering platform. Below is a formalized, structured breakdown of the overarching goals and sub-system plan, with technical notes woven in throughout.

***

## Project Mission Statement

Build a **cloud-native, open-standards geospatial data platform** that transforms a monolithic nationwide US parcel GPKG into queryable, partitioned GeoParquet and renderable PMTiles/MLT artifacts — then extend that same pipeline to authoritative public datasets (TIGER, FEMA NFHL, and beyond) — serving both analytical and visualization use cases from a modern blob-backed infrastructure.

***

## Core Design Principles

- **Incremental \& reproducible** — each stage produces a durable, re-usable artifact; no stage has to be re-run to produce the next
- **Cloud-native by default** — GeoParquet (columnar, predicate-pushdown) + PMTiles (single-file, range-request-served) + Tigris (S3-compatible, edge-cached)
- **Format-forward** — prefer open, modern specs: GeoParquet 1.1+ (with `bbox` covering struct), FlatGeoBuf (streaming + Hilbert-packed), MLT (announced January 2026, already the default in `freestiler`)[^1_1][^1_2]
- **Tool composability** — GDAL/OGR, DuckDB, R (`{freestiler}`, `{sfarrow}`, `{DBI}`), `tippecanoe`/`felt`, `pixi` environments

***

## The Pipeline Stages (Formalized)

### Stage 0 — Raw Source

The `LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg` is your ground truth. Your PRAGMA optimizations (WAL mode, `mmap_size`, composite B-tree index on `(statefp, countyfp, geoid)`) are exactly right and unlock dramatically faster filtered reads.  One important note: **do not treat Stage 0 as mutable** — once you've optimized the GPKG and verified integrity, treat it as read-only and derive all downstream artifacts from it. Your `OGR_SQLITE_PRAGMA` env vars on the extraction side cleanly handle the read-path without touching the file.[^1_3]

### Stage 1 — Per-State FlatGeoBuf Extraction

Your existing `ogr2ogr` bash script is solid. A few things worth formalizing:

- **Schema reduction is permanent at this stage** — the dropped fields (`parcelstate`, `lrversion`, `halfbaths`, `fullbaths`) should be documented as intentional, not accidental omissions
- The `-spat` bbox filter combined with `WHERE statefp = '${STATE_FIPS}'` is redundant (the SQL filter is sufficient and more precise) but acts as a coarse pre-filter for the spatial index — harmless, and potentially beneficial for GPKG query planning
- `-lco SPATIAL_INDEX=YES` on FGB enables the Hilbert-packed R-tree, which is critical for spatial streaming performance downstream[^1_4]
- **Consider storing the bounding boxes per state in a manifest JSON** alongside the FGBs — this enables fast bbox-only queries without opening the files


### Stage 2 — Hive-Partitioned GeoParquet

Partitioning by `statefp` then `countyfp` is the right call for your query patterns. Key implementation details to formalize:

- Use **GeoParquet 1.1** with the `bbox` covering struct — this enables column-statistics-based spatial skipping without opening the geometry column[^1_5]
- Compress with `ZSTD` (level 3–5) — consistently better than snappy for geometries; DuckDB's spatial extension writes this natively
- Within each partition file, **sort rows by a Hilbert or GeoHash index** on the centroid before writing — this dramatically improves spatial range scan performance[^1_5]
- One important **hive partition caveat**: partitions must be balanced (no mixing file-at-root with folder-per-key)  — your `state=XX/county=YYY/parcels.parquet` layout is clean and correct[^1_6]
- For very large states (Texas, California), consider a third tier: `quadkey` or H3 sub-partitioning within county[^1_7]


### Stage 3 — PMTiles with MLT Encoding

MLT (MapLibre Tile format) was formally released January 2026 and offers **up to 6× compression vs MVT** on large tiles and up to 3× faster decode speeds, via columnar layout and SIMD-friendly lightweight encodings. The `freestiler` R package by Kyle Walker already defaults to MLT, making it your natural tool here. Key design decisions:[^1_8][^1_9][^1_2]


| Decision | Recommendation |
| :-- | :-- |
| Source for tile generation | FGB (faster streaming) over GeoParquet for `tippecanoe`/`freestiler` |
| Zoom range for parcels | z8–z16 (parcels only meaningful at z12+; z8–11 for county/state aggregates) |
| Property simplification | Drop heavy text fields (`legaldesc`, `owneraddr`) at low zooms |
| Tile encoding | MLT (default in `freestiler`) over MVT for new work |
| PMTiles hosting | Tigris (R2-compatible, supports HTTP range requests natively) |

### Stage 4 — Interfaces

Two distinct surfaces with different audiences:

- **Data/metadata browser** — a lightweight interface over the GeoParquet catalog: file sizes, row counts, schema, sample queries (think STAC-inspired). DuckDB-WASM in the browser can query Tigris-hosted parquets directly[^1_6]
- **MapLibre web app** — MLT-served PMTiles via `maplibre-gl` with your custom styling library. The `encoding: "mlt"` source property is now supported in both MapLibre GL JS and MapLibre Native[^1_1]


### Stage 5 — Additional Data Sources

Each source has a distinct ingestion profile:


| Source | Format | Key Challenge | Output |
| :-- | :-- | :-- | :-- |
| **TIGER** | Shapefile/GDB (Census FTP) | Many separate zip downloads by layer/state | GeoParquet + PMTiles per layer |
| **FEMA NFHL** | FGDB inside ZIP (per county/state) | County-level fragmentation, NAD83 CRS [^1_10] | GeoParquet + PMTiles (flood zones, BFEs) |
| **NWI** | Shapefile/GDB | Large wetland polygons, national | GeoParquet |
| **SSURGO/gSSURGO** | GDB + tabular | Complex relational schema, soil horizon tables | GeoParquet (joined) |
| **Overture** | GeoParquet (already!) | Licensing, schema alignment | Direct ingest / join |
| **OSM** | PBF | Needs `osmium`/`osm2pgsql` pre-processing | GeoParquet |


***

## Sub-Systems / Repos to Formalize

```
us-parcels/
├── pipeline/          # GDAL/OGR scripts, pixi env, stage 0→3 automation
├── r-pkg/             # R package: gpkg analysis helpers, freestiler wrappers, DBI utils
├── catalog/           # Manifest JSON, schema docs, partition inventory
├── infra/             # Tigris bucket config, IAM, CDN rules
├── web/               # MapLibre frontend (maplibre-components + custom styling)
└── metadata-ui/       # Data browser (DuckDB-WASM or lightweight R Shiny/Quarto)
```


***

## Key Things to Be Aware Of

- **GeoParquet 2.0** (native geometry types in Apache Parquet itself) was formalized in early 2026  — worth watching as DuckDB spatial support converges on it, but GeoParquet 1.1 is the safe production target now[^1_11]
- **The Land Records dataset** from Kaggle is likely a public/lite version of the commercial `landrecords.us` product — verify field completeness against their docs, especially `totalvalue`, `saleamt`, and owner fields which commercial versions typically have for ~143M parcels across 2,800 counties[^1_12]
- **FEMA NFHL is stored in NAD83**  — you'll need an explicit `t_srs` in `ogr2ogr` when joining to WGS84 parcels[^1_10]
- **Tigris** (Cloudflare's S3-compatible object storage) natively supports HTTP range requests, which is exactly what both GeoParquet clients (range-fetching row groups) and PMTiles (range-fetching tiles) require — this is an architecturally excellent fit

What's your current thinking on the **automation/orchestration layer** for the per-state pipeline? Are you leaning toward simple shell/Make, something like a `{targets}` R pipeline, or a more formal workflow tool like Prefect/Dagster?
<span style="display:none">[^1_13][^1_14][^1_15][^1_16][^1_17][^1_18][^1_19][^1_20][^1_21][^1_22][^1_23][^1_24][^1_25][^1_26][^1_27][^1_28][^1_29][^1_30]</span>

<div align="center">⁂</div>

[^1_1]: https://maplibre.org/news/2026-01-23-mlt-release/

[^1_2]: https://walker-data.com/freestiler/articles/maplibre-tiles.html

[^1_3]: https://av.tib.eu/media/58674

[^1_4]: https://spyro-soft.com/blog/geospatial/the-role-of-spatial-data-engineering-in-modern-land-management

[^1_5]: https://github.com/opengeospatial/geoparquet/discussions/251

[^1_6]: https://cloudnativegeo.org/blog/2023/10/the-admin-partitioned-geoparquet-distribution/

[^1_7]: https://cloudnativegeo.org/blog/2025/01/sharing-some-tools-for-working-with-geoparquet/

[^1_8]: https://github.com/maplibre/maplibre-tile-spec

[^1_9]: https://arxiv.org/abs/2508.10791

[^1_10]: https://hazards.fema.gov/femaportal/wps/portal/NFHLWMS

[^1_11]: https://parquet.apache.org/blog/2026/02/13/native-geospatial-types-in-apache-parquet/

[^1_12]: https://carto.com/blog/landgrid-national-parcel-data-observatory/

[^1_13]: https://www.linkedin.com/pulse/how-geospatial-data-improves-engineering-decisions-sqvcf

[^1_14]: https://flypix.ai/geospatial-engineering/

[^1_15]: https://www.janeasystems.com/blog/geospatial-ai-across-industries

[^1_16]: https://www.youtube.com/watch?v=rntLCwT6bOA

[^1_17]: https://www.youtube.com/watch?v=nPMtFseyIkc

[^1_18]: https://www.geopackage.org/implementations.html

[^1_19]: https://cybercorsairs.com/captain-yars-treasure-goal-mapper-prompt/

[^1_20]: https://www.locana.co/wp-content/uploads/2024/02/ebook_ODD.pdf

[^1_21]: https://nsgic.org/wp-content/uploads/2024/04/The-Case-for-a-National-Parcels-Dataset.pdf

[^1_22]: https://www.databricks.com/blog/2019/12/05/processing-geospatial-data-at-scale-with-databricks.html

[^1_23]: https://www.reddit.com/r/omnifocus/comments/1040z09/how_to_organize_projects_that_drive_your_doing/

[^1_24]: https://www.fulcrumapp.com/blog/geospatial-data-solutions-in-modern-urban-planning/

[^1_25]: https://keita.blog/2025/maplibre-tile-format/

[^1_26]: https://www.youtube.com/watch?v=4nORdwDk4uU

[^1_27]: https://www.ferc.gov/sites/default/files/2020-04/CP19-495-EA.pdf

[^1_28]: https://www.maplibre.org/maplibre-tile-spec/specification/

[^1_29]: https://hazards.fema.gov/femaportal/NFHL/searchResult/

[^1_30]: https://www.reddit.com/r/programming/comments/1qndbz5/announcing_maplibre_tile_a_modern_and_efficient/


---

# follow ups:

First some high level information about the state of things:

# US Parcels: Phase 0 + Phase 1 Implementation Plan

## Current State

- **GPKG**: 93.66 GB (96.85 GB after index), 154,891,095 features, single layer `lr_parcel_us`, EPSG:4326, WAL mode active
- **Schema**: 51 fields + geometry; partition keys `statefp` (2-char) / `countyfp` (3-char); `geoid` pre-concatenated
- **Indexes**: R-tree spatial index + B-tree `idx_parcel_state_county` on `(statefp, countyfp, geoid)` (created 2026-04-09, 5.5 min)
- **Confirmed drops**: `parcelstate` (0%), `lrversion` (uniform "2026.1"), `halfbaths` (0%), `fullbaths` (0%)
- **GPKG location**: `C:/GEODATA/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg` (Windows NVMe), WSL: `/mnt/c/GEODATA/...`
- **Environment**: pixi on WSL with GDAL 3.12.3 + Arrow/Parquet driver + DuckDB 1.5.1 CLI (Not specifically this any more, windows also now)
- **Tigris bucket**: existing buckets: `noclocks-parcels-parquet`, `noclocks-parcels-source`


### Completed work (2026-04-09)

- B-tree index created on GPKG (5.5 min on NVMe)
- County manifest (3,229 rows) and state rollup (55 rows) generated and saved to `data/meta/`
- Attribute profiling via DuckDB on GA parquet: identified 4 safe nationwide drops
- Geometry complexity profiling: median 8 vertices, p99 131, max 128K, 311 invalid (0.007%)
- GA FGB extracted: 4,754,448 features, 2.9 GB, 4 min
- NC FGB extracted: 5,756,891 features, 4.1 GB, 6 min
- Reusable extraction script: `scripts/gpkg_fgb_extraction.sh`

NOTE: below is AI generated planning, and is not 100% inline with actual thoughts for naming conventions or code design from my end, but shows how i want to leverage certain R packages to formalize the work done into functions, etc:

## Phase 0 -- Inventory and Metadata

The core investigatory phase. All functions operate via RSQLite/DBI in read-only mode (except index creation). Produces manifests that drive all downstream work. Split across `parcels_connect.R`, `parcels_audit.R`, `parcels_sample.R`, `parcels_manifest.R`, and `parcels_schema.R`.

### 0a. GPKG Connection + Pragma Tuning

Create a reusable connection helper in `R/parcels_connect.R` that:

- Opens the GPKG with `SQLITE_RO` flag
- Sets session pragmas: `cache_size = -4000000` (4GB), `temp_store = MEMORY`
- Omits `mmap_size` (no-op via WSL 9P to NTFS)
- Returns the connection with an `on.exit(dbDisconnect)` pattern for callers


### 0b. SQLite Internals Audit

Function: `parcels_audit_db(gpkg_path)` returning a list with:

- `db_objects` from `sqlite_master`
- B-tree indexes on `lr_parcel_us` (now includes `idx_parcel_state_county`)
- R-tree virtual tables (4)
- DB file stats: `page_count`, `page_size`, `db_size_gb`, `free_pages`
- Scalar pragmas: `journal_mode`, `wal_autocheckpoint`


### 0c. GPKG OGC Metadata

Function: `parcels_audit_gpkg(gpkg_path)` using `gpkg` package:

- `gpkg::gpkg_contents()` -- layer-level metadata
- `gpkg::gpkg_spatial_ref_sys()` -- CRS definitions
- `gpkg::gpkg_ogr_contents()` -- cached feature count (154,891,095)
- `gpkg::gpkg_validate()` -- OGC spec compliance
- `DBI::dbReadTable("gpkg_geometry_columns")` -- geom column metadata (since `gpkg_geometry_columns()` is not exported)
- `gdalraster::ogrinfo()` -- authoritative schema + CRS


### 0d. Attribute Sampling

Function: `parcels_sample_attrs(gpkg_path, n = 1000)` using `vapour::vapour_read_attributes()`:

- Verify `statefp` is zero-padded 2-char, `countyfp` is zero-padded 3-char
- Verify `geoid` = `statefp || countyfp`
- Confirm `parcelstate` NULL rate
- Confirm `lrversion` uniformity ("2026.1")


### 0e. B-tree Index Creation (one-time, RW) -- DONE

Function: `parcels_create_index(gpkg_path)`:

- Opens RW connection
- Creates `idx_parcel_state_county ON lr_parcel_us (statefp, countyfp, geoid)`
- Verifies via `EXPLAIN QUERY PLAN` that the GROUP BY uses `COVERING INDEX`
- Completed: 5.5 min on NVMe, ANALYZE run, query planner confirmed


### 0f. Manifest Generation -- DONE

Function: `parcels_build_manifest(gpkg_path)` returning two data frames:

- **County manifest** (`manifest_state_county.csv`): `state_fips`, `county_fips`, `geoid_county`, `feature_count`, `null_geom_count`, `min_lrid`, `max_lrid`
- **State rollup** (`manifest_state_rollup.csv`): `state_fips`, `county_count`, `feature_count`, `null_geom_count`, `pct_of_total`, `cumulative_pct`, `large_state` flag, `est_parquet_mb`
- Sanity checks passed: total = 154,891,095, all geoids valid, all fips codes properly padded


### 0g. Field-Level Statistics -- DONE (via DuckDB on GA parquet)

Profiled from existing GA parquet in 4 seconds:

- Identified 4 safe nationwide drops: `parcelstate`, `lrversion`, `halfbaths`, `fullbaths`
- Geometry: median 8 vertices, p99 131, max 128K, 311 invalid (0.007%)
- No blanket simplification warranted


### 0h. Schema Artifact

Function: `parcels_schema(gpkg_path)` producing `data/meta/schema.json`:

- Canonical field list with OGR types
- Drop list with reasons
- Partition key designation (`statefp`, `countyfp`)
- Version/provenance metadata


### 0i. Persist All Findings -- PARTIALLY DONE

Written to `data/meta/`:

- `manifest_state_county.csv` -- DONE
- `manifest_state_rollup.csv` -- DONE
- `field_stats.csv` -- pending (formal artifact)
- `schema.json` -- pending
- `findings.rds` -- pending


## Phase 1 -- GPKG to FlatGeoBuf Extraction

Per-state extraction from the monolithic GPKG into individual FGB files with cleaned schema and Hilbert-packed spatial index.

### 1a. VRT Configuration -- DONE

[data/sources/parcels.vrt](data/sources/parcels.vrt) updated with:

- `parcels-local-wsl` pointing to `/mnt/c/GEODATA/...` (NVMe)
- `parcels-local-windows` pointing to `C:/GEODATA/...`
- `parcels-cloud` pointing to `/vsis3/noclocks-parcels-source/...`
- Canonical `parcels` alias → `parcels-local-wsl`


### 1b. Extraction Function -- DONE (as shell script)

Script: `scripts/gpkg_fgb_extraction.sh` with:

- `-f FlatGeoBuf`, `-lco SPATIAL_INDEX=YES` (Hilbert R-tree)
- `-sql` for explicit column selection (drops 4 columns)
- `-spat` optional (B-tree index on statefp makes WHERE sufficient alone)
- Environment: `OGR_SQLITE_PRAGMA`, `OGR_GPKG_NUM_THREADS=ALL_CPUS`, `GDAL_CACHEMAX=2048`
- Output: `data/output/flatgeobuf/state={XX}/parcels.fgb`


### 1c. Validation -- DONE (manual, 2 states)

- GA: 4,754,448 features, 2.9 GB, 47 columns, schema verified
- NC: 5,756,891 features, 4.1 GB, feature count matches manifest exactly


### 1d. Column Selection SQL

Selects all fields except `parcelstate`, `lrversion`, `halfbaths`, `fullbaths`:

```sql
SELECT
  lrid, parcelid, parcelid2, geoid, statefp, countyfp,
  taxacctnum, taxyear, usecode, usedesc, zoningcode, zoningdesc,
  numbldgs, numunits, yearbuilt, numfloors, bldgsqft,
  bedrooms,
  imprvalue, landvalue, agvalue, totalvalue, assdacres,
  saleamt, saledate,
  ownername, owneraddr, ownercity, ownerstate, ownerzip,
  parceladdr, parcelcity, parcelzip,
  legaldesc, township, section, qtrsection, range,
  plssdesc, book, page, block, lot, updated,
  centroidx, centroidy, surfpointx, surfpointy,
  geom
FROM lr_parcel_us
WHERE statefp = '{state_fips}'
```


---

## R File Organization

The naming convention follows the `{prefix}_{concern}.R` module pattern established across your packages (e.g. `geo_config.R`, `db_connect.R`, `utils_checks.R`). Functions within each file share the file's prefix as their name prefix.

### Phase 0 + Phase 1 Files (populate now)

**`parcels_*` -- parcel-specific pipeline functions:**

- **[R/parcels_connect.R](R/parcels_connect.R)** -- GPKG connection helpers: `parcels_connect()` (RO + pragmas), `parcels_connect_rw()`, `parcels_disconnect()`
- **[R/parcels_audit.R](R/parcels_audit.R)** -- Investigatory/introspection: `parcels_audit_db()` (sqlite_master, indexes, file stats, pragmas), `parcels_audit_gpkg()` (OGC metadata via gpkg pkg), `parcels_audit_schema()` (ogrinfo field types + CRS)
- **[R/parcels_sample.R](R/parcels_sample.R)** -- Attribute sampling: `parcels_sample_attrs()` (vapour-based partition key + field verification)
- **[R/parcels_manifest.R](R/parcels_manifest.R)** -- Manifest generation: `parcels_create_index()`, `parcels_build_manifest()` (county + state rollup), `parcels_field_stats()`
- **[R/parcels_schema.R](R/parcels_schema.R)** -- Schema artifact: `parcels_schema()` (canonical field list, drop list, partition keys -> schema.json)
- **[R/parcels_extract.R](R/parcels_extract.R)** -- Phase 1 FGB extraction: `parcels_extract_fgb()` (ogr2ogr with column-select SQL + spatial pre-filter from manifest)
- **[R/parcels_validate.R](R/parcels_validate.R)** -- Post-extraction validation: `parcels_validate_fgb()` (schema check, feature count vs manifest)

**`gdal_*` -- generic GDAL utility wrappers (not parcel-specific):**

- **[R/gdal_config.R](R/gdal_config.R)** -- GDAL environment setup: `gdal_sqlite_pragmas()`, `gdal_set_env()`, `gdal_check_driver()`
- **[R/gdal_ogr.R](R/gdal_ogr.R)** -- Generic ogr2ogr wrapper: `gdal_ogr2ogr()` (builds + executes ogr2ogr via system2/processx), `gdal_ogrinfo()`

**`utils_*` -- cross-cutting utilities:**

- **[R/utils_checks.R](R/utils_checks.R)** -- Validation predicates: `check_file_exists()`, `check_gpkg()`, `check_fips()`, `check_manifest()`
- **[R/utils_fips.R](R/utils_fips.R)** -- FIPS reference data: `fips_states()`, `fips_state_name()`, `fips_state_bbox()` (lookups from bundled reference)

**Bookend files:**

- **[R/aaa.R](R/aaa.R)** -- Shared internal constants, default paths, column lists (e.g. `PARCELS_DROP_COLS`, `PARCELS_LAYER`, `PARCELS_SELECT_SQL`)
- **[R/zzz.R](R/zzz.R)** -- Initialization (source env setup, config loading if applicable)


### Deferred Files (remain empty stubs)

These correspond to later phases and other data sources. They keep their current names as placeholders:

- `gdal_gdalg.R`, `gdal_pipeline.R`, `gdal_vrt.R`, `gdal_vsi.R` -- GDALG specs, vector pipelines, VRT gen, VSI remote access
- `data_tiger.R`, `data_fema.R`, `data_meta.R` -- TIGER/FEMA/metadata source integrations
- `utils_cache.R`, `utils_remote.R` -- Caching, Tigris/S3 upload utilities


### Renamed / Removed Stubs

The current stubs that get replaced by the new naming:

- `data_parcels.R` -> split into `parcels_connect.R`, `parcels_audit.R`, `parcels_sample.R`, `parcels_manifest.R`, `parcels_schema.R`
- `data_fips.R` -> `utils_fips.R` (cross-cutting reference, not a data source)


### Function Naming Convention

All functions follow `{module}_{verb/noun}()`:

- `parcels_connect()`, `parcels_audit_db()`, `parcels_build_manifest()`, `parcels_extract_fgb()`
- `gdal_ogr2ogr()`, `gdal_sqlite_pragmas()`, `gdal_check_driver()`
- `check_gpkg()`, `check_fips()`, `fips_states()`

Internal helpers (not exported) use a dot prefix: `.parcels_default_path()`, `.parcels_select_sql()`.

---

## Key Decisions from the Architecture Discussion

- **FGB as intermediate**: 40-60% smaller than GPKG, Hilbert spatial index, universally readable, repeatable extraction target -- avoids re-reading 93GB GPKG for every downstream iteration
- **DuckDB + DBI only for Phase 2**: no arrow/sfarrow/geoarrow/dbplyr/duckplyr in pipeline code; those are for interactive analysis only
- **ogr2ogr pragmas**: drop `mmap_size` (no-op via 9P); keep `cache_size`, `temp_store`, `journal_mode=WAL`
- **ZSTD compression**: level 3 during development iteration, level 15 for final Tigris distribution artifacts
- **ROW_GROUP_SIZE**: 65536 default for county parquets; dynamic sizing from manifest for Phase 2 (`max(16384, floor(feature_count / 10))`)
- **Schema cleanup at FGB stage**: all downstream formats (Parquet) inherit the cleaned schema
- **`statefp` retained in data**: self-describing files even though it is the partition key
- **FGB stays local**: `SPATIAL_INDEX=YES` requires seekable output, incompatible with `/vsis3/`; upload to Tigris separately
- **Index creation**: worthwhile for manifest and ad-hoc queries despite not helping ogr2ogr
- **No bbox needed for extraction**: B-tree index on `statefp` makes `WHERE` clause efficient; `-spat` is optional optimization
- **Batch extraction**: ~4-6 min per state on NVMe, ~4-5 hours for all 55 state/territory codes

---

## Execution Order

1. ~~Phase 0: index + manifest + profiling~~ -- DONE
2. ~~Phase 1: GA + NC FGB extraction~~ -- DONE
3. Scaffold R file structure to match convention
4. Implement R functions wrapping the validated script patterns
5. Batch FGB extraction for remaining 53 states
6. Upload FGBs to Tigris (`noclocks-parcels` bucket)
7. Phase 2: FGB to county-partitioned Parquet via DuckDB (separate follow-up)

\#\#\#\#\#\#\#\#\#\#\#\#\#\#

response to comments:

Schema reduction is permanent at this stage — the dropped fields (parcelstate, lrversion, halfbaths, fullbaths) should be documented as intentional, not accidental omissions

> all 100% missing fields

The -spat bbox filter combined with WHERE statefp = '\${STATE_FIPS}' is redundant (the SQL filter is sufficient and more precise) but acts as a coarse pre-filter for the spatial index — harmless, and potentially beneficial for GPKG query planning

> confirmed increases performance during querying/gpkg scanning, kept in as even if it doesn't its still harmless + the attribute indexes were added after the fact

Consider storing the bounding boxes per state in a manifest JSON alongside the FGBs — this enables fast bbox-only queries without opening the files

> I have the per-state bboxes kept in my R code via tiger state boundaries -> bboxes as a simple reference table (also added WKT/FIPS, etc. just for referential purposes)
> Question: how would a JSON be tied to the hosted FGBs? is this something official or a standard similar to STAC or GeoParquet headers/bboxes?

***

NOTE: I have iterated with you in prior chats about geoparquet creation and EVERYTIME you recommend a different set of configurations, i no longer am following this advise as it has lead to multiple re-iterations during my exploratory/discovery phases and been quite frustrating, i am following advice directly from official docs at  [raw.githubusercontent.com/opengeospatial/geoparquet/refs/heads/main/format-specs/distributing-geoparquet.md](https://raw.githubusercontent.com/opengeospatial/geoparquet/refs/heads/main/format-specs/distributing-geoparquet.md)

using WKB encoding NOT GeoArrow (recommended previously which was wrong). Ensure SORT_BY_BBOX and WRITE_COVERING_BBOX. the only "dynamic" value is the ROW_GROUP_SIZE used for each state/county specific created parquet which should be pre-determined during analysis/metadata phases. compression level will be static and likely 15 for final resulting hosted parquets using ZSTD. no additional work regarding hilbert or geohash index done separately, already did this and it just added unecessary complexity to the process with zero value add. partitioning needs to use actual field names i.e. statefp=13/countyfp=001/parcels.parquet (unsure what you mean by "partitions must be balanced (no mixing file-at-root with folder-per-key")

interested in both duckdb (direct to blob storage via httpfs extension) and/or GDAL 3.12+ vector partition feature + GDALG algorithmic API declarative JSONs for going from state to county partitions.

***

MLT

work ive done so far experiementally with freestiler (has limitations with needing to be build with geoparquet or duckdb features enabled properly, so not perfect, but works):

```R
# uses freestile_query() with DuckDB streaming — the 1-2GB state parquet never enters R.
#
# exact DuckDB query:
#   SELECT * FROM read_parquet('<state_parquet>')
#
# zoom strategy for parcel polygons:
#   min_zoom = 12: first visible at neighbourhood/street level
#   max_zoom = 16: full polygon resolution at building scale
#   base_zoom = 16: guarantees all features at z16 (thinning reference)
#   no drop_rate: parcels are exhaustive coverage — dropping creates gaps
#
tile_state_pmtiles <- function(state_parquet_path, state_fips) {
  out_dir  <- file.path("data", "pmtiles", paste0("state=", state_fips))
  out_path <- file.path(out_dir, "parcels.pmtiles")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  sz_mb <- round(file.size(state_parquet_path) / 1e6)
  cli::cli_alert_info(
    "state={state_fips}: tiling {state_parquet_path} ({sz_mb} MB) -> {out_path}"
  )
  cli::cli_alert_info("  freestile_query: SELECT * FROM read_parquet('{state_parquet_path}')")
  cli::cli_alert_info("  format=MLT | zoom=12-16 | streaming=always")

  freestiler::freestile_query(
    query      = sprintf("SELECT * FROM read_parquet('%s')",
                         normalizePath(state_parquet_path, winslash = "/")),
    output     = out_path,
    layer_name = "parcels",
    tile_format = "mlt",
    min_zoom   = 10L,   # first visible at z10 with ~0.07% of features
    max_zoom   = 16L,
    base_zoom  = 16L,   # 100% of features at z16, halved per zoom below
    drop_rate  = 2.5,   # z15=29% z14=8% z13=2% z12=0.7% z10=0.07%
    source_crs = "EPSG:4326",
    streaming  = "always",
    overwrite  = TRUE
  )

  cli::cli_alert_success("state={state_fips}: {out_path} ({round(file.size(out_path)/1e6,1)} MB)")
  out_path
}

# uses freestile_query() — reads parquet via DuckDB SQL, never loads into R.
#
# freestile_file(engine="geoparquet") requires FREESTILER_GEOPARQUET=true at
# compile time, absent from the Windows r-universe binary. freestile_query()
# with read_parquet() works on all platforms via R's DuckDB package.
#
# exact DuckDB query:
#   SELECT * FROM read_parquet('<county_parquet_path>')
#
tile_county_pmtiles <- function(county_parquet_path) {
  parts       <- strsplit(normalizePath(county_parquet_path, winslash = "/"), "/")[[1L]]
  state_dir   <- parts[grep("^state=", parts)]
  cty_dir     <- parts[grep("^county=", parts)]
  county_fips <- sub("county=", "", cty_dir)

  out_dir  <- file.path("data", "pmtiles", state_dir, cty_dir)
  out_path <- file.path(out_dir, "parcels.pmtiles")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  src   <- normalizePath(county_parquet_path, winslash = "/")
  sz_mb <- round(file.size(src) / 1e6, 1)
  cli::cli_alert_info(
    "county={county_fips}: SELECT * FROM read_parquet('{src}') ({sz_mb} MB)"
  )

  freestiler::freestile_query(
    query      = sprintf("SELECT * FROM read_parquet('%s')", src),
    output     = out_path,
    layer_name = "parcels",
    tile_format = "mlt",
    min_zoom   = 12L,
    max_zoom   = 16L,
    base_zoom  = 16L,
    source_crs = "EPSG:4326",
    overwrite  = TRUE
  )

  cli::cli_alert_success(
    "county={county_fips}: {out_path} ({round(file.size(out_path)/1e6,1)} MB)"
  )
  out_path
}
```

script version:

```R
# generate_pmtiles.R
#
# generates MLT PMTiles from GeoParquet using freestiler (Rust-powered, in-process).
# freestiler outputs MLT by default — MapLibre Tiles columnar format, natively decoded
# by MapLibre GL JS v5.12+. pmtiles.io also supports MLT.
#
# freestile_file(engine="geoparquet") reads WKB parquet directly in Rust — no R memory.
# requires freestiler compiled with FREESTILER_GEOPARQUET=true.
# falls back to freestile_query() (R DuckDB) if geoparquet engine unavailable.
#
# THREE TILE ARTIFACTS (different zoom strategies per use case):
#
# 1. county PMTiles (z12-16, no drop_rate):
#    - full parcel coverage within one county
#    - no thinning — gaps are worse than density for exhaustive polygon data
#    - used for: embedded county maps, on-demand focused views
#    - file size: 5-100MB per county
#
# 2. state PMTiles (z10-16, drop_rate=2.5):
#    - z10-11: ~0.3-2% of features visible (indicates coverage, not for detail)
#    - z12-13: ~8-29% of features (neighbourhood browse)
#    - z14-16: 50-100% of features (full detail)
#    - used for: the main browsable parcel layer in a national map
#    - file size: 50-500MB per state
#
# 3. national overview (z0-10, TIGER boundaries — NOT parcel polygons):
#    - parcels are invisible below z10, so show county/state outlines instead
#    - used for: always-loaded base layer showing political coverage
#    - file size: ~5-20MB for all CONUS
#
# VIEWING: always use serve_tiles() + maplibre() with explicit zoom/center.
# view_tiles() opens at a zoom determined by the extent, which for counties and
# states is below min_zoom=12 where no tiles exist.
#
# county centers for navigation (from centroidx/centroidy columns in parquet):
#   Appling (001): lon=-82.32, lat=31.75
#   Fulton  (121): lon=-84.39, lat=33.77
#
# usage:
#   source("scripts/generate_pmtiles.R")
#   generate_county_pmtiles("13", "001")   # Appling County
#   generate_county_pmtiles("13", "121")   # Fulton County
#   generate_state_pmtiles("13")           # full Georgia (takes several minutes)
#   generate_all_county_pmtiles("13")      # all 159 GA counties in parallel

library(freestiler)

# ---- helpers ----------------------------------------------------------------

.state_parquet <- function(state) {
  sprintf("data/geoparquet/state=%s/parcels.parquet", state)
}

.county_parquet <- function(state, county) {
  sprintf("data/geoparquet/state=%s/county=%s/parcels.parquet", state, county)
}

.state_pmtiles <- function(state) {
  path <- sprintf("data/pmtiles/state=%s/parcels.pmtiles", state)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  path
}

.county_pmtiles <- function(state, county) {
  path <- sprintf("data/pmtiles/state=%s/county=%s/parcels.pmtiles", state, county)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  path
}

# ---- state-level PMTiles ----------------------------------------------------
# min_zoom=10: first visible at z10 with ~0.07% of features (proves data exists)
# max_zoom=16: full polygon resolution
# base_zoom=16: thinning reference — all features at z16, halved per zoom below
# drop_rate=2.5: z16=100% | z15=29% | z14=8% | z13=2% | z12=0.7% | z10=0.07%
#   rural counties stay dense at all zooms (low absolute count)
#   urban counties (Fulton: 372k) thin to ~260 features/tile at z10 — renderable
# streaming=always: required for 5M+ features
#
# exact DuckDB query: SELECT * FROM read_parquet('<state_parquet>')
#
generate_state_pmtiles <- function(state) {
  src  <- normalizePath(.state_parquet(state), winslash = "/")
  dest <- .state_pmtiles(state)

  if (!file.exists(src)) stop("state parquet not found: ", src)

  message("generating state=", state, " PMTiles -> ", dest)
  message("  source: ", src, " (", round(file.size(src) / 1e6), " MB)")
  message("  zoom: 10-16 | drop_rate: 2.5 | base_zoom: 16 | streaming")

  freestiler::freestile_query(
    query      = sprintf("SELECT * FROM read_parquet('%s')", src),
    output     = dest,
    layer_name = "parcels",
    tile_format = "mlt",
    min_zoom   = 10L,
    max_zoom   = 16L,
    base_zoom  = 16L,
    drop_rate  = 2.5,
    source_crs = "EPSG:4326",
    streaming  = "always",
    overwrite  = TRUE
  )

  message("  done: ", dest, " (", round(file.size(dest) / 1e6, 1), " MB)")
  invisible(dest)
}

# ---- county-level PMTiles ---------------------------------------------------
# uses freestile_file(engine="geoparquet") — Rust reads the WKB parquet directly,
# never loads into R memory or DuckDB. requires freestiler compiled with
# FREESTILER_GEOPARQUET=true. falls back to freestile_query() if unavailable.
#
generate_county_pmtiles <- function(state, county) {
  src  <- normalizePath(.county_parquet(state, county), winslash = "/")
  dest <- .county_pmtiles(state, county)

  if (!file.exists(src)) stop("county parquet not found: ", src)

  sz <- round(file.size(src) / 1e6, 1)
  message("  county=", county, ": ", src, " (", sz, " MB)")

  result <- tryCatch(
    {
      freestiler::freestile_file(
        input      = src,
        output     = dest,
        layer_name = "parcels",
        tile_format = "mlt",
        min_zoom   = 12L,
        max_zoom   = 16L,
        base_zoom  = 16L,
        engine     = "geoparquet",
        overwrite  = TRUE
      )
      "file"
    },
    error = function(e) {
      if (grepl("GeoParquet support not compiled", conditionMessage(e))) {
        message("    geoparquet engine unavailable, falling back to duckdb query")
        freestiler::freestile_query(
          query      = sprintf("SELECT * FROM read_parquet('%s')", src),
          output     = dest,
          layer_name = "parcels",
          tile_format = "mlt",
          min_zoom   = 12L,
          max_zoom   = 16L,
          base_zoom  = 16L,
          source_crs = "EPSG:4326",
          overwrite  = TRUE
        )
        "query"
      } else {
        stop(e)
      }
    }
  )

  message("    written: ", round(file.size(dest) / 1e6, 1), " MB (via ", result, ")")
  invisible(dest)
}

# ---- all counties in parallel -----------------------------------------------
generate_all_county_pmtiles <- function(state, workers = 4L) {
  county_dirs <- list.dirs(
    sprintf("data/geoparquet/state=%s", state),
    recursive = FALSE, full.names = FALSE
  )
  counties <- sub("county=", "", county_dirs[grepl("^county=", county_dirs)])

  message("generating PMTiles for ", length(counties), " counties (", workers, " workers)")

  parallel::mclapply(counties, function(ct) {
    tryCatch(
      generate_county_pmtiles(state, ct),
      error = function(e) message("  FAILED county=", ct, ": ", conditionMessage(e))
    )
  }, mc.cores = workers)

  invisible(NULL)
}

# ---- CLI entrypoint ---------------------------------------------------------
if (!interactive()) {
  args <- commandArgs(trailingOnly = TRUE)

  state        <- NULL
  county       <- NULL
  all_counties <- FALSE

  i <- 1L
  while (i <= length(args)) {
    if (args[i] == "--state")        { i <- i + 1L; state  <- args[i] }
    else if (args[i] == "--county")  { i <- i + 1L; county <- args[i] }
    else if (args[i] == "--all-counties") { all_counties <- TRUE }
    i <- i + 1L
  }

  if (is.null(state)) stop("--state <fips> is required")

  if (all_counties) {
    generate_all_county_pmtiles(state)
  } else if (!is.null(county)) {
    generate_county_pmtiles(state, county)
  } else {
    generate_state_pmtiles(state)
  }
}
```


***

What's your current thinking on the automation/orchestration layer for the per-state pipeline? Are you leaning toward simple shell/Make, something like a {targets} R pipeline, or a more formal workflow tool like Prefect/Dagster?

initially targets, dont like it for this use case. custom R orchestration via packages above is the ideal choice, but still in a more pwsh + shell phase currently

This is a meaty follow-up. Let me address each thread precisely.

***

## FGB Sidecar / Manifest JSON

There is **no official sidecar standard for FlatGeoBuf** — it's not like GeoParquet's file-level `geo` metadata key or STAC's item spec. What you have are three practical options in ascending formality:

**Option 1 — FGB header itself (already there, free)**
The FGB binary header (bytes 8+ after magic bytes) already embeds `xmin/ymin/xmax/ymax`, feature count, CRS as WKT, and the full schema. You can read it cheaply without scanning the data with `ogrinfo -so file.fgb parcels` or the `vapour` package. This is sufficient for internal tooling and your R bbox reference table approach is the right call for pipeline use.[^2_1]

**Option 2 — Custom sidecar `.fgb.json`**
A `parcels.fgb.json` alongside each `parcels.fgb` on Tigris is a practical convention (analogous to `.prj` alongside shapefiles) but entirely informal. A sensible schema:

```json
{
  "statefp": "13",
  "feature_count": 4754448,
  "file_size_bytes": 2900000000,
  "bbox": [-85.61, 30.36, -80.84, 35.00],
  "crs": "EPSG:4326",
  "schema_version": "2026.1",
  "columns_dropped": ["parcelstate","lrversion","halfbaths","fullbaths"],
  "extracted_at": "2026-04-09T..."
}
```

This is queryable without opening the FGB and pairs naturally with your existing manifest CSVs — the JSON is just the per-file serialized form of a manifest row.

**Option 3 — STAC catalog (proper, interoperable)**
STAC is the closest thing to an official standard for cataloging geospatial file assets.  A STAC Item is a GeoJSON Feature with `bbox`, `geometry` (state footprint), `assets` (links to `.fgb` and `.fgb.json` on Tigris), and `properties`. The R `{rstac}` package can both write and query STAC catalogs. This is the right long-term answer if you intend the FGBs to be discoverable/consumable by external tooling, but is overhead for a purely internal pipeline. I'd recommend starting with Option 2 (generate the JSON sidecar as part of your `parcels_validate_fgb()` function) and graduating to STAC when you have the parquets and PMTiles all landed and want a unified catalog across all artifact types.[^2_2]

***

## GeoParquet: DuckDB httpfs vs GDAL 3.12 Vector Partition

These are genuinely complementary, not competing, and the right answer is **GDAL for creation, DuckDB for upload and querying**. Here's why:

### GDAL 3.12 `gdal vector partition` (for creation)

This is the right tool for the FGB→GeoParquet step precisely because GDAL's Parquet driver writes the `geo` key in Parquet file metadata natively, making it a spec-compliant GeoParquet 1.1 file without any post-processing. The `SORT_BY_BBOX`, `WRITE_COVERING_BBOX`, and `WKB` encoding options are first-class driver creation options.[^2_3][^2_1]

The pipeline form:

```bash
gdal vector pipeline \
  read "data/output/flatgeobuf/state=13/parcels.fgb" \
  ! partition \
    --output "data/geoparquet/state=13" \
    --partition-field countyfp \
    --output-format Parquet \
    --lco COMPRESSION=ZSTD \
    --lco COMPRESSION_LEVEL=15 \
    --lco SORT_BY_BBOX=YES \
    --lco WRITE_COVERING_BBOX=YES \
    --lco ROW_GROUP_SIZE=65536
```

This produces `data/geoparquet/state=13/countyfp=001/parcels.parquet` — your exact target layout using actual field names. The `gdal vector partition` step is the last step in the pipeline and handles the Hive directory creation.[^2_3]

The **GDALG JSON** equivalent is the declarative form of the above — a `.gdalg.json` file you can version-control, store alongside your scripts, and execute via `gdal vector pipeline --gdalg pipeline.gdalg.json`. This is the natural artifact for your `gdal_pipeline.R` stub. The JSON structure mirrors the pipeline steps directly and becomes your per-state idempotent execution spec.

**One important note on `gdal vector partition` output naming**: by default GDAL names partition subdirectories using the field value directly (e.g. `countyfp=001`), which matches your desired layout. Verify with GDAL 3.12.3 that the output directory name uses zero-padded FIPS values — since `countyfp` is stored as a string field in the FGB (inherited from your GPKG schema), it should be zero-padded already.

### DuckDB httpfs (for upload + analytical querying)

DuckDB 1.5.1 with the `httpfs` extension has native R2 secret type support — cleaner than the old `SET s3_*` approach:[^2_4]

```sql
CREATE SECRET tigris_parcels (
  TYPE r2,
  KEY_ID 'YOUR_ACCESS_KEY',
  SECRET 'YOUR_SECRET_KEY',
  ACCOUNT_ID 'your-tigris-account-id'
);

-- Upload a finished county parquet to Tigris
COPY (SELECT * FROM read_parquet('data/geoparquet/state=13/countyfp=001/parcels.parquet'))
TO 'r2://noclocks-parcels-parquet/state=13/countyfp=001/parcels.parquet'
WITH (FORMAT PARQUET, COMPRESSION 'zstd', COMPRESSION_LEVEL 15);
```

For batch state uploads, the glob pattern works: `read_parquet('data/geoparquet/state=13/**/*.parquet', hive_partitioning=true)`. However, this round-trips through DuckDB's parquet writer which will not preserve the `geo` metadata key — so **always upload the GDAL-produced files directly** rather than re-encoding through DuckDB. Use DuckDB httpfs purely for reading from Tigris (analytical queries against the hosted parquets) and for the upload use the AWS CLI or Tigris CLI with `aws s3 cp --recursive` (Tigris is S3-compatible, the AWS CLI works against it out of the box with a custom `--endpoint-url`).

### The full Phase 2 flow:

```
FGB (local)
  → gdal vector partition (GDAL 3.12, GDALG spec)
  → county GeoParquets (local, proper GeoParquet 1.1)
  → aws s3 cp --recursive (Tigris endpoint)
  → r2://noclocks-parcels-parquet/state=XX/countyfp=YYY/parcels.parquet
  → DuckDB httpfs (analytical queries against hosted parquets)
```


***

## MLT / freestiler Code Review

The code is well-structured. A few targeted observations:

**`parallel::mclapply` won't parallelize on Windows.** It silently falls back to sequential execution via `lapply` on Windows (fork-based). Since you're on WSL part of the time, this works there, but for the Windows R session: swap to `{future}` + `{furrr}`:

```r
generate_all_county_pmtiles <- function(state, workers = 4L) {
  # ... county discovery same as before ...
  future::plan(future::multisession, workers = workers)
  furrr::future_map(counties, \(ct)
    tryCatch(generate_county_pmtiles(state, ct),
             error = \(e) cli::cli_alert_danger("FAILED county={ct}: {e$message}")),
    .options = furrr::furrr_options(seed = TRUE)
  )
  future::plan(future::sequential)
  invisible(NULL)
}
```

**`drop_rate` on county PMTiles** — you've correctly omitted it for `generate_county_pmtiles` (no thinning, exhaustive coverage). The state function's `drop_rate = 2.5` with `base_zoom = 16` is reasonable, but consider documenting the effective feature percentages per zoom as a named constant rather than inline comments — those numbers are what drive tile size decisions and should survive a refactor.

**`freestile_file(engine="geoparquet")` fallback pattern** is good defensive code. One addition: log which engine path was used to a persistent run log so you know which counties used the fallback across a batch run.

**`min_zoom = 10L` on state PMTiles** — at z10 the state-level tile covers ~100km², so parcel polygons are essentially invisible (sub-pixel). The value is purely "proves the data layer exists" for the renderer. That's fine, but make this intent explicit in the function docs. Some rendering clients will request tiles at all zooms between `min_zoom` and `max_zoom` when the map is at that level — at z10 with `drop_rate=2.5` and 5M features you're serving ~3,500 features per tile, which is renderable but worth profiling tile sizes for the large states (TX, CA).

***

## Orchestration: Custom R Approach

Given that `{targets}` didn't fit (it's optimized for reproducible analysis graphs, not file-production pipelines with external system calls and ~hours-long stages), the custom R approach is correct. The key design insight is that your pipeline is fundamentally a **file state machine** — the output file is the contract.

The minimal viable orchestration primitive:

```r
# R/pipeline_run.R

.run_stage <- function(output_path, fn, ..., force = FALSE, log_con = NULL) {
  if (file.exists(output_path) && !force) {
    cli::cli_alert_success("skip  {basename(output_path)}")
    return(invisible(output_path))
  }
  t0 <- proc.time()
  tryCatch({
    fn(...)
    elapsed <- round((proc.time() - t0)[["elapsed"]])
    sz <- file.size(output_path)
    cli::cli_alert_success("done  {basename(output_path)} ({sz/1e6:.1f} MB, {elapsed}s)")
    if (!is.null(log_con))
      .log_stage(log_con, output_path, "OK", elapsed, sz)
    invisible(output_path)
  }, error = function(e) {
    cli::cli_alert_danger("FAIL  {basename(output_path)}: {e$message}")
    if (!is.null(log_con))
      .log_stage(log_con, output_path, "FAIL", NA, NA)
    invisible(NULL)
  })
}
```

The run log is a DuckDB or SQLite table (`pipeline_log.duckdb`) with columns `(output_path, stage, status, duration_sec, file_size_bytes, run_at)`. This gives you free resumability (skip completed), audit trail, and the ability to query "which states failed and why" across runs.

For the **batch FGB extraction order**: run states ordered by `feature_count ASC` from your manifest — process the small territories (DC, VI, GU, etc. ~10k features) first to validate the full pipeline end-to-end before committing the 4-6 hour full batch. Your manifest has `large_state` flag — consider a two-pass approach: all non-large states in parallel (4 workers), then large states sequentially to avoid NVMe I/O contention.
<span style="display:none">[^2_10][^2_11][^2_12][^2_13][^2_14][^2_15][^2_16][^2_17][^2_18][^2_19][^2_20][^2_21][^2_22][^2_23][^2_24][^2_25][^2_26][^2_27][^2_28][^2_29][^2_30][^2_5][^2_6][^2_7][^2_8][^2_9]</span>

<div align="center">⁂</div>

[^2_1]: https://gdal.org/en/stable/programs/gdal_vector_pipeline.html

[^2_2]: https://stacspec.org/en/about/stac-spec/

[^2_3]: https://gdal.org/en/stable/programs/gdal_vector_partition.html

[^2_4]: https://duckdb.org/docs/current/guides/network_cloud_storage/cloudflare_r2_import.html

[^2_5]: https://www.domo.com/learn/article/best-data-orchestration-platforms

[^2_6]: https://www.ovaledge.com/blog/data-orchestration-tools

[^2_7]: https://dagster.io/learn/data-pipeline-orchestration-tools

[^2_8]: https://www.reddit.com/r/dataengineering/comments/1c8z1qh/what_tools_do_you_use_to_orchestrate_pipelines/

[^2_9]: https://www.alation.com/blog/data-orchestration-tools/

[^2_10]: https://dagster.io/vs/dagster-vs-prefect

[^2_11]: https://www.fivetran.com/learn/best-data-pipeline-tools

[^2_12]: https://www.decube.io/post/dagster-prefect-compare

[^2_13]: https://www.larksuite.com/en_us/blog/workflow-orchestration-tools

[^2_14]: https://hoop.dev/blog/dagster-prefect-vs-similar-tools-which-fits-your-stack-best

[^2_15]: https://www.matillion.com/learn/blog/data-orchestration-tools

[^2_16]: https://www.youtube.com/watch?v=Nj0rlVbpsz0

[^2_17]: https://www.reddit.com/r/dataengineering/comments/1le9ltm/airflow_vs_prefect_vs_dagster_which_one_do_you/

[^2_18]: https://datavidhya.com/blog/airflow-vs-dagster-vs-prefect/

[^2_19]: https://ukdataservices.co.uk/blog/articles/python-data-pipeline-tools-2025

[^2_20]: https://gdal.org/en/stable/drivers/vector/parquet.html

[^2_21]: https://gdal.org/gdal.pdf

[^2_22]: https://github.com/opengeospatial/geoparquet/discussions/171

[^2_23]: https://help.iconik.backlight.co/hc/en-us/articles/25027403438871-Sidecar-metadata

[^2_24]: https://www.linkedin.com/posts/gdalorg_zarr-activity-7393689622674935808-kf2u

[^2_25]: https://github.com/duckdb/duckdb/issues/5685

[^2_26]: https://blog.rtwilson.com/how-to-get-geoparquet-support-in-gdal-ogr-from-conda-forge/

[^2_27]: https://observablehq.com/@kimmolinna/duckdb-parquet-and-cloudflare-r2

[^2_28]: https://github.com/radiantearth/stac-api-spec/blob/release/v1.0.0/stac-spec/item-spec/item-spec.md

[^2_29]: https://manpages.opensuse.org/Tumbleweed/gdal/gdal-vector-partition.1

[^2_30]: https://duckdb.org/docs/current/core_extensions/httpfs/s3api.html


---

# for the FGB to parquet steps, does this have to be done completely local before uploading to storage? if I instead used bbox based queries against the FGBs or state parquets (assuming state parquets did the local > upload approach for some initial states, etc.) to create the parquet partitioned county level parquets instead of the GDAL partition feature? or is there a limitation due to the SORT_BY_BBOX stuff? could leverage /vsicurl for FGBs if that's better for them than /vsis3 but not sure (i was under the impression FGB was essentially just like a vector version of COGs for rasters in this regard, whereas geoparquet is even more tuned to cloud native due to columnar/arrow based foundation, etc.) - there's also various other things not mentioned yet like GDAL's materialize sub-command, /vsicache or /vsimem and similar, or leveraging GDAL to read from a remote, cache locally, and in turn write/stream back to blob storage with minimal local use throughout. then there's the duckdb approach also.

This is the crux of the whole pipeline design — let me give you a precise breakdown of what's actually constrained and what's flexible.

## The SORT_BY_BBOX Constraint (It's Not What You Think)

SORT_BY_BBOX is a **two-pass sort, not a streaming write** — GDAL reads all features, computes their bbox sort order (Hilbert curve on bbox centroid), then writes them in sorted sequence.  The critical insight is that this constrains the **sort pass** (needs to buffer all features), not the **output destination**. GDAL's Parquet driver explicitly supports VirtualIO — the docs state it supports `/vsimem/` and other VSI paths as output targets.  So you **can** write directly to `/vsis3/` with `SORT_BY_BBOX=YES` as long as the sort fits in GDAL's internal temp space, which at county scale (5–100MB output → ~50–300MB in-memory working set) is entirely feasible.[^3_1]

## FGB as COG Analog — Your Intuition is Correct (with nuance)

The analogy holds well for reads:

- FGB's Hilbert-packed spatial index enables HTTP range requests to fetch only the byte ranges covering a bbox — GDAL's `/vsicurl/` uses exactly this[^3_2]
- COG has multi-resolution overviews (pyramid) baked in; FGB is single-resolution but spatially indexed — FGB is "narrower" in what it offers
- GeoParquet is **analytics-native** (columnar scan, predicate pushdown via `bbox` struct row-group statistics) more than **streaming-native** — it requires a Parquet-aware client, not plain HTTP, whereas FGB/COG work with any HTTP range-request client[^3_3]

For your pipeline, the practical implication is: FGB on Tigris via `/vsicurl/` is a legitimate first-class read source for county-level filtered extraction.

## The Full Spectrum of Approaches

### Pattern A: `/vsicurl/` FGB → `/vsis3/` Parquet (no local disk, GDAL-native)

The cleanest path if FGBs are already on Tigris:

```bash
# AWS_* env vars set for Tigris endpoint
ogr2ogr \
  -f Parquet \
  -lco SORT_BY_BBOX=YES \
  -lco WRITE_COVERING_BBOX=YES \
  -lco COMPRESSION=ZSTD \
  -lco COMPRESSION_LEVEL=15 \
  -lco ROW_GROUP_SIZE=65536 \
  -sql "SELECT * FROM parcels WHERE countyfp = '001'" \
  "/vsis3/noclocks-parcels-parquet/state=13/countyfp=001/parcels.parquet" \
  "/vsicurl/https://fly.storage.tigris.dev/noclocks-parcels-source/state=13/parcels.fgb"
```

GDAL's spatial extension means the FGB bbox filter (`-spat` or the WHERE clause) fires against the Hilbert index — only the county's byte ranges are fetched from Tigris. The sort buffers in GDAL's internal memory. No local disk needed at all. The output is spec-compliant GeoParquet (GDAL writes the `geo` metadata key correctly).

### Pattern B: `/vsimem/` as a Zero-Disk Temp Layer

For multi-step pipelines where you need an intermediate result without touching local disk, `/vsimem/` is GDAL's in-memory filesystem — a named byte buffer with the full VSI interface:

```bash
# Step 1: county FGB slice → /vsimem/
ogr2ogr \
  -f FlatGeoBuf \
  -spat -85.0 30.5 -81.0 35.0 \
  -sql "SELECT * FROM parcels WHERE countyfp = '001'" \
  "/vsimem/county_001.fgb" \
  "/vsicurl/https://fly.storage.tigris.dev/.../state=13/parcels.fgb"

# Step 2: /vsimem/ → sorted Parquet on S3
ogr2ogr \
  -f Parquet \
  -lco SORT_BY_BBOX=YES -lco WRITE_COVERING_BBOX=YES \
  "/vsis3/noclocks-parcels-parquet/state=13/countyfp=001/parcels.parquet" \
  "/vsimem/county_001.fgb"
```

Realistic for counties up to ~500MB uncompressed. For large urban counties (Fulton, Maricopa, LA), you'd hit memory limits — those are the cases to watch.

### Pattern C: State GeoParquet (Tigris) → County GeoParquet (Tigris) via GDAL Arrow Dataset

If you do the first pass as state-level GeoParquets (upload state parquets first, county partitioning second), GDAL 3.10+ has optimized spatial and attribute filtering for Arrow datasets with the `bbox` covering struct:

```bash
# GDAL reads from /vsis3/ state parquet, filters by countyfp, 
# bbox struct row-group pruning fires before fetching geometry column
ogr2ogr \
  -f Parquet \
  -lco SORT_BY_BBOX=YES -lco WRITE_COVERING_BBOX=YES \
  -where "countyfp = '001'" \
  "/vsis3/noclocks-parcels-parquet/state=13/countyfp=001/parcels.parquet" \
  "PARQUET:/vsis3/noclocks-parcels-parquet/state=13/parcels.parquet"
```

The `PARQUET:` prefix forces the Arrow dataset driver, which is what gives you column statistics filtering.  This is **true cloud-to-cloud** with zero local footprint and is probably the most elegant final-state design.[^3_1]

### Pattern D: DuckDB Cloud-to-Cloud (with GeoParquet caveat)

DuckDB 1.5.1 can read from and write to Tigris via the R2 secret.  However, DuckDB's `COPY TO ... FORMAT PARQUET` does not write the `geo` Parquet file metadata key — it reads and passes through existing `geo` metadata but does not generate it from scratch.  This means DuckDB-produced parquets are not spec-compliant GeoParquet unless you manually inject the `geo` key via `KV_METADATA` (which requires you to construct the exact JSON string matching the GeoParquet spec, including `geometry_types` and `crs` — fragile).[^3_4][^3_5][^3_6]

**DuckDB's role here is analytics and validation, not production writes.**

## `/vsicache/` and `materialize`

These serve distinct roles:


| Mechanism | What it does | When to use |
| :-- | :-- | :-- |
| `/vsicache/` | Transparent local byte-range cache over any remote VSI path | Multi-pass reads of the same FGB (e.g., processing all counties of one state sequentially — cache warms after first county) |
| `gdal vector materialize` | Downloads remote dataset to a local format | When you want a local scratch copy of one state's FGB before processing all its counties, then delete after |
| `/vsimem/` | In-process memory filesystem | Single-pass intermediate results for county-scale work |
| `gdal vsi sync` | rsync-equivalent across VSI filesystems | Batch uploading finished local parquets to Tigris; supports ETag-based skip-if-unchanged [^3_7] |

For `/vsicache/`, set it explicitly when reading FGBs to avoid redundant range requests across county iterations within a state:

```bash
export VSI_CACHE=YES
export VSI_CACHE_SIZE=536870912  # 512MB byte-range cache
```


## Recommended Pipeline Architecture

Given all of this, the optimal approach for your use case:

```
FGBs (Tigris /vsis3/)
  ↓  [county bbox filter via /vsicurl/ + Hilbert index]
  ↓  [SORT_BY_BBOX in GDAL internal memory]
  ↓  [GDAL Parquet driver writes geo metadata correctly]
County GeoParquets (Tigris /vsis3/)
```

The local NVMe never enters the picture for Phase 2 once FGBs are on Tigris. You can process counties in parallel across states, with `/vsicache/` warming the FGB byte-range cache per state. The only local resource consumed is RAM (for GDAL's in-memory sort buffer per county, roughly 2–5× the county parquet output size).

The local → upload pattern stays relevant only for the **FGB upload step itself** (FGBs require seekable output for `SPATIAL_INDEX=YES`, incompatible with `/vsis3/` writes as you noted). Once FGBs are on Tigris, all downstream Parquet work can be cloud-native end-to-end.
<span style="display:none">[^3_10][^3_11][^3_12][^3_13][^3_14][^3_15][^3_16][^3_17][^3_18][^3_19][^3_20][^3_21][^3_22][^3_23][^3_24][^3_25][^3_26][^3_27][^3_28][^3_29][^3_8][^3_9]</span>

<div align="center">⁂</div>

[^3_1]: https://gdal.org/en/stable/drivers/vector/parquet.html

[^3_2]: https://www.linkedin.com/pulse/flatgeobuf-vs-geoparquet-apache-iceberg-ogc-cloud-ingo-simonis-v0aue

[^3_3]: https://www.postholer.com/articles/Parquet-Is-Not-A-Cloud-Native-Format

[^3_4]: https://github.com/duckdb/duckdb-spatial/issues/423

[^3_5]: https://duckdb.org/docs/current/data/parquet/overview.html

[^3_6]: https://duckdb.org/docs/current/guides/network_cloud_storage/cloudflare_r2_import.html

[^3_7]: https://gdal.org/en/stable/programs/gdal_vsi_sync.html

[^3_8]: https://guide.cloudnativegeo.org/geoparquet/geoparquet-example.html

[^3_9]: https://jeffgillan.github.io/cloud-native-geospatial/flatgeobuf/

[^3_10]: https://streamnative.io/data-streaming-summit/recordings/dss-virtual-2025-avro-arrow-protobuf-parquet-and-why

[^3_11]: https://fme.safe.com/blog/2026/01/how-to-migrate-to-geoparquet-without-disrupting-existing-gis-workflows/

[^3_12]: https://cu-esiil.github.io/forest-carbon-codefest/data-library/mounting-via-vsi/

[^3_13]: https://cran.r-project.org/web/packages/duckspatial/duckspatial.pdf

[^3_14]: https://dlab.berkeley.edu/news/brief-introduction-cloud-native-approaches-big-data-analysis

[^3_15]: https://gdal.org/en/stable/user/virtual_file_systems.html

[^3_16]: https://github.com/duckdb/duckdb-spatial/discussions/396

[^3_17]: https://github.com/bertt/cloudnative_geospatial_workshop

[^3_18]: https://lists.osgeo.org/pipermail/gdal-dev/2018-December/049507.html

[^3_19]: https://dewey.dunnington.ca/post/2024/wrangling-and-joining-130m-points-with-duckdb--the-open-source-spatial-stack/

[^3_20]: https://stackoverflow.com/questions/78663272/i-have-a-problem-when-using-gdals-vsimem-feature

[^3_21]: https://github.com/OSGeo/gdal/issues/5670

[^3_22]: https://lists.osgeo.org/pipermail/gdal-dev/2016-August/045030.html

[^3_23]: https://gdal.org/en/stable/user/configoptions.html

[^3_24]: https://gdal.org/gdal.pdf

[^3_25]: https://docs.geotools.org/latest/userguide/unsupported/geoparquet.html

[^3_26]: https://api.qgis.org/api/qgsvectorfilewriter_8cpp_source.html

[^3_27]: https://github.com/OSGeo/gdal/issues/4158

[^3_28]: https://gdal.org/en/stable/tutorials/vector_geoparquet_tut.html

[^3_29]: https://gdal.org/en/stable/programs/gdal_vsi_list.html


---

# the GDAL partitioning feature is just sooo flashy and tempting lol - great feedback though, there's a lot of options, and glad you clarified the duckdb limitations as previous sessions did the opposite and told me to lean towards duckdb over GDAL...

the current state of the data right now is minimal but worth noting to guide future direction:

- local gpkg still in C and still the primary bottleneck regarding the full national scale data work
- have performed GA and NC FGB creations and have these saved locally also (from prior work / docs / plan i provided) - should not be an issue incrementally continuing to create these state by state over time and upload / rclone to tigris (need to decide if deserve separate bucket or not though)
- additionally (i decided the whole FGB more recently), have performed GA and NC statewide geoparquet creation that was done against the gpkg directly (not FGBs, but doesnt matter in this regard) and in turn have gone ahead and uploaded them to tigris bucket partitioned by statefp, i.e. tigris:noclocks-parcels-parquet/statefp={13,37}/parcels.parquet (each 1-2GB) and tested /vsis3 ogrinfo against them and works. they are also still local as well. see below for verification against them also.
- side note but i also have uploaded some of the previously created pmtiles to tigris as well, a couple AOI ones (greater atlanta area, fulton county, and full GA state - which was beautiful i must say to see on a map)

geoparquet verifications performed as a initial test of their "best practices"/validity:

```pwsh
➜ gpq validate data/output/geoparquet/statefp=13/parcels.parquet
Summary: Passed 20 checks.

 ✓ file must include a "geo" metadata key
 ✓ metadata must be a JSON object
 ✓ metadata must include a "version" string
 ✓ metadata must include a "primary_column" string
 ✓ metadata must include a "columns" object
 ✓ column metadata must include the "primary_column" name
 ✓ column metadata must include a valid "encoding" string
 ✓ column metadata must include a "geometry_types" list
 ✓ optional "crs" must be null or a PROJJSON object
 ✓ optional "orientation" must be a valid string
 ✓ optional "edges" must be a valid string
 ✓ optional "bbox" must be an array of 4 or 6 numbers
 ✓ optional "epoch" must be a number
 ✓ geometry columns must not be grouped
 ✓ geometry columns must be stored using the BYTE_ARRAY parquet type
 ✓ geometry columns must be required or optional, not repeated
 ✓ all geometry values match the "encoding" metadata
 ✓ all geometry types must be included in the "geometry_types" metadata (if not empty)
 ✓ all polygon geometries must follow the "orientation" metadata (if present)
 ✓ all geometries must fall within the "bbox" metadata (if present)

➜ gpq validate data/output/geoparquet/statefp=37/parcels.parquet
Summary: Passed 20 checks.

 ✓ file must include a "geo" metadata key
 ✓ metadata must be a JSON object
 ✓ metadata must include a "version" string
 ✓ metadata must include a "primary_column" string
 ✓ metadata must include a "columns" object
 ✓ column metadata must include the "primary_column" name
 ✓ column metadata must include a valid "encoding" string
 ✓ column metadata must include a "geometry_types" list
 ✓ optional "crs" must be null or a PROJJSON object
 ✓ optional "orientation" must be a valid string
 ✓ optional "edges" must be a valid string
 ✓ optional "bbox" must be an array of 4 or 6 numbers
 ✓ optional "epoch" must be a number
 ✓ geometry columns must not be grouped
 ✓ geometry columns must be stored using the BYTE_ARRAY parquet type
 ✓ geometry columns must be required or optional, not repeated
 ✓ all geometry values match the "encoding" metadata
 ✓ all geometry types must be included in the "geometry_types" metadata (if not empty)
 ✓ all polygon geometries must follow the "orientation" metadata (if present)
 ✓ all geometries must fall within the "bbox" metadata (if present)

➜ ogrinfo data/output/geoparquet/statefp=37/parcels.parquet parcels -limit 1
INFO: Open of `data/output/geoparquet/statefp=37/parcels.parquet'
      using driver `Parquet' successful.

Layer name: parcels
Geometry: Multi Polygon
Feature Count: 5756891
Extent: (-84.321810, 33.841582) - (-75.461054, 36.588486)
Layer SRS WKT:
GEOGCRS["WGS 84",
    ENSEMBLE["World Geodetic System 1984 ensemble",
        MEMBER["World Geodetic System 1984 (Transit)"],
        MEMBER["World Geodetic System 1984 (G730)"],
        MEMBER["World Geodetic System 1984 (G873)"],
        MEMBER["World Geodetic System 1984 (G1150)"],
        MEMBER["World Geodetic System 1984 (G1674)"],
        MEMBER["World Geodetic System 1984 (G1762)"],
        MEMBER["World Geodetic System 1984 (G2139)"],
        MEMBER["World Geodetic System 1984 (G2296)"],
        ELLIPSOID["WGS 84",6378137,298.257223563,
            LENGTHUNIT["metre",1]],
        ENSEMBLEACCURACY[2.0]],
    PRIMEM["Greenwich",0,
        ANGLEUNIT["degree",0.0174532925199433]],
    CS[ellipsoidal,2],
        AXIS["geodetic latitude (Lat)",north,
            ORDER[1],
            ANGLEUNIT["degree",0.0174532925199433]],
        AXIS["geodetic longitude (Lon)",east,
            ORDER[2],
            ANGLEUNIT["degree",0.0174532925199433]],
    USAGE[
        SCOPE["Horizontal component of 3D system."],
        AREA["World."],
        BBOX[-90,-180,90,180]],
    ID["EPSG",4326]]
Data axis to CRS axis mapping: 2,1
FID Column = lrid
Geometry Column = geometry
parcelid: String (0.0)
parcelid2: String (0.0)
geoid: String (0.0)
statefp: String (0.0)
countyfp: String (0.0)
taxacctnum: String (0.0)
taxyear: Integer (0.0)
usecode: String (0.0)
usedesc: String (0.0)
zoningcode: String (0.0)
zoningdesc: String (0.0)
numbldgs: Integer (0.0)
numunits: Integer (0.0)
yearbuilt: Integer (0.0)
numfloors: Integer (0.0)
bldgsqft: Integer (0.0)
bedrooms: Integer (0.0)
halfbaths: Integer (0.0)
fullbaths: Integer (0.0)
imprvalue: Integer64 (0.0)
landvalue: Integer64 (0.0)
agvalue: Integer64 (0.0)
totalvalue: Integer64 (0.0)
assdacres: Real (0.0)
saleamt: Integer64 (0.0)
saledate: Date
ownername: String (0.0)
owneraddr: String (0.0)
ownercity: String (0.0)
ownerstate: String (0.0)
ownerzip: String (0.0)
parceladdr: String (0.0)
parcelcity: String (0.0)
parcelstate: String (0.0)
parcelzip: String (0.0)
legaldesc: String (0.0)
township: String (0.0)
section: String (0.0)
qtrsection: String (0.0)
range: String (0.0)
plssdesc: String (0.0)
book: String (0.0)
page: String (0.0)
block: String (0.0)
lot: String (0.0)
updated: String (0.0)
lrversion: String (0.0)
centroidx: Real (0.0)
centroidy: Real (0.0)
surfpointx: Real (0.0)
surfpointy: Real (0.0)
OGRFeature(parcels):111301493
  parcelid (String) = 7940578469
  parcelid2 (String) = 7940578469
  geoid (String) = 37081
  statefp (String) = 37
  countyfp (String) = 081
  taxacctnum (String) = 100603330078100002
  taxyear (Integer) = 2011
  usecode (String) = (null)
  usedesc (String) = RESIDENTIAL
  zoningcode (String) = AG-Agricultural
  zoningdesc (String) = (null)
  numbldgs (Integer) = (null)
  numunits (Integer) = (null)
  yearbuilt (Integer) = (null)
  numfloors (Integer) = (null)
  bldgsqft (Integer) = (null)
  bedrooms (Integer) = (null)
  halfbaths (Integer) = (null)
  fullbaths (Integer) = (null)
  imprvalue (Integer64) = 0
  landvalue (Integer64) = 96400
  agvalue (Integer64) = 96400
  totalvalue (Integer64) = 96400
  assdacres (Real) = (null)
  saleamt (Integer64) = 383500
  saledate (Date) = 1997/07/10
  ownername (String) = KOTIS, WILLIAM M III;KOTIS, ASHELEY D
  owneraddr (String) = (null)
  ownercity (String) = (null)
  ownerstate (String) = (null)
  ownerzip (String) = (null)
  parceladdr (String) = 3214 STILLWELL RD SUMMERFIELD NC 27358
  parcelcity (String) = (null)
  parcelstate (String) = (null)
  parcelzip (String) = (null)
  legaldesc (String) = 2.40AC ALCON
  township (String) = (null)
  section (String) = (null)
  qtrsection (String) = (null)
  range (String) = (null)
  plssdesc (String) = (null)
  book (String) = 004560
  page (String) = 01964
  block (String) = 57
  lot (String) = (null)
  updated (String) = 2025-11-20
  lrversion (String) = 2026.1
  centroidx (Real) = -79.8618808342371
  centroidy (Real) = 36.2402510727265
  surfpointx (Real) = -79.8621690389014
  surfpointy (Real) = 36.239663301082
  MULTIPOLYGON (((-79.8623632 36.239252,-79.8616214 36.2400746,-79.8609744 36.2407771,-79.862301 36.2407204,-79.8623632 36.239252))
```


***

so given where files are at atm what would you recommend?

Before making any recommendations, there's a critical issue to flag from the `ogrinfo` output you shared.

## ⚠️ Current State Parquets Need Regeneration

The NC parquet (and almost certainly GA) still contains all four supposedly-dropped columns:

```
halfbaths: Integer (0.0)
fullbaths: Integer (0.0)
parcelstate: String (0.0)
lrversion: String (0.0)
```

These parquets were created directly against the GPKG (before the schema drops were confirmed via FGB work), so the clean schema never made it in. Additionally, and more critically for cloud-native query performance, there is **no `geometry_bbox` struct column** in the schema — meaning `WRITE_COVERING_BBOX` was not applied.  Without the covering bbox struct, row-group skipping via column statistics is disabled, which eliminates the primary cloud-native read optimization for `/vsis3/` queries. `SORT_BY_BBOX` also wasn't applied for the same reason. These parquets pass `gpq validate` because spec compliance is about geometry encoding and metadata keys — not whether the optional-but-critical performance features are present.[^4_1][^4_2]

**The good news**: you have local FGBs for both GA and NC with the correct schema already. Regeneration is fast (~5–10 min each from local NVMe FGB).

***

## Concrete Recommendation Given Current State

### Step 1 — Regenerate State Parquets from Local FGBs (do today)

```bash
# GA — ~5 min from local FGB
ogr2ogr \
  -f Parquet \
  -lco SORT_BY_BBOX=YES \
  -lco WRITE_COVERING_BBOX=YES \
  -lco COMPRESSION=ZSTD \
  -lco COMPRESSION_LEVEL=15 \
  -lco ROW_GROUP_SIZE=65536 \
  -nln parcels \
  "data/output/geoparquet/statefp=13/parcels.parquet" \
  "data/output/flatgeobuf/state=13/parcels.fgb"

# NC — ~6 min
ogr2ogr \
  -f Parquet \
  -lco SORT_BY_BBOX=YES \
  -lco WRITE_COVERING_BBOX=YES \
  -lco COMPRESSION=ZSTD \
  -lco COMPRESSION_LEVEL=15 \
  -lco ROW_GROUP_SIZE=65536 \
  -nln parcels \
  "data/output/geoparquet/statefp=37/parcels.parquet" \
  "data/output/flatgeobuf/state=37/parcels.fgb"
```

After regeneration, verify the bbox struct column appears:

```bash
ogrinfo data/output/geoparquet/statefp=13/parcels.parquet parcels -limit 0
# should show: geometry_bbox: ArrowStruct (0.0) -> xmin, ymin, xmax, ymax subfields
```

Then overwrite on Tigris via `aws s3 cp` with `--endpoint-url https://fly.storage.tigris.dev`.

### Step 2 — County Partition from Local FGBs (this is where `gdal vector partition` shines)

Now you have the local FGBs, this is the exact use case for it:

```bash
# Creates: data/output/geoparquet/statefp=13/countyfp=001/parcels.parquet, etc.
gdal vector pipeline \
  read "data/output/flatgeobuf/state=13/parcels.fgb" \
  ! partition \
    --output "data/output/geoparquet/statefp=13" \
    --partition-field countyfp \
    --output-format Parquet \
    --lco SORT_BY_BBOX=YES \
    --lco WRITE_COVERING_BBOX=YES \
    --lco COMPRESSION=ZSTD \
    --lco COMPRESSION_LEVEL=15 \
    --lco ROW_GROUP_SIZE=65536
```

GDAL's `partition` step creates `countyfp=XXX/` subdirectories matching your `statefp=13/countyfp=001/parcels.parquet` target layout exactly, using zero-padded string values since the field is `String` type in the FGB.  The dynamic `ROW_GROUP_SIZE` per county from your manifest can be injected here via a wrapper script. One important note from the GDAL source: for `SORT_BY_BBOX` at partition time, each partition's sort runs independently in memory — so even large-state, large-county combinations (Fulton, Harris TX, LA County) sort only their county slice, not the whole state.[^4_3][^4_4]

### Step 3 — Bucket Strategy for FGBs

Put FGBs in `noclocks-parcels-source` under a `flatgeobuf/` prefix, not a separate bucket. They are source-tier (cleaned intermediate), not derived product tier, and co-locating them with the GPKG reference keeps the "everything before Parquet" in one place:

```
noclocks-parcels-source/
  LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg   ← if/when migrated
  flatgeobuf/
    statefp=13/parcels.fgb
    statefp=37/parcels.fgb
    ...
```

This also gives you the clean VSI path pattern: `/vsis3/noclocks-parcels-source/flatgeobuf/statefp=13/parcels.fgb` — consistent with the parquet path convention.

***

## The Longer Path Forward

Once you have corrected state parquets and county parquets for GA and NC on Tigris, the remaining 53 states can follow this purely cloud-native loop — **no local disk involved after FGB upload**:

```
GPKG (local NVMe)
  → ogr2ogr FGB extraction (local, ~4-6 min/state)
  → rclone/aws s3 cp to noclocks-parcels-source/flatgeobuf/
  → gdal vector partition via /vsicurl/ → /vsis3/ county GeoParquets
  → gdal vsi sync for any missed/failed partitions
```

The `/vsicurl/` → `/vsis3/` county partition loop from previous discussion is the endgame — but only worth enabling once the FGBs are actually on Tigris. For the two states you have locally right now, local processing is faster and simpler. Run the remaining ~53 states' FGB extractions incrementally from the GPKG (your existing script handles this), upload each as it finishes, and the county partition step can trail behind it on Tigris without ever touching local disk again.
<span style="display:none">[^4_10][^4_11][^4_12][^4_13][^4_14][^4_15][^4_5][^4_6][^4_7][^4_8][^4_9]</span>

<div align="center">⁂</div>

[^4_1]: https://gdal.org/en/stable/drivers/vector/parquet.html

[^4_2]: https://lists.osgeo.org/pipermail/gdal-dev/2024-March/058740.html

[^4_3]: https://gdal.org/en/stable/programs/gdal_vector_partition.html

[^4_4]: https://github.com/osgeo/gdal/issues/13584

[^4_5]: https://github.com/duckdb/duckdb-spatial/discussions/650

[^4_6]: https://lists.osgeo.org/pipermail/gdal-dev/2026-January/061329.html

[^4_7]: https://gdal.org/en/stable/doxygen/functions_func_~.html

[^4_8]: https://stackoverflow.com/questions/60227123/read-write-parquet-with-struct-column-type

[^4_9]: https://github.com/planetlabs/gpq/issues/102

[^4_10]: https://geoparquet.org/releases/v1.0.0-beta.1/

[^4_11]: https://gdal.org/en/stable/programs/gdal_vector_check_coverage.html

[^4_12]: https://gdal.org/en/stable/tutorials/vector_geoparquet_tut.html

[^4_13]: https://guide.cloudnativegeo.org/geoparquet/

[^4_14]: https://github.com/opengeospatial/geoparquet/discussions/101

[^4_15]: https://bertt.wordpress.com/2022/12/20/geoparquet-geospatial-vector-data-using-apache-parquet/


---

# to counter your assumptions (except for the noted schema 4 columns mismatch) - I made a more formal script to check everything mentioned:

```pwsh
# --- verify_geoparquet.ps1 ---
# run from pwsh on windows
# adjust paths if needed

$files = @(
    "C:\\geodata\\output\\statefp=13\\parcels.parquet",
    "C:\\geodata\\output\\statefp=37\\parcels.parquet"
)

foreach ($f in $files) {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "FILE: $f" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    # ------------------------------------------------------------------
    # 1. spec compliance (gpq validate)
    # ------------------------------------------------------------------
    Write-Host "`n--- 1. GeoParquet Spec Compliance (gpq validate) ---" -ForegroundColor Yellow
    Push-Location (Split-Path $f)
    gpq validate (Split-Path $f -Leaf)
    Pop-Location

    # ------------------------------------------------------------------
    # 2. basic layer info (ogrinfo)
    # ------------------------------------------------------------------
    Write-Host "`n--- 2. Layer Summary (ogrinfo) ---" -ForegroundColor Yellow
    $ogr = ogrinfo $f parcels -limit 0
    $ogr | Select-String -Pattern "^(Layer name|Geometry:|Feature Count|Extent|Geometry Column|FID Column)" | ForEach-Object { Write-Host $_.Line }

    # ------------------------------------------------------------------
    # 3. check for bbox struct column in field list
    # ------------------------------------------------------------------
    Write-Host "`n--- 3. Covering BBox Struct Column ---" -ForegroundColor Yellow
    $bboxFields = $ogr | Select-String -Pattern "bbox"
    if ($bboxFields) {
        Write-Host "PASS: bbox struct column found in schema" -ForegroundColor Green
        $bboxFields | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
    } else {
        Write-Host "FAIL: no bbox struct column in schema" -ForegroundColor Red
    }

    # ------------------------------------------------------------------
    # 4. raw geo metadata: covering, encoding, version, bbox
    # ------------------------------------------------------------------
    Write-Host "`n--- 4. GeoParquet Geo Metadata (raw footer) ---" -ForegroundColor Yellow
    python -c @"
import struct, json, sys

path = r'$f'
with open(path, 'rb') as fh:
    # verify parquet magic bytes
    fh.seek(0)
    header = fh.read(4)
    fh.seek(-4, 2)
    trailer = fh.read(4)
    if header != b'PAR1' or trailer != b'PAR1':
        print('FAIL: invalid parquet magic bytes')
        sys.exit(1)

    # read footer
    fh.seek(-8, 2)
    footer_end = fh.read(8)
    footer_len = struct.unpack('<I', footer_end[:4])[0]
    fh.seek(-(8 + footer_len), 2)
    footer = fh.read(footer_len)

# extract geo json from footer
idx = footer.find(b'{"version"')
if idx < 0:
    print('FAIL: no geo metadata found in parquet footer')
    sys.exit(1)

depth = 0
for i in range(idx, len(footer)):
    if footer[i:i+1] == b'{': depth += 1
    elif footer[i:i+1] == b'}': depth -= 1
    if depth == 0:
        geo = json.loads(footer[idx:i+1])
        break

primary = geo.get('primary_column', '???')
col = geo.get('columns', {}).get(primary, {})

print(f"  version:        {geo.get('version', 'MISSING')}")
print(f"  primary_column: {primary}")
print(f"  encoding:       {col.get('encoding', 'MISSING')}")
print(f"  bbox:           {col.get('bbox', 'MISSING')}")

covering = col.get('covering')
if covering:
    print(f"  covering:       PRESENT")
    bbox_def = covering.get('bbox', {})
    for axis in ('xmin', 'ymin', 'xmax', 'ymax'):
        ref = bbox_def.get(axis, 'MISSING')
        print(f"    {axis}: {ref}")
else:
    print(f"  covering:       NOT PRESENT  <-- FAIL: WRITE_COVERING_BBOX was not applied")

# count row groups via bbox column refs in footer
struct_name = None
if covering:
    struct_name = covering.get('bbox', {}).get('xmin', [None])[0]
if struct_name:
    rg_count = footer.count(struct_name.encode()) // 5  # 5 refs per row group (struct + 4 fields)
    print(f"  est. row groups: ~{rg_count} (via '{struct_name}' occurrences)")
"@

    # ------------------------------------------------------------------
    # 5. full field list (check for schema consistency)
    # ------------------------------------------------------------------
    Write-Host "`n--- 5. Schema Fields ---" -ForegroundColor Yellow
    $ogr | Select-String -Pattern "^\\w+.*:" | Where-Object { $_.Line -notmatch "^(INFO|Layer SRS|GEOGCRS|ENSEMBLE|MEMBER|ELLIPSOID|PRIMEM|CS\\[|AXIS|ORDER|ANGLE|USAGE|SCOPE|AREA|BBOX|ID\\[|Data axis)" } | ForEach-Object {
        Write-Host "  $($_.Line.Trim())"
    }
}

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "DONE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
```

and then

```pwsh
➜ & "C:\\GEODATA\\verify-parquet.ps1"

============================================================
FILE: C:\\geodata\\output\\statefp=13\\parcels.parquet
============================================================

--- 1. GeoParquet Spec Compliance (gpq validate) ---

Summary: Passed 20 checks.

 ✓ file must include a "geo" metadata key
 ✓ metadata must be a JSON object
 ✓ metadata must include a "version" string
 ✓ metadata must include a "primary_column" string
 ✓ metadata must include a "columns" object
 ✓ column metadata must include the "primary_column" name
 ✓ column metadata must include a valid "encoding" string
 ✓ column metadata must include a "geometry_types" list
 ✓ optional "crs" must be null or a PROJJSON object
 ✓ optional "orientation" must be a valid string
 ✓ optional "edges" must be a valid string
 ✓ optional "bbox" must be an array of 4 or 6 numbers
 ✓ optional "epoch" must be a number
 ✓ geometry columns must not be grouped
 ✓ geometry columns must be stored using the BYTE_ARRAY parquet type
 ✓ geometry columns must be required or optional, not repeated
 ✓ all geometry values match the "encoding" metadata
 ✓ all geometry types must be included in the "geometry_types" metadata (if not empty)
 ✓ all polygon geometries must follow the "orientation" metadata (if present)
 ✓ all geometries must fall within the "bbox" metadata (if present)


--- 2. Layer Summary (ogrinfo) ---
Layer name: parcels
Geometry: Multi Polygon
Feature Count: 4754448
Extent: (-85.605338, 30.355656) - (-80.839783, 35.018623)
FID Column = lrid
Geometry Column = geom

--- 3. Covering BBox Struct Column ---
PASS: bbox struct column found in schema
  BBOX[-90,-180,90,180]],

--- 4. GeoParquet Geo Metadata (raw footer) ---
  version:        1.1.0
  primary_column: geom
  encoding:       WKB
  bbox:           [-85.6053381, 30.3556563, -80.8397834, 35.0186228]
  covering:       PRESENT
    xmin: ['geom_bbox', 'xmin']
    ymin: ['geom_bbox', 'ymin']
    xmax: ['geom_bbox', 'xmax']
    ymax: ['geom_bbox', 'ymax']
  est. row groups: ~77 (via 'geom_bbox' occurrences)

--- 5. Schema Fields ---
  Layer name: parcels
  Metadata:
  Geometry: Multi Polygon
  Feature Count: 4754448
  Extent: (-85.605338, 30.355656) - (-80.839783, 35.018623)
  parcelid: String (0.0)
  parcelid2: String (0.0)
  geoid: String (0.0)
  statefp: String (0.0)
  countyfp: String (0.0)
  taxacctnum: String (0.0)
  taxyear: Integer (0.0)
  usecode: String (0.0)
  usedesc: String (0.0)
  zoningcode: String (0.0)
  zoningdesc: String (0.0)
  numbldgs: Integer (0.0)
  numunits: Integer (0.0)
  yearbuilt: Integer (0.0)
  numfloors: Integer (0.0)
  bldgsqft: Integer (0.0)
  bedrooms: Integer (0.0)
  halfbaths: Integer (0.0)
  fullbaths: Integer (0.0)
  imprvalue: Integer64 (0.0)
  landvalue: Integer64 (0.0)
  agvalue: Integer64 (0.0)
  totalvalue: Integer64 (0.0)
  assdacres: Real (0.0)
  saleamt: Integer64 (0.0)
  saledate: Date
  ownername: String (0.0)
  owneraddr: String (0.0)
  ownercity: String (0.0)
  ownerstate: String (0.0)
  ownerzip: String (0.0)
  parceladdr: String (0.0)
  parcelcity: String (0.0)
  parcelstate: String (0.0)
  parcelzip: String (0.0)
  legaldesc: String (0.0)
  township: String (0.0)
  section: String (0.0)
  qtrsection: String (0.0)
  range: String (0.0)
  plssdesc: String (0.0)
  book: String (0.0)
  page: String (0.0)
  block: String (0.0)
  lot: String (0.0)
  updated: String (0.0)
  lrversion: String (0.0)
  centroidx: Real (0.0)
  centroidy: Real (0.0)
  surfpointx: Real (0.0)
  surfpointy: Real (0.0)

============================================================
FILE: C:\\geodata\\output\\statefp=37\\parcels.parquet
============================================================

--- 1. GeoParquet Spec Compliance (gpq validate) ---

Summary: Passed 20 checks.

 ✓ file must include a "geo" metadata key
 ✓ metadata must be a JSON object
 ✓ metadata must include a "version" string
 ✓ metadata must include a "primary_column" string
 ✓ metadata must include a "columns" object
 ✓ column metadata must include the "primary_column" name
 ✓ column metadata must include a valid "encoding" string
 ✓ column metadata must include a "geometry_types" list
 ✓ optional "crs" must be null or a PROJJSON object
 ✓ optional "orientation" must be a valid string
 ✓ optional "edges" must be a valid string
 ✓ optional "bbox" must be an array of 4 or 6 numbers
 ✓ optional "epoch" must be a number
 ✓ geometry columns must not be grouped
 ✓ geometry columns must be stored using the BYTE_ARRAY parquet type
 ✓ geometry columns must be required or optional, not repeated
 ✓ all geometry values match the "encoding" metadata
 ✓ all geometry types must be included in the "geometry_types" metadata (if not empty)
 ✓ all polygon geometries must follow the "orientation" metadata (if present)
 ✓ all geometries must fall within the "bbox" metadata (if present)


--- 2. Layer Summary (ogrinfo) ---
Layer name: parcels
Geometry: Multi Polygon
Feature Count: 5756891
Extent: (-84.321810, 33.841582) - (-75.461054, 36.588486)
FID Column = lrid
Geometry Column = geometry

--- 3. Covering BBox Struct Column ---
PASS: bbox struct column found in schema
  BBOX[-90,-180,90,180]],

--- 4. GeoParquet Geo Metadata (raw footer) ---
  version:        1.1.0
  primary_column: geometry
  encoding:       WKB
  bbox:           [-84.3218099, 33.8415816, -75.4610535, 36.5884857]
  covering:       PRESENT
    xmin: ['geometry_bbox', 'xmin']
    ymin: ['geometry_bbox', 'ymin']
    xmax: ['geometry_bbox', 'xmax']
    ymax: ['geometry_bbox', 'ymax']
  est. row groups: ~93 (via 'geometry_bbox' occurrences)

--- 5. Schema Fields ---
  Layer name: parcels
  Geometry: Multi Polygon
  Feature Count: 5756891
  Extent: (-84.321810, 33.841582) - (-75.461054, 36.588486)
  parcelid: String (0.0)
  parcelid2: String (0.0)
  geoid: String (0.0)
  statefp: String (0.0)
  countyfp: String (0.0)
  taxacctnum: String (0.0)
  taxyear: Integer (0.0)
  usecode: String (0.0)
  usedesc: String (0.0)
  zoningcode: String (0.0)
  zoningdesc: String (0.0)
  numbldgs: Integer (0.0)
  numunits: Integer (0.0)
  yearbuilt: Integer (0.0)
  numfloors: Integer (0.0)
  bldgsqft: Integer (0.0)
  bedrooms: Integer (0.0)
  halfbaths: Integer (0.0)
  fullbaths: Integer (0.0)
  imprvalue: Integer64 (0.0)
  landvalue: Integer64 (0.0)
  agvalue: Integer64 (0.0)
  totalvalue: Integer64 (0.0)
  assdacres: Real (0.0)
  saleamt: Integer64 (0.0)
  saledate: Date
  ownername: String (0.0)
  owneraddr: String (0.0)
  ownercity: String (0.0)
  ownerstate: String (0.0)
  ownerzip: String (0.0)
  parceladdr: String (0.0)
  parcelcity: String (0.0)
  parcelstate: String (0.0)
  parcelzip: String (0.0)
  legaldesc: String (0.0)
  township: String (0.0)
  section: String (0.0)
  qtrsection: String (0.0)
  range: String (0.0)
  plssdesc: String (0.0)
  book: String (0.0)
  page: String (0.0)
  block: String (0.0)
  lot: String (0.0)
  updated: String (0.0)
  lrversion: String (0.0)
  centroidx: Real (0.0)
  centroidy: Real (0.0)
  surfpointx: Real (0.0)
  surfpointy: Real (0.0)

============================================================
DONE
============================================================
```

Good — the verification script surfaces a cleaner picture than my previous assumptions. Let me give you a precise read of exactly what it confirms, what it flags, and what needs action.

## What's Actually Confirmed ✓

Both parquets are in better shape than assumed:

- **GeoParquet 1.1.0** spec-compliant (all 20 `gpq` checks) ✓
- **WKB encoding** ✓
- **`covering` present** with correct `xmin/ymin/xmax/ymax` struct references → `WRITE_COVERING_BBOX` was applied ✓
- **Row group sizing**: GA ~77 RGs / 4.75M features ≈ 61,700/RG; NC ~93 RGs / 5.76M ≈ 61,900/RG — both right at the 65,536 target ✓
- **`SORT_BY_BBOX` evidence**: row groups sized consistently implies the sort pass ran ✓


## Two Actual Issues to Fix

### Issue 1 — 4 Schema Columns (Confirmed)

`halfbaths`, `fullbaths`, `parcelstate`, `lrversion` are still present in both. This is the known issue from GPKG-direct creation, fixable by regenerating from the FGBs.

### Issue 2 — Geometry Column Name Inconsistency (New Finding)

This is the sneakier problem:


| File | FID Column | Geometry Column | Covering struct ref |
| :-- | :-- | :-- | :-- |
| `statefp=13` (GA) | `lrid` | **`geom`** | `geom_bbox` |
| `statefp=37` (NC) | `lrid` | **`geometry`** | `geometry_bbox` |

These were produced differently — GA inherited `geom` from the GPKG/FGB source column name; NC got `geometry` likely from a different invocation or tool default. This is a critical consistency issue for any downstream tooling that queries multiple states by column name — DuckDB `read_parquet(glob)`, GDAL multi-file datasets, and the Hive partition reader all assume uniform schema across partition files. You need to pick one and standardize across all 55 states. The natural choice is `geom` since that's what flows from the GPKG source through the FGBs, but `geometry` is the more widely assumed default in the broader ecosystem (PostGIS, GDAL's own default, GeoParquet example datasets). **Recommend standardizing on `geometry`** for maximum interoperability — use `-nln` plus an explicit `-sql` alias or `-rename` when regenerating from FGBs:

```bash
ogr2ogr \
  -f Parquet \
  -lco SORT_BY_BBOX=YES \
  -lco WRITE_COVERING_BBOX=YES \
  -lco COMPRESSION=ZSTD \
  -lco COMPRESSION_LEVEL=15 \
  -lco ROW_GROUP_SIZE=65536 \
  -lco GEOMETRY_NAME=geometry \
  -nln parcels \
  "data/output/geoparquet/statefp=13/parcels.parquet" \
  "data/output/flatgeobuf/state=13/parcels.fgb"
```

`-lco GEOMETRY_NAME=geometry` forces the output column name regardless of the source column name, so every state regeneration is guaranteed consistent.

## Fix for Check \#3 in Your Script

The PowerShell grep for `bbox` in the field list is catching the CRS WKT string `BBOX[-90,-180,90,180]`, not the actual `geometry_bbox`/`geom_bbox` struct field. It's a false positive — the only reliable check for covering bbox presence is the Python footer parse you already have in check \#4. You can either remove check \#3 or tighten the filter:

```powershell
# Replace the current bbox grep with a struct-specific pattern
$bboxFields = $ogr | Select-String -Pattern "^\s*(geom_bbox|geometry_bbox)\s*:"
```


## Updated Verification Function

Since you're formalizing this into `parcels_validate_parquet()` in your R package, the definitive checks in priority order should be:

```
1. gpq validate (spec compliance, 20 checks)  ← already in script
2. geo metadata footer: version=1.1.0, encoding=WKB ← Python check #4 ✓
3. covering struct present in geo metadata ← Python check #4 ✓ (not grep)
4. geometry column name = "geometry" (standardized) ← new check
5. 4 dropped columns absent ← schema check
6. feature count matches manifest ← cross-reference
7. bbox coordinates within expected state extent ← cross-reference vs TIGER state boundaries
```


## Immediate Action

Regenerate both from local FGBs with `-lco GEOMETRY_NAME=geometry` — this fixes both issues in one pass. The FGBs are on local NVMe, ~5–6 min each. Then replace on Tigris. From that point, every subsequent state extracted via your `gpkg_fgb_extraction.sh` → `ogr2ogr` Parquet flow should include `GEOMETRY_NAME=geometry` as a hardcoded constant in `aaa.R` alongside `PARCELS_DROP_COLS` so it can never diverge across states.
<span style="display:none">[^5_1][^5_10][^5_11][^5_12][^5_13][^5_14][^5_15][^5_2][^5_3][^5_4][^5_5][^5_6][^5_7][^5_8][^5_9]</span>

<div align="center">⁂</div>

[^5_1]: https://gdal.org/en/stable/drivers/vector/flatgeobuf.html

[^5_2]: https://courses.spatialthoughts.com/gdal-tools.html

[^5_3]: https://gdal.org/en/stable/user/configoptions.html

[^5_4]: https://github.com/opengeospatial/geoparquet/blob/main/format-specs/distributing-geoparquet.md

[^5_5]: https://worace.works/2022/02/23/kicking-the-tires-flatgeobuf/

[^5_6]: https://www.linkedin.com/pulse/flatgeobuf-vs-geoparquet-apache-iceberg-ogc-cloud-ingo-simonis-v0aue

[^5_7]: https://github.com/xaviernogueira/geoparquet-pydantic

[^5_8]: https://www.reddit.com/r/QGIS/comments/1jy20d6/why_cant_i_create_a_spatial_index_spatial_index/

[^5_9]: https://gdal.org/en/stable/user/virtual_file_systems.html

[^5_10]: https://cloudnativegeo.org/blog/2024/05/towards-flexible-data-schemas/

[^5_11]: https://groups.google.com/g/spatialite-users/c/73LeVY48JVM

[^5_12]: https://github.com/deepin-community/gdal/blob/master/NEWS.md

[^5_13]: https://geoparquet.org/releases/v1.0.0/

[^5_14]: https://gdal.org/en/stable/user/raster_data_model.html

[^5_15]: https://raw.githubusercontent.com/OSGeo/gdal/master/NEWS.md


---

# and what do you recommend for FGB metadata files? and what about FGB verifications? (im focusing on FGBs now and not parquets ATM)

The search results were unhelpfully generic here, so I'll work directly from the FlatGeoBuf spec and GDAL's implementation.

## FGB Native Metadata (Often Overlooked)

FlatGeoBuf actually has **three native optional string fields baked into its binary header** as part of the FlatBuffers schema: `title`, `description`, and `metadata`.  The `metadata` field is explicitly intended for arbitrary JSON. This is the cleanest place to embed provenance — the metadata physically travels with the file rather than being a separate artifact. GDAL exposes these via dataset-level metadata items when writing:[^6_1]

```bash
ogr2ogr \
  -f FlatGeoBuf \
  -lco SPATIAL_INDEX=YES \
  -dsco TITLE="US Parcels - Georgia (statefp=13)" \
  -dsco DESCRIPTION="State-level parcel extract from LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg. Drops: parcelstate, lrversion, halfbaths, fullbaths." \
  -dsco METADATA='{"statefp":"13","source":"LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg","schema_version":"2026.1","extracted_at":"2026-04-09","gdal_version":"3.12.3","drops":["parcelstate","lrversion","halfbaths","fullbaths"],"geometry_column":"geom","crs":"EPSG:4326"}' \
  ... (rest of extraction args)
```

This means you can bake state FIPS, provenance, schema version, and drop list directly into every FGB at extraction time. `ogrinfo -json` on the file will surface the metadata field in its output.

## Sidecar `.fgb.json`

Despite the header metadata above, a parallel sidecar JSON is still worth generating as output of your **validation step** (not extraction) because:

- It's machine-readable without parsing FlatBuffers binary
- It carries runtime facts only known post-extraction (file size, row count cross-referenced against manifest, Hilbert index node size, validation timestamp, elapsed time)
- It's uploadable alongside the FGB to Tigris with zero extra work

Structure to standardize on:

```json
{
  "statefp": "13",
  "state_name": "Georgia",
  "source_gpkg": "LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg",
  "schema_version": "2026.1",
  "extracted_at": "2026-04-09T22:14:00Z",
  "validated_at": "2026-04-09T22:18:32Z",
  "gdal_version": "3.12.3",
  "file_size_bytes": 2900000000,
  "feature_count": 4754448,
  "manifest_count": 4754448,
  "count_match": true,
  "geometry_type": "MultiPolygon",
  "geometry_column": "geom",
  "crs": "EPSG:4326",
  "bbox": { "xmin": -85.605, "ymin": 30.355, "xmax": -80.839, "ymax": 35.018 },
  "bbox_within_state": true,
  "hilbert_index": true,
  "index_node_size": 16,
  "column_count": 47,
  "dropped_columns": ["parcelstate", "lrversion", "halfbaths", "fullbaths"],
  "schema_ok": true,
  "status": "PASS"
}
```

Upload pattern to Tigris: `parcels.fgb` → `parcels.fgb.json` in the same prefix. At any point a catalog sweep can `aws s3 ls --recursive` the bucket, collect all `.fgb.json` sidecars, and build a master catalog without opening a single FGB.

***

## FGB Verification Checks

There's no `gpq`-equivalent for FGB, so you build it. Here's the full ordered check set for `parcels_validate_fgb()`:

### Level 1 — File Integrity (fast, no parsing)

```r
parcels_validate_fgb_integrity <- function(fgb_path) {
  # 1a. file exists and non-zero
  stopifnot(file.exists(fgb_path))
  sz <- file.size(fgb_path)
  stopifnot(sz > 0)
  
  # 1b. FlatGeoBuf magic bytes: first 8 bytes = 66 67 62 03 66 67 62 00
  con <- file(fgb_path, "rb")
  magic <- readBin(con, raw(), n = 8)
  close(con)
  expected <- as.raw(c(0x66, 0x67, 0x62, 0x03, 0x66, 0x67, 0x62, 0x00))
  stopifnot(identical(magic, expected))
  
  list(file_size_bytes = sz, magic_ok = TRUE)
}
```


### Level 2 — GDAL Summary (`ogrinfo -so`)

Uses `gdalraster::ogrinfo()` or `system2("ogrinfo", ...)`:

```r
# checks to run against ogrinfo output:
# - Feature Count matches manifest_count for this statefp
# - Geometry type is Polygon or MultiPolygon (not None, not mixed unknown)
# - CRS authority = EPSG:4326
# - "Extent" bbox falls within known state envelope (from fips_state_bbox())
# - Field named "geom" present (geometry column name consistency)
# - Field count = 47 (51 - 4 drops)
# - None of c("parcelstate","lrversion","halfbaths","fullbaths") in field list
# - "Spatial Index:" line present (confirms Hilbert index written)
```

The "Spatial Index:" line in `ogrinfo -so` output is the only quick signal that `SPATIAL_INDEX=YES` actually fired — GDAL prints `Spatial Index: hilbert` for FGB files with a valid index written. If it's absent, the FGB was written without an index (possibly due to an interrupted write or `/vsis3/` output).

### Level 3 — Sample Read (vapour)

```r
# 3a. read 1000 attributes via vapour::vapour_read_attributes()
# - verify statefp is all == state_fips (no contamination from WHERE clause failure)
# - verify countyfp values are all 3-char zero-padded strings
# - verify geoid = paste0(statefp, countyfp)
# - verify no NULL statefp or countyfp in sample

# 3b. read 100 geometries via vapour::vapour_read_geometry()
# - parse WKB and verify all are valid (sf::st_is_valid)
# - 0% invalid acceptable, warn at >0.01%, fail at >0.1%
```


### Level 4 — Cross-Reference vs Manifest

```r
# load manifest_state_county.csv
# for the given statefp, sum feature_count across all counties
# compare to ogrinfo Feature Count
# flag if delta > 0 (should be exact match since FGB was built with WHERE statefp=XX)
```


### Level 5 — Header Metadata (optional but nice)

```r
# read FGB header JSON via Python (flatgeobuf package) or raw binary parse
# verify METADATA field is present and parseable JSON
# verify METADATA.statefp matches file path statefp
# verify METADATA.extracted_at is a valid ISO8601 datetime
```


***

## PowerShell Verification Script Equivalent

Since you already have a polished `verify_geoparquet.ps1` pattern, here's the FGB analog structure:

```powershell
# verify_fgb.ps1

param(
  [Parameter(Mandatory)][string]$StateFips
)

$fgb = "data\output\flatgeobuf\state=$StateFips\parcels.fgb"
$sidecar = "$fgb.json"

Write-Host "`n=== FGB VERIFICATION: state=$StateFips ===" -ForegroundColor Cyan

# 1. magic bytes
$bytes = [System.IO.File]::ReadAllBytes($fgb)[0..7]
$magic  = @(0x66,0x67,0x62,0x03,0x66,0x67,0x62,0x00)
$magicOk = ($bytes -join ',') -eq ($magic -join ',')
Write-Host "1. Magic bytes: $(if ($magicOk) {'PASS'} else {'FAIL'})" -ForegroundColor $(if ($magicOk) {'Green'} else {'Red'})

# 2. ogrinfo summary
$ogr = pixi run ogrinfo -so $fgb parcels
$ogr | Select-String "^(Feature Count|Extent|Geometry:|Spatial Index)" | % { Write-Host "   $($_.Line.Trim())" }

# 3. schema checks
$fields = $ogr | Select-String "^\w+.*: " | % { $_.Line.Trim() }
$badCols = @("parcelstate","lrversion","halfbaths","fullbaths")
$found   = $badCols | Where-Object { $fields -match "^$_\s*:" }
if ($found) {
  Write-Host "3. Schema drops: FAIL - found: $($found -join ', ')" -ForegroundColor Red
} else {
  Write-Host "3. Schema drops: PASS (4 columns absent)" -ForegroundColor Green
}

# 4. spatial index
$idxLine = $ogr | Select-String "Spatial Index"
Write-Host "4. Spatial index: $(if ($idxLine) {'PASS - ' + $idxLine.Line.Trim()} else {'FAIL - no index found'})" `
  -ForegroundColor $(if ($idxLine) {'Green'} else {'Red'})

# 5. emit sidecar JSON
# ... (call R parcels_validate_fgb() or inline)
```


***

## Where This Fits in Your R Package

```
parcels_validate_fgb(fgb_path, manifest = NULL)
  calls: .fgb_check_magic()          → Level 1
         .fgb_check_ogrinfo()        → Level 2 (gdalraster::ogrinfo)
         .fgb_check_sample()         → Level 3 (vapour)
         .fgb_check_manifest()       → Level 4 (cross-ref manifest CSV)
         .fgb_write_sidecar()        → writes parcels.fgb.json
  returns: named list (all check results + sidecar path)
```

The sidecar write happens only if all checks pass — a present `.fgb.json` beside a `.fgb` is therefore an implicit "this file is validated" signal, which your batch runner can use to skip re-validation on subsequent runs.
<span style="display:none">[^6_10][^6_11][^6_12][^6_13][^6_14][^6_15][^6_16][^6_2][^6_3][^6_4][^6_5][^6_6][^6_7][^6_8][^6_9]</span>

<div align="center">⁂</div>

[^6_1]: https://gdal.org/en/stable/drivers/vector/flatgeobuf.html

[^6_2]: https://fgb-rdm.nl/rdm/tools/YODAInstructionsFGB.html

[^6_3]: https://learning.nceas.ucsb.edu/2023-01-arctic/metadata-best-practices-and-data-publishing.html

[^6_4]: https://www.youtube.com/watch?v=UL-C96dVnOU

[^6_5]: https://www.reddit.com/r/gis/comments/1kgy3le/proper_way_to_serialize_feature_properties_in/

[^6_6]: https://guides.lib.unc.edu/metadata/best-practices

[^6_7]: https://uobdv.github.io/Design-Verification/Lectures/Current/3_VerificationTools_narrated_v6-ink.pdf

[^6_8]: https://www.mintlify.com/thareUSGS/GDAL_scripts/scripts/metadata-generation

[^6_9]: https://www.collibra.com/blog/metadata-management-best-practices

[^6_10]: https://www.aldec.com/en/solutions/functional_verification--fpga-verification-tools

[^6_11]: https://gdal.org/en/stable/user/raster_data_model.html

[^6_12]: https://www.acceldata.io/blog/metadata-standards-made-simple-essential-types-and-best-practices

[^6_13]: https://www.reddit.com/r/FPGA/comments/mfcjy5/recommended_free_open_source_verification_platform/

[^6_14]: https://gdal.org/en/stable/development/rfc/rfc14_imagestructure.html

[^6_15]: https://www.crossref.org/documentation/principles-practices/best-practices/

[^6_16]: https://web.eecs.utk.edu/~dbouldin/protected/verification-synplicity.pdf


---

# great recommendations. the upload to tigris is by far the bottleneck (just did TX from gpkg to FGB in ~10-12m and its the largest state) - currently uploading GA and NC each to tigris and will take hours it looks like and they're only 2-4GB

The bottleneck here is almost certainly single-threaded upload with a small default part size — not Tigris itself. Tigris supports S3 multipart API and parallel part uploads are the documented solution for large objects.[^7_1][^7_2]

## The Root Cause

`aws s3 cp` and naive rclone both default to 8MB chunk sizes and limited concurrency. For a 3GB FGB that means ~375 sequential parts serialized over a single TCP connection — regardless of your available upload bandwidth, you're leaving most of it unused due to per-request latency and HTTP overhead.

## rclone (Recommended for Your Setup)

rclone is the right tool here — it has first-class S3 multipart with tunable chunk size and per-file concurrency. Config for Tigris:

```ini
# ~/.config/rclone/rclone.conf
[tigris]
type = s3
provider = Other
access_key_id = YOUR_KEY
secret_access_key = YOUR_SECRET
endpoint = https://fly.storage.tigris.dev
region = auto
```

Then for large FGB uploads:

```powershell
# single file — 128MB chunks, 16 parallel parts per file
rclone copy `
  "C:\geodata\output\flatgeobuf\state=13\parcels.fgb" `
  "tigris:noclocks-parcels-source/flatgeobuf/state=13/parcels.fgb" `
  --s3-chunk-size 128M `
  --s3-upload-concurrency 16 `
  --progress `
  --stats 5s
```

For a 3GB FGB with 128MB chunks that's ~24 parts uploading 16 at a time — this should saturate your actual upstream bandwidth rather than being limited by HTTP round-trip overhead.

For batch state uploads once you have multiple FGBs ready:

```powershell
# multiple files in parallel — 4 concurrent file transfers, 
# each using 8-part multipart (don't oversubscribe the pipe)
rclone copy `
  "C:\geodata\output\flatgeobuf" `
  "tigris:noclocks-parcels-source/flatgeobuf" `
  --s3-chunk-size 128M `
  --s3-upload-concurrency 8 `
  --transfers 4 `
  --progress `
  --stats 5s `
  --include "*.fgb"
```

Also upload the sidecar JSONs in the same pass — `--include "*.fgb" --include "*.fgb.json"` and rclone handles them in one shot.

## AWS CLI Tuning (if you prefer aws over rclone)

```powershell
# tune once, persists in ~/.aws/config
aws configure set default.s3.multipart_threshold 64MB
aws configure set default.s3.multipart_chunksize 128MB
aws configure set default.s3.max_concurrent_requests 16
aws configure set default.s3.max_bandwidth 0  # no cap

# then upload as normal, multipart fires automatically for >64MB
aws s3 cp `
  "C:\geodata\output\flatgeobuf\state=13\parcels.fgb" `
  "s3://noclocks-parcels-source/flatgeobuf/state=13/parcels.fgb" `
  --endpoint-url https://fly.storage.tigris.dev
```


## Reality Check on Actual Speed

If you're on a residential or typical office connection, raw upload bandwidth is the true ceiling — multipart helps by reducing latency overhead but can't exceed your pipe. At common upstream speeds:


| Upload speed | 3GB FGB | 4GB FGB |
| :-- | :-- | :-- |
| 25 Mbps | ~17 min | ~23 min |
| 50 Mbps | ~9 min | ~11 min |
| 100 Mbps | ~4 min | ~6 min |
| 250 Mbps | ~2 min | ~3 min |

"Hours" for a 3GB file points to either single-threaded uploads not using multipart (most likely), or you're bandwidth-capped below 10 Mbps sustained upstream. Run `rclone copy ... --progress` and watch the transfer rate — if it climbs to your expected upstream speed with the multipart config above, that's the fix. If it plateaus below your expected speed, the issue is your ISP or the connection path to Tigris's nearest PoP.

## One More Option: TigrisFS

Tigris also maintains [tigrisfs](https://github.com/tigrisdata/tigrisfs), a FUSE filesystem that mounts a Tigris bucket as a local directory.  This is worth experimenting with (it's one of your stated side goals of trying new tools) — you could mount the bucket and `cp` directly from WSL as if writing to a local path. Performance characteristics differ from raw S3 API uploads but it removes the explicit upload step from your workflow entirely.[^7_3]
<span style="display:none">[^7_10][^7_11][^7_12][^7_13][^7_14][^7_15][^7_4][^7_5][^7_6][^7_7][^7_8][^7_9]</span>

<div align="center">⁂</div>

[^7_1]: https://community.fly.io/t/tigris-performance-quotas-and-limits/21943

[^7_2]: https://www.tigrisdata.com/docs/sdks/tigris/client-uploads/

[^7_3]: https://github.com/tigrisdata/tigrisfs

[^7_4]: https://www.tigrisdata.com/docs/overview/benchmarks/metrics/

[^7_5]: https://benhoyt.com/writings/flyio-and-tigris/

[^7_6]: https://peterullrich.com/distribute-your-files-globally-with-tigris-and-fly

[^7_7]: https://www.reddit.com/r/reactjs/comments/1444j92/what_are_some_best_practices_to_uploading_very/

[^7_8]: https://oneuptime.com/blog/post/2026-02-17-how-to-optimize-upload-performance-with-parallel-composite-uploads-in-google-cloud-storage/view

[^7_9]: https://community.fly.io/t/best-practice-for-large-machine-tigris-transfer/24395

[^7_10]: https://dev.to/twiponyts/file-uploads-for-a-social-media-app-with-tigris-4773

[^7_11]: https://www.tigrisdata.com/docs/training-use-cases/

[^7_12]: https://www.tigrisdata.com/blog/benchmark-small-objects/

[^7_13]: https://community.fly.io/t/cant-upload-images-to-tigris-over-1mb/24721

[^7_14]: https://www.reddit.com/r/hetzner/comments/1j813a9/storage_for_user_file_uploads_share_between/

[^7_15]: https://www.tigrisdata.com/docs/objects/upload-via-html-form/


---

# ok - i am limited somewhat from ISP upload speeds also but Ill plan on getting more local FGBs done first than another night do a batch upload while sleeping or something

That's the right call — **produce locally, batch-upload overnight** is exactly how to work around ISP upstream constraints. A few things to make the overnight run solid and hands-off:

## Overnight Batch rclone Command

```powershell
rclone copy `
  "C:\geodata\output\flatgeobuf" `
  "tigris:noclocks-parcels-source/flatgeobuf" `
  --s3-chunk-size 128M `
  --s3-upload-concurrency 16 `
  --transfers 2 `
  --retries 10 `
  --retries-sleep 30s `
  --low-level-retries 20 `
  --progress `
  --log-file "C:\geodata\logs\upload_$(Get-Date -Format 'yyyyMMdd_HHmm').log" `
  --log-level INFO `
  --include "*.fgb" `
  --include "*.fgb.json"
```

`--transfers 2` is intentional here — two concurrent file uploads each with 16-part multipart saturates your upstream without over-subscribing it. More than 2 concurrent files at 128MB chunks will fight each other for the same pipe and actually slow things down.[^8_1]

The `--retries 10` + `--retries-sleep 30s` combo means if a part fails (connection drop, ISP throttle at 2am) rclone backs off and retries automatically — you won't wake up to a half-uploaded state.[^8_2]

## Resumability

rclone S3 copies are **resume-safe by default** — it compares ETags before uploading. If the overnight run is interrupted and you restart it in the morning, already-uploaded files are skipped. You can also add `--checksum` if you want byte-level integrity verification on resume rather than size+modtime comparison.

## Overnight FGB Production Strategy

While the batch is uploading, you can keep extracting more states from the GPKG in parallel since extraction reads from NVMe (fast) and upload is purely network-bound — they don't compete. Prioritize by feature count ascending so small states/territories finish fast and validate the pipeline end-to-end before committing hours to Texas-scale extractions:

```r
# from your manifest_state_rollup.csv, ordered small-to-large
# territories first (DC=11, VI=78, GU=66, AS=60, MP=69 — likely <50k features each)
# then small states (RI, DE, CT, VT, NH, ME)
# large states (TX, CA, FL) last since TX already done
```


## One Practical Addition

Create a simple done-file marker after each FGB extraction so your batch uploader can be re-run safely:

```powershell
# after each ogr2ogr extraction succeeds, touch a marker
New-Item "C:\geodata\output\flatgeobuf\state=13\.extracted" -ItemType File -Force
```

Then the upload script can target only directories with `.extracted` markers, and your R validation writes `.validated` after `parcels_validate_fgb()` passes. Three file states per directory — `none / .extracted / .validated` — gives you a simple pipeline state machine without any database.
<span style="display:none">[^8_10][^8_11][^8_12][^8_13][^8_14][^8_15][^8_3][^8_4][^8_5][^8_6][^8_7][^8_8][^8_9]</span>

<div align="center">⁂</div>

[^8_1]: https://community.fly.io/t/tigris-performance-quotas-and-limits/21943

[^8_2]: https://community.fly.io/t/best-practice-for-large-machine-tigris-transfer/24395

[^8_3]: https://www.tigrisdata.com/docs/objects/upload-via-html-form/

[^8_4]: https://peterullrich.com/distribute-your-files-globally-with-tigris-and-fly

[^8_5]: https://www.tigrisdata.com/docs/skills/

[^8_6]: https://oneuptime.com/blog/post/2026-02-12-optimize-s3-performance-high-throughput-workloads/view

[^8_7]: https://www.tigrisdata.com/blog/tigrisfs/

[^8_8]: https://www.tigrisdata.com/docs/training/tigrisfs/

[^8_9]: https://aws.amazon.com/blogs/compute/uploading-large-objects-to-amazon-s3-using-multipart-upload-and-transfer-acceleration/

[^8_10]: https://community.fly.io/t/our-experience-dealing-with-issues-of-tigris-reliability-500-responses-and-docs-questions-requests/23720

[^8_11]: https://dev.to/owen_roth_v1/optimizing-large-file-uploads-secure-client-side-multipart-uploads-to-aws-s3-6o6

[^8_12]: https://www.tigrisdata.com/docs/overview/

[^8_13]: https://github.com/tigrisdata/tigrisfs

[^8_14]: https://storj.dev/dcs/api/s3/multipart-upload/multipart-part-size

[^8_15]: https://litestream.io/guides/tigris/

