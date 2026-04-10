<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# help me architect the initial stages for this work that involve extracting and processing the data from the monolithic ~100GB gpkg containing nationwide parcel data and is currently sitting on my local disk unzipped into blob storage bucket hosted (via tigris) hive partitioned geoparquets by state + county (fips) and attempting to do this in a performant, modern, and ideally parallel manner. currently ive taken an ad-hoc approach via ogr2ogr with GDAL and the libarrow/parquet driver plugin and created two state-wide processed extractions locally and in turn uploaded to tigris as well for georgia and north carolina in an attempt to derive some initial artifacts and test out the parquet creation configurations and also downstream vector tiles via pmtiles for visualization, etc.

i recently just came across some R packages that could potentially aid with the gpkg processing dynamic such as gpkg ([Utilities for the Open Geospatial Consortium GeoPackage Format • gpkg](https://humus.rocks/gpkg/), [brownag/gpkg: Utilities for the Open Geospatial Consortium (OGC) 'GeoPackage' Format in R](https://github.com/brownag/gpkg)) and trditional DBI/RSQLite packages and for parallel processing, given the whole single file input source and gpkg spatial index etc., the shard ([bbuchsbaum/shard](https://github.com/bbuchsbaum/shard), [Deterministic, Zero-Copy Parallel Execution for R • shard](https://bbuchsbaum.github.io/shard/)) package could maybe be useful, but im not sure still

This is a well-scoped problem with a clear bottleneck: the monolithic GPKG is a SQLite database, and all parallelism decisions flow from that fundamental constraint. Here's a phased architecture designed for robustness and performance.

***

## The Core Constraint: SQLite Concurrency

Before anything else — a GPKG is SQLite, and SQLite's default journal mode allows only one writer but **multiple concurrent readers**. Two GDAL configuration options unlock better parallel read behavior:[^1_1]

- `OGR_GPKG_NUM_THREADS=ALL_CPUS` (GDAL ≥ 3.8.3) — threads the ArrowArray batch reader internally
- `-oo IMMUTABLE=YES` — skips change-detection checks on read-only open, critical for parallel processes
- `-oo NOLOCK=YES` — disables file locking entirely for read-only access (safe when WAL is pre-set)

You should also set WAL mode once as a one-time operation before beginning any parallel work:[^1_2]

```bash
# One-time setup on the GPKG — persists across connections
sqlite3 parcels.gpkg "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"
```

This flips the locking model so readers never block each other, which is the foundation for everything below.[^1_2]

***

## Phase 0 — Inventory \& Manifest (R + `gpkg`/RSQLite)

The `gpkg` package is genuinely well-suited here — not for extraction, but as a lightweight introspection layer. Use it to query `gpkg_contents`, enumerate layers, sample the schema, and build a **work manifest** before spawning any workers:[^1_3]

```r
library(gpkg)
library(DBI)
library(RSQLite)

con <- dbConnect(SQLite(), "parcels.gpkg")

# Query metadata tables directly
gpkg_contents <- dbReadTable(con, "gpkg_contents")

# Build state work manifest
manifest <- dbGetQuery(con, "
  SELECT state_fips, COUNT(*) AS feature_count
  FROM parcels
  GROUP BY state_fips
  ORDER BY feature_count DESC
")

dbDisconnect(con)
write.csv(manifest, "state_manifest.csv", row.names = FALSE)
```

This manifest drives all downstream parallelism and lets you estimate expected parquet sizes per state, flag anomalously large states (California, Texas), and build a priority queue.

***

## Phase 1 — Parallel State Extraction

You have two viable paths here depending on whether you want a single coordinating process or true multi-process reads.

### Path A: DuckDB (Recommended for simplicity + direct-to-Tigris writes)

DuckDB's spatial extension reads GPKG via OGR and writes natively partitioned parquet with direct S3 support via `httpfs`. The write side is where DuckDB truly shines — it handles `PARTITION_BY` with hive-style directory layout natively:[^1_4][^1_5]

```sql
INSTALL spatial; LOAD spatial;
INSTALL httpfs; LOAD httpfs;

-- Tigris S3-compatible config
SET s3_endpoint = 'fly.storage.tigris.dev';
SET s3_access_key_id = '${TIGRIS_ACCESS_KEY}';
SET s3_secret_access_key = '${TIGRIS_SECRET_KEY}';
SET s3_region = 'auto';

-- Single-pass hive-partitioned write, directly to Tigris
COPY (
  SELECT * REPLACE (ST_AsWKB(geom) AS geom)
  FROM ST_Read('/path/to/parcels.gpkg')
) TO 's3://your-bucket/parcels/'
(
  FORMAT PARQUET,
  PARTITION_BY (state_fips, county_fips),
  ROW_GROUP_SIZE 65536,
  OVERWRITE_OR_IGNORE 1
);
```

The **caveat**: DuckDB's `ST_Read()` reads GPKG sequentially through the OGR interface — it's single-threaded on the read side. For 100GB this will take time but requires zero orchestration code and handles partitioned writes atomically.[^1_6]

### Path B: GNU parallel + ogr2ogr (True read parallelism)

For genuine parallel reads off the same GPKG file, multiple independent `ogr2ogr` processes with per-state SQL filters is the most battle-tested approach. Each spawns its own SQLite read connection — WAL mode ensures they don't block each other:[^1_2]

```bash
#!/bin/bash
# states.txt: one state_fips per line from your manifest

GPKG="/path/to/parcels.gpkg"
OUTDIR="/tmp/parcels_staging"

extract_state() {
  STATE=$1
  OUTPATH="${OUTDIR}/state=${STATE}/data.parquet"
  mkdir -p "$(dirname "$OUTPATH")"

  ogr2ogr \
    -f Parquet "$OUTPATH" \
    -oo IMMUTABLE=YES \
    -sql "SELECT * FROM parcels WHERE state_fips='${STATE}'" \
    --config OGR_SQLITE_PRAGMA "journal_mode=WAL,synchronous=OFF,mmap_size=2147483648" \
    --config OGR_GPKG_NUM_THREADS 4 \
    --config SQLITE_USE_OGR_VFS YES \
    --config OGR_ARROW_BATCH_SIZE 65536 \
    "$GPKG"
}

export -f extract_state
export GPKG OUTDIR

# 4-6 workers is near-optimal — beyond this, disk I/O becomes the bottleneck
cat states.txt | parallel -j 5 extract_state {}
```

The `-j 5` ceiling matters — beyond ~6 parallel readers on the same spinning or NVMe file, you saturate sequential read bandwidth and get diminishing returns.[^1_7]

***

## Phase 2 — County Sub-partitioning (if not done inline)

If Path B was used and each state was written as a single file, a DuckDB second pass re-partitions by county efficiently — it reads the state parquets in parallel and writes the nested hive layout:

```sql
COPY (
  SELECT * FROM read_parquet('/tmp/parcels_staging/**/*.parquet', hive_partitioning = true)
) TO '/tmp/parcels_final/'
(
  FORMAT PARQUET,
  PARTITION_BY (state_fips, county_fips),
  ROW_GROUP_SIZE 65536
);
```

Row group size of 50K–150K is the GeoParquet community recommendation. For large counties (LA, Cook, Harris) you may want to split into multiple files — DuckDB does this automatically via `FILE_SIZE_BYTES` if specified.[^1_8]

***

## Phase 3 — Upload to Tigris

`rclone` is the cleanest option for syncing hive-partitioned directories since it understands S3-compatible endpoints and preserves directory structure:

```bash
rclone sync /tmp/parcels_final/ \
  tigris:your-bucket/parcels/ \
  --s3-endpoint https://fly.storage.tigris.dev \
  --transfers 16 \
  --checkers 8 \
  --progress
```

Alternatively, DuckDB Path A eliminates this step by writing directly to Tigris during extraction.

***

## Tool Assessment for Your Specific Use Case

| Tool | Fit for This Pipeline | Best Role |
| :-- | :-- | :-- |
| `gpkg` + RSQLite | ✅ Good | Phase 0: inventory, schema introspection, manifest building |
| `ogr2ogr` + GNU parallel | ✅ Excellent | Phase 1B: proven parallel reads by state FIPS filter |
| DuckDB spatial + httpfs | ✅ Excellent | Phase 1A or 2: parquet writing, county repartitioning, direct S3 |
| `shard` | ⚠️ Limited fit | Phase 1 bottleneck is disk I/O, not in-memory R data — shard's zero-copy advantage requires the shared input to be an R object in memory [^1_9], not a file on disk |
| `furrr`/`parallel` | ✅ Adequate | Phase 1: dispatching `system2(ogr2ogr, ...)` calls per state, simpler than shard for this pattern |

`shard` becomes relevant in a later stage if you're doing in-memory R-side transformations on the already-extracted parquets at scale — its memory-mapped shared inputs and worker supervision would be genuinely useful there. But for the SQLite→parquet extraction phase specifically, the bottleneck is sequential disk reads off a single file, which `shard`'s architecture doesn't address.[^1_10][^1_9]

***

## Recommended Sequencing

1. **One-time**: Set WAL mode on the GPKG via `sqlite3` pragma
2. **Phase 0**: R + `gpkg`/RSQLite → `state_manifest.csv`
3. **Phase 1**: GNU parallel + ogr2ogr at `-j 5` writing to `/tmp/parcels_staging/state=XX/`
4. **Phase 2**: DuckDB second pass → final `state=XX/county=XXXXXX/part-N.parquet` layout
5. **Phase 3**: `rclone sync` → Tigris, or replace steps 3–5 with DuckDB Path A for simpler orchestration

The Georgia/NC artifacts you've already produced are perfect validation fixtures — you can verify row counts, geometry validity, and parquet metadata against them before running the full 50-state job.
<span style="display:none">[^1_11][^1_12][^1_13][^1_14][^1_15][^1_16][^1_17][^1_18][^1_19][^1_20][^1_21][^1_22][^1_23][^1_24][^1_25][^1_26][^1_27][^1_28][^1_29][^1_30]</span>

<div align="center">⁂</div>

[^1_1]: https://gdal.org/en/stable/drivers/vector/gpkg.html

[^1_2]: https://dev.to/ahmet_gedik778845/sqlite-wal-mode-for-better-concurrent-web-performance-4fck

[^1_3]: https://github.com/brownag/gpkg

[^1_4]: https://duckdb.org/docs/current/data/partitioning/hive_partitioning.html

[^1_5]: https://duckdb.org/docs/current/data/partitioning/partitioned_writes.html

[^1_6]: https://news.ycombinator.com/item?id=43881468

[^1_7]: https://cloudnativegeo.org/blog/2023/08/performance-explorations-of-geoparquet-and-duckdb/

[^1_8]: https://github.com/opengeospatial/geoparquet/blob/main/format-specs/distributing-geoparquet.md

[^1_9]: https://rdrr.io/cran/shard/

[^1_10]: https://bbuchsbaum.github.io/shard/

[^1_11]: https://gdal.org/en/stable/drivers/vector/parquet.html

[^1_12]: https://support.safe.com/hc/en-us/articles/37463966031885-Reading-and-Writing-Partitioned-GeoParquet-in-FME-Using-OSM-Data

[^1_13]: https://xebia.com/blog/introducing-the-geoparquet-data-format/

[^1_14]: https://www.linkedin.com/pulse/flatgeobuf-vs-geoparquet-apache-iceberg-ogc-cloud-ingo-simonis-v0aue

[^1_15]: https://brownag.r-universe.dev/gpkg

[^1_16]: https://geoparquet.org

[^1_17]: https://cran.r-project.org/web/packages/gpkg/readme/README.html

[^1_18]: https://cran.r-project.org/package=shard

[^1_19]: http://erouault.blogspot.com/2017/03/dealing-with-huge-vector-geopackage.html

[^1_20]: https://www.rdocumentation.org/packages/gpkg/versions/0.0.14/topics/gpkg-package

[^1_21]: https://cloudnativegeo.org/blog/2023/10/the-admin-partitioned-geoparquet-distribution/

[^1_22]: https://github.com/duckdb/duckdb/discussions/21007

[^1_23]: https://www.reddit.com/r/dataengineering/comments/1lzbege/question_on_optimal_partitioning_structure_for/

[^1_24]: https://github.com/r-spatial/sf/issues/834

[^1_25]: https://oneuptime.com/blog/post/2026-03-31-rook-concurrent-access-libcephsqlite/view

[^1_26]: https://motherduck.com/blog/geospatial-for-beginner-duckdb-spatial-motherduck/

[^1_27]: https://gdal.org/en/stable/user/ogr_sql_dialect.html

[^1_28]: https://stackoverflow.com/questions/4060772/sqlite-concurrent-access

[^1_29]: https://www.youtube.com/watch?v=gDvDo0oNtmw

[^1_30]: https://courses.spatialthoughts.com/gdal-tools.html


---

# starting simple with the metadata and investigatory work against the gpkg, please provide me with the optimal apporach as there's many between the direct RSQLite approach, the gpkg package approach, and a more GDAL/OGR, i.e. ogrinfo, approach which would use GDAL/OGR commands or C++ bindings to the API in gdalraster or sf or terra (even though vector) for example, i.e.:

```R
require(DBI)
require(RSQLite)
require(gpkg)
require(gdalraster)

parcels_path <- "E:/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"

# GDAL approach
gdalraster::ogrinfo(dsn = parcels_path)
# INFO: Open of `E:/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg'
#       using driver `GPKG' successful.
# 1: lr_parcel_us (Multi Polygon)

layer <- "lr_parcel_us"

gdalraster::ogrinfo(dsn = parcels_path, layers = layer)
# INFO: Open of `E:/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg'
#       using driver `GPKG' successful.
# 
# Layer name: lr_parcel_us
# Geometry: Multi Polygon
# Feature Count: 154891095
# Extent: (-166.841139, 13.235464) - (145.829905, 71.389488)
# Layer SRS WKT:
#   GEOGCRS["WGS 84",
#           ENSEMBLE["World Geodetic System 1984 ensemble",
#                    MEMBER["World Geodetic System 1984 (Transit)"],
#                    MEMBER["World Geodetic System 1984 (G730)"],
#                    MEMBER["World Geodetic System 1984 (G873)"],
#                    MEMBER["World Geodetic System 1984 (G1150)"],
#                    MEMBER["World Geodetic System 1984 (G1674)"],
#                    MEMBER["World Geodetic System 1984 (G1762)"],
#                    MEMBER["World Geodetic System 1984 (G2139)"],
#                    MEMBER["World Geodetic System 1984 (G2296)"],
#                    ELLIPSOID["WGS 84",6378137,298.257223563,
#                              LENGTHUNIT["metre",1]],
#                    ENSEMBLEACCURACY[2.0]],
#           PRIMEM["Greenwich",0,
#                  ANGLEUNIT["degree",0.0174532925199433]],
#           CS[ellipsoidal,2],
#           AXIS["geodetic latitude (Lat)",north,
#                ORDER[1],
#                ANGLEUNIT["degree",0.0174532925199433]],
#           AXIS["geodetic longitude (Lon)",east,
#                ORDER[2],
#                ANGLEUNIT["degree",0.0174532925199433]],
#           USAGE[
#             SCOPE["Horizontal component of 3D system."],
#             AREA["World."],
#             BBOX[-90,-180,90,180]],
#           ID["EPSG",4326]]
# Data axis to CRS axis mapping: 2,1
# FID Column = lrid
# Geometry Column NOT NULL = geom
# parcelid: String (0.0)
# parcelid2: String (0.0)
# geoid: String (0.0)
# statefp: String (0.0)
# countyfp: String (0.0)
# taxacctnum: String (0.0)
# taxyear: Integer (0.0)
# usecode: String (0.0)
# usedesc: String (0.0)
# zoningcode: String (0.0)
# zoningdesc: String (0.0)
# numbldgs: Integer (0.0)
# numunits: Integer (0.0)
# yearbuilt: Integer (0.0)
# numfloors: Integer (0.0)
# bldgsqft: Integer (0.0)
# bedrooms: Integer (0.0)
# halfbaths: Integer (0.0)
# fullbaths: Integer (0.0)
# imprvalue: Integer64 (0.0)
# landvalue: Integer64 (0.0)
# agvalue: Integer64 (0.0)
# totalvalue: Integer64 (0.0)
# assdacres: Real (0.0)
# saleamt: Integer64 (0.0)
# saledate: Date
# ownername: String (0.0)
# owneraddr: String (0.0)
# ownercity: String (0.0)
# ownerstate: String (0.0)
# ownerzip: String (0.0)
# parceladdr: String (0.0)
# parcelcity: String (0.0)
# parcelstate: String (0.0)
# parcelzip: String (0.0)
# legaldesc: String (0.0)
# township: String (0.0)
# section: String (0.0)
# qtrsection: String (0.0)
# range: String (0.0)
# plssdesc: String (0.0)
# book: String (0.0)
# page: String (0.0)
# block: String (0.0)
# lot: String (0.0)
# updated: String (0.0)
# lrversion: String (0.0)
# centroidx: Real (0.0)
# centroidy: Real (0.0)
# surfpointx: Real (0.0)
# surfpointy: Real (0.0)

# gpkg approach
parcels_gpkg <- gpkg::gpkg(parcels_path)
# gpkg::gpkg_connect()
gpkg::gpkg_ogr_contents(parcels_gpkg)
diagnostics <- gpkg::gpkg_validate(parcels_gpkg, diagnostics = TRUE)

# RSQlite approach
parcels_conn <- DBI::dbConnect(RSQLite::SQLite(), parcels_path)
gpkg_contents <- DBI::dbReadTable(parcels_conn, "gpkg_contents")
gpkg_contents
# table_name data_type   identifier                                  description              last_change     min_x    min_y    max_x    max_y srs_id
# 1 lr_parcel_us  features lr_parcel_us Landrecords.us Parcel Layer. Version 2026_Q1 2026-01-04T06:22:33.187Z -166.8411 13.23546 145.8299 71.38949   4326

# can see the layer name is lr_parcel_us, etc. but still no field level details


# create "state" work manifest
manifest <- DBI::dbGetQuery(
  parcels_conn,
  "SELECT "
  # TODO
)
```

as initial scratch work by me

Given the output you've already captured from `ogrinfo`, I have a clear picture of the schema (154,891,095 features, `statefp`/`countyfp` are the partition keys, `lrid` is the FID). Let me give you the definitive approach comparison and then the complete investigatory script.

***

## Approach Comparison

Each tool operates at a different layer of the stack. For investigatory work, the choice maps directly to task type:


| Task | Best Tool | Why |
| :-- | :-- | :-- |
| Schema / field types / geometry / CRS / extent | `gdalraster::ogrinfo()` | Single C++ OGR call, complete authoritative output |
| Layer enumeration | `sf::st_layers()` | Cleaner R object than ogrinfo for multi-layer files |
| GPKG spec metadata tables | `gpkg` package | Native accessors for `gpkg_contents`, `gpkg_geometry_columns`, `gpkg_spatial_ref_sys` |
| Spec compliance validation | `gpkg::gpkg_validate()` | Only tool that checks against the OGC spec |
| SQLite internals (indexes, triggers, pages) | RSQLite/DBI | Direct `sqlite_master` access, no GDAL overhead |
| State/county manifest (GROUP BY) | RSQLite/DBI | Pure SQL aggregation — fastest path to counts |
| Row sampling with geometry | `sf::st_read(query=...)` | Returns proper `sf` object via OGR SQL |
| Field-level statistics | RSQLite/DBI | SQL `MIN/MAX/COUNT/NULLIF` — no memory load |

`ogrinfo` already gave you everything at the GDAL layer. The gap now is **SQLite internals** (indexes, page size, WAL state) and the **field/state-level statistics** needed for the manifest — that's all RSQLite.

***

## Performance Tuning Before Any Large Queries

The GROUP BY across 154M rows will do a full table scan unless `statefp`/`countyfp` are indexed. Set these pragmas on every connection before running aggregations:

```r
library(DBI)
library(RSQLite)
library(gpkg)
library(gdalraster)
library(dplyr)  # for clean manifest manipulation

parcels_path <- "E:/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"

# ── 1. Open connection with read-only flag ──────────────────────────────────
parcels_conn <- DBI::dbConnect(
  RSQLite::SQLite(),
  parcels_path,
  flags = RSQLite::SQLITE_RO  # read-only: no accidental writes
)

# ── 2. Session-level SQLite performance tuning ──────────────────────────────
# WAL is already set from your earlier pragma, but re-assert for this session
DBI::dbExecute(parcels_conn, "PRAGMA journal_mode = WAL;")

# Memory-map up to 8GB of the file directly into address space
# (reduces system call overhead on sequential scans)
DBI::dbExecute(parcels_conn, "PRAGMA mmap_size = 8589934592;")

# Page cache: -N means N kilobytes; 4GB cache keeps hot pages in RAM
DBI::dbExecute(parcels_conn, "PRAGMA cache_size = -4000000;")

# Temp store in memory for GROUP BY / ORDER BY sort spills
DBI::dbExecute(parcels_conn, "PRAGMA temp_store = MEMORY;")
```


***

## Stage 1 — SQLite Internals Audit

Before querying the feature table, audit the database structure. This tells you whether the manifest query will be fast or slow:

```r
# ── 3. Full SQLite object inventory ─────────────────────────────────────────
db_objects <- DBI::dbGetQuery(parcels_conn, "
  SELECT type, name, tbl_name
  FROM sqlite_master
  ORDER BY type, name
")
print(db_objects)

# ── 4. Check existing indexes (critical for manifest query planning) ─────────
indexes <- DBI::dbGetQuery(parcels_conn, "
  SELECT
    m.name    AS index_name,
    m.tbl_name,
    m.sql,
    il.seqno,
    il.name   AS column_name
  FROM sqlite_master m
  JOIN pragma_index_info(m.name) il
  WHERE m.type = 'index'
    AND m.tbl_name = 'lr_parcel_us'
  ORDER BY m.name, il.seqno
")
print(indexes)
# Expect: rtree_lr_parcel_us_geom (spatial index) but likely NO index on statefp/countyfp
# If statefp/countyfp have no index, the manifest query is a full 154M-row scan

# ── 5. Database file stats ───────────────────────────────────────────────────
db_stats <- DBI::dbGetQuery(parcels_conn, "
  SELECT
    (SELECT page_count FROM pragma_page_count())  AS total_pages,
    (SELECT page_size  FROM pragma_page_size())   AS page_size_bytes,
    (SELECT page_count FROM pragma_page_count()) *
    (SELECT page_size  FROM pragma_page_size()) / 1073741824.0 AS db_size_gb,
    (SELECT freelist_count FROM pragma_freelist_count()) AS free_pages,
    (SELECT wal_autocheckpoint FROM pragma_wal_autocheckpoint()) AS wal_autocheckpoint
")
print(db_stats)
```


***

## Stage 2 — GPKG Standard Metadata

Now use the `gpkg` package for the OGC-standard tables — it wraps these much more cleanly than raw `dbReadTable`:

```r
# ── 6. gpkg package: OGC metadata tables ────────────────────────────────────
parcels_gpkg <- gpkg::gpkg_connect(parcels_path)

# gpkg_contents: layer-level metadata (you already have this, but via gpkg accessor)
contents      <- gpkg::gpkg_contents(parcels_gpkg)

# gpkg_geometry_columns: geometry column name, type, SRS
geom_cols     <- gpkg::gpkg_geometry_columns(parcels_gpkg)

# gpkg_spatial_ref_sys: full CRS definitions stored in the file
srs           <- gpkg::gpkg_spatial_ref_sys(parcels_gpkg)

# gpkg_ogr_contents: OGR-cached feature count per layer (fast, no scan needed)
ogr_contents  <- gpkg::gpkg_ogr_contents(parcels_gpkg)
# feature_count should match your ogrinfo output: 154,891,095

# OGC spec validation — flags missing required tables, malformed SRS entries, etc.
diagnostics   <- gpkg::gpkg_validate(parcels_gpkg, diagnostics = TRUE)
print(diagnostics)

gpkg::gpkg_disconnect(parcels_gpkg)
```


***

## Stage 3 — Field-Level Statistics (RSQLite)

This is where RSQLite is strictly superior to anything else — pure SQL aggregations without loading geometry:

```r
# ── 7. Field-level null rates and cardinality (non-geometry columns only) ───
# Run on a sample first to estimate quality before committing to full scan
field_stats <- DBI::dbGetQuery(parcels_conn, "
  SELECT
    COUNT(*)                                          AS total_features,

    -- Partition keys
    COUNT(DISTINCT statefp)                           AS distinct_states,
    COUNT(DISTINCT countyfp)                          AS distinct_counties,
    COUNT(DISTINCT statefp || countyfp)               AS distinct_state_county_combos,

    -- Geometry completeness
    SUM(CASE WHEN geom IS NULL THEN 1 ELSE 0 END)     AS null_geom_count,

    -- Key attribute completeness
    SUM(CASE WHEN parcelid  IS NULL OR parcelid  = '' THEN 1 ELSE 0 END) AS null_parcelid,
    SUM(CASE WHEN totalvalue IS NULL THEN 1 ELSE 0 END) AS null_totalvalue,
    SUM(CASE WHEN saleamt   IS NULL THEN 1 ELSE 0 END)  AS null_saleamt,
    SUM(CASE WHEN yearbuilt IS NULL THEN 1 ELSE 0 END)  AS null_yearbuilt,

    -- Value ranges
    MIN(taxyear)   AS min_taxyear,
    MAX(taxyear)   AS max_taxyear,
    MIN(totalvalue) AS min_totalvalue,
    MAX(totalvalue) AS max_totalvalue,
    MIN(assdacres)  AS min_acres,
    MAX(assdacres)  AS max_acres,

    -- lrversion: check how many distinct data vintages exist
    COUNT(DISTINCT lrversion) AS distinct_lrversions

  FROM lr_parcel_us
")
print(field_stats)
```


***

## Stage 4 — State + County Work Manifest

This is the key query. It will be a full table scan if no index exists on `statefp`/`countyfp` — budget ~15–40 minutes depending on your NVMe vs HDD and the pragma cache settings above:

```r
# ── 8. (Optional but recommended) Create covering index before manifest query
# Only needed if indexes audit above showed none on statefp/countyfp
# Requires a READ-WRITE connection — reconnect without SQLITE_RO flag
# Time cost: ~30-60 min on 100GB, but pays back on every subsequent query

parcels_conn_rw <- DBI::dbConnect(RSQLite::SQLite(), parcels_path)
DBI::dbExecute(parcels_conn_rw, "PRAGMA journal_mode = WAL;")
DBI::dbExecute(parcels_conn_rw, "PRAGMA cache_size  = -4000000;")
DBI::dbExecute(parcels_conn_rw, "PRAGMA temp_store  = MEMORY;")

message("Creating covering index on (statefp, countyfp)...")
system.time(
  DBI::dbExecute(parcels_conn_rw,
    "CREATE INDEX IF NOT EXISTS idx_statefp_countyfp
     ON lr_parcel_us(statefp, countyfp)"
  )
)
DBI::dbDisconnect(parcels_conn_rw)

# Reconnect read-only
parcels_conn <- DBI::dbConnect(RSQLite::SQLite(), parcels_path, flags = RSQLite::SQLITE_RO)
DBI::dbExecute(parcels_conn, "PRAGMA mmap_size  = 8589934592;")
DBI::dbExecute(parcels_conn, "PRAGMA cache_size = -4000000;")
DBI::dbExecute(parcels_conn, "PRAGMA temp_store = MEMORY;")

# ── 9. State + county manifest ───────────────────────────────────────────────
message("Building state/county manifest...")
manifest_raw <- DBI::dbGetQuery(parcels_conn, "
  SELECT
    statefp                           AS state_fips,
    countyfp                          AS county_fips,
    statefp || countyfp               AS geoid_county,   -- 5-digit FIPS
    COUNT(*)                          AS feature_count,
    SUM(CASE WHEN geom IS NULL
             THEN 1 ELSE 0 END)       AS null_geom_count,
    MIN(lrid)                         AS min_lrid,
    MAX(lrid)                         AS max_lrid
  FROM lr_parcel_us
  GROUP BY statefp, countyfp
  ORDER BY statefp, countyfp
")

# ── 10. State-level rollup ───────────────────────────────────────────────────
state_manifest <- manifest_raw |>
  dplyr::group_by(state_fips) |>
  dplyr::summarise(
    county_count    = dplyr::n(),
    feature_count   = sum(feature_count),
    null_geom_count = sum(null_geom_count),
    .groups = "drop"
  ) |>
  dplyr::arrange(dplyr::desc(feature_count)) |>
  dplyr::mutate(
    pct_of_total    = round(feature_count / sum(feature_count) * 100, 2),
    cumulative_pct  = round(cumsum(pct_of_total), 2),
    # Flag large states that may need chunked extraction
    large_state     = feature_count > 5e6
  )

print(state_manifest, n = 60)

# ── 11. Write manifests to disk ──────────────────────────────────────────────
readr::write_csv(manifest_raw,    "manifest_state_county.csv")
readr::write_csv(state_manifest,  "manifest_state_rollup.csv")

DBI::dbDisconnect(parcels_conn)
```


***

## Decision Summary

The scratch work you had was already directionally correct — `ogrinfo` answered the schema question definitively (field names, types, CRS, extent, feature count), `gpkg` covers the OGC compliance layer, and RSQLite owns everything quantitative. The only missing pieces were the **SQLite pragma tuning** before the GROUP BY scan, the **index audit** (which will determine whether the manifest query takes 5 minutes or 45), and the **`SQLITE_RO` flag** on the read connection to prevent accidental writes to your source file.
<span style="display:none">[^2_1][^2_10][^2_11][^2_12][^2_13][^2_14][^2_15][^2_2][^2_3][^2_4][^2_5][^2_6][^2_7][^2_8][^2_9]</span>

<div align="center">⁂</div>

[^2_1]: https://gdal.org/en/stable/drivers/vector/gpkg.html

[^2_2]: https://brgd.eu/blog/geopackage-and-spatialite/

[^2_3]: https://www.reddit.com/r/gis/comments/15t3bpy/cons_to_geopackages/

[^2_4]: https://r.geocompx.org/read-write

[^2_5]: https://cloud.r-project.org/web/packages/gpkg/refman/gpkg.html

[^2_6]: https://www.jumpingrivers.com/blog/large-spatial-data-r-sql/

[^2_7]: https://r-spatial.org/book/09-Large.html

[^2_8]: https://pro.arcgis.com/en/pro-app/latest/help/data/databases/work-with-sqlite-databases-in-arcgis-pro.htm

[^2_9]: https://mapping-in-r-workshop.ryanpeek.org/02_import_export_gpkg

[^2_10]: https://r-spatial.github.io/sf/reference/st_read.html

[^2_11]: https://gdal.org/en/stable/drivers/raster/gpkg.html

[^2_12]: https://pinjiahe.github.io/posts/2020/09/spatial-sql

[^2_13]: https://gdal.org/en/stable/programs/ogrinfo.html

[^2_14]: https://stackoverflow.com/questions/54677495/how-to-read-geopackage-file-with-fid-column-using-rgdal-in-r

[^2_15]: https://jayrobwilliams.com/posts/2020/09/spatial-sql


---

# for step 1 only (combining with prior work also for context):

```R
require(DBI)
require(RSQLite)
require(gpkg)
require(gdalraster)
require(sf)
require(vapour)

parcels_path <- "E:/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"

# get layer(s)
sf::st_layers(parcels_path)
# Driver: GPKG 
# Available layers:
#   layer_name geometry_type  features fields crs_name
# 1 lr_parcel_us Multi Polygon 154891095     51   WGS 84

# vapour seems to be the only method to get the name back in an R manner as a character string/vector with the name(s)
gpkg_layer <- vapour::vapour_layer_names(parcels_path)

# GDAL approach
gdalraster::ogrinfo(dsn = parcels_path)
# INFO: Open of `E:/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg'
#       using driver `GPKG' successful.
# 1: lr_parcel_us (Multi Polygon)

parcels_conn <- DBI::dbConnect(RSQLite::SQLite(), parcels_path, flags = RSQLite::SQLITE_RO)

DBI::dbExecute(parcels_conn, "PRAGMA journal_mode = WAL;")
DBI::dbExecute(parcels_conn, "PRAGMA mmap_size = 8589934592;")
DBI::dbExecute(parcels_conn, "PRAGMA cache_size = -4000000;")
DBI::dbExecute(parcels_conn, "PRAGMA temp_store = MEMORY;")

db_objects <- DBI::dbGetQuery(
  parcels_conn,
  "SELECT type, name, tbl_name FROM sqlite_master ORDER BY type, name"
)
dplyr::glimpse(db_objects)
# Rows: 39
# Columns: 3
# $ type     <chr> "index", "index", "index", "index", "index", "index", "index", "index", "table", "table", "table", "table", "table", "table", "table", "tab…
# $ name     <chr> "sqlite_autoindex_gpkg_contents_1", "sqlite_autoindex_gpkg_contents_2", "sqlite_autoindex_gpkg_extensions_1", "sqlite_autoindex_gpkg_geomet…
# $ tbl_name <chr> "gpkg_contents", "gpkg_contents", "gpkg_extensions", "gpkg_geometry_columns", "gpkg_geometry_columns", "gpkg_ogr_contents", "gpkg_tile_matr…
db_objects
# type                                      name                       tbl_name
# 1    index          sqlite_autoindex_gpkg_contents_1                  gpkg_contents
# 2    index          sqlite_autoindex_gpkg_contents_2                  gpkg_contents
# 3    index        sqlite_autoindex_gpkg_extensions_1                gpkg_extensions
# 4    index  sqlite_autoindex_gpkg_geometry_columns_1          gpkg_geometry_columns
# 5    index  sqlite_autoindex_gpkg_geometry_columns_2          gpkg_geometry_columns
# 6    index      sqlite_autoindex_gpkg_ogr_contents_1              gpkg_ogr_contents
# 7    index       sqlite_autoindex_gpkg_tile_matrix_1               gpkg_tile_matrix
# 8    index   sqlite_autoindex_gpkg_tile_matrix_set_1           gpkg_tile_matrix_set
# 9    table                             gpkg_contents                  gpkg_contents
# 10   table                           gpkg_extensions                gpkg_extensions
# 11   table                     gpkg_geometry_columns          gpkg_geometry_columns
# 12   table                         gpkg_ogr_contents              gpkg_ogr_contents
# 13   table                      gpkg_spatial_ref_sys           gpkg_spatial_ref_sys
# 14   table                          gpkg_tile_matrix               gpkg_tile_matrix
# 15   table                      gpkg_tile_matrix_set           gpkg_tile_matrix_set
# 16   table                              lr_parcel_us                   lr_parcel_us
# 17   table                   rtree_lr_parcel_us_geom        rtree_lr_parcel_us_geom
# 18   table              rtree_lr_parcel_us_geom_node   rtree_lr_parcel_us_geom_node
# 19   table            rtree_lr_parcel_us_geom_parent rtree_lr_parcel_us_geom_parent
# 20   table             rtree_lr_parcel_us_geom_rowid  rtree_lr_parcel_us_geom_rowid
# 21   table                           sqlite_sequence                sqlite_sequence
# 22 trigger     gpkg_tile_matrix_matrix_height_insert               gpkg_tile_matrix
# 23 trigger     gpkg_tile_matrix_matrix_height_update               gpkg_tile_matrix
# 24 trigger      gpkg_tile_matrix_matrix_width_insert               gpkg_tile_matrix
# 25 trigger      gpkg_tile_matrix_matrix_width_update               gpkg_tile_matrix
# 26 trigger      gpkg_tile_matrix_pixel_x_size_insert               gpkg_tile_matrix
# 27 trigger      gpkg_tile_matrix_pixel_x_size_update               gpkg_tile_matrix
# 28 trigger      gpkg_tile_matrix_pixel_y_size_insert               gpkg_tile_matrix
# 29 trigger      gpkg_tile_matrix_pixel_y_size_update               gpkg_tile_matrix
# 30 trigger        gpkg_tile_matrix_zoom_level_insert               gpkg_tile_matrix
# 31 trigger        gpkg_tile_matrix_zoom_level_update               gpkg_tile_matrix
# 32 trigger            rtree_lr_parcel_us_geom_delete                   lr_parcel_us
# 33 trigger            rtree_lr_parcel_us_geom_insert                   lr_parcel_us
# 34 trigger           rtree_lr_parcel_us_geom_update1                   lr_parcel_us
# 35 trigger           rtree_lr_parcel_us_geom_update2                   lr_parcel_us
# 36 trigger           rtree_lr_parcel_us_geom_update3                   lr_parcel_us
# 37 trigger           rtree_lr_parcel_us_geom_update4                   lr_parcel_us
# 38 trigger trigger_delete_feature_count_lr_parcel_us                   lr_parcel_us
# 39 trigger trigger_insert_feature_count_lr_parcel_us                   lr_parcel_us

db_indexes <- DBI::dbGetQuery(
  parcels_conn, 
  "
  SELECT
    m.name AS index_name,
    m.tbl_name,
    m.sql,
    il.seqno,
    il.name AS column_name
  FROM sqlite_master m
  JOIN pragma_index_info(m.name) il
  WHERE m.type = 'index' 
    AND m.tbl_name = 'lr_parcel_us'
  ORDER BY m.name, il.seqno
  "
)
db_indexes
# [1] index_name  tbl_name    sql         seqno       column_name
# <0 rows> (or 0-length row.names)

# no indexes, however, I know that there is a spatial index from previous GDAL/OGR work... at least i thought there was

db_stats <- DBI::dbGetQuery(parcels_conn, "
  SELECT
    (SELECT page_count FROM pragma_page_count())  AS total_pages,
    (SELECT page_size  FROM pragma_page_size())   AS page_size_bytes,
    (SELECT page_count FROM pragma_page_count()) *
    (SELECT page_size  FROM pragma_page_size()) / 1073741824.0 AS db_size_gb,
    (SELECT freelist_count FROM pragma_freelist_count()) AS free_pages,
    (SELECT wal_autocheckpoint FROM pragma_wal_autocheckpoint()) AS wal_autocheckpoint
")
# Error:
#   ! no such table: pragma_wal_autocheckpoint
# Run `rlang::last_trace()` to see where the error occurred.

gdalraster::ogrinfo(dsn = parcels_path, layers = layer)
# INFO: Open of `E:/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg'
#       using driver `GPKG' successful.
# 
# Layer name: lr_parcel_us
# Geometry: Multi Polygon
# Feature Count: 154891095
# Extent: (-166.841139, 13.235464) - (145.829905, 71.389488)
# Layer SRS WKT:
#   GEOGCRS["WGS 84",
#           ENSEMBLE["World Geodetic System 1984 ensemble",
#                    MEMBER["World Geodetic System 1984 (Transit)"],
#                    MEMBER["World Geodetic System 1984 (G730)"],
#                    MEMBER["World Geodetic System 1984 (G873)"],
#                    MEMBER["World Geodetic System 1984 (G1150)"],
#                    MEMBER["World Geodetic System 1984 (G1674)"],
#                    MEMBER["World Geodetic System 1984 (G1762)"],
#                    MEMBER["World Geodetic System 1984 (G2139)"],
#                    MEMBER["World Geodetic System 1984 (G2296)"],
#                    ELLIPSOID["WGS 84",6378137,298.257223563,
#                              LENGTHUNIT["metre",1]],
#                    ENSEMBLEACCURACY[2.0]],
#           PRIMEM["Greenwich",0,
#                  ANGLEUNIT["degree",0.0174532925199433]],
#           CS[ellipsoidal,2],
#           AXIS["geodetic latitude (Lat)",north,
#                ORDER[1],
#                ANGLEUNIT["degree",0.0174532925199433]],
#           AXIS["geodetic longitude (Lon)",east,
#                ORDER[2],
#                ANGLEUNIT["degree",0.0174532925199433]],
#           USAGE[
#             SCOPE["Horizontal component of 3D system."],
#             AREA["World."],
#             BBOX[-90,-180,90,180]],
#           ID["EPSG",4326]]
# Data axis to CRS axis mapping: 2,1
# FID Column = lrid
# Geometry Column NOT NULL = geom
# parcelid: String (0.0)
# parcelid2: String (0.0)
# geoid: String (0.0)
# statefp: String (0.0)
# countyfp: String (0.0)
# taxacctnum: String (0.0)
# taxyear: Integer (0.0)
# usecode: String (0.0)
# usedesc: String (0.0)
# zoningcode: String (0.0)
# zoningdesc: String (0.0)
# numbldgs: Integer (0.0)
# numunits: Integer (0.0)
# yearbuilt: Integer (0.0)
# numfloors: Integer (0.0)
# bldgsqft: Integer (0.0)
# bedrooms: Integer (0.0)
# halfbaths: Integer (0.0)
# fullbaths: Integer (0.0)
# imprvalue: Integer64 (0.0)
# landvalue: Integer64 (0.0)
# agvalue: Integer64 (0.0)
# totalvalue: Integer64 (0.0)
# assdacres: Real (0.0)
# saleamt: Integer64 (0.0)
# saledate: Date
# ownername: String (0.0)
# owneraddr: String (0.0)
# ownercity: String (0.0)
# ownerstate: String (0.0)
# ownerzip: String (0.0)
# parceladdr: String (0.0)
# parcelcity: String (0.0)
# parcelstate: String (0.0)
# parcelzip: String (0.0)
# legaldesc: String (0.0)
# township: String (0.0)
# section: String (0.0)
# qtrsection: String (0.0)
# range: String (0.0)
# plssdesc: String (0.0)
# book: String (0.0)
# page: String (0.0)
# block: String (0.0)
# lot: String (0.0)
# updated: String (0.0)
# lrversion: String (0.0)
# centroidx: Real (0.0)
# centroidy: Real (0.0)
# surfpointx: Real (0.0)
# surfpointy: Real (0.0)

# gpkg approach
parcels_gpkg <- gpkg::gpkg(parcels_path)
# gpkg::gpkg_connect()
gpkg::gpkg_ogr_contents(parcels_gpkg)
diagnostics <- gpkg::gpkg_validate(parcels_gpkg, diagnostics = TRUE)

gpkg_contents <- DBI::dbReadTable(parcels_conn, "gpkg_contents")
gpkg_contents
# table_name data_type   identifier                                  description              last_change     min_x    min_y    max_x    max_y srs_id
# 1 lr_parcel_us  features lr_parcel_us Landrecords.us Parcel Layer. Version 2026_Q1 2026-01-04T06:22:33.187Z -166.8411 13.23546 145.8299 71.38949   4326


# create "state" work manifest
# manifest <- DBI::dbGetQuery(
#   parcels_conn,
#   "SELECT "
#   # TODO
# )
```

Two specific bugs to fix, one important structural finding from your output, and then the complete corrected block.

***

## Bug 1: `pragma_wal_autocheckpoint` — Not a Virtual Table

Not all SQLite pragmas have the `pragma_*()` virtual table form. `wal_autocheckpoint` is one that doesn't — it must be queried as a scalar statement. The ones that **do** work as virtual tables are: `pragma_table_info()`, `pragma_index_info()`, `pragma_database_list()`, `pragma_page_count()`, `pragma_page_size()`, `pragma_freelist_count()`. Fix: query scalar pragmas separately.[^3_1]

## Bug 2: R-tree ≠ B-tree Index in `sqlite_master`

Your `db_indexes` returning 0 rows is **correct behavior** — there are genuinely no B-tree column indexes on `lr_parcel_us`. The spatial index *does exist*, but it's stored as **four R-tree virtual tables** (visible in your `db_objects` output on rows 17–20), not as `type='index'` entries in `sqlite_master`:[^3_2]

```
rtree_lr_parcel_us_geom          ← the R-tree itself
rtree_lr_parcel_us_geom_node     ← internal R-tree nodes
rtree_lr_parcel_us_geom_parent   ← parent node lookup
rtree_lr_parcel_us_geom_rowid    ← rowid ↔ geom mapping
```

This means the R-tree exists for spatial bbox queries via GDAL/OGR, but **there is no B-tree index on `statefp` or `countyfp`** — the manifest GROUP BY will be a full 154M-row table scan regardless.

***

## Corrected + Completed Step 1

```r
require(DBI)
require(RSQLite)
require(gpkg)
require(gdalraster)
require(sf)
require(vapour)
require(dplyr)

parcels_path <- "E:/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"

# ── Layer enumeration ────────────────────────────────────────────────────────

# sf: richest R object (data frame with layer metadata)
sf::st_layers(parcels_path)

# vapour: cleanest way to get layer name as character vector for downstream use
gpkg_layer <- vapour::vapour_layer_names(parcels_path)
# [^3_1] "lr_parcel_us"

# gdalraster: full OGR schema + CRS + field types (authoritative)
gdalraster::ogrinfo(dsn = parcels_path, layers = gpkg_layer)

# ── Connection + read-only session pragmas ───────────────────────────────────
# NOTE: SQLITE_RO prevents PRAGMA journal_mode = WAL from persisting to disk.
# If WAL was already set (via sqlite3 CLI earlier), the mode is already active
# for all new connections. Verify below rather than set.
parcels_conn <- DBI::dbConnect(
  RSQLite::SQLite(),
  parcels_path,
  flags = RSQLite::SQLITE_RO
)

# These pragmas are session-level memory settings — safe on read-only connections
DBI::dbExecute(parcels_conn, "PRAGMA mmap_size  = 8589934592;")  # 8GB mmap
DBI::dbExecute(parcels_conn, "PRAGMA cache_size = -4000000;")    # ~4GB page cache
DBI::dbExecute(parcels_conn, "PRAGMA temp_store = MEMORY;")      # sort spills → RAM

# ── SQLite internals audit ───────────────────────────────────────────────────

# All objects in the database
db_objects <- DBI::dbGetQuery(
  parcels_conn,
  "SELECT type, name, tbl_name FROM sqlite_master ORDER BY type, name"
)

# Separate B-tree indexes from R-tree virtual tables
db_btree_indexes <- db_objects |>
  dplyr::filter(type == "index", tbl_name == "lr_parcel_us")
# → 0 rows: confirms no column indexes on statefp/countyfp

db_rtree_tables <- db_objects |>
  dplyr::filter(type == "table", grepl("^rtree_", name))
# → rtree_lr_parcel_us_geom + 3 support tables: spatial index IS present

# ── DB file statistics (fixed: scalar PRAGMAs queried individually) ──────────
db_stats <- DBI::dbGetQuery(parcels_conn, "
  SELECT
    (SELECT page_count    FROM pragma_page_count())    AS total_pages,
    (SELECT page_size     FROM pragma_page_size())     AS page_size_bytes,
    (SELECT page_count    FROM pragma_page_count()) *
    (SELECT page_size     FROM pragma_page_size())
      / 1073741824.0                                   AS db_size_gb,
    (SELECT freelist_count FROM pragma_freelist_count()) AS free_pages
")

# Scalar-only pragmas — must be queried as standalone statements
journal_mode       <- DBI::dbGetQuery(parcels_conn, "PRAGMA journal_mode")
wal_autocheckpoint <- DBI::dbGetQuery(parcels_conn, "PRAGMA wal_autocheckpoint")
page_size          <- DBI::dbGetQuery(parcels_conn, "PRAGMA page_size")

db_stats <- dplyr::bind_cols(
  db_stats,
  journal_mode       |> dplyr::rename(journal_mode = journal_mode),
  wal_autocheckpoint |> dplyr::rename(wal_autocheckpoint = wal_autocheckpoint),
  page_size          |> dplyr::rename(page_size_check = page_size)
)
print(db_stats)

# ── gpkg package: OGC standard metadata tables ──────────────────────────────
parcels_gpkg <- gpkg::gpkg_connect(parcels_path)

gpkg_contents      <- gpkg::gpkg_contents(parcels_gpkg)
gpkg_geom_cols     <- gpkg::gpkg_geometry_columns(parcels_gpkg)
gpkg_srs           <- gpkg::gpkg_spatial_ref_sys(parcels_gpkg)
gpkg_ogr_contents  <- gpkg::gpkg_ogr_contents(parcels_gpkg)
# feature_count should match ogrinfo: 154,891,095

# OGC spec validation — checks required tables, SRS entries, constraint conformance
gpkg_diagnostics   <- gpkg::gpkg_validate(parcels_gpkg, diagnostics = TRUE)
print(gpkg_diagnostics)

gpkg::gpkg_disconnect(parcels_gpkg)

# ── vapour: fast attribute-only sample (no geometry loaded) ─────────────────
# vapour_read_attributes skips geometry decoding entirely — fastest way to
# inspect field content and check partition key values on a small slice
sample_attrs <- vapour::vapour_read_attributes(
  parcels_path,
  layer    = gpkg_layer,
  limit_n  = 1000,
  offset   = 0,
  sql      = "SELECT lrid, statefp, countyfp, geoid, lrversion, parcelstate
              FROM lr_parcel_us
              LIMIT 1000"
)
sample_df <- as.data.frame(sample_attrs)

# Verify statefp/countyfp look clean (zero-padded 2/3 digit strings)
dplyr::count(sample_df, statefp, sort = TRUE)
dplyr::count(sample_df, parcelstate, sort = TRUE)  # compare against statefp

# Check lrversion uniformity — should all be "2026_Q1"
dplyr::count(sample_df, lrversion)

# ── Structural findings summary ──────────────────────────────────────────────
findings <- list(
  layer_name         = gpkg_layer,
  feature_count      = gpkg_ogr_contents$feature_count,
  fid_column         = "lrid",
  geometry_column    = "geom",
  geometry_type      = "Multi Polygon",
  crs_epsg           = 4326,
  spatial_index      = "R-tree (rtree_lr_parcel_us_geom)",
  btree_indexes      = nrow(db_btree_indexes),       # 0 — full scan needed for GROUP BY
  rtree_support_tbls = nrow(db_rtree_tables),        # 4
  journal_mode       = journal_mode[[^3_1]],            # verify WAL is active
  partition_keys     = c("statefp", "countyfp"),
  manifest_strategy  = if (nrow(db_btree_indexes) == 0)
    "full table scan — consider CREATE INDEX before manifest query"
  else
    "index scan available"
)
str(findings)

DBI::dbDisconnect(parcels_conn)
```


***

## Key Findings from Your Output

The `db_objects` output tells us everything we need to know before moving to the manifest stage:

- **Spatial index**: Present as R-tree virtual tables (rows 17–20) — used only by GDAL/OGR for bbox-filtered reads, invisible to SQL `WHERE statefp = 'XX'` queries
- **No B-tree indexes**: The manifest `GROUP BY statefp, countyfp` across 154M rows will be a full sequential scan — with the 4GB `cache_size` pragma set above, expect 20–50 minutes depending on your storage
- **WAL mode**: Verify `PRAGMA journal_mode` returns `wal` before creating the covering index in the next step — if it returns `delete` the one-time `sqlite3` CLI pragma from earlier didn't persist, and you'll want to set it on an RW connection first

The `vapour_read_attributes()` sample is worth running before the manifest query to confirm `statefp` is consistently 2-character zero-padded (e.g. `"06"` not `"6"`) and that `countyfp` is 3-character — this affects how you construct the `geoid` concatenation in the manifest SQL.

<div align="center">⁂</div>

[^3_1]: https://dev.to/ahmet_gedik778845/sqlite-wal-mode-for-better-concurrent-web-performance-4fck

[^3_2]: https://gdal.org/en/stable/drivers/vector/gpkg.html


---

# trying to provide as much rich result context as possible back for you along the way (and fixing some slight errors):

```R
require(DBI)
require(RSQLite)
require(gpkg)
require(gdalraster)
require(sf)
require(vapour)
require(dplyr)

parcels_path <- "E:/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"

# ── Layer enumeration ────────────────────────────────────────────────────────

# sf: richest R object (data frame with layer metadata)
sf::st_layers(parcels_path)

# vapour: cleanest way to get layer name as character vector for downstream use
gpkg_layer <- vapour::vapour_layer_names(parcels_path)
# [1] "lr_parcel_us"

# gdalraster: full OGR schema + CRS + field types (authoritative)
gdalraster::ogrinfo(dsn = parcels_path, layers = gpkg_layer)

# ── Connection + read-only session pragmas ───────────────────────────────────
# NOTE: SQLITE_RO prevents PRAGMA journal_mode = WAL from persisting to disk.
# If WAL was already set (via sqlite3 CLI earlier), the mode is already active
# for all new connections. Verify below rather than set.
# Response: yes i did this earlier via sqlite3 CLI command also
parcels_conn <- DBI::dbConnect(
  RSQLite::SQLite(),
  parcels_path,
  flags = RSQLite::SQLITE_RO
)

# These pragmas are session-level memory settings — safe on read-only connections
DBI::dbExecute(parcels_conn, "PRAGMA mmap_size  = 8589934592;")  # 8GB mmap
DBI::dbExecute(parcels_conn, "PRAGMA cache_size = -4000000;")    # ~4GB page cache
DBI::dbExecute(parcels_conn, "PRAGMA temp_store = MEMORY;")      # sort spills → RAM

# ── SQLite internals audit ───────────────────────────────────────────────────

# All objects in the database
db_objects <- DBI::dbGetQuery(
  parcels_conn,
  "SELECT type, name, tbl_name FROM sqlite_master ORDER BY type, name"
)
db_objects
# type                                      name                       tbl_name
# 1    index          sqlite_autoindex_gpkg_contents_1                  gpkg_contents
# 2    index          sqlite_autoindex_gpkg_contents_2                  gpkg_contents
# 3    index        sqlite_autoindex_gpkg_extensions_1                gpkg_extensions
# 4    index  sqlite_autoindex_gpkg_geometry_columns_1          gpkg_geometry_columns
# 5    index  sqlite_autoindex_gpkg_geometry_columns_2          gpkg_geometry_columns
# 6    index      sqlite_autoindex_gpkg_ogr_contents_1              gpkg_ogr_contents
# 7    index       sqlite_autoindex_gpkg_tile_matrix_1               gpkg_tile_matrix
# 8    index   sqlite_autoindex_gpkg_tile_matrix_set_1           gpkg_tile_matrix_set
# 9    table                             gpkg_contents                  gpkg_contents
# 10   table                           gpkg_extensions                gpkg_extensions
# 11   table                     gpkg_geometry_columns          gpkg_geometry_columns
# 12   table                         gpkg_ogr_contents              gpkg_ogr_contents
# 13   table                      gpkg_spatial_ref_sys           gpkg_spatial_ref_sys
# 14   table                          gpkg_tile_matrix               gpkg_tile_matrix
# 15   table                      gpkg_tile_matrix_set           gpkg_tile_matrix_set
# 16   table                              lr_parcel_us                   lr_parcel_us
# 17   table                   rtree_lr_parcel_us_geom        rtree_lr_parcel_us_geom
# 18   table              rtree_lr_parcel_us_geom_node   rtree_lr_parcel_us_geom_node
# 19   table            rtree_lr_parcel_us_geom_parent rtree_lr_parcel_us_geom_parent
# 20   table             rtree_lr_parcel_us_geom_rowid  rtree_lr_parcel_us_geom_rowid
# 21   table                           sqlite_sequence                sqlite_sequence
# 22 trigger     gpkg_tile_matrix_matrix_height_insert               gpkg_tile_matrix
# 23 trigger     gpkg_tile_matrix_matrix_height_update               gpkg_tile_matrix
# 24 trigger      gpkg_tile_matrix_matrix_width_insert               gpkg_tile_matrix
# 25 trigger      gpkg_tile_matrix_matrix_width_update               gpkg_tile_matrix
# 26 trigger      gpkg_tile_matrix_pixel_x_size_insert               gpkg_tile_matrix
# 27 trigger      gpkg_tile_matrix_pixel_x_size_update               gpkg_tile_matrix
# 28 trigger      gpkg_tile_matrix_pixel_y_size_insert               gpkg_tile_matrix
# 29 trigger      gpkg_tile_matrix_pixel_y_size_update               gpkg_tile_matrix
# 30 trigger        gpkg_tile_matrix_zoom_level_insert               gpkg_tile_matrix
# 31 trigger        gpkg_tile_matrix_zoom_level_update               gpkg_tile_matrix
# 32 trigger            rtree_lr_parcel_us_geom_delete                   lr_parcel_us
# 33 trigger            rtree_lr_parcel_us_geom_insert                   lr_parcel_us
# 34 trigger           rtree_lr_parcel_us_geom_update1                   lr_parcel_us
# 35 trigger           rtree_lr_parcel_us_geom_update2                   lr_parcel_us
# 36 trigger           rtree_lr_parcel_us_geom_update3                   lr_parcel_us
# 37 trigger           rtree_lr_parcel_us_geom_update4                   lr_parcel_us
# 38 trigger trigger_delete_feature_count_lr_parcel_us                   lr_parcel_us
# 39 trigger trigger_insert_feature_count_lr_parcel_us                   lr_parcel_us

# Separate B-tree indexes from R-tree virtual tables
db_btree_indexes <- db_objects |>
  dplyr::filter(type == "index", tbl_name == "lr_parcel_us")
# → 0 rows: confirms no column indexes on statefp/countyfp
# [1] type     name     tbl_name
# <0 rows> (or 0-length row.names)

db_rtree_tables <- db_objects |>
  dplyr::filter(type == "table", grepl("^rtree_", name))
# → rtree_lr_parcel_us_geom + 3 support tables: spatial index IS present
# type                           name                       tbl_name
# 1 table        rtree_lr_parcel_us_geom        rtree_lr_parcel_us_geom
# 2 table   rtree_lr_parcel_us_geom_node   rtree_lr_parcel_us_geom_node
# 3 table rtree_lr_parcel_us_geom_parent rtree_lr_parcel_us_geom_parent
# 4 table  rtree_lr_parcel_us_geom_rowid  rtree_lr_parcel_us_geom_rowid

# ── DB file statistics (fixed: scalar PRAGMAs queried individually) ──────────
db_stats <- DBI::dbGetQuery(parcels_conn, "
  SELECT
    (SELECT page_count    FROM pragma_page_count())    AS total_pages,
    (SELECT page_size     FROM pragma_page_size())     AS page_size_bytes,
    (SELECT page_count    FROM pragma_page_count()) *
    (SELECT page_size     FROM pragma_page_size())
      / 1073741824.0                                   AS db_size_gb,
    (SELECT freelist_count FROM pragma_freelist_count()) AS free_pages
")
# total_pages page_size_bytes db_size_gb free_pages
# 1    24553043            4096   93.66243          0

# Scalar-only pragmas — must be queried as standalone statements
journal_mode       <- DBI::dbGetQuery(parcels_conn, "PRAGMA journal_mode")
wal_autocheckpoint <- DBI::dbGetQuery(parcels_conn, "PRAGMA wal_autocheckpoint")
page_size          <- DBI::dbGetQuery(parcels_conn, "PRAGMA page_size")

db_stats <- dplyr::bind_cols(
  db_stats,
  journal_mode       |> dplyr::rename(journal_mode = journal_mode),
  wal_autocheckpoint |> dplyr::rename(wal_autocheckpoint = wal_autocheckpoint),
  page_size          |> dplyr::rename(page_size_check = page_size)
)
print(db_stats)
# total_pages page_size_bytes db_size_gb free_pages journal_mode wal_autocheckpoint page_size_check
# 1    24553043            4096   93.66243          0          wal               1000            4096

# ── gpkg package: OGC standard metadata tables ──────────────────────────────
parcels_gpkg <- gpkg::gpkg_connect(parcels_path)

gpkg_contents      <- gpkg::gpkg_contents(parcels_gpkg)
gpkg_contents
# table_name data_type   identifier                                  description              last_change     min_x    min_y    max_x    max_y srs_id
# 1 lr_parcel_us  features lr_parcel_us Landrecords.us Parcel Layer. Version 2026_Q1 2026-01-04T06:22:33.187Z -166.8411 13.23546 145.8299 71.38949   4326

gpkg_geom_cols     <- gpkg::gpkg_geometry_columns(parcels_gpkg)
# Error:
#   ! 'gpkg_geometry_columns' is not an exported object from 'namespace:gpkg'
vapour::vapour_geom_name(parcels_path, layer = gpkg_layer)
# [1] "geom"

gpkg_srs           <- gpkg::gpkg_spatial_ref_sys(parcels_gpkg)
gpkg_srs
# srs_name srs_id organization organization_coordsys_id
# 1  Undefined Cartesian SRS     -1         NONE                       -1
# 2 Undefined geographic SRS      0         NONE                        0
# 3          WGS 84 geodetic   4326         EPSG                     4326
# definition
# 1                                                                                                                                                                                                                                                                                                      undefined
# 2                                                                                                                                                                                                                                                                                                      undefined
# 3 GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]],AXIS["Latitude",NORTH],AXIS["Longitude",EAST],AUTHORITY["EPSG","4326"]]
# description
# 1                          undefined Cartesian coordinate reference system
# 2                         undefined geographic coordinate reference system
# 3 longitude/latitude coordinates in decimal degrees on the WGS 84 spheroid
gpkg_ogr_contents  <- gpkg::gpkg_ogr_contents(parcels_gpkg)
# feature_count should match ogrinfo: 154,891,095
gpkg_ogr_contents
# table_name feature_count
# 1 lr_parcel_us     154891095


# OGC spec validation — checks required tables, SRS entries, constraint conformance
gpkg_diagnostics   <- gpkg::gpkg_validate(parcels_gpkg, diagnostics = TRUE)
print(gpkg_diagnostics)

gpkg::gpkg_disconnect(parcels_gpkg)
# $required_tables
# [1] TRUE
# 
# $has_contents
# [1] TRUE
# 
# $has_spatial_tables
# [1] TRUE

# ── vapour: fast attribute-only sample (no geometry loaded) ─────────────────
# vapour_read_attributes skips geometry decoding entirely — fastest way to
# inspect field content and check partition key values on a small slice
sample_attrs <- vapour::vapour_read_attributes(
  parcels_path,
  layer    = gpkg_layer,
  limit_n  = 1000,
  offset   = 0,
  sql      = "SELECT lrid, statefp, countyfp, geoid, lrversion, parcelstate
              FROM lr_parcel_us
              LIMIT 1000"
)
# Error in `vapour::vapour_read_attributes()`:
#   ! unused argument (offset = 0)
sample_attrs <- vapour::vapour_read_attributes(
  parcels_path,
  layer    = gpkg_layer,
  limit_n  = 1000,
  skip_n   = 0,
  sql      = "SELECT lrid, statefp, countyfp, geoid, lrversion, parcelstate
              FROM lr_parcel_us
              LIMIT 1000"
)
sample_df <- as.data.frame(sample_attrs)
sample_df |> dplyr::glimpse()
# Rows: 1,000
# Columns: 5
# $ statefp     <chr> "39", "39", "39", "39", "39", "39", "39", "27", "27", "27", "27", "27", "27", "27", "27", "27", "27", "27", "27", "27", "27", "27", "27"…
# $ countyfp    <chr> "057", "057", "057", "057", "057", "057", "057", "035", "035", "035", "035", "035", "035", "035", "035", "035", "035", "035", "035", "03…
# $ geoid       <chr> "39057", "39057", "39057", "39057", "39057", "39057", "39057", "27035", "27035", "27035", "27035", "27035", "27035", "27035", "27035", "…
# $ lrversion   <chr> "2026.1", "2026.1", "2026.1", "2026.1", "2026.1", "2026.1", "2026.1", "2026.1", "2026.1", "2026.1", "2026.1", "2026.1", "2026.1", "2026.…
# $ parcelstate <chr> NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, …

# Verify statefp/countyfp look clean (zero-padded 2/3 digit strings)
dplyr::count(sample_df, statefp, sort = TRUE)
# statefp   n
# 1      27 240
# 2      39 204
# 3      55 137
# 4      29 136
# 5      13 134
# 6      25 116
# 7      01  33
dplyr::count(sample_df, parcelstate, sort = TRUE)  # compare against statefp
# parcelstate    n
# 1        <NA> 1000

# Check lrversion uniformity — should all be "2026_Q1"
dplyr::count(sample_df, lrversion)
# lrversion    n
# 1    2026.1 1000

# ── Structural findings summary ──────────────────────────────────────────────
findings <- list(
  layer_name         = gpkg_layer,
  feature_count      = gpkg_ogr_contents$feature_count,
  fid_column         = "lrid",
  geometry_column    = "geom",
  geometry_type      = "Multi Polygon",
  crs_epsg           = 4326,
  spatial_index      = "R-tree (rtree_lr_parcel_us_geom)",
  btree_indexes      = nrow(db_btree_indexes),       # 0 — full scan needed for GROUP BY
  rtree_support_tbls = nrow(db_rtree_tables),        # 4
  journal_mode       = journal_mode[[1]],            # verify WAL is active
  partition_keys     = c("statefp", "countyfp"),
  manifest_strategy  = if (nrow(db_btree_indexes) == 0)
    "full table scan — consider CREATE INDEX before manifest query"
  else
    "index scan available"
)
# str(findings)
# List of 12
# $ layer_name        : chr "lr_parcel_us"
# $ feature_count     : int 154891095
# $ fid_column        : chr "lrid"
# $ geometry_column   : chr "geom"
# $ geometry_type     : chr "Multi Polygon"
# $ crs_epsg          : num 4326
# $ spatial_index     : chr "R-tree (rtree_lr_parcel_us_geom)"
# $ btree_indexes     : int 0
# $ rtree_support_tbls: int 4
# $ journal_mode      : chr "wal"
# $ partition_keys    : chr [1:2] "statefp" "countyfp"
# $ manifest_strategy : chr "full table scan — consider CREATE INDEX before manifest query"

DBI::dbDisconnect(parcels_conn)
```

Excellent Step 1 results — very clean. Let me synthesize the critical findings, then move directly into Step 2.

***

## Step 1 Findings Summary

| Finding | Value | Implication |
| :-- | :-- | :-- |
| WAL mode | ✅ Active | Parallel readers safe |
| B-tree indexes | ❌ None on partition keys | Manifest = full 154M-row scan |
| `statefp` format | `"39"`, `"01"` — zero-padded 2-char | ✅ Clean, use directly |
| `countyfp` format | `"057"`, `"035"` — zero-padded 3-char | ✅ Clean, use directly |
| `geoid` | `"39057"` — already present, pre-concatenated | Use as-is, no `statefp \|\| countyfp` needed |
| `parcelstate` | 100% NULL in sample | ❌ Unusable — `statefp` is sole state key |
| `lrversion` | `"2026.1"` (not `"2026_Q1"`) | Minor: filename vs field value differ |
| File size | 93.66 GB, 0 free pages | No fragmentation, tight packing |
| `gpkg::gpkg_geometry_columns()` | ❌ Not exported | → Use `DBI::dbReadTable()` directly |
| `vapour_read_attributes()` offset | `skip_n` not `offset` | Fixed in your code already |


***

## Step 2 — Index Creation + Manifest

The index creation needs an RW connection. It will be the single longest-running operation before the manifest query becomes fast — on a cold 93GB file expect **45–90 minutes** on NVMe.

```r
# ── Step 2a: Geometry columns (corrected — gpkg_geometry_columns not exported) ──
parcels_conn_ro <- DBI::dbConnect(RSQLite::SQLite(), parcels_path, flags = RSQLite::SQLITE_RO)
geom_cols <- DBI::dbReadTable(parcels_conn_ro, "gpkg_geometry_columns")
geom_cols
#   table_name column_name geometry_type_name srs_id z m
# 1 lr_parcel_us        geom       MULTIPOLYGON   4326 2 0
DBI::dbDisconnect(parcels_conn_ro)

# ── Step 2b: Create covering B-tree index (RW connection required) ────────────
# This is a one-time cost that pays back on every subsequent per-state query.
# Safe to run: WAL mode means GDAL/OGR readers can still access the file
# concurrently during index build.
parcels_conn_rw <- DBI::dbConnect(RSQLite::SQLite(), parcels_path)
DBI::dbExecute(parcels_conn_rw, "PRAGMA journal_mode  = WAL;")
DBI::dbExecute(parcels_conn_rw, "PRAGMA cache_size    = -4000000;")   # 4GB
DBI::dbExecute(parcels_conn_rw, "PRAGMA temp_store    = MEMORY;")
DBI::dbExecute(parcels_conn_rw, "PRAGMA mmap_size     = 8589934592;") # 8GB

message("Building covering index on (statefp, countyfp)...")
# Use geoid too since it's pre-computed and is the natural partition key join target
t_index <- system.time({
  DBI::dbExecute(parcels_conn_rw, "
    CREATE INDEX IF NOT EXISTS idx_parcel_state_county
    ON lr_parcel_us (statefp, countyfp, geoid)
  ")
})
message(sprintf("Index built in %.1f minutes", t_index["elapsed"] / 60))

DBI::dbDisconnect(parcels_conn_rw)

# Verify index is now visible in sqlite_master
parcels_conn <- DBI::dbConnect(RSQLite::SQLite(), parcels_path, flags = RSQLite::SQLITE_RO)
DBI::dbExecute(parcels_conn, "PRAGMA mmap_size  = 8589934592;")
DBI::dbExecute(parcels_conn, "PRAGMA cache_size = -4000000;")
DBI::dbExecute(parcels_conn, "PRAGMA temp_store = MEMORY;")

new_indexes <- DBI::dbGetQuery(parcels_conn, "
  SELECT name, tbl_name, sql
  FROM sqlite_master
  WHERE type = 'index' AND tbl_name = 'lr_parcel_us'
")
print(new_indexes)
# Should now show: idx_parcel_state_county

# Confirm query planner will use it
query_plan <- DBI::dbGetQuery(parcels_conn, "
  EXPLAIN QUERY PLAN
  SELECT statefp, countyfp, COUNT(*)
  FROM lr_parcel_us
  GROUP BY statefp, countyfp
")
print(query_plan)
# Look for: USING INDEX idx_parcel_state_county
# If you see SCAN TABLE lr_parcel_us — index wasn't picked up, check creation

# ── Step 2c: State + county manifest ─────────────────────────────────────────
message("Building state/county manifest...")
t_manifest <- system.time({
  manifest_raw <- DBI::dbGetQuery(parcels_conn, "
    SELECT
      statefp                                          AS state_fips,
      countyfp                                         AS county_fips,
      geoid                                            AS geoid_county,
      COUNT(*)                                         AS feature_count,
      SUM(CASE WHEN geom IS NULL THEN 1 ELSE 0 END)   AS null_geom_count,
      MIN(lrid)                                        AS min_lrid,
      MAX(lrid)                                        AS max_lrid
    FROM lr_parcel_us
    GROUP BY statefp, countyfp, geoid
    ORDER BY statefp, countyfp
  ")
})
message(sprintf("Manifest built in %.1f minutes", t_manifest["elapsed"] / 60))

# ── Step 2d: State-level rollup ───────────────────────────────────────────────
state_manifest <- manifest_raw |>
  dplyr::group_by(state_fips) |>
  dplyr::summarise(
    county_count    = dplyr::n(),
    feature_count   = sum(feature_count),
    null_geom_count = sum(null_geom_count),
    min_lrid        = min(min_lrid),
    max_lrid        = max(max_lrid),
    .groups = "drop"
  ) |>
  dplyr::arrange(dplyr::desc(feature_count)) |>
  dplyr::mutate(
    pct_of_total   = round(feature_count / sum(feature_count) * 100, 3),
    cumulative_pct = round(cumsum(pct_of_total), 3),
    # Flag states likely to exceed ~500MB parquet output (rough heuristic: >4M parcels)
    large_state    = feature_count > 4e6,
    # Approximate expected parquet size at ~600 bytes/feature compressed
    est_parquet_mb = round(feature_count * 600 / 1048576)
  )

print(state_manifest, n = 60)

# ── Step 2e: Sanity checks ────────────────────────────────────────────────────
stopifnot(
  # Total features must match gpkg_ogr_contents
  sum(manifest_raw$feature_count) == 154891095L,
  # No NULL geoids (would break partition paths)
  sum(is.na(manifest_raw$geoid_county)) == 0,
  # geoid must always equal statefp || countyfp
  all(manifest_raw$geoid_county == paste0(manifest_raw$state_fips, manifest_raw$county_fips)),
  # statefp always 2 chars
  all(nchar(manifest_raw$state_fips) == 2),
  # countyfp always 3 chars
  all(nchar(manifest_raw$county_fips) == 3)
)
message("All manifest sanity checks passed.")

# ── Step 2f: Persist manifests ───────────────────────────────────────────────
readr::write_csv(manifest_raw,   "manifest_state_county.csv")
readr::write_csv(state_manifest, "manifest_state_rollup.csv")
message(sprintf(
  "Manifest: %d states, %d state-county combos, %d total features",
  dplyr::n_distinct(manifest_raw$state_fips),
  nrow(manifest_raw),
  sum(manifest_raw$feature_count)
))

DBI::dbDisconnect(parcels_conn)
```


***

## Two Things Worth Watching For

**`EXPLAIN QUERY PLAN` output**: if it shows `SCAN TABLE lr_parcel_us` instead of `USING INDEX idx_parcel_state_county`, SQLite's query planner decided a full scan was cheaper (possible on a GROUP BY with high cardinality). In that case, force it with `INDEXED BY`:

```sql
SELECT statefp, countyfp, geoid, COUNT(*)
FROM lr_parcel_us INDEXED BY idx_parcel_state_county
GROUP BY statefp, countyfp, geoid
```

**`parcelstate` being 100% NULL** in the 1,000-row sample is worth confirming isn't just a leading-rows artifact. A quick spot check before the full manifest run costs nothing:

```r
vapour::vapour_read_attributes(
  parcels_path,
  sql = "SELECT COUNT(*) AS total,
                SUM(CASE WHEN parcelstate IS NULL OR parcelstate = '' THEN 1 ELSE 0 END) AS null_count
         FROM lr_parcel_us"
)
# If null_count == total: confirmed entirely unpopulated — drop from parquet schema
```


---

# The index creation needs an RW connection. It will be the single longest-running operation before the manifest query becomes fast — on a cold 93GB file expect 45–90 minutes on NVMe.

and is this worth it? im assuming it is worth it as currently the two states I did the ogr2ogr for (without querying out or reshaping the schema for the attribute fields, and just using OGRSQL to filter the state bbox and statefp fields to a) use the spatial index and then b) ensure only the correct state fips code for the attribute field values) each took about that same amount of time each, but in turn produces parquet's by state (see attache for both pwsh and R specific implementations, I used the pwsh script `run_georgia_parquet_direct.ps1` for the georgia one and altered it for the north carolina one and the R functions were used for pmtiles specific work, but also include R functions mirroring the pwsh work with GDAL also but this is all scratch work that will be replaced with a new more optimized setup for the various workloads, etc.)

also, while getting those scripts from the old folder which also is where the actual gpkg is stored, i noticed new files alongside the gpkg now:

```pwsh
 E:\\GEODATA\\us_parcels :: git(main)                                                               /npm 24.14.1 20:45:27 
➜ ls *LR_*                 

        Directory: E:\\GEODATA\\us_parcels


Mode                LastWriteTime         Length Name
----                -------------         ------ ----
-a---        2026-04-08   8:03 PM   100569264128   LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg
-a---        2026-04-08   8:05 PM          32768   LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg-shm
-a---        2026-04-08   8:05 PM              0   LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg-wal
```

Now I have the full picture from all three files. Let me address everything.

***

## The WAL Files: What You're Seeing

The three files you're seeing are **exactly correct and expected**:

```
LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg      ← main database (100.57 GB)
LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg-shm  ← shared memory index (32 KB, fixed size)
LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg-wal  ← write-ahead log (0 bytes = clean/checkpointed)
```

The `-shm` and `-wal` files are the WAL mode artifacts that appeared the moment you ran `PRAGMA journal_mode = WAL` via the `sqlite3` CLI. The critical number here is the WAL file being **0 bytes** — this means the WAL has been fully checkpointed back to the main database, which is the cleanest possible state. No uncommitted data, no risk of corruption. These companion files will persist as long as WAL mode is active and must always travel with the `.gpkg` — never delete or move the `.gpkg` without the `-shm`/`-wal` files.[^5_1]

***

## Is the Index Worth It?

**Yes, unambiguously** — but the reasoning from your existing scripts reveals a subtlety worth addressing first.

Looking at your `run_georgia_parquet_direct.ps1` and `pipeline_functions.R`, you're already doing the right thing with the dual-filter strategy:[^5_2][^5_3]

```powershell
"-spat", $bbox[^5_0], $bbox[^5_1], $bbox[^5_2], $bbox[^5_3],   # R-tree spatial pre-filter
"-where", "statefp='13'"                             # attribute post-filter
```

This is the optimal `ogr2ogr` approach — `-spat` hits the existing R-tree to narrow candidates spatially, then `-where` does a cheap string comparison on the surviving rows. The ~45–90 minutes per state you're seeing is **entirely expected** given:[^5_2]

1. 154M features × sequential disk reads off a 93GB file
2. Geometry decoding (WKB → OGR geometry) for every feature
3. `SORT_BY_BBOX=YES` in your lco — this builds a *second* temporary R-tree in the output for spatial sorting, which is the dominant cost

The index question then depends on **what it buys you**:


| Use case | Index helps? | Why |
| :-- | :-- | :-- |
| `ogr2ogr -spat + -where` (your current approach) | ❌ Marginally | GDAL uses the R-tree, not a B-tree, for spatial pre-filter. The `-where` scan happens only on R-tree candidates |
| RSQLite `GROUP BY statefp, countyfp` for manifest | ✅ Significantly | Pure SQL scan with no geometry involved — index can serve the GROUP BY entirely from the index B-tree without touching the main table |
| DuckDB `ST_Read()` sequential extraction | ❌ Not at all | DuckDB reads GPKG via OGR, same path as ogr2ogr |
| `SELECT COUNT(*) WHERE statefp='13'` ad-hoc queries | ✅ Yes | Index lookup vs full table scan |

**Verdict**: Create the index **only for the manifest query**. It won't speed up your `ogr2ogr` extractions, which are already using the optimal read path via the R-tree.

***

## Issues Found in Your Existing Scripts

Reading through `pipeline_functions.R` and `pipeline_functions.R` carefully:[^5_4][^5_2]

**1. `GEOMETRY_ENCODING=WKB` missing from `pipeline_functions.R`**
Your PowerShell script has it, but the R `extract_state_parquet()` function doesn't pass `-lco GEOMETRY_ENCODING=WKB`. Without it, GDAL defaults to `GEOARROW` encoding in recent GDAL versions, which isn't universally read by DuckDB's `read_parquet()` or `freestiler`. Add it for consistency:[^5_3][^5_2]

```r
args <- c(
  "-f", "Parquet",
  "-lco", "COMPRESSION=ZSTD",
  "-lco", "COMPRESSION_LEVEL=9",
  "-lco", "GEOMETRY_ENCODING=WKB",   # ← add this
  "-lco", "ROW_GROUP_SIZE=50000",
  ...
)
```

**2. `USE_PARQUET_GEO_TYPES=NO` absent from R function**
Present in the PowerShell script, missing from `extract_state_parquet()`. This forces legacy WKB-in-binary-column layout vs the newer GeoArrow-native Parquet types. Since your `freestiler` pipeline uses `source_crs = "EPSG:4326"` explicitly and reads via DuckDB, `NO` is the safer default for broad compatibility.[^5_4][^5_3][^5_2]

**3. `COMPRESSION_LEVEL=9` is likely over-compressed**
ZSTD level 9 on spatial data gives ~3–5% better compression vs level 3, at ~4× the CPU time. For a pipeline that runs once and reads many times, level 3–5 is the right trade-off:

```r
"-lco", "COMPRESSION_LEVEL=3",  # 3-5 recommended; 9 only if storage cost matters more than build time
```

**4. Missing states in `STATE_BOUNDS`**
Your `STATE_BOUNDS` list  covers ~35 states but is missing: `ME`, `NH`, `VT`, `RI`, `NY` (present), `NE`, `ND`, `SD`, `MT`, `WY`, `NM`, `NV`, `UT`, `OR`, `AK`, `HI`, `WV`, `MS`, `AL` (present), `SC`, `NC` (present), `CT` (present). Worth completing before the full 50-state run rather than hitting a `NULL` bounds error mid-pipeline.[^5_2]

**5. `generate_pmtiles.R` has unclosed braces**[^5_4]
Every helper function (`.state_parquet`, `.county_parquet`, `.state_pmtiles`, `.county_pmtiles`) is missing its closing `}`. This is likely a copy/paste artifact — the functions won't parse as written.

**6. `parallel::mclapply` won't work on Windows**[^5_4]
`generate_all_county_pmtiles()` uses `parallel::mclapply` with `mc.cores`, which uses `fork()` — not available on Windows. Since you're running PowerShell on Windows (pixi environment), replace with:

```r
generate_all_county_pmtiles <- function(state, workers = 4L) {
  county_dirs <- list.dirs(
    sprintf("data/geoparquet/state=%s", state),
    recursive = FALSE, full.names = FALSE
  )
  counties <- sub("county=", "", county_dirs[grepl("^county=", county_dirs)])

  message("generating PMTiles for ", length(counties), " counties (", workers, " workers)")

  cl <- parallel::makeCluster(workers, type = "PSOCK")  # Windows-safe
  on.exit(parallel::stopCluster(cl), add = TRUE)

  parallel::parLapply(cl, counties, function(ct) {
    tryCatch(
      generate_county_pmtiles(state, ct),
      error = function(e) message(" FAILED county=", ct, ": ", conditionMessage(e))
    )
  })
  invisible(NULL)
}
```

<span style="display:none">[^5_5][^5_6]</span>

<div align="center">⁂</div>

[^5_1]: https://dev.to/ahmet_gedik778845/sqlite-wal-mode-for-better-concurrent-web-performance-4fck

[^5_2]: pipeline_functions.R

[^5_3]: run_georgia_parquet_direct.ps1

[^5_4]: generate_pmtiles.R

[^5_5]: image-4.jpg

[^5_6]: image-5.jpg


---

# for all of your recommendations about existing code, none of this code is going to be used at all and was all generated by AI, the only code worth scrutiny and assessment is what was actually run which is the pwsh script or more specifically just the command(s):

```pwsh
# note this points to a VRT b/c i wanted to point to the actual gpkg in a manner non-specific to my paths/machine and also without having to use symlinks, etc.
# also note, this script was most recently used for northcarolina, but was also run for georgia but with different bbox/statefips and output file inputs at the top defined
$out = "data/output/geoparquet/state=37/parcels.parquet"
$vrt = "data/sources/parcels.vrt"
$bbox = @("-84.32", "33.84", "-75.46", "36.59")
$statefips = "37"

$env:OGR_SQLITE_PRAGMA = "mmap_size=107374182400,cache_size=-4194304,temp_store=MEMORY,journal_mode=OFF"
$env:OGR_GPKG_NUM_THREADS = "4"
$env:GDAL_CACHEMAX = "2048"


$ogrArgs = @(
  "-f", "Parquet",
  "-lco", "COMPRESSION=ZSTD",
  "-lco", "COMPRESSION_LEVEL=9",
  "-lco", "GEOMETRY_ENCODING=WKB",
  "-lco", "ROW_GROUP_SIZE=50000",
  "-lco", "WRITE_COVERING_BBOX=YES",
  "-lco", "SORT_BY_BBOX=YES",
  "-lco", "USE_PARQUET_GEO_TYPES=NO",
  "-nln", "parcels",
  "-spat", $bbox[0], $bbox[1], $bbox[2], $bbox[3],
  "-where", "statefp='$statefips'",
  "-progress", "-overwrite", $out, $vrt, "parcels"
)

pixi run ogr2ogr @ogrArgs
$exitCode = $LASTEXITCODE

Remove-Item Env:OGR_SQLITE_PRAGMA -ErrorAction SilentlyContinue
Remove-Item Env:OGR_GPKG_NUM_THREADS -ErrorAction SilentlyContinue
Remove-Item Env:GDAL_CACHEMAX -ErrorAction SilentlyContinue

exit $exitCode
```

and the VRT

```xml
<OGRVRTDataSource>
  <OGRVRTLayer name="parcels">
    <SrcDataSource>E:/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg</SrcDataSource>
    <SrcLayer>lr_parcel_us</SrcLayer>
    <GeometryType>wkbMultiPolygon</GeometryType>
  </OGRVRTLayer>
</OGRVRTDataSource>
```

and lastly, just to show you the output was valid:

```pwsh
➜ gpq validate data/output/geoparquet/state=13/parcels.parquet

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

➜ gpq validate data/output/geoparquet/state=37/parcels.parquet

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
```

besides the work we are doing with the adjustments to optimize the gpkg and collect metadata, etc. up-front, regarding these actual ogr2ogr commands/how to properly setup the resulting output parquet's, the one thing that could be optimized further relating to these state wide examples would be the row_group_size which i just used an arbitrary value for, but additionally, im leaning towards a more optimial approach that would involve a)  potentially altering the pipeline to instead leverage an intermediate initial extract by state to FLATGEOBUF which would allow downstream work to work against a more modern and optimal and smaller data file than always circling back to the original gpkg everytime and support better iterative work and discovery etc. but also could keep these FGBs as the GDAL parquet driver may not always be available for those wanting to get the data etc. and b) end resulting parquet's partitioned by COUNTY and not just state (also my state=13 etc. naming isnt even proper hive partitioning given the fields stayed the same as gpkg source, new approach should clean up and revamp the schemas better and use real hive paritioning for the tigris blob storage)

thoughts?

Good — let's only work from what was actually run. The VRT + ogr2ogr command is well-constructed. Let me give a precise assessment of what's optimal, what's suboptimal, and then lay out the revised two-stage architecture you're describing.

***

## Assessment of the Current Command

```powershell
$env:OGR_SQLITE_PRAGMA = "mmap_size=107374182400,cache_size=-4194304,temp_store=MEMORY,journal_mode=OFF"
```

**`journal_mode=OFF` note**: This is fine for reads-only sessions, but it's a write-path pragma — it doesn't meaningfully affect read performance since WAL mode is already set at the file level. Harmless but unnecessary.

**`OGR_GPKG_NUM_THREADS=4`**: Good. `ALL_CPUS` is better if you have ≥8 cores — this controls the Arrow batch geometry decoder thread count.

**`COMPRESSION_LEVEL=9`**: The single most impactful thing to change. ZSTD level 9 vs level 3 on geospatial polygon data gives roughly 3–5% better compression ratio at ~4× the CPU time. For a 50-state pipeline run once, that's real wall-clock cost for almost no storage benefit. **Use level 3**.

**`SORT_BY_BBOX=YES` + `WRITE_COVERING_BBOX=YES`**: Correct and important to keep — these are what make row group spatial statistics meaningful for downstream bbox pushdown in DuckDB.

**`USE_PARQUET_GEO_TYPES=NO`**: Correct for WKB compatibility with DuckDB `read_parquet()`, freestiler, and anything that doesn't have the latest GeoArrow runtime.

**`-spat` + `-where` dual filter**: This is the right pattern. `-spat` invokes the GPKG R-tree, `-where` post-filters on `statefp` from the spatial candidates. Both 20/20 `gpq validate` passes confirm the output is spec-compliant GeoParquet.[^6_1]

***

## ROW_GROUP_SIZE Optimization

`50000` isn't wrong, but it's arbitrary. The right value depends on the level of partitioning. The core trade-off is:

- **Too small**: Many row groups → large footer metadata → more seeks for full scans
- **Too large**: Few row groups → poor spatial selectivity (covering bbox spans too many irrelevant features per group)

For **state-level** single-file parquets, with `SORT_BY_BBOX=YES` producing Hilbert-ordered output, the GeoParquet community recommendation converges around **65,536–150,000**. At state scale (Georgia ~5M, NC ~4.5M features), 100K gives 45–50 row groups per file — enough granularity for spatial filtering without excessive footer overhead.[^6_2]

For **county-level** parquets (the end target), county feature counts vary by 3 orders of magnitude: rural counties like Echols GA (~3K) vs Fulton GA (~370K). A fixed row group size is a poor fit here. The practical approach is to target **~8–12 row groups per file**:

```
row_group_size = max(16384, ceil(feature_count / 10))
```

This isn't something `ogr2ogr` can compute dynamically — it's another argument for the DuckDB-driven county partitioning step described below.

***

## The Two-Stage Architecture

Your instinct is correct on both counts. Here's the full reasoning:

### Stage A: GPKG → FlatGeoBuf per state (one-time archival extract)

FGB is the right intermediate for several reasons:

- The Hilbert-packed spatial index is built directly into the file — no companion files, no SQLite overhead
- ~40–60% smaller than equivalent GPKG for the same data (no SQLite page structure)
- Streamable over HTTP range requests (relevant for later Tigris serving)
- Universally readable without the GDAL Arrow/Parquet driver
- Allows anyone to work with the state extract with just GDAL/QGIS/ogr2ogr

The command delta from your current script is minimal — swap the output format and drop the Parquet-specific lcos:

```powershell
$env:OGR_SQLITE_PRAGMA = "mmap_size=107374182400,cache_size=-4194304,temp_store=MEMORY,journal_mode=OFF"
$env:OGR_GPKG_NUM_THREADS = "ALL_CPUS"
$env:GDAL_CACHEMAX = "2048"

$ogrArgs = @(
  "-f", "FlatGeoBuf",
  "-lco", "SPATIAL_INDEX=YES",       # Hilbert R-tree packed into FGB
  "-lco", "DESCRIPTION=LandRecords US Parcels 2026_Q1",
  "-nln", "parcels",
  "-spat", $bbox[^6_0], $bbox[^6_1], $bbox[^6_2], $bbox[^6_3],
  "-where", "statefp='$statefips'",
  "-progress", "-overwrite",
  $out_fgb, $vrt, "parcels"
)
```

FGB time will be faster than Parquet because there's no geometry sort, no compression computation, and no Arrow schema translation — it's essentially a direct WKB copy with index build.

### Stage B: FGB → County GeoParquets (DuckDB, repeatable)

This is where the schema cleanup, proper hive partitioning, and dynamic row group sizing all happen. DuckDB's spatial extension reads FGB via `ST_Read()`, which is much faster than re-reading the 93GB GPKG:

```sql
-- Run per state after Stage A completes
INSTALL spatial; LOAD spatial;
INSTALL httpfs;  LOAD httpfs;

-- Tigris config
SET s3_endpoint    = 'fly.storage.tigris.dev';
SET s3_access_key_id     = getenv('TIGRIS_ACCESS_KEY');
SET s3_secret_access_key = getenv('TIGRIS_SECRET_KEY');
SET s3_region      = 'auto';

-- Schema cleanup + county partition write
COPY (
  SELECT
    -- drop uniform/null columns (lrversion=2026.1 everywhere, parcelstate=NULL)
    * EXCLUDE (parcelstate, lrversion, statefp),
    -- NOTE: countyfp stays in the data for self-describing files,
    -- even though it's also encoded in the partition path
  FROM ST_Read('data/fgb/state=13/parcels.fgb')
  -- statefp already filtered by Stage A, countyfp is the remaining partition key
) TO 's3://your-bucket/parcels/state=13/'
(
  FORMAT        PARQUET,
  PARTITION_BY  (countyfp),
  ROW_GROUP_SIZE 65536,       -- DuckDB will size per county file, adjust per file
  COMPRESSION   'zstd',
  OVERWRITE_OR_IGNORE 1
);
```

The resulting Tigris layout:

```
s3://bucket/parcels/
  state=13/
    countyfp=001/
      data_0.parquet
    countyfp=121/        ← Fulton
      data_0.parquet
  state=37/
    countyfp=001/
      data_0.parquet
```

DuckDB predicate pushdown against this from anywhere:

```sql
SELECT * FROM read_parquet(
  's3://bucket/parcels/**/*.parquet',
  hive_partitioning = true
)
WHERE statefp = '13' AND countyfp = '121'
-- reads only state=13/countyfp=121/data_0.parquet
```


***

## Schema Cleanup — What to Drop

From the audit so far, the confirmed drops are:


| Column | Reason |
| :-- | :-- |
| `parcelstate` | 100% NULL confirmed in sample |
| `lrversion` | Uniform `"2026.1"` across all rows — encode in file metadata instead |
| `statefp` | Becomes the hive partition key — removed from column data per Hive convention OR kept for self-describing reads (your call) |

Columns worth keeping even though they look redundant: `geoid` (pre-joined 5-digit FIPS, useful for TIGER/FEMA joins), `centroidx`/`centroidy` (pre-computed, avoids geometry reads for point-in-polygon lookups), `surfpointx`/`surfpointy` (same rationale).

Before committing to drops on the full pipeline, run the field-level null audit from Step 2 against the GA or NC parquet you already have — it's fast against the already-extracted files and will catch any other sparsely-populated columns worth dropping:

```r
library(duckdb)
con <- duckdb::dbConnect(duckdb::duckdb())
duckdb::dbExecute(con, "INSTALL spatial; LOAD spatial;")

null_audit <- duckdb::dbGetQuery(con, "
  SELECT
    COUNT(*) AS total,
    SUM(CASE WHEN parcelid   IS NULL THEN 1 ELSE 0 END) AS null_parcelid,
    SUM(CASE WHEN zoningcode IS NULL THEN 1 ELSE 0 END) AS null_zoningcode,
    SUM(CASE WHEN legaldesc  IS NULL THEN 1 ELSE 0 END) AS null_legaldesc,
    SUM(CASE WHEN usecode    IS NULL THEN 1 ELSE 0 END) AS null_usecode,
    SUM(CASE WHEN ownername  IS NULL THEN 1 ELSE 0 END) AS null_ownername,
    SUM(CASE WHEN totalvalue IS NULL THEN 1 ELSE 0 END) AS null_totalvalue,
    SUM(CASE WHEN yearbuilt  IS NULL THEN 1 ELSE 0 END) AS null_yearbuilt,
    SUM(CASE WHEN saleamt    IS NULL THEN 1 ELSE 0 END) AS null_saleamt,
    SUM(CASE WHEN taxacctnum IS NULL THEN 1 ELSE 0 END) AS null_taxacctnum,
    SUM(CASE WHEN parcelstate IS NULL THEN 1 ELSE 0 END) AS null_parcelstate
  FROM read_parquet('data/output/geoparquet/state=13/parcels.parquet')
")
print(null_audit)
duckdb::dbDisconnect(con)
```

This gives you the full null rate picture across both already-extracted states before finalizing the schema for the 50-state run.

<div align="center">⁂</div>

[^6_1]: run_georgia_parquet_direct.ps1

[^6_2]: https://github.com/opengeospatial/geoparquet/blob/main/format-specs/distributing-geoparquet.md


---

## ZSTD Compression Level — Setting the Record Straight

You're right to push back, and I was wrong to flatly say "use level 3." Let me explain the actual nuance rather than give another arbitrary recommendation.

The GeoParquet spec's recommendation of **level 15** is specifically for **distribution artifacts** — files that will be downloaded repeatedly by end users. The reasoning is sound: compression is a one-time write cost, decompression happens on every read, and a critically important property of ZSTD is that **decompression speed is roughly constant regardless of compression level** — only compression (write) speed varies dramatically. This is unlike gzip/deflate where higher levels hurt both sides. So for ZSTD specifically, there's no read-time penalty for using level 15.

The practical breakdown for your situation:


| Artifact | Recommended Level | Why |
| :-- | :-- | :-- |
| FGB intermediate (local, pipeline-internal) | 0 (no compression) | FGB uses its own binary layout; compression isn't a first-class option and adds nothing for a local temp file |
| Final county Parquets on Tigris (distribution) | **15** per spec | One-time write cost, benefits every DuckDB query and download thereafter |
| Development/iteration parquets (throwaway) | 3 | Fast rebuild cycles during pipeline development |

So for your final Tigris artifacts: the spec is right, use 15. For scratch work while developing the pipeline: use 3 to keep iteration fast, then rebuild final artifacts at 15.

***

## FGB: Schema Changes in the GPKG→FGB Step

Yes — apply schema cleanup at the FGB step. This keeps all downstream formats consistent and means you're never re-processing a field you've already decided to drop. The ogr2ogr `-sql` flag (instead of `-where` + `-spat` separately) gives you full column control:

```powershell
$env:OGR_SQLITE_PRAGMA = "mmap_size=107374182400,cache_size=-4194304,temp_store=MEMORY,journal_mode=OFF"
$env:OGR_GPKG_NUM_THREADS = "ALL_CPUS"
$env:GDAL_CACHEMAX = "2048"

# Use -sql instead of -where + -spat to control columns explicitly
# EXCLUDE: parcelstate (100% NULL), lrversion (uniform "2026.1"), statefp (hive key)
# KEEP:    geoid (pre-joined FIPS for TIGER joins), centroidx/y, surfpointx/y

$sql = @"
SELECT
  lrid, parcelid, parcelid2, geoid,
  countyfp,
  taxacctnum, taxyear,
  usecode, usedesc, zoningcode, zoningdesc,
  numbldgs, numunits, yearbuilt, numfloors, bldgsqft,
  bedrooms, halfbaths, fullbaths,
  imprvalue, landvalue, agvalue, totalvalue, assdacres,
  saleamt, saledate,
  ownername, owneraddr, ownercity, ownerstate, ownerzip,
  parceladdr, parcelcity, parcelzip,
  legaldesc, township, section, qtrsection, range,
  plssdesc, book, page, block, lot, updated,
  centroidx, centroidy, surfpointx, surfpointy,
  geom
FROM parcels
WHERE
  statefp = '$statefips'
  AND ST_EnvelopeIntersects(geom, $($bbox[0]), $($bbox[1]), $($bbox[2]), $($bbox[3]))
"@

$ogrArgs = @(
  "-f", "FlatGeoBuf",
  "-lco", "SPATIAL_INDEX=YES",
  "-sql", $sql,
  "-nln", "parcels",
  "-progress", "-overwrite",
  $out_fgb, $vrt
  # no layer name after VRT when using -sql
)

pixi run ogr2ogr @ogrArgs
```

Note: when using `-sql`, you drop the layer name from the end of the argument list and use `-nln` to name the output layer. Also `ST_EnvelopeIntersects` in OGR SQL replaces the separate `-spat` flag when you're in `-sql` mode — though you can also keep `-spat` alongside `-sql` as a pre-filter and it still works.

***

## Direct-to-S3 via `/vsis3/` — Where It Works and Where It Doesn't

The honest constraint: **`SPATIAL_INDEX=YES` on FGB requires a seekable output** — GDAL does a two-pass write (Hilbert sort pass, then indexed write pass), which is incompatible with streaming to a non-seekable sink like `/vsis3/`. Same issue applies to `SORT_BY_BBOX=YES` on Parquet. GDAL will either fail or silently fall back to writing without the spatial structure.

Your options for direct-to-S3:

**Option A — Write FGB locally, sync to Tigris (recommended for FGB)**
Keep the GPKG→FGB step local (gets you the spatial index), then rclone sync:

```powershell
rclone copy data/fgb/state=$statefips/ `
  tigris:your-bucket/fgb/state=$statefips/ `
  --s3-endpoint https://fly.storage.tigris.dev `
  --transfers 4 --progress
```

**Option B — DuckDB directly to Tigris for the Parquet step (recommended for Parquet)**
DuckDB's httpfs handles S3 multipart uploads natively and doesn't need seekable output since it manages its own write buffering. This is the right place to go direct-to-S3 — FGB stays local, Parquet goes straight to Tigris.

***

## DuckDB from R for FGB → County Parquets on Tigris

This is the right architecture. R orchestrates, DuckDB is the engine, nothing enters R memory:

```r
library(duckdb)
library(glue)

tigris_parquet <- function(state_fips, fgb_path, bucket = "your-bucket") {

  con <- duckdb::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(duckdb::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  duckdb::dbExecute(con, "INSTALL spatial; LOAD spatial;")
  duckdb::dbExecute(con, "INSTALL httpfs;  LOAD httpfs;")

  # Tigris S3-compatible config
  duckdb::dbExecute(con, glue("SET s3_endpoint    = 'fly.storage.tigris.dev';"))
  duckdb::dbExecute(con, glue("SET s3_access_key_id     = '{Sys.getenv('TIGRIS_ACCESS_KEY')}';"))
  duckdb::dbExecute(con, glue("SET s3_secret_access_key = '{Sys.getenv('TIGRIS_SECRET_KEY')}';"))
  duckdb::dbExecute(con, "SET s3_region = 'auto';")
  duckdb::dbExecute(con, "SET s3_url_style = 'path';")  # Tigris requires path-style

  # Normalize path for DuckDB (forward slashes, no UNC)
  fgb_norm <- normalizePath(fgb_path, winslash = "/")

  s3_prefix <- glue("s3://{bucket}/parcels/state={state_fips}/")

  message(glue("state={state_fips}: FGB → Tigris county partitions"))
  message(glue("  src:  {fgb_norm}"))
  message(glue("  dest: {s3_prefix}"))

  t <- system.time({
    duckdb::dbExecute(con, glue("
      COPY (
        SELECT * FROM ST_Read('{fgb_norm}')
        -- schema already cleaned at FGB stage; countyfp is partition key
      ) TO '{s3_prefix}'
      (
        FORMAT        PARQUET,
        PARTITION_BY  (countyfp),
        COMPRESSION   'zstd',
        COMPRESSION_LEVEL 15,
        ROW_GROUP_SIZE    65536,
        WRITE_PARTITION_COLUMNS false,  -- countyfp already in data, skip duplicate
        OVERWRITE_OR_IGNORE 1
      );
    "))
  })

  message(glue("  done in {round(t['elapsed']/60, 1)} min"))
  invisible(s3_prefix)
}

# Per-state calls — each is independent, can be lapply'd or run sequentially
tigris_parquet("13", "data/fgb/state=13/parcels.fgb")
tigris_parquet("37", "data/fgb/state=37/parcels.fgb")
```

A few DuckDB-specific notes for this call:

- `WRITE_PARTITION_COLUMNS false` prevents DuckDB from adding a duplicate `countyfp` column inside the parquet file (it's already in the data from the FGB, and it's in the partition path — you don't want it three times)
- `ROW_GROUP_SIZE 65536` is a reasonable fixed default; DuckDB will create one file per county partition, so the row group count per file will naturally scale with county size
- For counties with very few features (< 16K), DuckDB produces a single row group regardless — this is fine
- For high-density counties (Fulton GA ~370K, LA County ~1M+), 65536 gives ~6–15 row groups with good spatial selectivity

The resulting Tigris layout with proper hive partitioning:

```
s3://bucket/parcels/
  state=13/countyfp=001/data_0.parquet   ← Appling County, GA
  state=13/countyfp=121/data_0.parquet   ← Fulton County, GA
  state=37/countyfp=001/data_0.parquet   ← Alamance County, NC
```


---

# ok now, lets step back and a) establish and solidify this planned setup and our determined architecture and goals, etc. for the entire initial metadata work and what artifacts/information/manifests, etc. are necessary in this phase and encode this in R code or functions, etc. and then the entire raw local gpkg > tigris hosted and processed/cleansed/revamped FGBs by state created using OGR approach + declarative SQL and probably formalizing into actual VRT or GDALG specifications to use > state partitioned parquets on tigris blob storage created using duckdb approach (no declarative specs like GDALG, but still SQL etc.) and especially all of the MANY options around how to approach duckdb in R as there's too many ways to do this between all the available duckdb specific packages plus arrow/sfarrow/geoarrow/DBI/dbplyr/dplyr/duckplyr/duckdb/duckspatial/etc. > (may not need to be a separate step, may be a part of the previous step but not sure) county partitioned parquets generated from state ones (or FGBs, same step specific nuance) and any final polishing / metadata / STAC or whatever to make it all official and begin working on an R "client" package

NOTE: we will not attempt to do this across all states yet, only single states one by one, however, the metadata step should be in the context of the full workflow to help for all downstream work, but the full e2e will be done for a couple states first before attempting anything larger.

NOTE: not specific to this work, as this is all about the "data" portion of the system and resulting artifacts, however, keep in mind that a whole nother output system that will use these derived artifacts will eventually be designed also with regard to the vector tiles and their styles and maplibre map clients, etc. - may be something to keep in mind

Answer skipped.
<span style="display:none">[^8_1][^8_10][^8_11][^8_12][^8_13][^8_14][^8_15][^8_2][^8_3][^8_4][^8_5][^8_6][^8_7][^8_8][^8_9]</span>

<div align="center">⁂</div>

[^8_1]: https://gdal.org/en/stable/programs/ogr2ogr.html

[^8_2]: https://gdal.org/gdal.pdf

[^8_3]: https://gdal.org/en/stable/drivers/raster/gdalg.html

[^8_4]: https://gdal.org/en/stable/drivers/vector/gdalg.html

[^8_5]: https://gdal.org/en/stable/programs/gdal_vector_pipeline.html

[^8_6]: https://posit.co/blog/duckplyr-dplyr-powered-by-duckdb/

[^8_7]: https://cloudnativegeo.org/blog/2024/08/introduction-to-stac-geoparquet/

[^8_8]: https://engineering.kablamo.com.au/posts/gdal-evolved/

[^8_9]: https://www.appsilon.com/post/r-dplyr-vs-duckdb

[^8_10]: https://stac-utils.github.io/stac-geoparquet/latest/spec/stac-geoparquet-spec/

[^8_11]: https://github.com/dwtkns/gdal-cheat-sheet

[^8_12]: https://duckplyr.tidyverse.org/articles/duckdb.html

[^8_13]: https://github.com/opengeospatial/geoparquet/discussions/114

[^8_14]: https://www.r-bloggers.com/2024/10/duckdb-vs-dplyr-vs-base-r/

[^8_15]: https://github.com/radiantearth/stac-geoparquet-spec/blob/main/stac-geoparquet-spec.md


---

# this is the 2nd time in row perplexity has errored out after you've done substantial efforts taking ~10m, it may be too large of a task to try and do with actual code and project generation, maybe just respond to my statement instead? (see image)

Totally fair — let me give you the full architectural response in prose and structured text only. No code generation.

***

## Pipeline Architecture — US Parcels

### Phases at a Glance

```
GPKG (local, 93GB)
  │
  ▼ Phase 0 — Inventory (RSQLite + gpkg + gdalraster + vapour)
  │   → manifests/state_manifest.csv
  │   → manifests/county_manifest.csv
  │   → manifests/schema.json
  │
  ▼ Phase 1 — GPKG → FGB per state (ogr2ogr + VRT, local)
  │   → data/fgb/state={XX}/parcels.fgb
  │
  ▼ Phase 2 — FGB → County GeoParquets → Tigris (DuckDB via DBI)
  │   → s3://bucket/parcels/state={XX}/countyfp={YYY}/data_0.parquet
  │
  ▼ Phase 3 — State GeoParquets → Tigris (DuckDB, optional derived step)
  │   → s3://bucket/parcels-state/state={XX}/parcels.parquet
  │
  ▼ Phase 4 — STAC Metadata (stub, post initial states)
      → stac/collection.json
      → stac/items/state={XX}.json

  [Separate system, later]
  FGB/Parquet → PMTiles (MLT) → MapLibre GL JS
```


***

## Phase 0 — Inventory

**Tools**: RSQLite + DBI (SQL aggregations), `gpkg` (OGC metadata tables), `gdalraster::ogrinfo()` (schema/CRS), `vapour` (attribute sampling without geometry decode)

**What it produces and why each artifact matters**:

- **`state_manifest.csv`** — `statefp`, `feature_count`, `county_count`, `null_geom_count`, `min_x/y/max_x/y` (exact bbox from data, used as `-spat` values in Phase 1 rather than hardcoded estimates), `est_parquet_mb`, `large_state` flag. This drives all downstream work.
- **`county_manifest.csv`** — `statefp`, `countyfp`, `geoid`, `feature_count`. Used for dynamic `ROW_GROUP_SIZE` calculation per county in Phase 2, and for post-hoc validation after Tigris upload.
- **`schema.json`** — Canonical field list with types, descriptions, which fields are dropped and why, partition key designation. Single source of truth referenced by Phase 1 SQL and Phase 2 DuckDB queries. Prevents drift between formats.
- **`findings.rds`** — The R list object from the audit (WAL state, B-tree indexes, R-tree presence, null rates). Not a deliverable, just a persisted checkpoint.

**Key findings already confirmed**:

- WAL active, `-shm`/`-wal` present and healthy (WAL at 0 bytes = fully checkpointed)
- No B-tree indexes on `statefp`/`countyfp` → manifest GROUP BY is a full scan, index creation recommended before running it
- `parcelstate` 100% NULL → drop
- `lrversion` uniform `"2026.1"` → drop (encode in schema.json version field instead)
- `statefp` zero-padded 2-char, `countyfp` zero-padded 3-char, `geoid` pre-concatenated 5-char → all clean, use directly as partition keys
- R-tree spatial index present (4 virtual tables), used by GDAL/OGR `-spat` filter

***

## Phase 1 — GPKG → FGB

**Why FGB as intermediate rather than going GPKG → Parquet directly**:

- FGB is 40–60% smaller than GPKG for equivalent data (no SQLite page overhead)
- Hilbert-packed spatial index built directly into file (no companion files)
- Universally readable without GDAL Arrow/Parquet driver — anyone with basic GDAL/QGIS/ogr2ogr can use it
- Repeatable extraction target: if the county Parquet step needs to be re-run (schema tweak, compression change), you re-read FGB not the 93GB GPKG
- Future-proof: FGB serves as the canonical state-level distribution format alongside Parquet

**Source abstraction — VRT vs GDALG**:

The `parcels.vrt` you already have is the right tool for source path abstraction. Keep it.

GDALG (GDAL Streamed Algorithm, GDAL ≥ 3.9) is a different concept — it encodes a `gdal vector pipeline` invocation as a JSON virtual source. It's useful for defining a transform-on-read virtual layer (read FGB + apply column projection lazily), but for a materialized write like GPKG→FGB with `SPATIAL_INDEX=YES`, ogr2ogr is still what executes it. GDALG shines later if you want to expose the FGB as a virtual projected/filtered source to DuckDB's `ST_Read()` without touching it — worth revisiting at Phase 2. For now: VRT for source path portability, `-sql` in ogr2ogr for column selection.

**Schema cleanup happens here** — apply at Phase 1 so all downstream formats (FGB, Parquet) are consistent. The `-sql` flag in ogr2ogr selects columns explicitly, dropping `parcelstate` and `lrversion`. All other fields retained including `statefp` (self-describing) and `countyfp` (needed for Phase 2 partition).

**`-spat` values come from the state manifest** (Phase 0 output), not hardcoded bboxes. This makes Phase 1 driven entirely by data rather than estimates.

**Direct-to-S3 FGB**: Not possible with `SPATIAL_INDEX=YES` — the Hilbert sort requires a seekable output. FGB stays local. Upload to Tigris separately via rclone after extraction.

***

## Phase 2 — FGB → County Parquets → Tigris

**Why DuckDB over ogr2ogr here**:

- `PARTITION_BY` with multiple keys is native DuckDB SQL, not a GDAL concept
- Dynamic `ROW_GROUP_SIZE` per county (from county manifest) is trivial in SQL, impossible in a single ogr2ogr call
- Direct write to S3 (Tigris) via httpfs — DuckDB manages its own multipart upload buffering, no seekable-output constraint
- Schema transformations (column reordering, type casting, derived fields) are SQL, not lco flags

**DuckDB in R — the definitive package decision**:

For pipeline functions: **`duckdb` + `DBI` only.** That's two packages, one purpose each.

```
duckdb::duckdb()           → the driver object (never call methods on it directly)
DBI::dbConnect()           → open connection (:memory: for pipeline steps)
DBI::dbExecute()           → INSTALL, LOAD, SET, COPY, DDL — anything with no result set
DBI::dbGetQuery()          → SELECT → data.frame (validation and manifest queries only)
DBI::dbDisconnect(shutdown=TRUE) → close + release memory
```

Every other package and its correct scope:


| Package | Role | In pipeline functions? |
| :-- | :-- | :-- |
| `duckdb` | Driver | ✅ Yes (driver only) |
| `DBI` | Interface | ✅ Yes |
| `arrow` | R-side parquet I/O | ❌ Inspection/validation only |
| `sfarrow` | sf ↔ parquet bridge | ❌ Spot-checks only |
| `geoarrow` | Geometry-aware arrow in R | ❌ Spot-checks only |
| `dbplyr` | dplyr → SQL translation | ❌ Interactive notebooks only |
| `duckplyr` | dplyr with DuckDB backend | ❌ Interactive analysis only |
| `duckspatial` | DuckDB spatial R wrappers | ❌ Skip entirely — write SQL directly |

The pattern that matters: **one connection per pipeline function, opened inside the function, closed with `on.exit()`**. R is the orchestrator. DuckDB does the work. Nothing geospatial enters R memory.

**Compression**: ZSTD level 15 for Tigris-hosted final artifacts (distribution, per GeoParquet spec). ZSTD level 3 during development iteration (fast rebuilds). Switch to 15 for the definitive upload.

**Hive layout on Tigris**:

```
s3://bucket/parcels/state=13/countyfp=001/data_0.parquet
s3://bucket/parcels/state=13/countyfp=121/data_0.parquet
s3://bucket/parcels/state=37/countyfp=001/data_0.parquet
```

`statefp` and `countyfp` both retained as data columns (self-describing) AND encoded in the partition path.

**`ROW_GROUP_SIZE`**: 65536 as a fixed default works well. For a more principled approach, derive it from the county manifest: `max(16384, floor(feature_count / 10))` targeting ~10 row groups per county file. For counties under 16K features (many rural counties), a single row group is fine. This calculation can be done in Phase 0 and stored in the county manifest.

***

## Phase 3 — State Parquets (Optional)

Single-file state parquets derived from the already-uploaded county parquets via a DuckDB `read_parquet(..., hive_partitioning=true)` → `COPY TO` pattern. These are convenience artifacts for users who want one file per state. Stored at a separate prefix (`parcels-state/`) to avoid confusing DuckDB's hive partition detection on the county prefix.

***

## Phase 4 — STAC (Stub)

One STAC Collection, one Item per state. Each Item's assets point to the county parquet paths on Tigris. The STAC GeoParquet spec (items-as-rows in a parquet file) is worth implementing here since you already have all the machinery — it lets tools like `rstac` query the catalog spatially without loading individual items. Post initial states.

***

## What to Do Right Now

Given you have GA and NC already extracted as state parquets (not yet county-partitioned):

1. **Phase 0**: Run the index creation + manifest query against the GPKG (this conversation covers exactly how)
2. **Phase 1**: Re-extract GA and NC as FGB with the schema cleanup SQL (drop `parcelstate`, `lrversion`), using manifest bboxes for `-spat`
3. **Phase 2**: Run DuckDB FGB→county parquet→Tigris for GA and NC as the e2e validation
4. **Validate**: `gpq validate` on a sample county parquet, DuckDB query against Tigris to confirm hive partitioning works, row count matches manifest
5. **Then**: formalize everything above into R functions before attempting additional states
<span style="display:none">[^9_1]</span>

<div align="center">⁂</div>

[^9_1]: image.jpg


---

# I can still access the files you generated though up until the last one which is parcels.vrt at least though, ill stash away for reference in the new clean project ive setup on WSL for this work (see image showing your work on the left and the document on the right). reviewing your latest answer now

Good — glad the files made it through before the error. The architecture document and the `parcels.vrt` are the most durable artifacts from that session, and the document shows the full pipeline flow clearly.

A few things worth noting from what you can see in the screenshot of the architecture doc on the right:

The pipeline diagram it generated captures exactly what we settled on — the `SCHEMA_SELECT_COLS` as the drop list (`parcelstate`, `lrversion`), the per-state GDALG spec as a versioned source spec, and the DuckDB `COPY TO s3://` with `ROW_GROUP_SIZE from manifest` — that dynamic row group sizing from the county manifest is the key improvement over your original arbitrary 50000 value.

For the WSL project setup, a couple things that will matter immediately when you move from the Windows pixi environment to WSL:

**Path handling**: The `parcels.vrt` will need its `SrcDataSource` updated — the `E:/GEODATA/...` Windows path becomes `/mnt/e/GEODATA/...` under WSL. If you want the VRT to work on both, you can either maintain two VRTs or use a symlink inside WSL pointing to the drive path.

**pixi vs WSL GDAL**: Confirm whether you're running `pixi run ogr2ogr` from WSL pointing to a pixi environment on the Windows side, or installing a fresh pixi/GDAL in the WSL environment itself. The `OGR_GPKG_NUM_THREADS` env var behavior and available GDAL drivers (especially the Arrow/Parquet driver) can differ between a Windows-native GDAL binary and a Linux one — worth verifying `gdalinfo --formats | grep -i parquet` in the WSL context before running Phase 1.

**Memory pragmas**: The `mmap_size=107374182400` (100GB) in `OGR_SQLITE_PRAGMA` is aggressive but fine on Windows where it's a hint. On Linux/WSL it's a harder reservation against the process's virtual address space — if WSL's memory limit in `.wslconfig` is set below that, SQLite will silently clamp it. Not a correctness issue but worth knowing.

The next concrete step remains Phase 0 manifest generation — specifically the B-tree index creation on `(statefp, countyfp, geoid)` and then the GROUP BY manifest query. Once that's done and the county manifest has exact bboxes and feature counts per state, Phase 1 FGB extraction for GA and NC can be re-run from WSL with the cleaned schema SQL.
<span style="display:none">[^10_1]</span>

<div align="center">⁂</div>

[^10_1]: image.jpg


---

# For the WSL project setup, a couple things that will matter immediately when you move from the Windows pixi environment to WSL:

Path handling: The parcels.vrt will need its SrcDataSource updated — the E:/GEODATA/... Windows path becomes /mnt/e/GEODATA/... under WSL. If you want the VRT to work on both, you can either maintain two VRTs or use a symlink inside WSL pointing to the drive path.
pixi vs WSL GDAL: Confirm whether you're running pixi run ogr2ogr from WSL pointing to a pixi environment on the Windows side, or installing a fresh pixi/GDAL in the WSL environment itself. The OGR_GPKG_NUM_THREADS env var behavior and available GDAL drivers (especially the Arrow/Parquet driver) can differ between a Windows-native GDAL binary and a Linux one — worth verifying gdalinfo --formats | grep -i parquet in the WSL context before running Phase 1.

all of this is already taken care of, no worries. im pointing to the /mnt/e/* path in the WSL VRT (and for version control have setup a template and am using a gitignored file named parcels.local.vrt with the actual path defined, kind of similar to .env.example or .env.local patterns seen in the wild). im using pixi in WSL also and it has full gdalraster support unlike windows with regard to the GDAL algorithmic API C++ bindings and features which could be nice also and provide API access to the latest gdalraster::gdal_*() and vector pipeline and gdalg features, etc. (all broken on windows due to RTools and C++ ABI mismatches etc.) and other benefits like better docker support etc.

however this statement: Memory pragmas: The mmap_size=107374182400 (100GB) in OGR_SQLITE_PRAGMA is aggressive but fine on Windows where it's a hint. On Linux/WSL it's a harder reservation against the process's virtual address space — if WSL's memory limit in .wslconfig is set below that, SQLite will silently clamp it. Not a correctness issue but worth knowing.

is worth addressing as the gpkg is still and always will only be on an external HD which is part of the windows OS specific file system setup but still accessible via WSL /mnt/* etc. also note that i can still use windows exes from WSL if that's the concern but not sure exactly where and what the mmap_size etc. are effecting

This is actually a more specific issue than general WSL memory limits — the `mmap_size` pragma is effectively **a silent no-op** in your setup regardless of `.wslconfig`, and the reason is the filesystem bridge itself.

## Why `mmap_size` Does Nothing Here

WSL mounts Windows NTFS volumes (`/mnt/e/`, `/mnt/d/`, etc.) via the **9P filesystem protocol** — a network-like filesystem bridge between the Linux VFS layer and the Windows NTFS driver. Memory-mapped I/O (`mmap()`) requires the OS to be able to back virtual address space with direct file pages, which is only possible on real local filesystems (ext4, tmpfs, etc.). The 9P bridge **does not support `mmap()`** — the Linux kernel will either return `ENODEV` or silently fall back to `pread()` syscalls. SQLite detects this and silently falls back to regular I/O without any error or warning.

So the `mmap_size=107374182400` line in `OGR_SQLITE_PRAGMA` is doing exactly nothing for this workload. The 100GB virtual address reservation never happens.

## What Actually Does Work Through 9P

The other pragmas in your env var **are** still effective because they operate in process heap memory, not file-backed mmap:


| Pragma | Mechanism | Works via 9P? |
| :-- | :-- | :-- |
| `mmap_size` | File-backed virtual memory | ❌ No-op — 9P can't mmap |
| `cache_size = -4194304` | SQLite in-process page cache (heap) | ✅ Yes — ~4GB RAM cache still buffers hot pages |
| `temp_store = MEMORY` | Sort/groupby spill target | ✅ Yes — spills go to RAM not disk |
| `journal_mode = OFF` | Write-path only | ✅ Harmless on read sessions |

## The Real Performance Bottleneck

Your actual I/O path for the GPKG reads is:

```
ogr2ogr (WSL Linux process)
  → pread() syscalls
  → WSL 9P VirtioFS driver
  → Windows NTFS driver
  → USB/eSATA external HD
```

Every sequential read through this chain carries 9P protocol overhead on top of external HD speeds. This is the dominant cost, not mmap. The `cache_size` helps significantly for repeated access to the same SQLite pages (the R-tree nodes, GPKG metadata tables) but the large sequential feature table scan during extraction is cold data that can't be cached.

## Practical Implication

You can remove `mmap_size` from `OGR_SQLITE_PRAGMA` — it's dead weight in this context and slightly misleading to have it documented as an optimization. Clean version for WSL + external HD:

```powershell
$env:OGR_SQLITE_PRAGMA = "cache_size=-4194304,temp_store=MEMORY,journal_mode=WAL"
```

`journal_mode=WAL` instead of `OFF` here because WAL is already set at the file level and asserting it is more correct than asserting OFF (which is a different mode entirely and technically requests a mode change that would be rejected on a read-only connection anyway).

The most meaningful performance improvement available to you for Phase 1 FGB extraction would be copying the GPKG to the WSL native ext4 filesystem first (inside the WSL VHD at `~/` or similar) — at 93GB that's a one-time ~15–30 minute copy depending on your external HD speed, but subsequent reads would have no 9P overhead and mmap would actually function. Whether that trade-off is worth it depends on how many times you expect to re-run Phase 1 extractions.

---

# well i can use windows or WSL or docker or anything related to the gpkg whatever will provide the optimal I/O and performance while still having all tools necessary, etc. the main thing to note regardless of where commands are called from or on what OS/platform/drive, etc. is the fact the gpkg is on an external hard drive (pretty sure its HDD not SDD also, can provide more details if could be useful), i.e. E: is a USB plugged in external drive with ~2TB total and ~400GB remaining. ive tried getting the gpkg into blob storage for remote access from anywhere but it takes too long or errors every time ive tried and would also add network latency regardless and likely not be worth it compared to local especially now that we are going to use the FGB approach. another note is that the actual original zip archive for the gpkg is still available on kaggle

The HDD detail is the most important piece of hardware context for this whole pipeline. Let me be precise about what it means for each decision.

## HDD vs SSD — The Fundamental Split

HDDs have two completely different performance characteristics:

- **Sequential reads**: 80–120 MB/s (fine — ogr2ogr reading feature data page by page)
- **Random reads**: 0.5–2 MB/s effective, gated by seek time (~8–12ms per seek)

SQLite is a random-access database. Nearly every operation that isn't a pure sequential table scan involves seeks. This makes the HDD the single biggest variable in the entire pipeline.

## Implications Per Phase

**Phase 0 — B-tree index creation**: This is the one to reconsider most seriously on an HDD. Building a `(statefp, countyfp, geoid)` index on 154M rows involves:

1. A full sequential table scan to read all rows (fine on HDD, ~15–20 min)
2. An external sort of 154M index entries (sequential, fine)
3. Writing the B-tree structure back to the GPKG — this is **random writes interleaved with the existing file structure**, and on an HDD with no free pages (`free_pages = 0` from your stats) this will be very slow and cause significant seek thrashing

The question is whether the manifest GROUP BY query time savings justify it. If you only run the manifest once, the index build cost likely exceeds the query savings on an HDD. Run the GROUP BY without the index first and time it — you may find it's perfectly acceptable since it's a sequential scan and HDDs handle those reasonably well. Reserve the index creation decision until you know whether you actually need to re-run the manifest multiple times.

**Phase 1 — GPKG → FGB extraction**: Run this from **Windows native** (PowerShell + pixi), not WSL. The I/O path difference is real and material on an HDD where every millisecond of extra latency matters:

```
Windows pixi ogr2ogr → NTFS driver → USB controller → HDD spindle
WSL pixi ogr2ogr    → 9P bridge → NTFS driver → USB controller → HDD spindle
```

The 9P bridge adds round-trip latency to every read syscall, which on an HDD compounds badly because you're already paying 8–12ms per seek. For Phase 1 specifically, your existing PowerShell approach is the right call — not for WSL compatibility reasons, but for raw throughput.

**Phase 2 — FGB → Parquet → Tigris**: Run from WSL. The FGBs will live on a local (ideally internal SSD) drive at this point, so the 9P overhead disappears. DuckDB, R, httpfs — all better in WSL anyway.

## The Single Biggest Improvement Available

If you have ~100GB free on any internal SSD (WSL VHD partition, a secondary internal drive, even a fast NVMe external), copy the GPKG there before running Phase 0 and Phase 1:

```bash
# From WSL, copying to WSL native ext4 filesystem (inside the VHD)
cp /mnt/e/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg \
   ~/geodata/parcels.gpkg
# Also copy the -shm and -wal files
cp /mnt/e/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg-shm ~/geodata/
cp /mnt/e/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg-wal ~/geodata/
```

The copy itself at HDD sequential speeds takes ~15–20 minutes. Everything after that — index creation, Phase 0 manifest, Phase 1 FGB extractions — runs against SSD random I/O (~3,000 MB/s NVMe vs ~1 MB/s HDD random). For a 50-state pipeline that'll be run iteratively this is a one-time cost that pays back immediately.

## The FGB Endgame

Once Phase 1 is complete and all state FGBs exist on a fast drive, **the GPKG is effectively retired** from active use. The FGBs collectively will be 40–60% smaller (~40–55GB for all 50 states), they can live on the external drive or Tigris, and you never need to touch the original 93GB GPKG again. That's the actual goal of the FGB intermediate step — not just format conversion, but permanently escaping the HDD/SQLite bottleneck.

The Kaggle archive being available is a good safety net — if the external drive fails or the GPKG gets corrupted during index creation, you have a recovery path. Worth noting the Kaggle URL in your project README as the canonical source reference.

## Recommended I/O Strategy Per Tool

| Phase | Run from | Why |
| :-- | :-- | :-- |
| Phase 0 manifest (RSQLite) | Windows R | Direct NTFS, no 9P for heavy SQLite reads |
| Phase 0 index creation | Windows R (RW conn) | Same + avoids 9P write latency |
| Phase 1 GPKG→FGB | Windows PowerShell pixi | Native NTFS, maximum HDD throughput |
| Phase 2 FGB→Parquet | WSL pixi/R | FGB on fast drive by then, WSL has full GDAL |
| All R orchestration | WSL R | Better gdalraster support, consistent Linux env |


---

# lets be sure not to get too caught up in details unless they are 100% worth addressing

Fair. The one thing actually worth acting on from all of that:

**Copy the GPKG to an internal SSD before running anything further.** Everything else — OS choice, path handling, pragma tuning — is marginal compared to getting off the HDD. That single change will make Phase 0 (manifest + index) and Phase 1 (FGB extractions) dramatically faster and is the only hardware-level decision that materially affects the pipeline timeline.

Once the GPKG is on SSD, proceed exactly as planned:

1. Phase 0 manifest + index (Windows R, RW connection)
2. Phase 1 FGB extractions per state (Windows PowerShell pixi, your existing script pattern)
3. Phase 2 FGB → county parquets → Tigris (WSL R + DuckDB)

Everything else is fine as-is.

---

# does windows vs WSL matter for where it is stored? im just going to teracopy (tool i use on windows) it to either my main C drive (dont really want to do this though) or one of my partitioned dev drives (not sure about the implications here though as these are that ReFS format). i have a lot of drives available but dunno what the best option is, the current E: drive is where all work so far has been done though and is also my "data" disk and has a lot of GEODATA in it so will likely keep it there but can still copy to another drive for initial work against it.

(sorry wasnt sure the best way to provide you this information):

```pwsh
➜ Get-Disk; Get-Partition; Get-Volume

Number Friendly Name Serial Number                    HealthStatus         OperationalStatus      Total Size Partition
                                                                                                             Style
------ ------------- -------------                    ------------         -----------------      ---------- ----------
2      Msft Virtual…                                  Healthy              Online                   50.02 GB GPT
0      WDC PC SN730… E823_8FA6_BF53_0001_001B_448B_4… Healthy              Online                  953.87 GB GPT
1      BUFFALO HD-P… 0000009020006253                 Healthy              Online                    1.82 TB GPT

ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Partition.ObjectId="{d87cbf99-d
                       fbd-11ec-99ad-806e6f6e6963}:PR:{00000000-0000-0000-0044-000000000000}\\\\?\\scsi#disk&ven_msft&prod
                       _virtual_disk#2&1f4adffe&0&000004#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : {00000000-0000-0000-0044-000000000000}60022480DBD0474A43EDB73D61A9664A
AccessPaths          :
DiskId               : \\\\?\\scsi#disk&ven_msft&prod_virtual_disk#2&1f4adffe&0&000004#{53f56307-b6bf-11d0-94f2-00a0c91efb
                       8b}
DiskNumber           : 2
DriveLetter          :
GptType              : {e3c9e316-0b5c-4db8-817d-f92df00215ae}
Guid                 : {762c329a-7816-476e-b495-6ab140638c76}
IsActive             : False
IsBoot               : False
IsDAX                :
IsHidden             : True
IsOffline            : False
IsReadOnly           :
IsShadowCopy         :
IsSystem             : False
MbrType              :
NoDefaultDriveLetter :
Offset               : 17408
OperationalStatus    : Online
PartitionNumber      : 1
Size                 : 16759808
TransitionState      : 1
PSComputerName       :
Type                 : Reserved
DiskPath             : \\\\?\\scsi#disk&ven_msft&prod_virtual_disk#2&1f4adffe&0&000004#{53f56307-b6bf-11d0-94f2-00a0c91efb
                       8b}


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Partition.ObjectId="{d87cbf99-d
                       fbd-11ec-99ad-806e6f6e6963}:PR:{00000000-0000-0000-0000-000100000000}\\\\?\\scsi#disk&ven_msft&prod
                       _virtual_disk#2&1f4adffe&0&000004#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : {00000000-0000-0000-0000-000100000000}60022480DBD0474A43EDB73D61A9664A
AccessPaths          : {N:\\, \\\\?\\Volume{9582f351-41e1-4a84-bd86-9933fec9e87d}\\}
DiskId               : \\\\?\\scsi#disk&ven_msft&prod_virtual_disk#2&1f4adffe&0&000004#{53f56307-b6bf-11d0-94f2-00a0c91efb
                       8b}
DiskNumber           : 2
DriveLetter          : N
GptType              : {ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}
Guid                 : {9582f351-41e1-4a84-bd86-9933fec9e87d}
IsActive             : False
IsBoot               : False
IsDAX                : False
IsHidden             : False
IsOffline            : False
IsReadOnly           : False
IsShadowCopy         : False
IsSystem             : False
MbrType              :
NoDefaultDriveLetter : False
Offset               : 16777216
OperationalStatus    : Online
PartitionNumber      : 2
Size                 : 53687091200
TransitionState      : 1
PSComputerName       :
Type                 : Basic
DiskPath             : \\\\?\\scsi#disk&ven_msft&prod_virtual_disk#2&1f4adffe&0&000004#{53f56307-b6bf-11d0-94f2-00a0c91efb
                       8b}


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Partition.ObjectId="{d87cbf99-d
                       fbd-11ec-99ad-806e6f6e6963}:PR:{00000000-0000-0000-0000-100000000000}\\\\?\\scsi#disk&ven_nvme&prod
                       _wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : {00000000-0000-0000-0000-100000000000}eui.E8238FA6BF530001001B448B4961FDC6
AccessPaths          : {\\\\?\\Volume{56df2da2-fe09-446a-989a-8ba0720cb875}\\}
DiskId               : \\\\?\\scsi#disk&ven_nvme&prod_wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c9
                       1efb8b}
DiskNumber           : 0
DriveLetter          :
GptType              : {c12a7328-f81f-11d2-ba4b-00a0c93ec93b}
Guid                 : {56df2da2-fe09-446a-989a-8ba0720cb875}
IsActive             : False
IsBoot               : False
IsDAX                :
IsHidden             : True
IsOffline            : False
IsReadOnly           :
IsShadowCopy         :
IsSystem             : True
MbrType              :
NoDefaultDriveLetter :
Offset               : 1048576
OperationalStatus    : Online
PartitionNumber      : 1
Size                 : 104857600
TransitionState      : 1
PSComputerName       :
Type                 : System
DiskPath             : \\\\?\\scsi#disk&ven_nvme&prod_wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c9
                       1efb8b}


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Partition.ObjectId="{d87cbf99-d
                       fbd-11ec-99ad-806e6f6e6963}:PR:{00000000-0000-0000-0000-500600000000}\\\\?\\scsi#disk&ven_nvme&prod
                       _wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : {00000000-0000-0000-0000-500600000000}eui.E8238FA6BF530001001B448B4961FDC6
AccessPaths          :
DiskId               : \\\\?\\scsi#disk&ven_nvme&prod_wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c9
                       1efb8b}
DiskNumber           : 0
DriveLetter          :
GptType              : {e3c9e316-0b5c-4db8-817d-f92df00215ae}
Guid                 : {ebc487ee-317e-4233-be39-4f0801a2e92d}
IsActive             : False
IsBoot               : False
IsDAX                :
IsHidden             : True
IsOffline            : False
IsReadOnly           :
IsShadowCopy         :
IsSystem             : False
MbrType              :
NoDefaultDriveLetter :
Offset               : 105906176
OperationalStatus    : Online
PartitionNumber      : 2
Size                 : 16777216
TransitionState      : 1
PSComputerName       :
Type                 : Reserved
DiskPath             : \\\\?\\scsi#disk&ven_nvme&prod_wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c9
                       1efb8b}


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Partition.ObjectId="{d87cbf99-d
                       fbd-11ec-99ad-806e6f6e6963}:PR:{00000000-0000-0000-0000-500700000000}\\\\?\\scsi#disk&ven_nvme&prod
                       _wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : {00000000-0000-0000-0000-500700000000}eui.E8238FA6BF530001001B448B4961FDC6
AccessPaths          : {C:\\, \\\\?\\Volume{d789c1fb-8ca3-4b2c-b48d-3820d1506989}\\}
DiskId               : \\\\?\\scsi#disk&ven_nvme&prod_wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c9
                       1efb8b}
DiskNumber           : 0
DriveLetter          : C
GptType              : {ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}
Guid                 : {d789c1fb-8ca3-4b2c-b48d-3820d1506989}
IsActive             : False
IsBoot               : True
IsDAX                : False
IsHidden             : False
IsOffline            : False
IsReadOnly           : False
IsShadowCopy         : False
IsSystem             : False
MbrType              :
NoDefaultDriveLetter : False
Offset               : 122683392
OperationalStatus    : Online
PartitionNumber      : 3
Size                 : 966006931456
TransitionState      : 1
PSComputerName       :
Type                 : Basic
DiskPath             : \\\\?\\scsi#disk&ven_nvme&prod_wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c9
                       1efb8b}


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Partition.ObjectId="{d87cbf99-d
                       fbd-11ec-99ad-806e6f6e6963}:PR:{00000000-0000-0000-0000-d0f1e0000000}\\\\?\\scsi#disk&ven_nvme&prod
                       _wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : {00000000-0000-0000-0000-d0f1e0000000}eui.E8238FA6BF530001001B448B4961FDC6
AccessPaths          : {\\\\?\\Volume{f3239620-ccd8-43c0-bdc1-15163ac9e0dd}\\}
DiskId               : \\\\?\\scsi#disk&ven_nvme&prod_wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c9
                       1efb8b}
DiskNumber           : 0
DriveLetter          :
GptType              : {de94bba4-06d1-4d40-a16a-bfd50179d6ac}
Guid                 : {f3239620-ccd8-43c0-bdc1-15163ac9e0dd}
IsActive             : False
IsBoot               : False
IsDAX                :
IsHidden             : True
IsOffline            : False
IsReadOnly           :
IsShadowCopy         :
IsSystem             : False
MbrType              :
NoDefaultDriveLetter :
Offset               : 966129614848
OperationalStatus    : Online
PartitionNumber      : 4
Size                 : 723517440
TransitionState      : 1
PSComputerName       :
Type                 : Recovery
DiskPath             : \\\\?\\scsi#disk&ven_nvme&prod_wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c9
                       1efb8b}


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Partition.ObjectId="{d87cbf99-d
                       fbd-11ec-99ad-806e6f6e6963}:PR:{00000000-0000-0000-0000-101de1000000}\\\\?\\scsi#disk&ven_nvme&prod
                       _wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : {00000000-0000-0000-0000-101de1000000}eui.E8238FA6BF530001001B448B4961FDC6
AccessPaths          : {D:\\, \\\\?\\Volume{4abf233b-798d-4865-9a51-39651c6c3261}\\}
DiskId               : \\\\?\\scsi#disk&ven_nvme&prod_wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c9
                       1efb8b}
DiskNumber           : 0
DriveLetter          : D
GptType              : {ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}
Guid                 : {4abf233b-798d-4865-9a51-39651c6c3261}
IsActive             : False
IsBoot               : False
IsDAX                : False
IsHidden             : False
IsOffline            : False
IsReadOnly           : False
IsShadowCopy         : False
IsSystem             : False
MbrType              :
NoDefaultDriveLetter : False
Offset               : 966855229440
OperationalStatus    : Online
PartitionNumber      : 5
Size                 : 56704892928
TransitionState      : 1
PSComputerName       :
Type                 : Basic
DiskPath             : \\\\?\\scsi#disk&ven_nvme&prod_wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c9
                       1efb8b}


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Partition.ObjectId="{d87cbf99-d
                       fbd-11ec-99ad-806e6f6e6963}:PR:{00000000-0000-0000-0000-f050ee000000}\\\\?\\scsi#disk&ven_nvme&prod
                       _wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : {00000000-0000-0000-0000-f050ee000000}eui.E8238FA6BF530001001B448B4961FDC6
AccessPaths          : {\\\\?\\Volume{464b4356-8109-40ec-98dd-ede68818af3e}\\}
DiskId               : \\\\?\\scsi#disk&ven_nvme&prod_wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c9
                       1efb8b}
DiskNumber           : 0
DriveLetter          :
GptType              : {de94bba4-06d1-4d40-a16a-bfd50179d6ac}
Guid                 : {464b4356-8109-40ec-98dd-ede68818af3e}
IsActive             : False
IsBoot               : False
IsDAX                :
IsHidden             : True
IsOffline            : False
IsReadOnly           :
IsShadowCopy         :
IsSystem             : False
MbrType              :
NoDefaultDriveLetter :
Offset               : 1023560122368
OperationalStatus    : Online
PartitionNumber      : 6
Size                 : 648019968
TransitionState      : 1
PSComputerName       :
Type                 : Recovery
DiskPath             : \\\\?\\scsi#disk&ven_nvme&prod_wdc_pc_sn730_sdb#5&2e1275f8&0&000000#{53f56307-b6bf-11d0-94f2-00a0c9
                       1efb8b}


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Partition.ObjectId="{d87cbf99-d
                       fbd-11ec-99ad-806e6f6e6963}:PR:{00000000-0000-0000-0000-100000000000}\\\\?\\usbstor#disk&ven_buffal
                       o&prod_hd-pznu3&rev_0000#0000009020006253&0#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : {00000000-0000-0000-0000-100000000000}USBSTOR\\DISK&VEN_BUFFALO&PROD_HD-PZNU3&REV_0000\\0000009020
                       006253&0:DESKTOP-MSI
AccessPaths          : {E:\\, \\\\?\\Volume{cac08e79-d3ff-06af-724b-1a8eba0a53bc}\\}
DiskId               : \\\\?\\usbstor#disk&ven_buffalo&prod_hd-pznu3&rev_0000#0000009020006253&0#{53f56307-b6bf-11d0-94f2-
                       00a0c91efb8b}
DiskNumber           : 1
DriveLetter          : E
GptType              : {ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}
Guid                 : {cac08e79-d3ff-06af-724b-1a8eba0a53bc}
IsActive             : False
IsBoot               : False
IsDAX                : False
IsHidden             : False
IsOffline            : False
IsReadOnly           : False
IsShadowCopy         : False
IsSystem             : False
MbrType              :
NoDefaultDriveLetter : False
Offset               : 1048576
OperationalStatus    : Online
PartitionNumber      : 1
Size                 : 1206358953984
TransitionState      : 1
PSComputerName       :
Type                 : Basic
DiskPath             : \\\\?\\usbstor#disk&ven_buffalo&prod_hd-pznu3&rev_0000#0000009020006253&0#{53f56307-b6bf-11d0-94f2-
                       00a0c91efb8b}


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Partition.ObjectId="{d87cbf99-d
                       fbd-11ec-99ad-806e6f6e6963}:PR:{00000000-0000-0000-00d0-a8e018010000}\\\\?\\usbstor#disk&ven_buffal
                       o&prod_hd-pznu3&rev_0000#0000009020006253&0#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : {00000000-0000-0000-00d0-a8e018010000}USBSTOR\\DISK&VEN_BUFFALO&PROD_HD-PZNU3&REV_0000\\0000009020
                       006253&0:DESKTOP-MSI
AccessPaths          : {F:\\, \\\\?\\Volume{ec0f751f-b1ea-49c8-958d-15c82e0e23ea}\\}
DiskId               : \\\\?\\usbstor#disk&ven_buffalo&prod_hd-pznu3&rev_0000#0000009020006253&0#{53f56307-b6bf-11d0-94f2-
                       00a0c91efb8b}
DiskNumber           : 1
DriveLetter          : F
GptType              : {ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}
Guid                 : {ec0f751f-b1ea-49c8-958d-15c82e0e23ea}
IsActive             : False
IsBoot               : False
IsDAX                : False
IsHidden             : False
IsOffline            : False
IsReadOnly           : False
IsShadowCopy         : False
IsSystem             : False
MbrType              :
NoDefaultDriveLetter : False
Offset               : 1206360002560
OperationalStatus    : Online
PartitionNumber      : 2
Size                 : 53686042624
TransitionState      : 1
PSComputerName       :
Type                 : Basic
DiskPath             : \\\\?\\usbstor#disk&ven_buffalo&prod_hd-pznu3&rev_0000#0000009020006253&0#{53f56307-b6bf-11d0-94f2-
                       00a0c91efb8b}


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Partition.ObjectId="{d87cbf99-d
                       fbd-11ec-99ad-806e6f6e6963}:PR:{00000000-0000-0000-0000-a06025010000}\\\\?\\usbstor#disk&ven_buffal
                       o&prod_hd-pznu3&rev_0000#0000009020006253&0#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : {00000000-0000-0000-0000-a06025010000}USBSTOR\\DISK&VEN_BUFFALO&PROD_HD-PZNU3&REV_0000\\0000009020
                       006253&0:DESKTOP-MSI
AccessPaths          : {X:\\, \\\\?\\Volume{9191af14-867b-4a82-8866-b9b8331b2033}\\,
                       \\\\?\\Volume{9191af14-867b-4a82-8866-b9b8331b2033}\\}
DiskId               : \\\\?\\usbstor#disk&ven_buffalo&prod_hd-pznu3&rev_0000#0000009020006253&0#{53f56307-b6bf-11d0-94f2-
                       00a0c91efb8b}
DiskNumber           : 1
DriveLetter          : X
GptType              : {ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}
Guid                 : {9191af14-867b-4a82-8866-b9b8331b2033}
IsActive             : False
IsBoot               : False
IsDAX                : False
IsHidden             : False
IsOffline            : False
IsReadOnly           : False
IsShadowCopy         : False
IsSystem             : False
MbrType              :
NoDefaultDriveLetter : False
Offset               : 1260046516224
OperationalStatus    : Online
PartitionNumber      : 3
Size                 : 740111155200
TransitionState      : 1
PSComputerName       :
Type                 : Basic
DiskPath             : \\\\?\\usbstor#disk&ven_buffalo&prod_hd-pznu3&rev_0000#0000009020006253&0#{53f56307-b6bf-11d0-94f2-
                       00a0c91efb8b}


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Volume.ObjectId="{d87cbf99-dfbd
                       -11ec-99ad-806e6f6e6963}:VO:\\\\?\\Volume{464b4356-8109-40ec-98dd-ede68818af3e}\\"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : \\\\?\\Volume{464b4356-8109-40ec-98dd-ede68818af3e}\\
AllocationUnitSize   : 4096
DedupMode            : NotAvailable
DriveLetter          :
DriveType            : Fixed
FileSystem           : NTFS
FileSystemLabel      :
FileSystemType       : NTFS
HealthStatus         : Healthy
OperationalStatus    : OK
Path                 : \\\\?\\Volume{464b4356-8109-40ec-98dd-ede68818af3e}\\
ReFSDedupMode        : NotAvailable
Size                 : 648015872
SizeRemaining        : 67846144
PSComputerName       :


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Volume.ObjectId="{d87cbf99-dfbd
                       -11ec-99ad-806e6f6e6963}:VO:\\\\?\\Volume{4abf233b-798d-4865-9a51-39651c6c3261}\\"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : \\\\?\\Volume{4abf233b-798d-4865-9a51-39651c6c3261}\\
AllocationUnitSize   : 4096
DedupMode            : NotAvailable
DriveLetter          : D
DriveType            : Fixed
FileSystem           : NTFS
FileSystemLabel      : DevDrive
FileSystemType       : NTFS
HealthStatus         : Healthy
OperationalStatus    : OK
Path                 : \\\\?\\Volume{4abf233b-798d-4865-9a51-39651c6c3261}\\
ReFSDedupMode        : NotAvailable
Size                 : 56704888832
SizeRemaining        : 44519735296
PSComputerName       :


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Volume.ObjectId="{d87cbf99-dfbd
                       -11ec-99ad-806e6f6e6963}:VO:\\\\?\\Volume{9191af14-867b-4a82-8866-b9b8331b2033}\\"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : \\\\?\\Volume{9191af14-867b-4a82-8866-b9b8331b2033}\\
AllocationUnitSize   : 4096
DedupMode            : NotAvailable
DriveLetter          : X
DriveType            : Fixed
FileSystem           : ReFS
FileSystemLabel      : DevDriveX
FileSystemType       : ReFS
HealthStatus         : Healthy
OperationalStatus    : OK
Path                 : \\\\?\\Volume{9191af14-867b-4a82-8866-b9b8331b2033}\\
ReFSDedupMode        : Disabled
Size                 : 740076552192
SizeRemaining        : 398542860288
PSComputerName       :


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Volume.ObjectId="{d87cbf99-dfbd
                       -11ec-99ad-806e6f6e6963}:VO:\\\\?\\Volume{9582f351-41e1-4a84-bd86-9933fec9e87d}\\"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : \\\\?\\Volume{9582f351-41e1-4a84-bd86-9933fec9e87d}\\
AllocationUnitSize   : 4096
DedupMode            : NotAvailable
DriveLetter          : N
DriveType            : Fixed
FileSystem           : ReFS
FileSystemLabel      : DevDrive (No Clocks)
FileSystemType       : ReFS
HealthStatus         : Healthy
OperationalStatus    : OK
Path                 : \\\\?\\Volume{9582f351-41e1-4a84-bd86-9933fec9e87d}\\
ReFSDedupMode        : Disabled
Size                 : 53687091200
SizeRemaining        : 14656737280
PSComputerName       :


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Volume.ObjectId="{d87cbf99-dfbd
                       -11ec-99ad-806e6f6e6963}:VO:\\\\?\\Volume{cac08e79-d3ff-06af-724b-1a8eba0a53bc}\\"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : \\\\?\\Volume{cac08e79-d3ff-06af-724b-1a8eba0a53bc}\\
AllocationUnitSize   : 4096
DedupMode            : NotAvailable
DriveLetter          : E
DriveType            : Fixed
FileSystem           : NTFS
FileSystemLabel      : Data
FileSystemType       : NTFS
HealthStatus         : Healthy
OperationalStatus    : OK
Path                 : \\\\?\\Volume{cac08e79-d3ff-06af-724b-1a8eba0a53bc}\\
ReFSDedupMode        : NotAvailable
Size                 : 1206358949888
SizeRemaining        : 420842360832
PSComputerName       :


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Volume.ObjectId="{d87cbf99-dfbd
                       -11ec-99ad-806e6f6e6963}:VO:\\\\?\\Volume{d789c1fb-8ca3-4b2c-b48d-3820d1506989}\\"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : \\\\?\\Volume{d789c1fb-8ca3-4b2c-b48d-3820d1506989}\\
AllocationUnitSize   : 4096
DedupMode            : NotAvailable
DriveLetter          : C
DriveType            : Fixed
FileSystem           : NTFS
FileSystemLabel      : Windows
FileSystemType       : NTFS
HealthStatus         : Healthy
OperationalStatus    : OK
Path                 : \\\\?\\Volume{d789c1fb-8ca3-4b2c-b48d-3820d1506989}\\
ReFSDedupMode        : NotAvailable
Size                 : 966006927360
SizeRemaining        : 304578662400
PSComputerName       :


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Volume.ObjectId="{d87cbf99-dfbd
                       -11ec-99ad-806e6f6e6963}:VO:\\\\?\\Volume{ec0f751f-b1ea-49c8-958d-15c82e0e23ea}\\"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : \\\\?\\Volume{ec0f751f-b1ea-49c8-958d-15c82e0e23ea}\\
AllocationUnitSize   : 4096
DedupMode            : NotAvailable
DriveLetter          : F
DriveType            : Fixed
FileSystem           : NTFS
FileSystemLabel      :
FileSystemType       : NTFS
HealthStatus         : Healthy
OperationalStatus    : OK
Path                 : \\\\?\\Volume{ec0f751f-b1ea-49c8-958d-15c82e0e23ea}\\
ReFSDedupMode        : NotAvailable
Size                 : 53686038528
SizeRemaining        : 38156275712
PSComputerName       :


ObjectId             : {1}\\\\DESKTOP-MSI\\root/Microsoft/Windows/Storage/Providers_v2\\WSP_Volume.ObjectId="{d87cbf99-dfbd
                       -11ec-99ad-806e6f6e6963}:VO:\\\\?\\Volume{f3239620-ccd8-43c0-bdc1-15163ac9e0dd}\\"
PassThroughClass     :
PassThroughIds       :
PassThroughNamespace :
PassThroughServer    :
UniqueId             : \\\\?\\Volume{f3239620-ccd8-43c0-bdc1-15163ac9e0dd}\\
AllocationUnitSize   : 4096
DedupMode            : NotAvailable
DriveLetter          :
DriveType            : Fixed
FileSystem           : NTFS
FileSystemLabel      :
FileSystemType       : NTFS
HealthStatus         : Healthy
OperationalStatus    : OK
Path                 : \\\\?\\Volume{f3239620-ccd8-43c0-bdc1-15163ac9e0dd}\\
ReFSDedupMode        : NotAvailable
Size                 : 723513344
SizeRemaining        : 51814400
PSComputerName       :
```

The answer is clear from the disk layout:

**Copy to `C:\` — the NVMe SSD (Disk 0, WDC PC SN730).**

- `C:\` has **304 GB free**, more than enough for the 93 GB GPKG plus FGB outputs
- It's the internal NVMe — the only SSD in your setup
- NTFS — no filesystem compatibility concerns with SQLite/WAL
- Accessible from both Windows (`C:\`) and WSL (`/mnt/c/`)

The other options don't work:

- `D:\` — same NVMe as C:, only 44 GB free, not enough
- `X:\` — ReFS is fine, but it's on the **same physical USB HDD as E:**, zero performance gain
- `N:\` — WSL VHD, ReFS, only 13.7 GB free, not enough

**ReFS note**: Your X:\ and N:\ volumes have ReFS with dedup disabled — SQLite WAL works fine on ReFS in that configuration. Just not relevant here since X:\ is on the HDD anyway.

So: TeraCopy `E:\GEODATA\us_parcels\LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg` (plus the `-shm` and `-wal` companion files) to `C:\GEODATA\us_parcels\` or wherever fits your conventions, update your VRT `SrcDataSource` accordingly, and proceed.

---

# if my C drive gets full im not guna be happy! will do though, just need to make sure to get it off afterwards as this computer is pack full of over 8 years of crap and a ton of installs/VMs/virtual disks/runtimes/appdata/etc. its a mess but its also amazing

Totally valid concern — but the math works out fine. C:\ has **304 GB free**, the GPKG is 93 GB, leaving ~210 GB after the copy. That's not tight.

The key thing to remember: **this is a temporary working copy, not permanent storage.** The workflow is:

1. TeraCopy GPKG to C:\
2. Run Phase 0 (manifest) + Phase 1 (FGB extractions) against it
3. Delete the C:\ copy — you're done with the GPKG forever at that point
4. FGBs (~40–55 GB total for all states, or ~2–4 GB per state as you go) become the new source of truth and can live wherever makes sense

You'll have the GPKG back on C:\ for maybe a few days of active work total. Once the FGBs exist and are validated, the original GPKG only needs to stay on E:\ as an archive (and Kaggle is always there as a recovery point anyway).
<span style="display:none">[^15_1][^15_2][^15_3][^15_4][^15_5][^15_6][^15_7]</span>

<div align="center">⁂</div>

[^15_1]: https://www.safegraph.com/blog/best-practices-for-working-with-large-quantities-of-geospatial-data

[^15_2]: https://www.signiant.com/resources/articles/big-data-big-challenges-geospatial/

[^15_3]: https://www.solved.scality.com/geospatial-data-storage/

[^15_4]: https://datagroomr.com/top-10-best-practices-for-managing-and-cleansing-large-datasets/

[^15_5]: https://millermountain.com/geospatialblog/2017/04/10/gis-data-storage/

[^15_6]: https://spatial-eye.com/blog/spatial-analysis/what-are-the-best-practices-for-geospatial-data-collection/

[^15_7]: https://www.reddit.com/r/gis/comments/d1mh39/how_to_work_with_big_geospatial_data/


---

# Do you think the previous work I was doing with the gpkg and GDAL would have been noticeably faster if it wasn’t on E?

Yes, noticeably — but with a nuance specific to your workload.

Your USB HDD (Buffalo HD-PZNU3) is bottlenecked twice: first by the spinning disk itself (~80–120 MB/s sequential), and then by the USB 3.0 interface on top of that. The NVMe C:\ does ~3,500 MB/s sequential and effectively unlimited random I/O.

For the **sequential part** of the extraction (reading 154M feature rows page by page), you'd see a real speedup — probably 3–5× faster in wall-clock time just from sequential throughput alone.

For **`SORT_BY_BBOX=YES`** specifically, which builds a temporary R-tree during output, the speedup would be even more pronounced because that step involves intensive random writes to a temp file. That's where HDDs hurt most and where NVMe would make the biggest difference.

However — a chunk of the total time is **CPU-bound**: WKB geometry decoding, ZSTD level 9 compression, Arrow batch assembly. That portion doesn't change regardless of storage. So realistically the 45–90 min per state extractions probably would have been more like **20–35 min on NVMe** — meaningful, not transformative. Still worth doing for the remaining 48 states.

The `SORT_BY_BBOX` temp file also writes back to the same drive as the source by default. Worth explicitly setting `CPL_TMPDIR` to C:\ during extraction so the temp R-tree doesn't thrash the same spindle as the read:

```powershell
$env:CPL_TMPDIR = "C:\Temp\gdal"
```

<span style="display:none">[^16_1][^16_10][^16_11][^16_12][^16_13][^16_14][^16_15][^16_2][^16_3][^16_4][^16_5][^16_6][^16_7][^16_8][^16_9]</span>

<div align="center">⁂</div>

[^16_1]: https://www.reddit.com/r/GrandTheftAutoV/comments/1ml05y/gtav_ssd_vs_hdd_performance_comparison_finally/

[^16_2]: https://www.youtube.com/watch?v=CW-GQJVaZcc

[^16_3]: https://www.youtube.com/watch?v=hUGt0M6YhsU

[^16_4]: https://www.youtube.com/watch?v=FQpiZ44GyYU

[^16_5]: https://forums.crateentertainment.com/t/ssd-and-gd/109671

[^16_6]: https://windowsvps.host/blog/speed-vs-capacity-nvme-ssd-and-hdd-compared-in-2024/

[^16_7]: https://www.youtube.com/watch?v=F2gn-ntl0No

[^16_8]: https://oneuptime.com/blog/post/2026-03-31-rook-choose-hdd-ssd-nvme-workloads/view

[^16_9]: https://www.youtube.com/watch?v=c1YtJ1EPqnc

[^16_10]: https://www.servermania.com/kb/articles/nvme-vs-sata-database-cache-performance

[^16_11]: https://gamesandgeeks.pk/nvme-vs-ssd-vs-hdd-2025/

[^16_12]: https://www.reddit.com/r/jellyfin/comments/1ri5cvz/noticeable_performance_difference_between_hdd_and/

[^16_13]: https://www.youtube.com/watch?v=f9OZ_krCYpk

[^16_14]: https://bbs.archlinux.org/viewtopic.php?id=287244

[^16_15]: https://www.youtube.com/watch?v=ssBHUfNAxcg


---

# so I copied them over to C:\GEODATA\LR_*.gpkg including the additional other 2 files, however, then I ran a simple `ogrinfo C:\\GEODATA\\LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg` and this made the other 2 files dissapear

Not a problem at all — this is expected SQLite behavior.

When `ogrinfo` opened the GPKG, read it, and closed the connection cleanly, SQLite saw that the WAL file was already 0 bytes (fully checkpointed — exactly what you observed earlier) and deleted both companion files on clean close. This is correct behavior, not data loss.[^17_1]

The GPKG itself is completely intact. WAL mode is still set permanently in the database header — the next time any connection opens the file, SQLite will automatically recreate the `-shm` and `-wal` files. You'll see them reappear the moment you run any read or write operation against it again.

So the copy to C:\ worked fine, the file is healthy, and you're ready to proceed.
<span style="display:none">[^17_10][^17_11][^17_12][^17_13][^17_14][^17_15][^17_2][^17_3][^17_4][^17_5][^17_6][^17_7][^17_8][^17_9]</span>

<div align="center">⁂</div>

[^17_1]: https://sqlite.org/forum/forumpost/2a8c51e0b8?t=h

[^17_2]: https://github.com/PostgresApp/PostgresApp/issues/724

[^17_3]: https://www.reddit.com/r/QGIS/comments/marq24/why_would_my_gpkg_file_size_grow_when_i_deleted/

[^17_4]: https://gdal.org/en/stable/programs/ogr2ogr.html

[^17_5]: https://www.youtube.com/watch?v=ghUy0DLTXH0

[^17_6]: https://github.com/qgis/QGIS/issues/51188

[^17_7]: https://cloud.r-project.org/web/packages/gpkg/refman/gpkg.html

[^17_8]: https://github.com/groue/GRDB.swift/issues/739

[^17_9]: https://lists.osgeo.org/pipermail/gdal-dev/2017-March/046327.html

[^17_10]: https://community.home-assistant.io/t/strange-behaviour-of-sqlite-database-with-wal-and-shm-files/701948

[^17_11]: http://erouault.blogspot.com/2017/03/dealing-with-huge-vector-geopackage.html

[^17_12]: https://github.com/opengisch/QField/issues/804

[^17_13]: https://gdal-dev.osgeo.narkive.com/fSQtwG6S/dropping-geopackage-table-doesn-t-reduce-file-size

[^17_14]: https://stackoverflow.com/questions/64878314/what-could-be-preventing-sqlite-wal-files-from-being-cleared

[^17_15]: https://www.lightroomqueen.com/community/threads/lock-shm-and-wal-files-dont-go-away.51740/


---

# and sorry if you alraedy told me this, but does it matter if I use either a dev drive or WSL and then /mnt/c/* references to the file etc. now? in other words does it matter where I put the code that will run using the gpkg file between either dev drive or WSL vs. C?

Yes it matters, and the rule is simple:

**Run the code from the same OS that natively owns the filesystem the GPKG is on.**

The GPKG is on C:\ — a Windows NTFS volume. So run the extraction code from **Windows** (PowerShell pixi). Accessing `C:\` from WSL via `/mnt/c/` goes through the 9P bridge and is meaningfully slower for large file I/O — the same problem you had with E:\, just less severe since it's NVMe instead of HDD.[^18_1]

The practical split for your setup:


| Task | Run from | Reason |
| :-- | :-- | :-- |
| Phase 0 — RSQLite manifest against GPKG | Windows R | GPKG on C:\, direct NTFS |
| Phase 1 — ogr2ogr GPKG→FGB | Windows PowerShell pixi | Same |
| Phase 2 — DuckDB FGB→Parquet→Tigris | WSL R | FGBs can live on WSL native ext4, or C:\ is acceptable here since FGB reads are sequential and less sensitive |
| All code editing / git / tooling | WSL | Better environment |

Dev Drive (X:\ ReFS) doesn't help here — it's still on the same USB HDD as E:\. The Dev Drive performance benefits are for package managers and many-small-files workloads anyway, not large sequential reads.[^18_2]

Bottom line: **code lives wherever you want in WSL for version control and editing. But the actual process executing against the GPKG should be a native Windows process.**
<span style="display:none">[^18_10][^18_11][^18_12][^18_13][^18_14][^18_15][^18_3][^18_4][^18_5][^18_6][^18_7][^18_8][^18_9]</span>

<div align="center">⁂</div>

[^18_1]: https://github.com/microsoft/WSL/issues/4197

[^18_2]: https://discourse.julialang.org/t/pkg-performance-on-windows-dev-drive/126948

[^18_3]: https://www.reddit.com/r/microsoftsucks/comments/1gdg65n/wsl2_ubuntu_significantly_outperforms_windows_11/

[^18_4]: https://github.com/OSGeo/gdal/issues/4033

[^18_5]: https://forums.developer.nvidia.com/t/when-wsl-is-faster-than-windows/220998

[^18_6]: https://stackoverflow.com/questions/75683957/gdal-geopackage-gpkg-vs-shapefile-shp-performance

[^18_7]: https://dalencatt.com/2023/07/25/crafting-a-powerful-development-environment-with-wsl-and-docker/

[^18_8]: https://stackoverflow.com/questions/79724928/volume-mappings-from-windows-to-wsl-are-causing-problems-when-using-mnt-c

[^18_9]: https://news.ycombinator.com/item?id=44037717

[^18_10]: https://www.reddit.com/r/wsl2/comments/1nmsta9/filesystem_performance_comparision_and_having_wsl/

[^18_11]: https://gdal.org/en/stable/user/virtual_file_systems.html

[^18_12]: https://news.ycombinator.com/item?id=27897427

[^18_13]: https://pomeroy.me/2023/12/how-i-fixed-wsl-2-filesystem-performance-issues/

[^18_14]: https://insiderthreatmatrix.org/detections/DT123

[^18_15]: https://github.com/microsoft/WSL/issues/4197?timeline_page=1


---

# ok so just call the script or whatever from C drive but source code can be stored wherever

Exactly. Source code lives wherever you want (WSL, git repo, wherever). The only thing that matters is that the **process executing against the GPKG** is a native Windows process — meaning you invoke it from PowerShell, not from a WSL terminal.

So in practice: write and edit your scripts in WSL, but when it's time to actually run the ogr2ogr or R extraction commands against the GPKG, open a PowerShell terminal and run them there.
<span style="display:none">[^19_1][^19_10][^19_11][^19_12][^19_13][^19_14][^19_15][^19_2][^19_3][^19_4][^19_5][^19_6][^19_7][^19_8][^19_9]</span>

<div align="center">⁂</div>

[^19_1]: https://stackoverflow.com/questions/68972448/why-is-wsl-extremely-slow-when-compared-with-native-windows-npm-yarn-processing

[^19_2]: https://www.reddit.com/r/rust/comments/1gef1of/comparing_performance_of_native_windows_vs_wsl2/

[^19_3]: https://www.xda-developers.com/wsl-great-run-linux-natively-instead/

[^19_4]: https://news.ycombinator.com/item?id=34638679

[^19_5]: https://vxlabs.com/2019/12/06/wsl2-io-measurements/

[^19_6]: https://www.reddit.com/r/qemu_kvm/comments/1n8ih2t/9p_shared_folders_are_painfully_slow_5mbs_max/

[^19_7]: https://www.linkedin.com/pulse/managing-native-linux-vs-wsl12-technical-comparison-windows-ahl-nza6f

[^19_8]: https://www.linkedin.com/pulse/optimizing-wsl2-claude-code-complete-performance-tuning-cooper-rlqzc

[^19_9]: https://windowsforum.com/threads/wsl2-vs-native-ubuntu-on-windows-11-25h2-real-world-performance.380888/

[^19_10]: https://github.com/microsoft/WSL/discussions/9412

[^19_11]: https://www.facebook.com/groups/linux.fans.group/posts/9020444814663887/

[^19_12]: https://knowledge.e.southern.edu/context/mscs_reports/article/1012/viewcontent/A_Further_Performance_Comparison_of_Operations_in_the_File_System.pdf

[^19_13]: https://support.gurobi.com/hc/en-us/community/posts/17481975903121-Solve-speed-difference-between-Linux-Windows-and-WSL2

[^19_14]: https://en.wikipedia.org/wiki/Comparison_of_file_systems

[^19_15]: https://adaebabbage.files.wordpress.com/2011/04/comparison_of_file_systems.pdf


---

# the thing is that the pixi environments etc. would be in the source code locations..

You're right — that's the actual constraint. If the pixi environment (with the Windows GDAL binary) lives in your WSL filesystem, then `pixi run ogr2ogr` from PowerShell pointing into `/home/user/...` gets complicated.

The practical resolution: **have two pixi environments** — one in WSL (for Phase 2 onwards, DuckDB/R work) and one on the Windows side (for Phase 0/1 GPKG extraction). They share the same `pixi.toml` spec, pixi just resolves platform-appropriate binaries for each. The Windows one can live on C:\ or D:\ alongside the project, or you can just use the Windows pixi install you already have for the extraction scripts since you've already proven that works (your GA and NC extractions both succeeded from PowerShell).

Since Phase 0 and Phase 1 are a small, bounded set of commands you've already validated, the path of least resistance is: keep running those specific extraction commands exactly as you have been from PowerShell with the Windows pixi, and do everything else from WSL. Don't over-engineer the environment setup just for two phases that'll each run once per state.
<span style="display:none">[^20_1][^20_10][^20_11][^20_12][^20_13][^20_14][^20_15][^20_2][^20_3][^20_4][^20_5][^20_6][^20_7][^20_8][^20_9]</span>

<div align="center">⁂</div>

[^20_1]: https://www.reddit.com/r/bioinformatics/comments/1mbpihn/best_way_to_install_and_operate_linux_on_windows/

[^20_2]: https://discuss.avogadro.cc/t/switching-to-pixi-if-available/7156

[^20_3]: https://prefix-dev.github.io/pixi/v0.32.1/features/system_requirements/

[^20_4]: https://github.com/prefix-dev/pixi/issues/417

[^20_5]: https://prefix-dev.github.io/pixi/dev/workspace/system_requirements/

[^20_6]: https://www.reddit.com/r/PowerShell/comments/111tq4x/development_in_powershell_vs_wsl/

[^20_7]: https://github.com/prefix-dev/pixi/issues/3055

[^20_8]: https://github.com/microsoft/vscode-python/issues/25197

[^20_9]: https://optimizelabsmart.blogspot.com/?page=en-git-adenhq-hive-1770406342689

[^20_10]: https://www.reddit.com/r/JetBrains_Rider/comments/1i6bpxp/wsl_or_powershell/

[^20_11]: https://news.ycombinator.com/item?id=45751400

[^20_12]: https://discuss.avogadro.cc/t/pixi-and-plugin-environments/6713

[^20_13]: https://pixi.prefix.dev/latest/installation/

[^20_14]: https://mintlify.com/prefix-dev/pixi/advanced/environment-activation

[^20_15]: https://ericmjl.github.io/blog/2024/8/16/its-time-to-try-out-pixi/


---

# its just from your prior answer:

The answer is clear from the disk layout:
Copy to C:\ — the NVMe SSD (Disk 0, WDC PC SN730).
C:\ has 304 GB free, more than enough for the 93 GB GPKG plus FGB outputs
It's the internal NVMe — the only SSD in your setup
NTFS — no filesystem compatibility concerns with SQLite/WAL
Accessible from both Windows (C:\) and WSL (/mnt/c/)
The other options don't work:
D:\ — same NVMe as C:, only 44 GB free, not enough
X:\ — ReFS is fine, but it's on the same physical USB HDD as E:, zero performance gain
N:\ — WSL VHD, ReFS, only 13.7 GB free, not enough
ReFS note: Your X:\ and N:\ volumes have ReFS with dedup disabled — SQLite WAL works fine on ReFS in that configuration. Just not relevant here since X:\ is on the HDD anyway.
So: TeraCopy E:\GEODATA\us_parcels\LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg (plus the -shm and -wal companion files) to C:\GEODATA\us_parcels\ or wherever fits your conventions, update your VRT SrcDataSource accordingly, and proceed.

it seemed like the /mnt/ wouldn't matter, but ok will do

You're right to call that out — I contradicted myself. I said "accessible from both Windows (`C:\`) and WSL (`/mnt/c/`)" implying it wouldn't matter, then later said accessing it via `/mnt/c/` from WSL would be slow due to 9P.

The honest answer: **for Phase 1 ogr2ogr specifically, use Windows PowerShell to call pixi since that's already your working setup and avoids the 9P question entirely.** The `/mnt/c/` path is fine for everything else (reading configs, editing VRTs, DuckDB in Phase 2 where sequential FGB reads are less sensitive to the bridge overhead).

Don't change anything about how you're already running the extraction scripts — that workflow is proven and correct. The GPKG being on C:\ instead of E:\ is the only meaningful change.

