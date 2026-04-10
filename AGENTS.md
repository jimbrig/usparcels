# US Parcels Data Pipeline

## Project Overview

Geospatial data engineering workspace for processing a nationwide US parcel
dataset (~97 GB GPKG, 154.9M features) into cloud-native formats hosted on
Tigris (S3-compatible blob storage). The pipeline produces per-state FlatGeoBuf
intermediates, county-partitioned GeoParquet, and eventually PMTiles for map
visualization.

Future direction: multi-source geospatial platform incorporating TIGER, FEMA
NFHL, and other public datasets with data/API interfaces and a MapLibre web
frontend. Repository structure and separation of concerns are still evolving.

## Source Data

- **File**: `LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg` (Land Records US / Kaggle)
- **Location**: `C:\GEODATA\` on NVMe SSD (not in repo; gitignored)
- **Layer**: `lr_parcel_us`, EPSG:4326, MultiPolygon, FID column `lrid`
- **Features**: 154,891,095 across 55 state/territory FIPS codes, 3,229 counties
- **Indexes**: R-tree spatial + B-tree on `(statefp, countyfp, geoid)`
- **WAL mode**: active

## Pipeline Stages

| Stage | Description | Engine | Status |
|-------|-------------|--------|--------|
| 0 | GPKG inventory, indexing, manifests | RSQLite, GDAL ogrinfo | Done |
| 1 | GPKG to per-state FlatGeoBuf | ogr2ogr (GDAL 3.12+) | In progress |
| 2 | FGB to county-partitioned GeoParquet | TBD (GDAL vs DuckDB) | Not started |
| 3 | PMTiles (MLT encoding) | freestiler / tippecanoe | Not started |
| 4 | Data browser + MapLibre web app | TBD | Not started |
| 5 | Additional sources (TIGER, FEMA, etc.) | TBD | Not started |

## Key Artifacts

### `data/meta/`

Manifests and reference data that drive all downstream work:

- `manifest_state_county.csv` -- 3,229 rows (statefp, countyfp, feature counts)
- `manifest_state_rollup.csv` -- 55 rows (state-level aggregates)
- `state_bboxes.csv` -- 56 rows (TIGER/Census bounding boxes)

### `data/sources/`

- `parcels.vrt` -- OGR VRT with local-windows, local-wsl, and cloud source layers;
  canonical `parcels` alias resolves to `parcels-local-windows`

### FGB Output Schema (47 columns)

Dropped from source: `parcelstate`, `lrversion`, `halfbaths`, `fullbaths`.
Partition keys: `statefp` (2-char FIPS), `countyfp` (3-char FIPS).

### Tigris Bucket Layout (`noclocks-parcels`)

```
flatgeobuf/statefp=XX/parcels.fgb
geoparquet/statefp=XX/countyfp=YYY/data_0.parquet   (future)
pmtiles/statefp=XX/parcels.pmtiles                   (future)
```

## Environment

- **pixi** manages GDAL 3.12.3 + libgdal-arrow-parquet on `win-64`
- **rclone** for S3 uploads to Tigris (config in `config/rclone.conf`, gitignored)
- **GDAL env vars**: `OGR_SQLITE_PRAGMA`, `OGR_GPKG_NUM_THREADS`, `GDAL_CACHEMAX`
  set at script level; GDAL VSI/S3 config via `config/gdalrc.ps1` (gitignored)
- **R**: not a formal package yet; `R/` contains utility modules sourced as needed
- **Secrets**: Tigris credentials via `.env` / `.Renviron` (gitignored); see
  `.env.example` for variable names

## Repository Structure

```
R/                    utility modules (parcels_*, gdal_*, utils_*)
scripts/
  pwsh/               PowerShell scripts (Windows-native)
  r/                  standalone R scripts (index creation, manifests, bboxes)
  shell/              bash scripts (from WSL era, may need porting)
