Here's a full walkthrough of the generated project scaffold.

___

## Project Structure

```
<div><p><span><code><span><span>parcels-pipeline/
</span></span><span>├── _targets.R              # Pipeline DAG (entry point)
</span><span>├── config.yml              # Multi-profile config (default / dev / ci)
</span><span>├── DESCRIPTION             # Package deps declaration
</span><span>├── .Renviron.example       # Auth template (copy → .Renviron, never commit)
</span><span>└── R/
</span><span>    ├── globals.R           # CONUS state FIPS/bbox table, shard index builder
</span><span>    ├── extract.R           # Stage 1 (GPKG→FGB) + Stage 2 (FGB→Parquet)
</span><span>    ├── partition.R         # Stage 3: county partitioning via DuckDB
</span><span>    └── upload.R            # Stage 4: AzureStor upload to tigris blob</span></code></span></p></div>
```

___

## Pipeline Stages

## Stage 0 — Shared Routing Index (`routing_index`, main process)

`build_routing_index()` in `globals.R` opens the GPKG via `RSQLite` with a **geometry-free** query (`SELECT fid, statefp, countyfp`) — no WKB blobs are loaded. The resulting data frame is placed into a `shard::share()` shared-memory segment. Workers receive the segment name and call `shard::attach()` for zero-copy access. This eliminates the N-workers × full-attribute-table-scan problem that would otherwise hit the SQLite page cache under contention. It runs on `deployment = "main"` so it executes once on the coordinating process before any workers are dispatched.

## Stage 1 — GPKG → State FlatGeobuf (`state_fgb_XX`)

`extract_state_fgb()` in `extract.R` calls `ogr2ogr` via `system2()` with two complementary filters applied together:

```
<div><p><span><code><span><span>ogr2ogr -f FlatGeobuf </span><span>\</span><span>
</span></span><span><span>  -where </span><span>"STATEFP = '13'"</span><span> </span><span>\</span><span>          </span><span># → SQLite WHERE pushdown (attribute index)</span><span>
</span></span><span><span>  -spat -85.606 </span><span>30.358</span><span> -80.840 </span><span>35.001</span><span> -spat_srs EPSG:4326 </span><span>\</span><span>  </span><span># → R-tree pre-filter</span><span>
</span></span><span><span>  -nlt PROMOTE_TO_MULTI </span><span>\</span><span>
</span></span><span><span>  -lco </span><span>SPATIAL_INDEX</span><span>=</span><span>YES </span><span>\</span><span>
</span></span><span><span>  </span><span>statefp</span><span>=</span><span>13</span><span>/GA.fgb  parcels.gpkg</span></span></code></span></p></div>
```

The FGB is the **re-entry checkpoint** — if parquet configs change (row group size, added columns, compression level), you invalidate only Stage 2+ and never touch the GPKG again. This is the key decoupling that makes iteration cheap.

## Stage 2 — State FGB → State GeoParquet (`state_parquet_XX`)

`fgb_to_state_parquet()` applies the full optimised GDAL Parquet driver flag set (requires **GDAL ≥ 3.9**):

| Flag | Value | Rationale |
| --- | --- | --- |
| `COMPRESSION` | `ZSTD` | Best size/speed tradeoff for spatial data |
| `ROW_GROUP_SIZE` | `65536` | 64k rows/group; balances scan perf vs. memory |
| `WRITE_COVERING_BBOX` | `YES` | Adds per-feature `geometry_bbox_*` columns enabling bbox predicate pushdown in GDAL, DuckDB, and Arrow |
| `SORT_BY_BBOX` | `YES` | Hilbert-like sort before write — groups spatially proximate features into the same row groups for faster scans |
| `FID` | `fid` | Preserves original FID for traceability back to source GPKG |
| `-xyRes` | `0.0000001` | 7 decimal places ≈ 1cm precision; reduces geometry float bloat |

## Stage 3 — County Partitioning via DuckDB (`county_parquet_dir_XX`)

`partition_by_county()` uses a single DuckDB `COPY ... PARTITION_BY` query — no intermediate files, no R memory involvement for geometry:

```
<div><p><span><code><span><span>COPY </span><span>(</span><span>
</span></span><span><span>  </span><span>SELECT</span><span> </span><span>*</span><span> </span><span>FROM</span><span> read_parquet</span><span>(</span><span>'GA.parquet'</span><span>)</span><span>
</span></span><span><span>  </span><span>ORDER</span><span> </span><span>BY</span><span> countyfp</span><span>,</span><span> geometry_bbox_xmin</span><span>,</span><span> geometry_bbox_ymin
</span></span><span><span></span><span>)</span><span>
</span></span><span><span></span><span>TO</span><span> </span><span>'statefp=13/'</span><span>
</span></span><span><span></span><span>(</span><span>FORMAT PARQUET</span><span>,</span><span> PARTITION_BY </span><span>(</span><span>countyfp</span><span>)</span><span>,</span><span> COMPRESSION ZSTD</span><span>,</span><span> ROW_GROUP_SIZE </span><span>65536</span><span>)</span></span></code></span></p></div>
```

