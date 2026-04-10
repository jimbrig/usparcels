# US Parcels → GeoParquet Pipeline

> **Stack**: R · targets · crew · GDAL/ogr2ogr · DuckDB · shard · AzureStor  
> **Input**: ~100 GB US Parcels GeoPackage  
> **Output**: County-partitioned GeoParquet on Azure Blob Storage (tigris)

---

## Architecture

```
100 GB GPKG (SQLite/GPKG)
        │
        │  [routing_index]  ← shard shared-memory (main process)
        │       ↓ zero-copy FID/STATEFP/COUNTYFP index for worker routing
        │
        ├── crew worker pool (N parallel state jobs) ─────────────────────────
        │
Stage 1 │  GPKG ──[ogr2ogr -where STATEFP + -spat bbox]──► statefp=XX/XX.fgb
        │                                                   FlatGeobuf checkpoint
        │  • Attribute filter pushes to SQLite WHERE clause
        │  • Spatial bbox pre-filter limits R-tree page reads
        │  • Spatially indexed FGB becomes re-entry point for all downstream
        │    stages — avoids returning to the GPKG if parquet config changes
        │
Stage 2 │  XX.fgb ──[ogr2ogr -f Parquet lco*]──► statefp=XX/XX.parquet
        │                                          State-level GeoParquet
        │  Key flags (GDAL >= 3.9):
        │    COMPRESSION=ZSTD           best size/speed for spatial data
        │    ROW_GROUP_SIZE=65536        64k rows/group
        │    WRITE_COVERING_BBOX=YES    per-feature bbox cols → pushdown filters
        │    SORT_BY_BBOX=YES           Hilbert-sort → spatial row group locality
        │    FID=fid                    preserve original FID column
        │
Stage 3 │  XX.parquet ──[DuckDB COPY PARTITION_BY(countyfp)]──►
        │    statefp=XX/
        │      countyfp=001/data_0.parquet
        │      countyfp=003/data_0.parquet
        │      ...
        │  ORDER BY countyfp, geometry_bbox_xmin → spatial locality within file
        │
Stage 4 │  Local county dirs ──[AzureStor::multiupload_blob]──► Azure Blob
        │    parcels/v1/statefp=XX/countyfp=YYY/data_0.parquet
        │  Idempotent: existing blobs skipped unless force=TRUE
        │
Manifest│  pipeline_manifest ← tar_combine of all upload_status targets
        └─────────────────────────────────────────────────────────────────────
```

---

## Prerequisites

### System

| Tool | Min Version | Notes |
|------|-------------|-------|
| GDAL / ogr2ogr | **3.9.0** | Required for `WRITE_COVERING_BBOX`, `SORT_BY_BBOX`, native Parquet driver |
| DuckDB CLI | 0.10+ | Optional; DuckDB R package is sufficient |
| R | 4.3+ | |

Verify: `sf::sf_extSoftVersion()[["GDAL"]]`

### R Packages

```r
# CRAN
install.packages(c(
  "targets", "tarchetypes", "crew",
  "sf", "arrow", "duckdb", "DBI", "RSQLite",
  "glue", "fs", "tibble", "dplyr", "purrr",
  "config", "AzureStor"
))

# GitHub
remotes::install_github("bbuchsbaum/shard")       # shared-memory parallel inputs
remotes::install_github("christophertull/freestiler") # for downstream tile work
remotes::install_github("JoshLDowns/pmtiles")        # for downstream tile work
```

---

## Configuration

### `config.yml`

Edit `config.yml` to set local paths and worker count. All paths use forward
slashes and should be absolute.

```yaml
default:
  gpkg_path: "/data/parcels/us_parcels.gpkg"
  fgb_dir:   "/data/parcels/fgb"
  state_parquet_dir:  "/data/parcels/parquet_state"
  county_parquet_dir: "/data/parcels/parquet_county"
  workers: 8
  az_prefix: "parcels/v1"
```

