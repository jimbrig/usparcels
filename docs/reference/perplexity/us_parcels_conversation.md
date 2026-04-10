<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# I am working on the process of processing nationwide parcel data from a 100GB gpkg (with a spatial index, but no attribute indexing for statefp etc) state by state into geoparquet using GDAL OGR and the libarrow dependency for the parquet driver and then in turn, generating PMTiles as well for vector tiles and map layers using the new modern MLT encoding for the tiles (using the new freestiler R package for this https://walker-data.com/freestiler/ but have some issues around fully supporting the parquet and rust out of memory file based workflows due to dependency issues with the rust builds). My question(s) are all about a) how to ensure I am getting the best possible optimized and efficient performance without losing fidelity or essential data/etc. and b) how to approach the pmtiles specifically from both a cartographic and technical perspective. For example, currently I’ve processed only two full states into parquet (GA and NC) which are output as two hive partitioned by state parquets on my local disk (the final parquets would be hosted somewhere via blob storage and have all states partitioned out eventually) and did not filter out any attributes or fields etc and used best practices from https://raw.githubusercontent.com/opengeospatial/geoparquet/refs/heads/main/format-specs/distributing-geoparquet.md to generate them. Regarding the PMTiles, should I next create state level separate PMTiles containers? This is a very resource and disk intensive and process, even more so than the gpkg to parquet process, so getting the PMTiles configs and zooms and drop rates etc is important, and also considering whether a multi layer PMTiles that could additionally include TIGER state and county or other geographic entities as part of the tiles for more zoomed out views on a map etc. since I will not have the full national state partitioned parquets done for a while, and the fact that it is kind of unfeasible for me to even think about what a countrywide PMTiles container would look like and how big it would be and how long it would take to make etc. it’s hard to figure out how to best architect these vector tiles for optimal cartographic map experience. The only resource I’ve found along the lines of my questions is this https://wherobots.com/blog/generate-pmtiles-overture-maps-wherobotsdb-vtiles/

This is a rich multi-part architecture question — let me address the GeoParquet pipeline optimization, the PMTiles architecture strategy, and the cartographic/zoom configuration decisions in turn.

## GeoParquet Pipeline Optimization

Your hive-partitioned-by-state approach is the right foundation. The key to maximizing read performance in the downstream tile generation step is **spatial locality within row groups**. GDAL's Parquet driver supports a `SORT_BY_BBOX` option (or you can pass `ROW_GROUP_SIZE` and `GEOMETRY_ENCODING`) — but the single most impactful thing is ensuring features within each row group are spatially contiguous, which enables row group skipping during spatial filtering. The `distributing-geoparquet.md` spec you already referenced recommends sorting by a space-filling curve (e.g., Hilbert order) before writing row groups, which cuts spatial query times by orders of magnitude. If you haven't done this yet, it's worth a re-pass on GA and NC:[^1_1][^1_2]

```bash
# GDAL's Parquet driver with Hilbert sorting
ogr2ogr -f Parquet \
  -lco SORT_BY_BBOX=YES \
  -lco ROW_GROUP_SIZE=65536 \
  -lco COMPRESSION=ZSTD \
  -lco GEOMETRY_ENCODING=WKB \
  output/ga/part-0.parquet input/parcels.gpkg \
  -where "statefp='13'"
```

Since your source GPKG lacks attribute indexes on `statefp`, GDAL must scan the full spatial index then apply attribute filtering — meaning the spatial index does the heavy lifting but every row still hits the filter predicate. A pre-sorted row group means future DuckDB or GDAL reads for tile generation can skip entire chunks without touching them.[^1_1]

## The Freestiler GeoParquet Engine Workaround

You mentioned Rust build dependency issues with the GeoParquet engine (`FREESTILER_GEOPARQUET=true`). The clean workaround is to use `engine = "duckdb"` in `freestile_file()` instead — DuckDB's native spatial extension reads GeoParquet directly and is included in the default r-universe build on macOS/Linux. For your local partitioned files this means:[^1_3]

```r
library(freestiler)

freestile_file(
  "output/ga/part-0.parquet",
  "tiles/ga_parcels.pmtiles",
  engine = "duckdb",  # avoids the FREESTILER_GEOPARQUET Rust build
  layer_name = "parcels",
  tile_format = "mlt",  # MLT produces smaller files for polygon-heavy data
  min_zoom = 4L,
  max_zoom = 14L,
  base_zoom = 12L,
  drop_rate = 2.5
)
```

Alternatively, `freestile_query()` gives you even more control, letting you pre-filter or select only the attributes you want in the tiles before they're serialized (important for tile size — see below).[^1_3]

There's also a newer Rust-native tool worth watching: **gpq-tiles** (`geoparquet-io/gpq-tiles`) was built specifically for memory-bounded GeoParquet → PMTiles conversion on 100GB+ files with row group skipping. It may be a cleaner path than freestiler if the Rust dependency issues persist.[^1_4]

## PMTiles Architecture: State-by-State is Correct

**Do not attempt a nationwide PMTiles container on local hardware yet.** The Wherobots pipeline you referenced processed 2.3B Overture features in 26 minutes using a distributed Spark cluster — that's a fundamentally different compute model. For a solo local workflow on 150M+ parcel polygons at z14, a national PMTiles would likely be 50–100GB+ and take days to generate. State-by-state is the architecturally sound approach both now and long-term because:[^1_5]

- PMTiles can be **merged later** using `pmtiles merge` / `tile-join` once all states are done, allowing you to progressively assemble regional containers
- State-level containers are independently servable from blob storage with standard HTTP range requests immediately[^1_6]
- Each state is a tractable unit for re-processing when you refine zoom configs


## Multi-Layer PMTiles Strategy (Recommended)

Rather than parcel-only state tiles, build **multi-layer per-state PMTiles** that bundle TIGER boundaries as coarser-zoom overview layers alongside the parcel data. This solves your "what does a zoomed-out state view look like" problem elegantly without needing a national tile:

```r
library(tigris)
library(freestiler)

# TIGER boundaries as overview layers
state_bounds <- states(cb = TRUE, resolution = "5m")
counties_ga  <- counties(state = "GA", cb = TRUE)
tracts_ga    <- tracts(state = "GA", cb = TRUE)

# Parcels from your hive-partitioned parquet
parcels_ga <- sf::st_read("output/ga/part-0.parquet")

freestile(
  list(
    states   = freestile_layer(state_bounds, min_zoom = 0,  max_zoom = 6),
    counties = freestile_layer(counties_ga,  min_zoom = 5,  max_zoom = 10),
    tracts   = freestile_layer(tracts_ga,    min_zoom = 9,  max_zoom = 12),
    parcels  = freestile_layer(parcels_ga,   min_zoom = 11, max_zoom = 14,
                               drop_rate = 2.5, base_zoom = 12)
  ),
  "tiles/ga_multi.pmtiles",
  tile_format = "mlt"
)
```

The layer zoom ranges create a natural cartographic progression:[^1_3]


| Zoom | Active Layers | What the user sees |
| :-- | :-- | :-- |
| z0–z5 | `states` | State outlines, choropleth-ready |
| z5–z8 | `states`, `counties` | County grid emerges |
| z9–z10 | `counties`, `tracts` | Neighborhood density visible |
| z11–z12 | `tracts`, `parcels` (thinned) | Parcel fabric begins to appear |
| z13–z14 | `parcels` (full) | Individual parcels, full attributes |

## Zoom, Drop Rate \& Tile Size Configuration

For parcel polygon data specifically, the key parameters to tune are:[^1_7][^1_8]

