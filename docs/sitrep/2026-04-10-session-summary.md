# Situation Report: 2026-04-10

## Overview

First working session for the US Parcels data pipeline. Focused on Phase 0 (GPKG metadata/inventory) and Phase 1 (FlatGeoBuf extraction). Three states successfully extracted, manifests generated, and infrastructure established.

## Source Data

- **File**: `LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg`
- **Size**: 96.85 GB (93.66 GB data + 3.19 GB B-tree index added this session)
- **Features**: 154,891,095 across 55 state/territory FIPS codes, 3,229 county-level groups
- **Layer**: `lr_parcel_us`, EPSG:4326, MultiPolygon, FID column `lrid`
- **Location**: `C:\GEODATA\` (NVMe SSD), accessible via WSL at `/mnt/c/GEODATA/`
- **WAL mode**: active (set prior to this session)

## Completed Work

### Phase 0 -- GPKG Preparation

| Task | Time | Notes |
|---|---|---|
| B-tree index `idx_parcel_state_county` on `(statefp, countyfp, geoid)` | 5.5 min | ANALYZE run, EXPLAIN confirms covering index scan |
| County manifest (3,229 rows) | 15.3 min | GROUP BY statefp, countyfp with feature counts, null geom counts, lrid ranges |
| State rollup manifest (55 rows) | 14.6 min | Aggregated from county manifest with pct, cumulative pct, size estimates |
| Attribute profiling (via DuckDB on GA parquet) | 4 sec | Full null/empty rates for all 51 columns |
| Geometry complexity profiling | 9 sec | Vertex distribution, invalid geom count |
| State bboxes from TIGER/Census | 2 sec | 56 states/territories via `tigris::states()` + `sf::st_bbox()` |

### Phase 1 -- FGB Extraction

| State | FIPS | Features | FGB Size | Time | Notes |
|---|---|---|---|---|---|
| Georgia | 13 | 4,754,448 | 2.9 GB | 4 min | Clean, no issues |
| North Carolina | 37 | 5,756,891 | 4.1 GB | 6 min | 1 saledate warning (non-blocking) |
| Texas | 48 | 13,689,455 | 9.1 GB | 17 min | 548 empty geoms excluded via bbox filter |

Schema: 47 columns (dropped `parcelstate`, `lrversion`, `halfbaths`, `fullbaths` from original 51).

### Infrastructure

- **pixi environment**: GDAL 3.12.3 + Arrow/Parquet driver, DuckDB 1.5.1 CLI, radian
- **Tigris bucket**: `noclocks-parcels` created (existing: `noclocks-parcels-parquet`, `noclocks-parcels-source`)
- **WSL fix**: `.wslconfig` was limiting WSL to 4GB RAM / 2 CPUs -- removed, now defaults to 16GB / 12 CPUs

## Key Findings

### Empty Geometries

547 features in Texas (and potentially other states) have WKB blobs under 50 bytes -- empty/degenerate geometries that are not NULL but cannot be spatially indexed. The `-spat` bbox filter naturally excludes these via the R-tree. This is the reason the extraction script uses both `-spat` (from TIGER bboxes) and `-sql WHERE statefp = 'XX'` together.

### Attribute Population Rates (Georgia sample)

- **Well populated (>90%)**: `parcelid`, `geoid`, `statefp`, `countyfp`, `taxyear`, `updated`, `lrversion`, `centroidx/y`, `surfpointx/y`
- **Moderate (20-80%)**: `ownername` (79%), `totalvalue` (68%), `numbldgs` (40%), `parceladdr` (38%), `legaldesc` (34%), `numfloors` (29%), `lot` (24%)
- **Sparse (<20%)**: `usecode`, `usedesc`, `zoningcode`, `taxacctnum`, `numunits`, most building fields
- **Empty (0%)**: `halfbaths`, `fullbaths`, `ownercity/state/zip`, `parcelcity/state/zip`, `township/section/qtrsection/range/plssdesc` (note: PLSS fields will be populated in western states)
- **Dropped**: `parcelstate` (0% nationwide), `lrversion` (uniform "2026.1"), `halfbaths` (0%), `fullbaths` (0%)

### Geometry Complexity (Georgia)

- Median: 8 vertices, Average: 17, P90: 29, P95: 45, P99: 131
- Max: 128,647 vertices (0.002% over 10K)
- 311 invalid geometries (0.007%) -- not blocking
- No blanket simplification warranted

### Upload Performance

- Browser upload to Tigris: ~1 MB/s (8 Mbps) -- failed mid-upload for GA
- rclone via WSL interop: ~200 KB/s -- bottlenecked by 9P file bridge, not ISP
- Recommended: rclone from native Windows PowerShell with `--s3-chunk-size 128M --s3-upload-concurrency 16`

## Artifacts in Repo

### `data/meta/`

| File | Description |
|---|---|
| `manifest_state_county.csv` | 3,229 rows: statefp, countyfp, geoid, feature_count, null_geom_count, lrid range |
| `manifest_state_rollup.csv` | 55 rows: state-level aggregates with pct, cumulative pct, size estimates |
| `state_bboxes.csv` | 56 rows: statefp, name, min_x, min_y, max_x, max_y from TIGER/Census |
| `us-parcel-layer-metadata.json` | Croissant schema metadata for the source Kaggle dataset |
| `fgb_validation_report.csv` | Validation results (currently empty header -- needs run) |

### `data/output/flatgeobuf/` (WSL local, also being copied to `C:\GEODATA\output\flatgeobuf\`)

| Path | Size |
|---|---|
| `statefp=13/parcels.fgb` | 2.9 GB |
| `statefp=37/parcels.fgb` | 4.1 GB |
| `statefp=48/parcels.fgb` | 9.1 GB |

### `scripts/`

| File | Purpose |
|---|---|
| `gpkg_index_creation.R` | B-tree index creation on GPKG (run once, completed) |
| `gpkg_manifest_creation.R` | County/state manifest generation from GPKG (completed) |
| `generate_state_bboxes.R` | State bboxes from TIGER/Census via tigris + sf |
| `gpkg_fgb_extraction.sh` | Per-state or batch FGB extraction with bbox + metadata |
| `validate_fgb.sh` | FGB validation with sidecar .fgb.json generation |
| `tigris_upload_fgb.sh` | Upload FGBs to Tigris via rclone (WSL, needs Windows port) |
| `parcels_index_creation.log` | Index creation log |
| `parcels_manifest_creation.log` | Manifest creation log |
| `fgb_extraction_{ga,nc,tx}.log` | Per-state extraction logs |

### `data/sources/`

| File | Description |
|---|---|
| `parcels.vrt` | OGR VRT with WSL, Windows, and cloud source layers; canonical `parcels` alias |

## WSL vs Windows Considerations

All development so far has been in WSL (Ubuntu 24.04) using Cursor Remote-WSL. The following paths and behaviors need adjustment when moving to Windows:

### Path Mapping

| WSL Path | Windows Path |
|---|---|
| `/mnt/c/GEODATA/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg` | `C:\GEODATA\LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg` |
| `/mnt/c/GEODATA/output/flatgeobuf/statefp=XX/` | `C:\GEODATA\output\flatgeobuf\statefp=XX\` |
| `data/output/flatgeobuf/statefp=XX/` (repo-local) | same relative path |

### Script Adjustments for Windows

- **Shell scripts** (`.sh`): rewrite as PowerShell (`.ps1`) or use Git Bash
- **`pixi run ogr2ogr`**: works identically on both platforms (pixi resolves platform binaries)
- **`pixi.toml`**: currently `platforms = ["linux-64"]` -- add `"win-64"` and re-solve
- **rclone**: use native `rclone.exe` directly, not via WSL interop
- **R scripts**: work as-is from Windows R, just update file paths (already tested with index creation and manifest)
- **DuckDB CLI**: available via pixi on both platforms

### Key Behavioral Differences

- **9P bridge overhead**: eliminated when running natively on Windows -- expect faster I/O for GPKG reads
- **`mmap_size` pragma**: actually functional on native Windows NTFS (was no-op on WSL 9P)
- **Cursor stability**: no WSL crash/reconnection issues on native Windows
- **rclone uploads**: native Windows rclone reads files directly from NTFS, no 9P bottleneck

### What Stays the Same

- GDAL commands, SQL, ogr2ogr flags -- identical across platforms
- DuckDB queries -- identical
- FGB/Parquet file formats -- binary, cross-platform
- Tigris S3 API -- endpoint and credentials unchanged
- VRT files -- `parcels.vrt` already has both WSL and Windows source layers

## Next Steps

1. **Validate existing FGBs**: run `./scripts/validate_fgb.sh all` to generate sidecar `.fgb.json` and validation report
2. **Upload FGBs to Tigris**: use rclone from Windows PowerShell with multipart config against `noclocks-parcels` bucket
3. **Batch FGB extraction**: remaining 52 states/territories via `./scripts/gpkg_fgb_extraction.sh all` (~4-5 hours)
4. **Move workspace to Windows**: add `win-64` to pixi platforms, port shell scripts to PowerShell, update paths
5. **Phase 2**: FGB to county-partitioned GeoParquet via DuckDB (separate task, uses `GEOMETRY_NAME=geometry`, ZSTD-15, ROW_GROUP_SIZE=65536)
6. **R package scaffolding**: implement `parcels_*`, `gdal_*`, `utils_*` R modules per the plan

## Tigris Bucket Layout (Target)

```
noclocks-parcels/
  flatgeobuf/
    statefp=01/parcels.fgb
    statefp=01/parcels.fgb.json
    statefp=02/parcels.fgb
    ...
  geoparquet/
    statefp=01/countyfp=001/data_0.parquet
    statefp=01/countyfp=003/data_0.parquet
    ...
  pmtiles/                    (future)
    statefp=01/parcels.pmtiles
    ...
```