Worker count rule of thumb:
```
workers = min(logical_cores - 2, floor(available_ram_gb / 4))
```

### `.Renviron`

```bash
# Azure Blob SAS URL for the tigris container
TIGRIS_BLOB_SAS_URL=https://<account>.blob.core.windows.net/<container>?<sas_token>

# Optional: activate dev profile
# R_CONFIG_ACTIVE=dev
```

---

## Quickstart

```r
library(targets)

# 1. Smoke test: single state (GA, already validated)
tar_make(names = c("state_fgb_GA", "state_parquet_GA", "county_parquet_dir_GA"))

# 2. Run full CONUS pipeline
tar_make()

# 3. Resume after interruption (targets skips completed stages automatically)
tar_make()

# 4. Run only Stage 1 (FGB extraction) for all states
tar_make(names = starts_with("state_fgb_"))

# 5. Visualise DAG
tar_visnetwork()

# 6. Check what is outdated / needs re-running
tar_outdated()

# 7. Force-invalidate county partitions (e.g. after changing partition config)
tar_invalidate(starts_with("county_parquet_dir_"))
tar_make()
```

---

## Output Layout

```
Azure Blob: parcels/v1/
  statefp=01/
    countyfp=001/data_0.parquet
    countyfp=003/data_0.parquet
    ...
  statefp=04/
    ...
  statefp=13/   ← Georgia
    countyfp=001/data_0.parquet
    ...

Local (county_parquet_dir):
  statefp=13/
    countyfp=001/data_0.parquet
    ...

Local (fgb_dir):           ← checkpoint layer, keep these
  statefp=13/GA.fgb

Local (state_parquet_dir): ← can delete after county partition validated
  statefp=13/GA.parquet
```

Consuming from R (client package):
```r
library(arrow)

# Open full CONUS dataset (cloud or local)
ds <- arrow::open_dataset(
  "https://<account>.blob.core.windows.net/<container>/parcels/v1",
  format      = "parquet",
  partitioning = c("statefp", "countyfp")
)

# Filter to Fulton County, GA (FIPS 13121)
fulton <- ds |>
  dplyr::filter(statefp == "13", countyfp == "121") |>
  dplyr::collect()
```

---

## Re-entry Strategy (FGB Checkpoint)

If parquet configs change (e.g. different row group size, added columns,
changed compression), you do **not** need to re-extract from the GPKG:

```r
# Invalidate only Stage 2 onwards; Stage 1 FGB files are reused
tar_invalidate(starts_with("state_parquet_"))
tar_make()  # skips all state_fgb_* targets, re-runs from FGB
```

This is the primary value of the FGB intermediate layer — it decouples the
slow (~hours) GPKG extraction from the fast (~minutes) parquet configuration.

---

## Parallel Performance Notes

- **Stage 1 (GPKG → FGB)** is the bottleneck — all workers contend on the
  single SQLite file. `shard` mitigates routing overhead; sequential page reads
  are minimised by combining `-where STATEFP` (attribute pushdown) with
  `-spat bbox` (spatial index pre-filter). Expect ~2-5 min/state on NVMe.

- **Stage 2 (FGB → Parquet)** is CPU-bound (ZSTD compression). Scales linearly
  with worker count. Expect ~30-90s/state depending on size.

- **Stage 3 (County partition)** is memory + I/O bound via DuckDB. Each worker
  processes one state in isolation; no inter-worker coordination. ~1-3 min/state.

- **Stage 4 (Upload)** is network-bound. `n_threads=8` per worker saturates most
  uplinks for typical state file counts (100-300 files).

---

## Disk Space Estimates

| Artifact | Per State | CONUS Total |
|----------|-----------|-------------|
| FGB checkpoint | ~1.5 GB avg | ~75 GB |
| State GeoParquet | ~1.0 GB avg | ~50 GB |
| County GeoParquet | ~1.1 GB avg | ~55 GB |
| **Total local** | | **~180 GB** |

Delete `state_parquet_dir` after county partition validation to reduce to ~130 GB.