config/               GDAL, rclone, service configs (secrets gitignored)
data/meta/            manifests and reference data (committed)
data/sources/         VRT source definitions (committed)
data/cache/           transient cached data (gitignored contents)
docker/               Dockerfiles for PostGIS, Martin, GDAL
docs/reference/       architecture discussions, command references
docs/sitrep/          session summaries
logs/                 extraction and processing logs
```

## Coding Conventions

### R

- Namespace-prefix all non-base functions: `dplyr::filter()`, `purrr::map()`
- Native pipe only: `|>` (never `%>%`)
- Use `cli` for messages and `rlang` for conditions: `cli::cli_abort()`, etc.
- Use `httr2` for HTTP (never `httr`)
- Use `htmltools::tags$<tag>()` for HTML elements
- File naming: `{prefix}_{concern}.R` (e.g. `gdal_ogr.R`, `utils_checks.R`)
- Function naming: `{module}_{verb}()` (e.g. `parcels_extract_fgb()`)
- Comments: lowercase, sparingly, only for non-obvious logic
- No emojis in code or output

### Scripts

- PowerShell (`.ps1`) preferred on Windows; bash (`.sh`) for cross-platform/CI
- GDAL commands use `pixi run ogr2ogr` / `pixi run ogrinfo` to resolve
  platform-specific binaries

### General

- Large data files (GPKG, FGB, Parquet, PMTiles) are gitignored
- Secrets never committed; use env vars and gitignored config files
- `config/config.yml` centralizes paths and connection settings; secrets
  reference `Sys.getenv()` via `!expr` tags

## Optional Development Tools

These are not pipeline dependencies but useful for inspection and debugging:

- **fgbdump** ([github.com/C-Loftus/fgbdump](https://github.com/C-Loftus/fgbdump)) -- Rust TUI for inspecting FGB files (metadata, columns, map extent). Works on remote S3/VSI URLs with GDAL auth env vars set. Install: `cargo install --git https://github.com/c-loftus/fgbdump`

## Remote Access and HTTP Range Requests

Once all per-state FGBs are uploaded to Tigris, all Phase 2+ work operates **remote-only** -- the local GPKG is no longer a dependency.

### Format Range-Request Behavior

### Tigris Bucket Access

The `noclocks-parcels` bucket is **publicly readable**. Two access methods work for reads:

- **`/vsicurl/https://noclocks-parcels.t3.storage.dev/...`** -- generic GDAL HTTPS range-request handler; no credentials required; works for any tool that speaks HTTP (GDAL, DuckDB, fgbdump, browsers). Use this for public read access.
- **`/vsis3/noclocks-parcels/...`** -- S3-API access via AWS env vars (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL=https://t3.storage.dev`); required for writes; generally more efficient chunk management than `/vsicurl/` for large files.

For writes (uploading new objects), only `/vsis3/` works. For reads, prefer `/vsicurl/` when credentials are not available or when sharing access patterns with external tools. DuckDB can read public objects via plain HTTPS without any extension configuration.

### Format Range-Request Behavior

| Format | Index location | Range request pattern | Can write to /vsis3? |
|--------|---------------|----------------------|----------------------|
| FlatGeoBuf | Header (start) → Hilbert R-tree → features | 2-3 requests: header + index nodes + matching features | No -- seekable output required |
| GeoParquet | Footer (end) → row group ranges | Footer first, then targeted row group fetches | Yes -- append-only write |
| PMTiles | Radix trie (start) | Direct tile offset lookup, one range per tile | No -- seekable output required |

`/vsicurl/` issues standard HTTP range requests (`Range: bytes=X-Y`). `/vsis3/` uses the S3 API which has better support for parallel chunk reads and retries. For FGB and Parquet served from Tigris, both work identically for spatial queries since Tigris supports byte-range requests natively.

**FGB write constraint**: the Hilbert spatial index requires materializing all features, sorting by Hilbert position, then back-seeking to write the header. S3 (and `/vsis3/`) is append-only. Workarounds: `/vsimem/` (in-memory FS) or `/vsicache/` as intermediate, then stream complete file to S3. For this project FGBs are extracted locally and uploaded via rclone.

**Phase 2 remote workflow**: once FGBs are in Tigris, `ogr2ogr /vsis3/output.parquet /vsicurl/https://noclocks-parcels.t3.storage.dev/flatgeobuf/statefp=XX/parcels.fgb` or equivalent DuckDB `httpfs` reads work natively -- FGB is read via HTTP range requests against the Hilbert index, Parquet is written directly to S3. No local staging required.

## Important Constraints

- **GPKG is read-only** after index creation; all mutations happen downstream
- **FGB requires seekable output** -- cannot write directly to `/vsis3/`;
  extract locally then upload via rclone
- **Phase 2 engine is undecided** -- GDAL and DuckDB each have tradeoffs for
  GeoParquet creation; do not assume one over the other
- **No formal R package structure** (`DESCRIPTION`, `NAMESPACE`) -- this is a
  workspace/monorepo, not an installable package
- **Windows-native development** -- paths use `C:\` or `C:/` format; WSL paths
  (`/mnt/c/`) exist in legacy scripts but are not the active environment