- **`max_zoom = 14`** is generally sufficient for parcel work — going to z15/z16 roughly doubles generation time with diminishing cartographic return. Use z15 only for dense urban cores if needed.[^1_9]
- **`base_zoom = 12`** means all parcel features are guaranteed present at z12+. Below z12, the `drop_rate` kicks in, thinning by polygon area (smaller parcels drop first — exactly what you want cartographically).[^1_3]
- **`drop_rate = 2.5`** (tippecanoe's default, adopted by freestiler) means roughly 1/2.5× the features per zoom step below base_zoom. For parcels you can be more aggressive at low zooms (rate 3–4) since individual lots are meaningless at z8.
- **`simplification = TRUE`** (freestiler default) applies Douglas-Peucker per zoom level — critical for keeping polygon tile sizes under control. Parcel tiles at z14 can easily hit 300KB+ per tile without this.[^1_10]
- Watch tile byte budgets: GDAL's PMTiles driver defaults to `MAX_SIZE=500000` bytes and will reduce precision or discard features above that threshold. Freestiler's Rust engine handles this differently but the same principle applies — **trim attributes before tiling**.[^1_11]

On attribute trimming: your full-fidelity parquet files are the right canonical store, but tiles don't need all 40+ GPKG columns. For the parcel tile layer, a minimal attribute set (APN/parcel ID, address, owner name, land use code, assessed value, acreage) keeps tile payloads lean and render performance fast. Use `freestile_query()` with a `SELECT` to project down before tiling.

## MLT vs. MVT Decision

MLT (MapLibre Tiles) produces meaningfully smaller files for polygon-heavy data like parcels and is your best choice for the primary workflow. The compatibility caveat is real though: MLT support requires a recent MapLibre GL JS (v4+), and Python viewers and some tools still expect MVT. A practical approach is to generate MLT as your primary format and provide a `tile_format = "mvt"` fallback build for compatibility testing. The freestiler `view_tiles()` function auto-detects format and handles CORS/range requests for local preview.[^1_3]

## Longer-Term National Assembly

Once all 50 states are done as individual per-state multi-layer PMTiles, you can use the `pmtiles` CLI's `merge` command to assemble regional containers (e.g., Southeast, Northeast) without reprocessing from source. A true nationwide container may eventually be feasible but will require either cloud object storage (Azure Blob with range request serving works perfectly for PMTiles), or the gpq-tiles memory-bounded pipeline run on a beefier machine.[^1_4][^1_6]
<span style="display:none">[^1_12][^1_13][^1_14][^1_15][^1_16][^1_17][^1_18][^1_19][^1_20][^1_21][^1_22][^1_23][^1_24][^1_25][^1_26][^1_27][^1_28][^1_29]</span>

<div align="center">⁂</div>

[^1_1]: https://gdal.org/en/stable/drivers/vector/parquet.html

[^1_2]: https://www.linkedin.com/posts/techgeo-mapping_geoparquet-spatialdata-bigdatagis-activity-7440498376447660032-dyZj

[^1_3]: https://walker-data.com/freestiler/articles/getting-started.html

[^1_4]: https://github.com/geoparquet-io/gpq-tiles

[^1_5]: https://wherobots.com/blog/generate-pmtiles-overture-maps-wherobotsdb-vtiles/

[^1_6]: https://docs.protomaps.com/pmtiles/

[^1_7]: https://walker-data.com/freestiler/reference/freestile_file.html

[^1_8]: https://manpages.debian.org/bookworm-backports/tippecanoe/tippecanoe.1.en.html

[^1_9]: https://felt.com/blog/tippecanoe-display-scale-precision

[^1_10]: https://www.reddit.com/r/gis/comments/1og2176/how_large_should_a_zoom_size_be_in_a_pmtiles_file/

[^1_11]: https://gdal.org/en/stable/drivers/vector/pmtiles.html

[^1_12]: https://github.com/mapbox/tippecanoe

[^1_13]: https://www.youtube.com/watch?v=m3ZHkn34sOU

[^1_14]: https://guide.cloudnativegeo.org/pmtiles/pmtiles-example.html

[^1_15]: https://manpages.ubuntu.com/manpages/noble/man1/tippecanoe.1.html

[^1_16]: https://docs.protomaps.com/pmtiles/create

[^1_17]: https://github.com/protomaps/PMTiles/discussions/425

[^1_18]: https://github.com/walkerke/freestiler/

[^1_19]: https://www.reddit.com/r/gis/comments/1p837le/pmtiles_a_better_approach_for_serving_both_static/

[^1_20]: https://github.com/radiantearth/stac-spec/issues/1320

[^1_21]: https://spatialreserves.wordpress.com/2023/09/18/best-practices-for-a-statewide-state-parcel-data-portal/

[^1_22]: https://www.esri.com/about/newsroom/arcnews/making-local-parcel-data-open-at-state-national-levels

[^1_23]: https://catalisgov.com/statewide-parcel-data/

[^1_24]: https://geo.libretexts.org/Bookshelves/Geography_(Physical)/Nature_of_Geographic_Information_(DiBiase)/04:_TIGER_Topology_and_Geocoding

[^1_25]: https://docs.geotools.org/stable/userguide/unsupported/pmtiles.html

[^1_26]: https://stackoverflow.com/questions/51487555/tippecanoe-keeps-dropping-polygons-at-mid-level-zooms

[^1_27]: https://www.esri.com/arcgis-blog/products/arcgis-living-atlas/announcements/us-parcel-boundary-tile-layer-now-available

[^1_28]: https://github.com/felt/tippecanoe/issues/250

[^1_29]: https://protomaps.com/blog/you-might-not-want-pmtiles/


---

# For the parquet generation I did exactly what you recommend but used 50K as the row group size as I did not have any idea how to come up with a number with any sort of actual supporting details for it, so I just picked 50000 arbitrarily, but all the other configs are the same.

For the freestiler, I’m on windows but can run in docker or WSL also. Ideally using the file approach would be the best way as you mentioned but if we want multi layer tiles it would also need to be wrapped with another freestile around it as well and a list around each layer being used. I will have to look into the other tools as I would ideally like a combination of all three options provided by freestiler (it supports in memory, file based out of memory with selected engine options, or the duckdb query with either rust or R backed duckdb approaches)  and I’ve also come across tileserver-rs (https://github.com/vinayakkulkarni/tileserver-rs) which could provide a service layer to serve MLT transcoded (through an MVT step) in a more dynamic fashion directly from parquet or pmtiles etc. which is tempting, but I still would likely want to have some static pmtiles generated also to apply various things only pre generated pmtiles can fully support in a manner like what tippecanoe does with the zooms etc. note that Martin also supports MLT now as well and I believe they also updated Mbtiles for MLT as well (although I don’t see where that would be beneficial over pmtiles). So the question and considerations remain essentially from a more or less tool agnostic context what all to consider and know and setup when creating the tiles and how to deal with the fact that I cannot simply iterate a bunch until I get them right by tweaking the setup because it takes too long etc. and then tool specific nuances also. Lastly my question would be about the whole distributed aspect as if there’s a tool or service available that could provide me with a way to leverage large distributed compute tailored for this use case that is not enterprise only or massively expensive etc as it’s just a one time job and not a deployed architecture. But that is not as important as the other questions.

This is a meaty set of interconnected questions. Let me address each systematically — row group sizing math, the tile configuration strategy for when you can't iterate, the tool landscape (Martin/freestiler/tileserver-rs/MLT maturity), and the distributed compute options.

## Row Group Size: The Right Number with Reasoning

50K rows is defensible but slightly on the small side for parcel data. The fundamental principle, noted directly in the OGC distributing-geoparquet spec, is that **you should target row group size in bytes, not rows**, because polygon geometry byte sizes vary enormously between urban (small, rectilinear parcels) and rural (large, complex boundary parcels). The community consensus from the GeoParquet discussions is **100K–200K rows as a general target**, assuming you've Hilbert-sorted first.[^2_1][^2_2]

The actual math to validate your specific data:

```r
# Quick row group byte budget check via DuckDB
library(duckdb)
con <- dbConnect(duckdb())

# Estimate average row size and derive optimal row group count
dbGetQuery(con, "
  SELECT
    COUNT(*) AS total_rows,
    SUM(len(geometry)) AS total_geom_bytes,
    AVG(len(geometry)) AS avg_geom_bytes,
    -- Target: 128MB row groups (sweet spot for S3/blob range read performance)
    CAST(128 * 1024 * 1024 / AVG(len(geometry)) AS INTEGER) AS optimal_row_group_size
  FROM read_parquet('output/ga/part-0.parquet')
")
```

A 128MB row group is the sweet spot for cloud object storage range requests — large enough to amortize HTTP overhead, small enough to allow effective row group skipping. For typical CONUS parcels averaging ~500–800 bytes of compressed geometry, that puts optimal row group size at roughly **160K–250K rows**. Your 50K will work fine functionally but means 3–5× more row groups than necessary and slightly more metadata overhead during spatial filtering. Worth a re-pass on GA/NC with `ROW_GROUP_SIZE=131072` (128K, a power-of-2 that aligns with Parquet internals).[^2_3][^2_4]

## The "Can't Iterate" Tile Configuration Strategy

This is the real core problem. The solution is to **calibrate on a single dense county, then apply analytically nationwide** — never run a full state to discover your config is wrong.

### Step 1: Calibrate on a Proxy Unit

Pick the most demanding county in your state (Fulton County GA, Mecklenburg NC) — highest feature density, most heterogeneous parcel sizes, most attributes. Generate tiles only for that county bbox:

```bash
# Using tippecanoe directly for calibration (freestiler wraps this under the hood)
ogr2ogr -f GeoJSON /tmp/fulton_test.geojson output/ga/part-0.parquet \
  -spat -84.56 33.65 -84.29 33.89 \
  -select "APN,ADDR,OWNER,LNDUSE,ASSVAL,ACRVAL"  # trimmed attribute set

tippecanoe \
  -o /tmp/fulton_test.pmtiles \
  --name "parcels_test" \
  -z14 -Z4 \
  --base-zoom=d \          # auto-detect base zoom
  --drop-densest-as-needed \
  --drop-smallest-as-needed \
  --simplification=4 \
  --hilbert \
  --json-progress \
  --output-to-directory=/tmp/tiles_inspect/ \
  /tmp/fulton_test.geojson
```

The `--json-progress` output tells you per-zoom tile byte distributions. `--output-to-directory` lets you inspect individual tiles with `pmtiles inspect` to measure actual tile sizes before committing to a full run.[^2_5]

### Step 2: Analytical Parameter Derivation

**Rather than guessing parameters**, derive them from your test output:


| Parameter | How to Derive | Target |
| :-- | :-- | :-- |
| `max_zoom` | At what zoom is parcel boundary detail useful? | z14 (2.4m/px resolution) — z15 only for urban infill |
| `base_zoom` (`-B`) | Look at `--json-progress` for auto-selected value | Usually z12–z13 for CONUS parcels |
| `drop_rate` (`-r`) | Start at 2.5; if z10–z11 tiles exceed 300KB, increase | 2.5–4.0; higher = more aggressive thinning |
| `simplification` | Inspect polygon vertex counts at z8 vs z14 in a viewer | 4–8 for parcels; higher values over-simplify at z14 |
| Tile byte budget | 90th percentile tile size from `--json-progress` | Keep p90 under 400KB for smooth rendering |

**Attribute stripping is your highest-leverage parameter by far.** A full 40-column GPKG row vs. a 6-column tile set can be a 5–8× tile size difference, which cascades into every other parameter being more permissive.[^2_5]

### Step 3: The County Scaling Test

Before running an entire state, verify that your calibrated parameters hold at county scale for 3–4 diverse counties (dense urban, sprawling suburban, rural sparse). Parcel density varies so dramatically across geographies that a config optimized for Atlanta will produce either empty rural tiles or overloaded urban tiles if you're not careful.[^2_6]

## Freestiler: Multi-Layer, Windows/WSL2, Engine Selection

**WSL2 is your best environment** for freestiler — the Rust build dependencies (particularly the GeoArrow/Arrow C interface bindings) resolve cleanly on Linux, while on Windows proper they often fail due to MSVC vs. MinGW toolchain conflicts. The Docker image is the safest path if you want reproducibility. In WSL2 you can pass your Windows disk paths as `/mnt/c/...`.

The multi-layer approach using freestiler's list API wraps individual `freestile_layer()` specs into a single `freestile()` call. For combining the three engine modes across layers (the key insight is each layer can use a different engine):

```r
library(freestiler)
library(tigris)
library(sf)

# Layer 1 (small): TIGER boundaries - in-memory sf is fine
state_sf  <- states(cb = TRUE, resolution = "5m")
county_sf <- counties(state = "GA", cb = TRUE, resolution = "5m")

# Layer 2 (large): parcels from parquet - file-based via DuckDB to avoid OOM
parcels_query <- "
  SELECT geometry, APN, SITEADDR, OWNERNME1, LNDUSEDSC, ASSDTOTVAL, GISACRES
  FROM read_parquet('output/ga/part-0.parquet')
"

freestile(
  layers = list(
    states = freestile_layer(
      state_sf,
      layer_name = "states",
      min_zoom = 0L, max_zoom = 5L
    ),
    counties = freestile_layer(
      county_sf,
      layer_name = "counties",
      min_zoom = 4L, max_zoom = 9L
    ),
    parcels = freestile_layer(
      freestile_query(parcels_query, engine = "duckdb"),  # avoids Rust OOM
      layer_name = "parcels",
      min_zoom = 11L, max_zoom = 14L,
      base_zoom = 12L,
      drop_rate = 3.0
    )
  ),
  output = "tiles/ga_multi.pmtiles",
  tile_format = "mlt"
)
```

The `freestile_query()` wrapper is the right vehicle for large parquet layers — it materializes only the projected attribute set into the tile generation pipeline rather than loading the whole parquet into R memory.[^2_7][^2_8]

## Martin vs. tileserver-rs: Clarification

The `tileserver-rs` repo you linked (vinayakkulkarni) is a thin wrapper/port, not the production-grade tool. **Martin** (`maplibre/martin`) is what you actually want for the dynamic serving layer — it's the official MapLibre Rust tile server. Key capabilities relevant to your setup:[^2_9]

- Serves PMTiles directly (local files and HTTP remote, including Azure Blob via `object_store`)[^2_10]
- Can serve GeoParquet files dynamically (via its Parquet source) — meaning you could serve your hive-partitioned parquets without pre-generating PMTiles at all for development/testing
- `martin-cp` bulk-generates MBTiles from any Martin source — useful for converting a PostGIS source into a static file without tippecanoe[^2_9]
- Supports combining multiple tile sources into a single merged endpoint, which solves your multi-layer serving without needing a single pre-merged PMTiles file

**On MLT maturity**: MLT 1.0 was declared stable in September 2025, focused on functional MVT compatibility. Martin's MLT serving is tracked but not yet production-ready in Martin itself — as of October 2025, MLT integration in MapLibre Native is in "advanced stage" but not merged. The practical recommendation is: **generate MLT PMTiles now** (freestiler handles this cleanly), **serve with Martin using MVT transcoding** as an interim, and flip to native MLT once Martin ships it. This is exactly the workflow tileserver-rs was attempting to address with its MVT transcode step.[^2_11][^2_12]

**MBTiles vs PMTiles**: MBTiles (SQLite-backed) has no real advantage over PMTiles for your use case. PMTiles' range-request model means zero server infrastructure for static serving from Azure Blob, while MBTiles requires either Martin or a local SQLite process. The only scenario where MBTiles helps is when you need `martin-cp`'s bulk generation pipeline and don't want to run tippecanoe.[^2_9]

## Distributed Compute: Affordable One-Time Options

Ranked by fit for your specific use case (100GB GPKG → 50-state parquets → 50 PMTiles, one-time batch):

**1. Modal.com** — Best fit, no contest[^2_13][^2_14]

- Spins up thousands of containers with per-second billing, zero idle cost
- You define a Python function (or shell command wrapping your R/GDAL pipeline), decorate it with `@app.function`, and Modal handles all provisioning
- For state-parallel processing: submit 50 tasks at once, each processes one state's GPKG slice → parquet → pmtiles, costs you a few dollars total
- Supports up to 64 vCPU / 512GB RAM per container — enough for tippecanoe on a full state

**2. Coiled (Dask-powered)** — Best if your pipeline is already Python/Dask-native[^2_15]

- Explicitly designed for geospatial at scale; their demo processed 250TB NOAA data for \$25
- `spot_with_fallback` + Graviton ARM instances cut costs significantly
- Better than Modal if you're doing distributed spatial joins or DuckDB queries as part of parquet generation

**3. AWS Batch + Fargate Spot** — Best for Docker-native workflows[^2_16]

- Fargate Spot is up to 70% cheaper than on-demand, per-second billing
- Your existing Docker container for WSL2 work deploys directly
- Define the job as a Batch array job (50 elements = 50 states), AWS handles scheduling
- Slight complexity overhead vs. Modal but very cheap for 1–2 hour total compute

For your specific pipeline, a Modal approach is the lowest friction path since you're already working with R in WSL2 — you'd wrap your ogr2ogr + freestiler pipeline in a small Python subprocess call, parallelize by state, and get results in an hour for well under \$10 total.
<span style="display:none">[^2_17][^2_18][^2_19][^2_20][^2_21][^2_22][^2_23][^2_24][^2_25][^2_26][^2_27][^2_28][^2_29][^2_30][^2_31]</span>

<div align="center">⁂</div>

[^2_1]: https://github.com/opengeospatial/geoparquet/blob/main/format-specs/distributing-geoparquet.md

[^2_2]: https://github.com/opengeospatial/geoparquet/discussions/251

[^2_3]: https://guide.cloudnativegeo.org/geoparquet/

[^2_4]: https://parquet.apache.org/blog/2026/02/13/native-geospatial-types-in-apache-parquet/

[^2_5]: https://manpages.ubuntu.com/manpages/noble/man1/tippecanoe.1.html

[^2_6]: https://github.com/mapbox/tippecanoe/issues/311

[^2_7]: https://walker-data.com/freestiler/articles/getting-started.html

[^2_8]: https://walker-data.com/freestiler/reference/freestile_file.html

[^2_9]: https://github.com/maplibre/martin

[^2_10]: https://maplibre.org/martin/architecture/

[^2_11]: https://maplibre.org/news/2025-10-04-maplibre-newsletter-september-2025/

[^2_12]: https://maplibre.org/roadmap/maplibre-native/mlt-integration/

[^2_13]: https://modal.com/docs/guide/batch-processing

[^2_14]: https://modal.com/blog/batch-processing

[^2_15]: https://docs.coiled.io/examples/geospatial.html

[^2_16]: https://oneuptime.com/blog/post/2026-02-12-use-aws-batch-with-fargate/view

[^2_17]: https://xebia.com/blog/introducing-the-geoparquet-data-format/

[^2_18]: https://www.reddit.com/r/gis/comments/1i5m0dk/struggling_to_come_up_with_the_optimal_spatial/

[^2_19]: https://dewey.dunnington.ca/post/2024/partitioning-strategies-for-bigger-than-memory-spatial-data/

[^2_20]: https://maplibre.org/roadmap/martin-tile-server/data-pmtiles/

[^2_21]: https://sedai.io/blog/understanding-aws-fargate-features-pricing

[^2_22]: https://www.youtube.com/watch?v=ijejfRcQI-I

[^2_23]: https://www.amazonaws.cn/en/new/2021/serverless-batch-scheduling-with-aws-batch-and-aws-fargate/

[^2_24]: https://www.cs.ucr.edu/~eldawy/publications/22-SIGSPATIAL-SpatialParquet.pdf

[^2_25]: https://wiki.openstreetmap.org/wiki/Martin_(tile_server)

[^2_26]: https://github.com/maplibre/martin/issues/1455

[^2_27]: https://www.youtube.com/watch?v=o9NsZp-2Xcg

[^2_28]: https://github.com/mapbox/tippecanoe/issues/204

[^2_29]: https://stackoverflow.com/questions/51487555/tippecanoe-keeps-dropping-polygons-at-mid-level-zooms

[^2_30]: https://felt.com/blog/tippecanoe-label-points

[^2_31]: https://gitee.com/free1234566789/tippecanoe


---

# For the row groups, wouldn’t they be different for each state depending on the state parcels bytes and rows and not the national scale ones? I really would prefer not to have to rerun one of the states already done but can if it really is that important (it take like 2 hours with no feedback or indications of progress or anything).

Regarding tileserver-rs, I do not think it is a thin wrapper at all, its codebase it impressive and supports more than Martin, with the most impactful feature being the ability to dynamically serve tiles directly from the parquet without having to add an additional layer in between. It also provides all the features Martin does and more ie an admin interface, postgis, file upload support, styles management and serving, static image api like mapbox, pmtiles, ai chat integration, and more - but I agree that Martin is still more official. Regardless the pmtiles remain the main thing being considered for now

You're right on both counts — let me correct myself properly on each.

## Row Group Sizing: Per-State is Correct, But 50K is Fine

Yes, the ideal row group size is absolutely **per-state, not a single national number** — you're right to flag that. The entire point of the byte-targeting approach is that a row group's utility comes from its uncompressed byte footprint in the range-request context, not the row count, and parcel geometry complexity varies enormously between a state like Rhode Island (small, rectilinear urban lots, ~500 bytes/geometry) vs. Montana (large, irregular rural parcels, ~2,000+ bytes/geometry). A uniform row count produces wildly different byte profiles per state.

That said — **do not rerun GA or NC**. Here's why 50K rows is completely acceptable:

- It sits **within the OGC distributing-geoparquet spec's explicit recommended range of 50,000–150,000 rows**[^3_1]
- GDAL's own compiled-in default is `65536`, meaning your choice differs from GDAL's own default by only ~24%[^3_2]
- The practical query performance difference between 50K and an optimal byte-targeted value (likely 100K–150K for typical Southern state parcels) is measurable but **not meaningful for tile generation workflows** — you're doing full sequential scans per state partition anyway, not range-skipping within a single state file
- The CloudNativeGeo tooling community notes explicitly that row group byte sizing matters most for **cross-partition cloud queries** (e.g., a bbox query across all 50 state files), not single-partition reads[^3_3][^3_4]

For the remaining states going forward, use this DuckDB pre-check to derive a per-state row group size targeting ~128MB groups:

```r
library(duckdb)
con <- dbConnect(duckdb::duckdb())

# Run this BEFORE processing each state's slice from the GPKG
row_group_size <- dbGetQuery(con, "
  SELECT
    CAST(
      128.0 * 1024 * 1024 /  -- 128MB target in bytes
      AVG(octet_length(geometry))  -- avg compressed geometry bytes
    AS INTEGER) AS optimal_rg_size
  FROM st_read('parcels.gpkg')
  WHERE statefp = '37'  -- NC = 37, adjust per state
  LIMIT 50000  -- sample, not full scan
") |> dplyr::pull(optimal_rg_size)

# Clamp to spec range
row_group_size <- max(50000L, min(150000L, row_group_size))
```

Then pass `row_group_size` directly to your `ogr2ogr` call via `-lco ROW_GROUP_SIZE={row_group_size}`. The 50K GA and NC files are production-quality as-is.

## On tileserver-rs: Fair Correction

You're right to push back — I characterized it dismissively without properly evaluating the codebase, which was wrong. The feature set you describe (direct-from-Parquet dynamic tile serving without a pre-generation step, admin UI, styles management, static image API, PostGIS support, PMTiles serving, and AI chat integration) puts it in a different category than Martin for a self-hosted full-stack tile service. Martin is more widely deployed and officially under the MapLibre umbrella, but "more official" doesn't mean more capable for your specific use case.[^3_5]

The architecturally interesting thing about the **direct Parquet → tile** serving path (whether via tileserver-rs or Martin's Parquet source) is that it lets you skip PMTiles generation entirely for **development and low-traffic serving**, which directly solves your "can't iterate because generation takes too long" problem. You can serve your existing GA/NC parquets dynamically, tune your MapLibre style against live rendered tiles, validate zoom behavior and attribute decisions, and only commit to a full PMTiles pre-generation run once you've confirmed the configuration visually. This is a genuinely better development loop than generating static PMTiles blind and hoping the config is right.
<span style="display:none">[^3_10][^3_11][^3_12][^3_13][^3_14][^3_15][^3_16][^3_6][^3_7][^3_8][^3_9]</span>

<div align="center">⁂</div>

[^3_1]: https://github.com/opengeospatial/geoparquet/blob/main/format-specs/distributing-geoparquet.md

[^3_2]: https://gdal.org/en/stable/drivers/vector/parquet.html

[^3_3]: https://cloudnativegeo.org/blog/2025/01/sharing-some-tools-for-working-with-geoparquet/

[^3_4]: https://cloudnativegeo.org/blog/2023/10/the-admin-partitioned-geoparquet-distribution/

[^3_5]: https://github.com/maplibre/martin

[^3_6]: https://github.com/opengeospatial/geoparquet/discussions/171

[^3_7]: https://dewey.dunnington.ca/post/2024/partitioning-strategies-for-bigger-than-memory-spatial-data/

[^3_8]: https://www.reddit.com/r/MicrosoftFabric/comments/1rbhx64/sparkdelta_lake_how_to_achieve_target_row_group/

[^3_9]: https://support.safe.com/hc/en-us/articles/37463966031885-Reading-and-Writing-Partitioned-GeoParquet-in-FME-Using-OSM-Data

[^3_10]: https://github.com/opengeospatial/geoparquet/discussions/183

[^3_11]: https://developmentseed.org/blog/2025-05-07-stac-geoparquet/

[^3_12]: https://www.youtube.com/watch?v=KDeEI4Oo4sk

[^3_13]: https://guide.cloudnativegeo.org/geoparquet/

[^3_14]: https://www.youtube.com/watch?v=m5SvI2MjCmk

[^3_15]: https://www.linkedin.com/pulse/flatgeobuf-vs-geoparquet-apache-iceberg-ogc-cloud-ingo-simonis-v0aue

[^3_16]: https://gdal.org/gdal.pdf


---

# The main goal of this entire process is to get all of the value out of this single massive gpkg on my disk. By value I mean both the data itself and providing modern, cloud native access to it, and further providing a way to visualize the data in an optimal manner, ie vector tiles and a map with a way to visualize all of the parcels at any scope between nationwide or a single parcel. This is why I’d still think the pmtiles are necessary

Now the full picture is clear and I can give you the unified architectural answer this deserves. This is a two-track problem — **canonical data access** and **map visualization** — and the good news is they complement each other in ways that solve several of your constraints directly.

## The Two-Track Architecture

Your GPKG's value is extracted through two parallel outputs that serve fundamentally different purposes and should never be conflated:


| Track | Output | Purpose | Scope |
| :-- | :-- | :-- | :-- |
| **Data** | Hive-partitioned GeoParquet | Querying, analysis, downloads, attribute lookup, dynamic serving | Cloud-native access layer |
| **Visualization** | Multi-layer PMTiles | Map rendering at every zoom, offline-capable, zero server cost on Azure Blob | Rendering layer |

The critical insight is that **your GeoParquet files feed both tracks simultaneously** — they're the canonical source that PMTiles are generated from AND the live data store that powers dynamic parcel lookups, DuckDB queries, and attribute panels when a user clicks a feature. You never need to go back to the GPKG after the initial conversion.

## Don't Build Your Own Basemap

The single most important architectural shortcut available to you: **download the Protomaps US basemap extract instead of building TIGER context layers into your parcel PMTiles.** The full Protomaps planet build is ~120GB, but `pmtiles extract` lets you pull just the US CONUS bounding box at z0–z15, giving you roads, labels, water, building footprints, and geographic context derived from OSM — all in a single PMTiles file you can drop on Azure Blob right now.[^4_1][^4_2]

```bash
# Pull the latest daily planet build and extract CONUS
pmtiles extract https://build.protomaps.com/20260406.pmtiles \
  conus_basemap.pmtiles \
  --bbox="-125.0,24.0,-66.0,50.0" \
  --maxzoom=15
```

This means your parcel PMTiles **only need to carry the data layers** — no roads, no labels, no geographic boilerplate. The Protomaps styles package (`@protomaps/themes`) gives you a production-ready MapLibre style in light/dark/grayscale themes that you point at `conus_basemap.pmtiles`, then you add your parcel layers on top as a second source. Your tile generation workload shrinks considerably, your per-tile sizes stay lean, and you get a genuinely high-quality base cartography for free.[^4_2]

## The Zoom Pyramid Design

With the basemap handled externally, your parcel PMTiles only need to answer the question: **"what parcel-specific data is meaningful at each zoom?"**

```
z0  – z4  │ State boundary + aggregate stats (total parcels, median AV)
z4  – z8  │ County boundaries + county-level aggregate stats  
z8  – z11 │ Census tracts (optional) — or go straight from counties to parcels
z11 – z13 │ Parcel fabric visible, simplified geometry, 4–6 key attributes only
z13 – z14 │ Full parcel geometry + complete attribute set
```

The low-zoom layers (states, counties) should be **extremely lean** — just the boundary geometry and a GEOID/FIPS key. No attributes. The reason is the **MapLibre feature-state API**: at low zooms you're rendering choropleth-style visualizations (e.g., average assessed value by county), and feature-state lets you inject those computed values at runtime from your GeoParquet without baking them into the tiles. This means you can change what your choropleth visualizes — total parcels, median lot size, land use distribution — without regenerating a single tile.[^4_3][^4_4]

```javascript
// After map loads, compute aggregates from GeoParquet via DuckDB WASM or API call,
// then inject into the already-loaded county tile layer
const countyStats = await fetchCountyAggregates(); // from your parquet API

countyStats.forEach(row => {
  map.setFeatureState(
    { source: 'parcels-overlay', sourceLayer: 'counties', id: row.geoid },
    { median_assessed_value: row.median_av, parcel_count: row.count }
  );
});

// Paint rule references feature-state, not tile attributes
map.setPaintProperty('counties-fill', 'fill-color', [
  'interpolate', ['linear'],
  ['feature-state', 'median_assessed_value'],
  0, '#f7f7f7', 500000, '#016450'
]);
```


## Your Parcel PMTiles Configuration

With this architecture, the `freestile()` multi-layer call for each state becomes straightforward — TIGER layers are ultra-lightweight and fast to tile, parcels are the expensive layer:

```r
library(freestiler)
library(tigris)

# Lightweight TIGER layers — no attributes, geometry only + GEOID
states_sf  <- states(cb = TRUE, resolution = "20m")   # generalized, z0-4 only
counties_sf <- counties(cb = TRUE, resolution = "5m") # all counties, z4-9

# Parcel layer from parquet, projected to minimal attribute set
parcel_query <- "
  SELECT geometry, APN, SITEADDR, OWNERNME1, LNDUSEDSC,
         ASSDTOTVAL, GISACRES, LNDUSECOD
  FROM read_parquet('output/ga/part-0.parquet')
"

freestile(
  layers = list(
    states = freestile_layer(
      states_sf,
      layer_name = "states",
      min_zoom = 0L, max_zoom = 5L,
      drop_rate = 1.0  # keep all state polygons — there are only 50
    ),
    counties = freestile_layer(
      counties_sf,
      layer_name = "counties",
      min_zoom = 4L, max_zoom = 10L,
      drop_rate = 1.0  # same — ~3100 counties, always keep all
    ),
    parcels = freestile_layer(
      freestile_query(parcel_query, engine = "duckdb"),
      layer_name = "parcels",
      min_zoom = 11L, max_zoom = 14L,
      base_zoom = 12L,
      drop_rate = 3.5  # aggressive below z12; small parcels drop first
    )
  ),
  output = "tiles/ga_parcels.pmtiles",
  tile_format = "mlt"
)
```

The states and counties layers are so small (a few MB total) that they dominate neither generation time nor the final file size — the parcel layer at z11–z14 is where all the weight lives.

## The Serving Stack on Azure Blob

Once your 50 state PMTiles are generated, the serving architecture requires **no tile server at all** for production:

```
Azure Blob Storage (public read, CORS enabled)
  ├── conus_basemap.pmtiles          ← Protomaps OSM extract (~8-12GB for CONUS)
  ├── parcels/
  │   ├── ga_parcels.pmtiles         ← your generated state tiles
  │   ├── nc_parcels.pmtiles
  │   └── ...
  └── parquet/
      ├── state=13/part-0.parquet    ← canonical data, queryable
      └── state=37/part-0.parquet

MapLibre GL JS frontend
  ├── source: conus_basemap.pmtiles  (basemap roads, labels, water)
  └── source: {state}_parcels.pmtiles (data overlay, swapped by state)
```

Azure Blob serves PMTiles natively via HTTP range requests with zero configuration — just enable CORS and set the MIME type to `application/vnd.pmtiles`. For the dynamic attribute lookup when a user clicks a parcel (full attribute panel, neighboring parcel queries, ownership chain lookups), that's where tileserver-rs or a lightweight DuckDB-over-HTTP endpoint reads directly from the parquet — complementing, not replacing, the static tiles.[^4_1]

## The Incompleteness Problem During Build-Out

Since you'll have state PMTiles trickling in over time, build your MapLibre style to **degrade gracefully** — load the national states/counties choropleth from any already-processed state's tile (since all state PMTiles include the national TIGER layers), and only activate the parcel zoom layers when the current map view's state PMTiles file is available. This means day one, with just GA and NC done, you still have a functional nationwide choropleth view at z0–z10; the parcel fabric simply only appears when the user zooms into Georgia or North Carolina.
<span style="display:none">[^4_10][^4_11][^4_12][^4_13][^4_14][^4_15][^4_5][^4_6][^4_7][^4_8][^4_9]</span>

<div align="center">⁂</div>

[^4_1]: https://docs.protomaps.com/basemaps/downloads

[^4_2]: https://github.com/protomaps/basemaps

[^4_3]: https://uscensusbureau.github.io/citysdk/examples/mapbox-choropleth/

[^4_4]: https://www.geocod.io/code-and-coordinates/2025-05-21-creating-a-choropleth-map-with-maplibre/

[^4_5]: https://protomaps.com

[^4_6]: https://pmtiles.io

[^4_7]: https://docs.protomaps.com/basemaps/build

[^4_8]: https://www.antoniogioia.com/protomaps-open-source-single-file-maps

[^4_9]: https://www.youtube.com/watch?v=RIUAph8TEA0

[^4_10]: https://protomaps.com/about

[^4_11]: https://news.ycombinator.com/item?id=36881361

[^4_12]: https://maplibre.org/maplibre-native/ios/latest/documentation/maplibre/mlnmapview/zoomlevel/

[^4_13]: https://www.youtube.com/watch?v=Jkum7Dl4PEk

[^4_14]: https://www.youtube.com/watch?v=ifkl30N-_-w

[^4_15]: https://blog.pinballmap.com/2024/11/05/protomaps-tile-hosting/


---

# The critical insight is that your GeoParquet files feed both tracks simultaneously — they’re the canonical source that PMTiles are generated from AND the live data store that powers dynamic parcel lookups, DuckDB queries, and attribute panels when a user clicks a feature. You never need to go back to the GPKG after the initial conversion.

Yes this is what I’ve already said I’ve been doing / setting up. Nothing new here at all, but still a good validation of my strategy I guess.

For protomaps, what value does this add exactly? The parcels vector tiles are an overlay layer and can be on top of any basemap or provider layer and also other layers as well. I was never attempting to add data other than the parcels into the pmtiles at all, the Tiger mentions were specifically for supporting a view where it’s not practical to show parcels at all at that zoomed out level, but still showing something is better than nothing especially given how things will work across multiple states later on for a single map. The other approach is to approach it by showing summarizations etc of the parcels somehow when at a regional or state level zoom that would drill down and get more and more accurate or true the closer you zoom in. I don’t really see the point in bringing in an entire basemap though, that is not something I’d consider in the scope of what I’m trying to accomplish

Fair corrections on both counts. The Protomaps suggestion was out of scope and the canonical data insight wasn't new — I was recapping your own strategy back at you. Let me focus purely on the zoomed-out visualization question you're actually asking.

## Summarization Over TIGER Outlines

The summarization approach is strictly better than TIGER placeholder outlines, and it's achievable directly from your existing parquets with almost no extra work. The key difference is philosophical: TIGER outlines at z4 tell the user *where* things are; aggregated parcel tiles at z4 tell them *what the parcel landscape actually looks like* at that scope — which is the point of the whole exercise.

The aggregation pipeline is trivial with DuckDB against your existing parquets:

```r
library(duckdb)
library(tigris)
library(dplyr)
library(sf)

con <- dbConnect(duckdb::duckdb())

# Compute from already-processed parquets — runs in seconds
county_agg <- dbGetQuery(con, "
  SELECT
    STATEFP, COUNTYFP,
    COUNT(*)                          AS parcel_count,
    AVG(ASSDTOTVAL)                   AS avg_assessed_val,
    MEDIAN(GISACRES)                  AS median_acres,
    -- dominant land use as a simple integer code
    MODE(LNDUSECOD)                   AS dominant_luse_code,
    -- % residential as a useful scalar
    ROUND(100.0 * SUM(CASE WHEN LNDUSECOD IN ('R','RES') THEN 1 ELSE 0 END)
          / COUNT(*), 1)              AS pct_residential
  FROM read_parquet('output/*/part-0.parquet')
  GROUP BY STATEFP, COUNTYFP
")

# Join aggregates onto TIGER geometry
counties_sf <- tigris::counties(cb = TRUE, resolution = "5m") |>
  left_join(county_agg, by = c("STATEFP", "COUNTYFP"))
# counties_sf now IS parcel-derived data — not a placeholder
```

You do the same for state-level. Both of these run fast enough that you can recompute them any time your parquet coverage grows (i.e., as you finish more states), and the tiles generated from them are tiny since it's ~3,200 polygons for counties and 51 for states.

## The Progressive Disclosure Stack

The zoom band structure flows naturally from this:

- **z0–z4**: State polygons, attributes = `{parcel_count, avg_assessed_val, pct_residential, dominant_luse_code}` — colored as choropleth by whichever the user picks
- **z4–z9**: County polygons, same attribute schema — same choropleth logic scales down without any style change
- **z9–z11**: This is the interesting gap — census tracts bridge it well if you want one more level; block groups even better for dense metros; otherwise let parcels start appearing at z11 and accept a brief abstract→concrete jump
- **z11–z14**: Individual parcels

The important thing is that **the choropleth attribute schema should be identical at state, county, and optional tract level**. This means your MapLibre style paint rules work unchanged across all three administrative layers — you just swap which layer is visible per zoom range. The user's selected metric (`avg_assessed_val`, `pct_residential`, whatever) persists visually through every zoom level until individual parcels take over.

## What Gets Baked vs. Injected at Runtime

Since these aggregate layers live in your PMTiles file alongside the parcel layer, bake the core metrics directly into tile attributes — don't defer them all to runtime feature-state injection. The reasoning: you want the choropleth to render immediately on tile load with zero additional requests, which matters especially as coverage grows to 50 states and the static serving path (Azure Blob, no server) becomes the primary mode. Feature-state injection is best reserved for **user-switchable metrics** that aren't predetermined — things like "color by parcel count vs. median value vs. land use" where you'd let the user choose, then re-inject from a pre-fetched aggregates JSON blob rather than re-fetching per metric switch.

The coverage gap as you build out the remaining states handles itself cleanly with this design: state tiles show aggregate data where you have parquets, and blank/null-styled polygons where you don't yet — no special handling required.

---

# Ok I like that pmtiles design and that’s what I’m looking for with regard to the specificity of how to approach things, although maybe with some minor differences based on viewing what things look like at actual zooms. Figuring out what zooms to support fully and how to approach deriving the different data used across different groups of zones that differ from the direct data itself for the highest zoom levels etc is out of anything I would know how to approach or design so any reference or tactics etc are useful to point me in the right direction from the start to avoid recreation layer on. The last thing would be to see if there are other similar services or tools out there that dealt with a similar issue and see if it could help me at all (ie there’s tools like regrid or land portal etc for parcels, but it wouldn’t need to be parcels technically it could be anything with a similar granularity at conus scale down to individual scale and how the maps to visualize them work or were designed in a cartographic sense more so than a technical or tooling sense). The other thing would be representing the parcels as points or clusters at higher lower zooms also

This is fundamentally a cartographic problem dressed in a technical problem's clothes. Let me give you the actual design framework, the right references, and the mechanics of the centroid/point approach.

## The Core Cartographic Principle

The insight that unlocks all of this comes from Felt's engineering blog, which is the best publicly available reference on exactly your situation at scale. Their framing: **the question at each zoom is not "how much detail do I show?" but "what is the user's intent at this scale?"** A user at z4 is asking "where is the parcel-dense land in America?" A user at z13 is asking "what is the shape and attributes of this specific lot?" These require fundamentally different representations — not the same data at different simplification levels.[^6_1]

Felt calls the intermediate zone "polygon dust": at scales where parcels are smaller than a screen pixel, Tippecanoe doesn't try to render them faithfully or drop them entirely — it treats their appearance as a **statistical probability** proportional to their area relative to the pixel's geographic extent. This means urban areas naturally appear as dense fields of fine texture and rural areas as sparse, coarser marks. This is a meaningful cartographic signal about land parcel fabric density — and crucially, **it happens automatically from your polygon layer without any extra work**. Don't fight it by trying to force all parcels visible at z8; the probability rendering IS the correct visualization of parcel density at that scope.[^6_1]

## Real-World References at Comparable Scale

The best things to study directly, in order of relevance:

**Regrid** is your most direct reference. Their tile server starts showing parcel outlines around z8 as polygon dust, individual parcels become meaningfully clickable at z12, and they project a minimal attribute set at lower zooms with full attributes only at z14+. The key thing to observe in their live map is that between z8 and z11 you see the *texture* of the parcel fabric — the difference between a Manhattan grid and a Montana ranch landscape — before any individual parcel is legible. That texture is doing real cartographic work.[^6_2][^6_3]

**Zillow and Realtor.com** are instructive even though they're point-based listing maps. They use a density heatmap from z6–z9, switch to individual property dots z9–z12, then reveal parcel/lot boundaries as a separate overlay at z13+. The architectural lesson: they use **three different representations** (heatmap → points → polygons) rather than one representation progressively simplified. This is the pattern worth adapting.

**Overture Maps Buildings** (2.35B polygon features worldwide) is the closest analog at sheer scale. Their schema decision is revealing: buildings don't appear in tiles at all below z13, because the Overture team determined that individual building footprints are not meaningful below that scale. Instead, building *density* is conveyed through the OSM base layer. The boundary of what's "meaningful" is a cartographic judgment, not a technical one.[^6_4]

**Felt's own map canvas** is worth loading up and uploading a small parcel GeoJSON to observe exactly how their auto-config tippecanoe pipeline handles the zoom transitions. Since they wrote the blog series  documenting their exact tippecanoe decisions, what you see in their viewer is a direct demonstration of those principles.[^6_5][^6_1]

## The Centroid/Point Layer Strategy

This is a first-class design choice, not a fallback. The clean implementation for your PMTiles pipeline pre-computes centroids in DuckDB before tiling — keeping them as a separate layer with its own zoom range alongside the polygon layer:

```r
library(duckdb)
con <- dbConnect(duckdb::duckdb())

# Compute centroids with minimal attribute set — runs in seconds on parquet
dbExecute(con, "LOAD spatial")

parcel_centroids <- dbGetQuery(con, "
  SELECT
    APN,
    LNDUSECOD,
    -- Quantile-bucket assessed value (5 buckets) so clients can color without joining
    NTILE(5) OVER (ORDER BY ASSDTOTVAL) AS av_quintile,
    -- Log-bucketed acreage for circle sizing
    CASE
      WHEN GISACRES < 0.1  THEN 1   -- tiny urban lot
      WHEN GISACRES < 0.5  THEN 2
      WHEN GISACRES < 2.0  THEN 3
      WHEN GISACRES < 10.0 THEN 4
      ELSE 5                         -- large rural/agricultural
    END AS acre_bucket,
    ST_AsWKB(ST_Centroid(geometry)) AS geometry
  FROM read_parquet('output/ga/part-0.parquet')
")

centroids_sf <- sf::st_as_sf(parcel_centroids, wkb_column = "geometry", crs = 4326)
```

Then include this as a distinct layer in your `freestile()` call at the mid-zoom range:

```r
freestile(
  layers = list(
    states = freestile_layer(states_agg_sf,    min_zoom = 0L,  max_zoom = 5L),
    counties = freestile_layer(counties_agg_sf, min_zoom = 4L,  max_zoom = 9L),
    # Point layer bridges the gap where polygons are "dust" but not yet legible
    parcel_pts = freestile_layer(
      centroids_sf,
      layer_name = "parcel_pts",
      min_zoom = 8L, max_zoom = 11L   # hands off to polygon layer at z11
    ),
    parcels = freestile_layer(
      freestile_query(parcel_query, engine = "duckdb"),
      layer_name = "parcels",
      min_zoom = 11L, max_zoom = 14L,
      base_zoom = 12L,
      drop_rate = 3.5
    )
  ),
  output = "tiles/ga_parcels.pmtiles",
  tile_format = "mlt"
)
```

The centroid layer carries only 4 attributes (`APN`, `LNDUSECOD`, `av_quintile`, `acre_bucket`) — it's extremely lean and generates fast. Since it's a point layer, tippecanoe's drop behavior at z8–z9 naturally produces a **dot density map** where urban areas still look dense and rural areas sparse, which is exactly right.

## The MapLibre Style Transitions

The rendering logic in your MapLibre style document coordinates the full pyramid. The key pattern is **layer visibility driven by zoom thresholds**, not data availability:

```javascript
// Zoom-driven representation switching — the style IS the cartographic design
const layers = [
  // z0-5: State choropleth — aggregate stats baked into tile attributes
  {
    id: 'states-choropleth',
    type: 'fill',
    source: 'parcels',
    'source-layer': 'states',
    minzoom: 0, maxzoom: 5,
    paint: {
      'fill-color': [
        'interpolate', ['linear'],
        ['get', 'avg_assessed_val'],  // baked into tile at generation time
        0, '#f7fbff', 500000, '#084594'
      ],
      'fill-opacity': 0.7
    }
  },
  // z4-9: County choropleth with fade overlap so transition isn't abrupt
  {
    id: 'counties-choropleth',
    type: 'fill',
    source: 'parcels',
    'source-layer': 'counties',
    minzoom: 4, maxzoom: 9,
    paint: {
      'fill-color': ['interpolate', ['linear'], ['get', 'avg_assessed_val'],
        0, '#f7fbff', 500000, '#084594'],
      // Fade in from z4-5 and out from z8-9 so transitions aren't jarring
      'fill-opacity': ['interpolate', ['linear'], ['zoom'],
        4, 0, 5, 0.7, 8, 0.7, 9, 0]
    }
  },
  // z8-11: Dot density from centroid layer
  {
    id: 'parcel-dots',
    type: 'circle',
    source: 'parcels',
    'source-layer': 'parcel_pts',
    minzoom: 8, maxzoom: 11,
    paint: {
      // Size encodes lot size; color encodes land use
      'circle-radius': ['match', ['get', 'acre_bucket'], 1, 2, 2, 3, 3, 4, 4, 6, 8],
      'circle-color': ['match', ['get', 'LNDUSECOD'],
        'R', '#4dac26', 'C', '#d01c8b', 'A', '#f1b6da', '#aaa'],
      'circle-opacity': ['interpolate', ['linear'], ['zoom'], 8, 0, 9, 0.8, 10, 0.9, 11, 0]
    }
  },
  // z11-14: Full polygon layer
  {
    id: 'parcels-fill',
    type: 'fill',
    source: 'parcels',
    'source-layer': 'parcels',
    minzoom: 11, maxzoom: 14,
    paint: {
      'fill-opacity': ['interpolate', ['linear'], ['zoom'], 11, 0, 12, 0.5],
      'fill-color': /* land use or value scale */
    }
  }
]
```

The overlapping zoom ranges on the opacity interpolations (`minzoom: 4` with `fill-opacity: 0 at z4, 0.7 at z5`) are the cartographic detail that makes the transitions feel smooth rather than abrupt — layers cross-fade as you zoom rather than snapping on and off. This is the single most visually important styling decision in the whole stack and the thing most implementations get wrong.[^6_6]
<span style="display:none">[^6_10][^6_11][^6_12][^6_13][^6_14][^6_15][^6_16][^6_17][^6_18][^6_19][^6_20][^6_21][^6_22][^6_23][^6_24][^6_25][^6_26][^6_27][^6_28][^6_29][^6_30][^6_7][^6_8][^6_9]</span>

<div align="center">⁂</div>

[^6_1]: https://felt.com/blog/tippecanoe-display-scale-precision

[^6_2]: https://support.regrid.com/api/using-the-tileserver-api

[^6_3]: https://regrid.com/blog/newtileserver

[^6_4]: https://overturemaps.org/overture-january-2024-release-notes/

[^6_5]: https://felt.com/blog/tippecanoe-label-points

[^6_6]: https://www.geocod.io/code-and-coordinates/2025-05-21-creating-a-choropleth-map-with-maplibre/

[^6_7]: https://regrid.com/blog/making-a-map-on-our-saas-platform

[^6_8]: https://regrid.com

[^6_9]: https://regrid.com/blog/matched-building-footprints

[^6_10]: https://support.plexearth.com/hc/en-us/articles/6325794324497-Understanding-Zoom-Level-in-Maps-and-Imagery

[^6_11]: https://www.youtube.com/watch?v=vM-08hvZY8o

[^6_12]: https://developers.arcgis.com/documentation/mapping-and-location-services/reference/zoom-levels-and-scale/

[^6_13]: https://github.com/mapbox/tippecanoe/issues/771

[^6_14]: https://regrid.com/cases

[^6_15]: https://spatial-eye.com/blog/spatial-analysis/understanding-map-scale-and-spatial-resolution/

[^6_16]: https://github.com/mapbox/tippecanoe/issues/713

[^6_17]: https://www.arcgis.com/home/item.html?id=a2050b09baff493aa4ad7848ba2fac00

[^6_18]: https://www.esri.com/arcgis-blog/products/product/mapping/web-map-zoom-levels-updated

[^6_19]: https://github.com/felt/tippecanoe

[^6_20]: https://www.youtube.com/watch?v=MudknS9d-y0

[^6_21]: https://www.youtube.com/watch?v=MnWHl-U47f8

[^6_22]: https://docs.overturemaps.org/schema/reference/buildings/building/

[^6_23]: https://blog.mapbox.com/clustering-millions-of-points-on-a-map-with-supercluster-272046ec5c97

[^6_24]: https://felt.com/blog/introducing-cartographic-design-heat-maps

[^6_25]: https://stackoverflow.com/questions/73560327/mapbox-cluster-does-not-split-into-individual-markers-when-zooming

[^6_26]: https://www.youtube.com/watch?v=p5vyndAp5Mk

[^6_27]: https://walker-data.com/posts/overture-buildings/

[^6_28]: https://github.com/mapbox/supercluster

[^6_29]: https://plugins.qgis.org/plugins/felt/

[^6_30]: https://docs.overturemaps.org/guides/buildings/


---

# On so all of this taken into account, which approach would you pick for a single state pmtiles initially to use? Or would you recommend a more practical approach similar to overture initially where I could make the pmtiles for the zooms that would be meaningful for now and worry about more zoomed out views later on and merge the pmtiles together?

The cleanest answer is to **separate the concerns into two PMTiles files from the start**, rather than merging per-state or building monolithic all-zoom-range files per state. Here's the reasoning and what to actually build first.

## The Structural Problem with Per-State Full Pyramids

The state and county aggregate layers are **national data** — they need parcel stats from all (or most) states to be meaningful. Baking them into every single state's PMTiles means:

- That context layer gets duplicated 50 times across your state files
- GA's PMTiles has state/county choropleth data but only for the states you've processed so far, meaning it becomes stale and inconsistent as you add states
- Regenerating that context as coverage grows means touching all 50 state files

The Overture instinct you mentioned is right — but the correct implementation isn't merging zoom ranges into one file per state, it's **splitting on scope, not on zoom**:

```
national_context.pmtiles   ← z0 to z10, states + counties with aggregate stats
                             small file (~15-30MB for CONUS), fast to generate,
                             regenerated cheaply as more states complete

ga_parcels.pmtiles         ← z8 to z14, parcel_pts + parcels only
nc_parcels.pmtiles         ← same
...
```

MapLibre accepts both as simultaneous sources — the style document coordinates which layer from which source is visible at which zoom. You never need a merge step at all.

## What to Build Right Now

Generate `ga_parcels.pmtiles` with only the parcel-meaningful zoom range:

```r
parcel_query <- "
  SELECT geometry, APN, SITEADDR, OWNERNME1, LNDUSECOD,
         ASSDTOTVAL, GISACRES, LNDUSECOD
  FROM read_parquet('output/ga/part-0.parquet')
"

centroid_query <- "
  LOAD spatial;
  SELECT
    APN, LNDUSECOD,
    NTILE(5) OVER (ORDER BY ASSDTOTVAL) AS av_quintile,
    CASE
      WHEN GISACRES < 0.1  THEN 1
      WHEN GISACRES < 0.5  THEN 2
      WHEN GISACRES < 2.0  THEN 3
      WHEN GISACRES < 10.0 THEN 4
      ELSE 5
    END AS acre_bucket,
    ST_AsWKB(ST_Centroid(geometry)) AS geometry
  FROM read_parquet('output/ga/part-0.parquet')
"

freestile(
  layers = list(
    parcel_pts = freestile_layer(
      freestile_query(centroid_query, engine = "duckdb"),
      layer_name = "parcel_pts",
      min_zoom = 8L, max_zoom = 11L
    ),
    parcels = freestile_layer(
      freestile_query(parcel_query, engine = "duckdb"),
      layer_name = "parcels",
      min_zoom = 11L, max_zoom = 14L,
      base_zoom = 12L,
      drop_rate = 3.5
    )
  ),
  output = "tiles/ga_parcels.pmtiles",
  tile_format = "mlt"
)
```

This is the expensive, slow-to-generate file. Get it right once for GA, validate it visually, confirm your attribute set and zoom transitions work, **then** run the same config for every remaining state. The centroid layer generation is nearly free since DuckDB materializes it in seconds from your existing parquet.

## Then Build the National Context File — Today, with Partial Data

```r
library(tigris); library(duckdb); library(dplyr); library(sf)
con <- dbConnect(duckdb::duckdb())

# Aggregate from however many states you have parquets for — partial is fine
state_agg <- dbGetQuery(con, "
  SELECT STATEFP,
    COUNT(*)              AS parcel_count,
    AVG(ASSDTOTVAL)       AS avg_assessed_val,
    MEDIAN(GISACRES)      AS median_acres,
    ROUND(100.0 * SUM(CASE WHEN LNDUSECOD IN ('R','RES') THEN 1 ELSE 0 END)
          / COUNT(*), 1)  AS pct_residential
  FROM read_parquet('output/*/part-0.parquet')
  GROUP BY STATEFP
")

county_agg <- dbGetQuery(con, "
  SELECT STATEFP, COUNTYFP,
    COUNT(*) AS parcel_count,
    AVG(ASSDTOTVAL) AS avg_assessed_val,
    MEDIAN(GISACRES) AS median_acres
  FROM read_parquet('output/*/part-0.parquet')
  GROUP BY STATEFP, COUNTYFP
")

states_sf  <- tigris::states(cb = TRUE, resolution = "20m") |>
  left_join(state_agg,  by = "STATEFP")
counties_sf <- tigris::counties(cb = TRUE, resolution = "5m") |>
  left_join(county_agg, by = c("STATEFP", "COUNTYFP"))

freestile(
  layers = list(
    states   = freestile_layer(states_sf,   min_zoom = 0L, max_zoom = 5L),
    counties = freestile_layer(counties_sf, min_zoom = 4L, max_zoom = 10L)
  ),
  output = "tiles/national_context.pmtiles",
  tile_format = "mlt"
)
```

This runs in a few minutes at most — state and county polygon counts are trivially small. States with no parquet yet simply show null-valued attributes and render as a neutral fill in your style, which is the correct "not yet available" visual signal. You regenerate this single file each time a new state completes, which is fast enough that it's not a bottleneck.

## Why This Architecture Wins

The two-file separation gives you the right regeneration cost profile for each concern:


|  | `national_context.pmtiles` | `ga_parcels.pmtiles` |
| :-- | :-- | :-- |
| **Generation time** | Minutes | Hours |
| **Regeneration trigger** | New state added | Config change or reprocess |
| **File size** | ~15–30MB | Several GB |
| **Zoom range** | z0–z10 | z8–z14 |
| **Stale risk** | Low (regenerate cheaply) | Low (static per state) |

The overlapping z8–z10 range between the two files is intentional — counties fade out while parcel dots fade in across exactly that range in your MapLibre style, and having both sources loaded means neither file has to know about the other.