The `ORDER BY geometry_bbox_*` inside the COPY sorts features spatially _within_ each county file, which preserves row group locality in the output. There's a graceful fallback if `geometry_bbox_*` columns aren't present (i.e., if GDAL was < 3.9 on Stage 2).

The Hive-partitioned output layout (`statefp=XX/countyfp=YYY/data_0.parquet`) is directly consumable by `arrow::open_dataset()` with partition filtering, DuckDB `read_parquet(..., hive_partitioning=true)`, and cloud storage range-request readers.

## Stage 4 — Upload to Azure Blob (`upload_status_XX`)

`upload_county_parquet()` in `upload.R` uses `AzureStor::multiupload_blob()` with 8 parallel connections per worker. It is fully idempotent — it lists existing blobs under the state prefix and skips any already-present files unless `force = TRUE`. The SAS URL is never in config or code; it lives exclusively in `.Renviron` as `TIGRIS_BLOB_SAS_URL`.

Remote path mirrors the local Hive layout exactly:

```
<div><p><span><code><span><span>parcels/v1/statefp=13/countyfp=121/data_0.parquet</span></span></code></span></p></div>
```

___

## `_targets.R` Design Decisions

**`tar_map()` (static branching) over dynamic branching** — CONUS states are fixed and known at definition time, so `tar_map(values = get_conus_states(), names = stusps)` generates named targets like `state_fgb_GA`, `state_parquet_NC`, etc. This gives full visibility in `tar_visnetwork()` and lets you run individual states by name (`tar_make("state_fgb_GA")`). With ~49 states × 4 stages = ~200 named targets, this is well within `targets`' capability.

**`format = "file"`** on FGB and parquet targets — `targets` tracks the file hash rather than serialising the path string, meaning it detects if a file is deleted or externally modified and marks the target as outdated automatically.

**`error = "continue"`** — a single state failure (e.g. a corrupt GPKG segment) doesn't abort the entire CONUS run. Failed targets are logged and the rest proceed. Re-run `tar_make()` to retry only failures.

**`storage = "worker"` + `retrieval = "worker"`** — workers write their own target store entries and retrieve dependencies directly, avoiding the main process becoming a serialisation bottleneck when 8-16 workers are finishing simultaneously.

**`tar_combine(pipeline_manifest, ...)`** aggregates all 49 `upload_status_XX` tibbles into a single completion record with a timestamp, giving a clean audit trail of what was uploaded and when.

___

## Operational Quickstart

```
<div><p><span><code><span><span>library</span><span>(</span><span>targets</span><span>)</span><span>
</span></span><span>
</span><span><span></span><span># Smoke test with the two already-validated states</span><span>
</span></span><span><span>tar_make</span><span>(</span><span>names </span><span>=</span><span> c</span><span>(</span><span>"state_fgb_GA"</span><span>,</span><span> </span><span>"state_parquet_GA"</span><span>,</span><span> </span><span>"county_parquet_dir_GA"</span><span>)</span><span>)</span><span>
</span></span><span>
</span><span><span></span><span># Full CONUS run</span><span>
</span></span><span><span>tar_make</span><span>(</span><span>)</span><span>
</span></span><span>
</span><span><span></span><span># Resume after interruption (completed stages are skipped automatically)</span><span>
</span></span><span><span>tar_make</span><span>(</span><span>)</span><span>
</span></span><span>
</span><span><span></span><span># Re-run only parquet stages after changing ogr2ogr flags (FGBs reused)</span><span>
</span></span><span><span>tar_invalidate</span><span>(</span><span>starts_with</span><span>(</span><span>"state_parquet_"</span><span>)</span><span>)</span><span>
</span></span><span><span>tar_make</span><span>(</span><span>)</span><span>
</span></span><span>
</span><span><span></span><span># Re-partition counties only (state parquets reused)</span><span>
</span></span><span><span>tar_invalidate</span><span>(</span><span>starts_with</span><span>(</span><span>"county_parquet_dir_"</span><span>)</span><span>)</span><span>
</span></span><span><span>tar_make</span><span>(</span><span>)</span><span>
</span></span><span>
</span><span><span></span><span># Visualise the full DAG</span><span>
</span></span><span><span>tar_visnetwork</span><span>(</span><span>)</span></span></code></span></p></div>
```

___

## Disk Budget

| Artifact | Avg per State | CONUS Total |
| --- | --- | --- |
| FGB checkpoints | ~1.5 GB | ~75 GB |
| State GeoParquet | ~1.0 GB | ~50 GB |
| County GeoParquet | ~1.1 GB | ~55 GB |
| **Local total** |  | **~180 GB** |

Once county partitions are validated (`validate_county_parquet()` in `partition.R`), `state_parquet_dir` can be deleted to recover ~50 GB. FGB checkpoints are worth keeping permanently as the re-entry point.

___

## One Hard Requirement

**GDAL ≥ 3.9.0** is mandatory for `WRITE_COVERING_BBOX` and `SORT_BY_BBOX`. `globals.R` includes `assert_gdal_version()` which you can call at the top of a session to verify before a long run. On Ubuntu/Debian, GDAL 3.9+ is available via the `ubuntugis-unstable` PPA; on macOS via Homebrew `gdal` (currently ships 3.9.x).lists.osgeo+1