# FEMA NFHL Data Architecture

## Scope

Covers all decisions for the FEMA National Flood Hazard Layer (NFHL) integration: GDB archive sourcing and PMTiles materialization, on-demand ArcGIS parcel analysis, FIRMette artifact generation, PostgreSQL schema, GDAL OGR declarative pipeline specs, MapLibre style definitions, and implications for the wider data architecture pattern.

---

## Decision 1 — State vs. County GDB Archives

**Use state-level GDB archives for PMTiles materialization.**

County-level GDB archives (`EFFECTIVE.NFHL_COUNTY_DATA`) update more frequently but introduce ~3,000+ source files for CONUS versus 56 state/territory files. Since the PMTiles layer is a general-purpose cartographic overlay — not an authoritative parcel-analysis source — the additional update frequency of county archives provides no meaningful benefit. State archives are updated on a biweekly cadence when new data arrives, which is more than adequate for a background visual overlay.

The state-level archive is also the complete effective picture for the state in a single GDB — no spatial stitching or gap-filling logic required. FIPS codes `01` through `56` (excluding `03`, `07`, `14`, `19` which are unassigned) cover all CONUS states, territories (PR, VI, GU, AS, MP), and the District of Columbia.

For the MSC API query, the `EFFECTIVE.NFHL_STATE_DATA` key in the response gives the product file path needed to compose the `/vsizip/vsicurl/` URI as shown in the existing R workflow. No change needed there.

---

## Decision 2 — Layer Selection and OGR Field Schemas

Seven layers from the GDB are materialized to PMTiles. The `L_*` non-spatial lookup tables are not tiled but are used for attribute enrichment during the GDAL pipeline before tile generation where relevant.

### S_FLD_HAZ_AR — Flood Hazard Areas (Primary Layer)

The core layer. Every rendering and analysis decision in the map client derives from this.

**OGR SQL:**
```sql
SELECT
  FLD_ZONE,
  ZONE_SUBTY,
  SFHA_TF,
  STATIC_BFE,
  DEPTH,
  FLD_AR_ID,
  SHAPE
FROM S_FLD_HAZ_AR
WHERE FLD_ZONE IS NOT NULL
  AND FLD_ZONE != ''
```

**Dropped fields:** `DFIRM_ID`, `VERSION_ID`, `V_DATUM`, `LEN_UNIT`, `VELOCITY`,
`VEL_UNIT`, `AR_REVERT`, `AR_SUBTRV`, `BFE_REVERT`, `DEP_REVERT`, `DUAL_ZONE`,
`SOURCE_CIT`, `GFID`, `SHAPE_Length`, `SHAPE_Area`, `OBJECTID`

**Natural key:** `FLD_AR_ID` (format `{DFIRM_ID}_{seq}`)  
**Zoom range:** z4–z16  
**Tippecanoe layer name:** `flood_zones`

### S_FIRM_PAN — FIRM Panel Boundaries

Shows map panel coverage and effective dates. Useful for visual context (which panels are effective vs. unmapped) and as a tooltip source at moderate zoom.

**OGR SQL:**
```sql
SELECT
  FIRM_PAN,
  PANEL_TYP,
  EFF_DATE,
  SCALE,
  ST_FIPS,
  CO_FIPS,
  SHAPE
FROM S_FIRM_PAN
WHERE PANEL_TYP IS NOT NULL
```

**Zoom range:** z5–z12  
**Tippecanoe layer name:** `firm_panels`

### S_BFE — Base Flood Elevation Lines

Elevation contour lines for BFE-determined zones (primarily Zone AE). Only useful at street-level zoom.

**OGR SQL:**
```sql
SELECT
  BFE_LN_ID,
  ELEV,
  LEN_UNIT,
  V_DATUM,
  SHAPE
FROM S_BFE
WHERE ELEV IS NOT NULL
  AND ELEV > 0
```

**Zoom range:** z11–z16  
**Tippecanoe layer name:** `bfe_lines`

### S_LOMR — Letters of Map Revision

Active and historical LOMRs overlaid on the effective NFHL. A LOMR polygon intersecting a parcel is a signal that recent revisions have been issued for that area.

**OGR SQL:**
```sql
SELECT
  CASE_NO,
  STATUS,
  EFF_DATE,
  PROJECT_NA,
  SHAPE
FROM S_LOMR
WHERE STATUS IS NOT NULL
```

**Zoom range:** z8–z16  
**Tippecanoe layer name:** `lomr`

### S_LEVEE — Levee Alignments

Levee lines with certification status. Critical for interpreting Zone D and reduced-risk areas near levee-protected zones.

**OGR SQL:**
```sql
SELECT
  LEVEE_ID,
  CERT_STAT,
  SHAPE
FROM S_LEVEE
```

**Zoom range:** z9–z16  
**Tippecanoe layer name:** `levees`

### S_WTR_AR — Water Body Areas

Background hydrographic context for the flood zone map. Helps users orient flood zones relative to rivers, lakes, and ponds.

**OGR SQL:**
```sql
SELECT
  WTR_NM,
  SHAPE
FROM S_WTR_AR
WHERE SHAPE IS NOT NULL
```

**Zoom range:** z6–z14  
**Tippecanoe layer name:** `water_areas`

### S_WTR_LN — Water Lines

**OGR SQL:**
```sql
SELECT
  WTR_NM,
  SHAPE
FROM S_WTR_LN
WHERE SHAPE IS NOT NULL
```

**Zoom range:** z9–z16  
**Tippecanoe layer name:** `water_lines`

### Excluded Layers

| Layer | Reason |
|---|---|
| `S_XS` | Cross-section profiles — hydraulic modeling only, not relevant to map overlay |
| `S_GEN_STRUCT` | Culverts/channels — annotation level detail, minimal value in tiles |
| `S_NODES` | Internal hydraulic nodes — no cartographic use |
| `S_HYDRO_REACH` | Hydrologic routing — internal FEMA data, not display relevant |
| `S_PROFIL_BASLN` | 3D profile baselines — display irrelevant |
| `S_SUBMITTAL_INFO` | Internal workflow geometry — not for map display |
| `S_POL_AR` | Community political boundaries — TIGER is authoritative for this |
| `S_BASE_INDEX` | Coverage index — useful as metadata, not as a tile layer |
| `S_GAGE` / `S_HWM` / `S_STN_START` | Point features — high feature count, low cartographic value |
| `S_DATUM_CONV_PT` | Internal geodetic points |
| `S_LABEL_PT` / `S_LABEL_LD` | FEMA's own annotation — replaced by MapLibre labels |
| `S_TSCT_BASLN` / `S_CST_TSCT_LN` / `S_LIMWA` / `S_PFD_LN` | Coastal/profile technical lines |
| All `L_*` tables | Non-spatial lookup tables — used in pipeline for enrichment only |

---

## Decision 3 — Declarative GDAL OGR Pipeline Spec

### Spec Format

Each state's pipeline is defined as a JSON spec document stored alongside the PMTiles output in object storage. The spec is the declarative source of truth for re-runs and is the pattern that generalizes to TIGER, NWI, SSURGO, and other archive-sourced datasets.

```json
{
  "spec_version": "1.0",
  "source_type": "nfhl_gdb",
  "state_fips": "13",
  "state_name": "Georgia",
  "source_url": "https://hazards.fema.gov/nfhlv2/output/State/NFHL_13_20260208.zip",
  "source_vsi": "/vsizip/vsicurl/https://hazards.fema.gov/nfhlv2/output/State/NFHL_13_20260208.zip/NFHL_13_20260208.gdb",
  "effective_date": "2026-02-08",
  "output": {
    "pmtiles_key": "tiles/nfhl/state/13/nfhl_13_20260208.pmtiles",
    "geoparquet_prefix": "geoparquet/nfhl/state/13/"
  },
  "crs": {
    "source": "EPSG:4269",
    "target": "EPSG:4326"
  },
  "layers": [
    {
      "gdb_layer": "S_FLD_HAZ_AR",
      "tile_layer": "flood_zones",
      "sql": "SELECT FLD_ZONE, ZONE_SUBTY, SFHA_TF, STATIC_BFE, DEPTH, FLD_AR_ID, SHAPE FROM S_FLD_HAZ_AR WHERE FLD_ZONE IS NOT NULL AND FLD_ZONE != ''",
      "geometry_type": "MULTIPOLYGON",
      "makevalid": true,
      "zoom_min": 4,
      "zoom_max": 16,
      "tippecanoe_opts": {
        "simplification": 4,
        "simplification_at_maximum_zoom": 1,
        "no_simplification_of_shared_nodes": true,
        "coalesce_densest_as_needed": true,
        "extend_zooms_if_still_dropping": true
      }
    },
    {
      "gdb_layer": "S_FIRM_PAN",
      "tile_layer": "firm_panels",
      "sql": "SELECT FIRM_PAN, PANEL_TYP, EFF_DATE, SCALE, ST_FIPS, CO_FIPS, SHAPE FROM S_FIRM_PAN WHERE PANEL_TYP IS NOT NULL",
      "geometry_type": "MULTIPOLYGON",
      "makevalid": true,
      "zoom_min": 5,
      "zoom_max": 12,
      "tippecanoe_opts": {
        "simplification": 8,
        "simplification_at_maximum_zoom": 2,
        "coalesce_densest_as_needed": true
      }
    },
    {
      "gdb_layer": "S_BFE",
      "tile_layer": "bfe_lines",
      "sql": "SELECT BFE_LN_ID, ELEV, LEN_UNIT, V_DATUM, SHAPE FROM S_BFE WHERE ELEV IS NOT NULL AND ELEV > 0",
      "geometry_type": "MULTILINESTRING",
      "makevalid": false,
      "zoom_min": 11,
      "zoom_max": 16,
      "tippecanoe_opts": {
        "simplification": 2,
        "simplification_at_maximum_zoom": 1
      }
    },
    {
      "gdb_layer": "S_LOMR",
      "tile_layer": "lomr",
      "sql": "SELECT CASE_NO, STATUS, EFF_DATE, PROJECT_NA, SHAPE FROM S_LOMR WHERE STATUS IS NOT NULL",
      "geometry_type": "MULTIPOLYGON",
      "makevalid": true,
      "zoom_min": 8,
      "zoom_max": 16,
      "tippecanoe_opts": {
        "simplification": 3,
        "simplification_at_maximum_zoom": 1
      }
    },
    {
      "gdb_layer": "S_LEVEE",
      "tile_layer": "levees",
      "sql": "SELECT LEVEE_ID, CERT_STAT, SHAPE FROM S_LEVEE",
      "geometry_type": "MULTILINESTRING",
      "makevalid": false,
      "zoom_min": 9,
      "zoom_max": 16,
      "tippecanoe_opts": {
        "simplification": 2,
        "simplification_at_maximum_zoom": 1
      }
    },
    {
      "gdb_layer": "S_WTR_AR",
      "tile_layer": "water_areas",
      "sql": "SELECT WTR_NM, SHAPE FROM S_WTR_AR WHERE SHAPE IS NOT NULL",
      "geometry_type": "MULTIPOLYGON",
      "makevalid": true,
      "zoom_min": 6,
      "zoom_max": 14,
      "tippecanoe_opts": {
        "simplification": 6,
        "simplification_at_maximum_zoom": 2,
        "coalesce_densest_as_needed": true
      }
    },
    {
      "gdb_layer": "S_WTR_LN",
      "tile_layer": "water_lines",
      "sql": "SELECT WTR_NM, SHAPE FROM S_WTR_LN WHERE SHAPE IS NOT NULL",
      "geometry_type": "MULTILINESTRING",
      "makevalid": false,
      "zoom_min": 9,
      "zoom_max": 16,
      "tippecanoe_opts": {
        "simplification": 3,
        "simplification_at_maximum_zoom": 1
      }
    }
  ]
}
```

### R Pipeline Executor

The spec above is consumed by a pipeline function that:
1. Parses the spec
2. For each layer: runs `ogr2ogr` to GeoJSONSeq (stdout pipe or temp file)
3. Passes all layers to a single `tippecanoe` invocation with per-layer `-L` flags
4. Uploads the resulting `.pmtiles` to object storage
5. Records the run in `pipeline.materialization_runs`

```r
run_nfhl_pipeline <- function(spec_path, storage_bucket, dry_run = FALSE) {
  spec <- jsonlite::read_json(spec_path)
  state_fips <- spec$state_fips
  vsi_source <- spec$source_vsi

  # Temp dir for per-layer GeoJSONSeq intermediates
  tmp_dir <- fs::path_temp(glue::glue("nfhl_{state_fips}"))
  fs::dir_create(tmp_dir)
  on.exit(fs::dir_delete(tmp_dir), add = TRUE)

  layer_files <- purrr::map(spec$layers, function(lyr) {
    out_file <- fs::path(tmp_dir, glue::glue("{lyr$tile_layer}.geojsonl"))

    ogr2ogr_args <- c(
      "-f", "GeoJSONSeq",
      "-t_srs", spec$crs$target,
      if (lyr$makevalid) "-makevalid",
      "-nlt", lyr$geometry_type,
      "-sql", lyr$sql,
      out_file,
      vsi_source
    )

    cli::cli_alert_info("Converting {.field {lyr$gdb_layer}} -> {.path {out_file}}")
    if (!dry_run) {
      result <- sf::gdal_utils("vectortranslate", vsi_source, out_file,
        options = ogr2ogr_args[-c(1, length(ogr2ogr_args) - 0:1)])
    }

    list(
      tile_layer = lyr$tile_layer,
      file = out_file,
      zoom_min = lyr$zoom_min,
      zoom_max = lyr$zoom_max,
      opts = lyr$tippecanoe_opts
    )
  })

  # Build tippecanoe -L flags per layer
  pmtiles_out <- fs::path(tmp_dir, glue::glue("nfhl_{state_fips}.pmtiles"))

  tippecanoe_layers <- purrr::map_chr(layer_files, function(lf) {
    jsonlite::toJSON(list(
      file = as.character(lf$file),
      layer = lf$tile_layer,
      minzoom = lf$zoom_min,
      maxzoom = lf$zoom_max
    ), auto_unbox = TRUE)
  })

  tippecanoe_cmd <- c(
    "tippecanoe",
    "--force",
    "-o", as.character(pmtiles_out),
    "--no-tile-size-limit",
    purrr::map(tippecanoe_layers, ~ c("-L", .x)) |> unlist()
  )

  if (!dry_run) {
    processx::run(tippecanoe_cmd[1], tippecanoe_cmd[-1], echo = TRUE)
    # upload pmtiles_out to storage at spec$output$pmtiles_key
  }

  invisible(pmtiles_out)
}
```

### CONUS Merge (Optional)

After all 56 state PMTiles archives are generated, a CONUS merge is run using `tile-join`:

```bash
tile-join \
  --output=tiles/nfhl/conus/nfhl_conus_20260208.pmtiles \
  --force \
  tiles/nfhl/state/01/nfhl_01_*.pmtiles \
  tiles/nfhl/state/02/nfhl_02_*.pmtiles \
  # ... all 56 states
```

The per-state archives remain in storage for targeted re-materialization when a single state's data changes. The CONUS archive is the primary serving URL for MapLibre.

---

## Decision 4 — PMTiles Bundling Strategy

**Strategy: Per-state archives → CONUS `tile-join` merge → single CONUS serving URL.**

- The MapLibre client declares exactly **one PMTiles source** pointing to the CONUS archive
- All 7 layers are source-layers within that single archive — no protocol multiplexing
- Per-state archives remain in storage for targeted re-materialization (when Georgia updates, only Georgia's archive is rebuilt and the CONUS merge is re-run with the updated state replacing the stale one)
- The CONUS merge is a cheap `tile-join` operation — no re-processing of any GDB data

**Object storage layout:**

```
bucket/
└── tiles/
    └── nfhl/
        ├── state/
        │   ├── 13/nfhl_13_20260208.pmtiles
        │   ├── 12/nfhl_12_20260115.pmtiles
        │   └── ...
        ├── conus/
        │   └── nfhl_conus_20260208.pmtiles   ← primary serving URL
        └── specs/
            ├── nfhl_13_20260208_spec.json    ← pipeline spec per run
            └── ...
```

---

## Decision 5 — MapLibre Style Definitions

Style is derived from the official FEMA FIRM/FIRMette symbology (visible in the attached FIRMette legend). The `drawingInfo.renderer` from the NFHL ArcGIS MapServer layer endpoints provides the official FEMA color values and should be fetched once per layer to inform these definitions — but the styles themselves live in the client's MapLibre style JSON, not in the tiles.

### flood_zones Layer Style

```javascript
// Flood zone fill — primary layer
{
  "id": "flood-zones-fill",
  "type": "fill",
  "source": "nfhl",
  "source-layer": "flood_zones",
  "paint": {
    "fill-color": [
      "case",
      // Floodway — highest priority, override zone color
      ["==", ["get", "ZONE_SUBTY"], "FLOODWAY"],
      "rgba(0, 70, 200, 0.75)",

      // Coastal High Hazard (VE, V)
      ["in", ["get", "FLD_ZONE"], ["literal", ["VE", "V"]]],
      "rgba(115, 0, 230, 0.5)",

      // SFHA Zones AE / AR / AO / AH / A1-30 / A99
      ["==", ["get", "SFHA_TF"], "T"],
      "rgba(0, 112, 255, 0.45)",

      // 0.2% Annual Chance (Zone X shaded)
      ["==", ["get", "ZONE_SUBTY"], "0.2 PCT ANNUAL CHANCE FLOOD HAZARD"],
      "rgba(255, 160, 0, 0.25)",

      // Zone D — undetermined
      ["==", ["get", "FLD_ZONE"], "D"],
      "rgba(130, 130, 130, 0.3)",

      // Zone X (unshaded) / everything else — no fill
      "rgba(0, 0, 0, 0)"
    ],
    "fill-opacity": 1
  }
},

// Flood zone outline
{
  "id": "flood-zones-outline",
  "type": "line",
  "source": "nfhl",
  "source-layer": "flood_zones",
  "filter": ["!=", ["get", "FLD_ZONE"], "X"],
  "paint": {
    "line-color": [
      "case",
      ["in", ["get", "FLD_ZONE"], ["literal", ["VE", "V"]]],
      "rgba(115, 0, 230, 0.8)",
      ["==", ["get", "SFHA_TF"], "T"],
      "rgba(0, 80, 200, 0.6)",
      "rgba(130, 130, 130, 0.4)"
    ],
    "line-width": ["interpolate", ["linear"], ["zoom"], 8, 0.5, 14, 1.5],
    "line-opacity": 0.8
  }
},

// Floodway hatch pattern (requires MapLibre pattern or CSS stripes approach)
// Use a fill-pattern referencing a pre-loaded hatch sprite, or simulate
// with a second translucent fill at higher opacity:
{
  "id": "flood-zones-floodway-overlay",
  "type": "fill",
  "source": "nfhl",
  "source-layer": "flood_zones",
  "filter": ["==", ["get", "ZONE_SUBTY"], "FLOODWAY"],
  "paint": {
    "fill-pattern": "floodway-hatch",   // sprite-based hatch
    "fill-opacity": 0.6
  }
}
```

### firm_panels Layer Style

```javascript
{
  "id": "firm-panels-outline",
  "type": "line",
  "source": "nfhl",
  "source-layer": "firm_panels",
  "minzoom": 6,
  "maxzoom": 12,
  "paint": {
    "line-color": "rgba(80, 80, 80, 0.4)",
    "line-width": 0.75,
    "line-dasharray": [4, 3]
  }
},
{
  "id": "firm-panels-label",
  "type": "symbol",
  "source": "nfhl",
  "source-layer": "firm_panels",
  "minzoom": 8,
  "maxzoom": 12,
  "layout": {
    "text-field": ["get", "FIRM_PAN"],
    "text-size": 10,
    "text-font": ["DIN Pro Regular", "Arial Unicode MS Regular"]
  },
  "paint": {
    "text-color": "rgba(80, 80, 80, 0.7)",
    "text-halo-color": "rgba(255,255,255,0.8)",
    "text-halo-width": 1
  }
}
```

### bfe_lines Layer Style

```javascript
{
  "id": "bfe-lines",
  "type": "line",
  "source": "nfhl",
  "source-layer": "bfe_lines",
  "minzoom": 11,
  "paint": {
    "line-color": "#0050b3",
    "line-width": ["interpolate", ["linear"], ["zoom"], 11, 0.75, 16, 1.5],
    "line-dasharray": [6, 2]
  }
},
{
  "id": "bfe-labels",
  "type": "symbol",
  "source": "nfhl",
  "source-layer": "bfe_lines",
  "minzoom": 13,
  "layout": {
    "text-field": ["concat", ["to-string", ["get", "ELEV"]], " ft"],
    "text-size": 10,
    "symbol-placement": "line",
    "text-offset": [0, -0.5]
  },
  "paint": {
    "text-color": "#0050b3",
    "text-halo-color": "rgba(255,255,255,0.9)",
    "text-halo-width": 1.5
  }
}
```

### lomr Layer Style

```javascript
{
  "id": "lomr-fill",
  "type": "fill",
  "source": "nfhl",
  "source-layer": "lomr",
  "minzoom": 8,
  "paint": {
    "fill-color": "rgba(255, 80, 80, 0.12)",
    "fill-outline-color": "rgba(200, 0, 0, 0.6)"
  }
},
{
  "id": "lomr-outline",
  "type": "line",
  "source": "nfhl",
  "source-layer": "lomr",
  "minzoom": 8,
  "paint": {
    "line-color": "rgba(200, 0, 0, 0.7)",
    "line-width": 1.5,
    "line-dasharray": [3, 2]
  }
}
```

### levees Layer Style

```javascript
{
  "id": "levees",
  "type": "line",
  "source": "nfhl",
  "source-layer": "levees",
  "minzoom": 9,
  "paint": {
    "line-color": [
      "match", ["get", "CERT_STAT"],
      "CERTIFIED",   "#2d6a2d",
      "PROVISIONALLY CERTIFIED", "#7a9e4e",
      "UNDER CERT",  "#c0a000",
      "NON-ACCREDITED", "#cc4400",
      "#888888"
    ],
    "line-width": ["interpolate", ["linear"], ["zoom"], 9, 1.5, 16, 3],
    "line-offset": 1
  }
}
```

### water_areas / water_lines Layer Style

```javascript
{
  "id": "water-areas-fill",
  "type": "fill",
  "source": "nfhl",
  "source-layer": "water_areas",
  "minzoom": 6,
  "paint": {
    "fill-color": "rgba(180, 215, 240, 0.6)"
  }
},
{
  "id": "water-lines",
  "type": "line",
  "source": "nfhl",
  "source-layer": "water_lines",
  "minzoom": 9,
  "paint": {
    "line-color": "rgba(100, 180, 230, 0.8)",
    "line-width": ["interpolate", ["linear"], ["zoom"], 9, 0.75, 16, 2]
  }
}
```

### Source Declaration

```javascript
import { Protocol } from 'pmtiles';
const protocol = new Protocol();
maplibregl.addProtocol('pmtiles', protocol.tile);

map.addSource('nfhl', {
  type: 'vector',
  url: 'pmtiles://https://your-r2-domain.com/tiles/nfhl/conus/nfhl_conus_20260208.pmtiles',
  attribution: 'FEMA National Flood Hazard Layer'
});
```

---

## Decision 6 — NFHLWMS Service

**Skip as a tile/map source entirely.** The NFHL vector tiles served from the CONUS PMTiles archive are superior in every dimension: styling control, performance, interactivity (click/hover queries on features), and zero dependency on FEMA's server availability.

**However, extract the ArcGIS renderer JSON for style reference.** The `drawingInfo.renderer` block from each MapServer layer endpoint provides the official FEMA symbology — FEMA's exact color values and zone classification scheme. Fetch these once and store in the pipeline spec metadata:

```r
fetch_nfhl_renderer <- function(layer_index) {
  url <- glue::glue(
    "https://hazards.fema.gov/arcgis/rest/services/public/NFHL/MapServer/{layer_index}?f=json"
  )
  resp <- httr2::request(url) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  resp$drawingInfo$renderer
}
# layer 28 = S_FLD_HAZ_AR
renderer_28 <- fetch_nfhl_renderer(28)
```

The WMS `GetLegendGraphic` endpoint can also produce legend PNG tiles per layer — useful as a legend reference image in the UI without custom implementation. Store the legend PNGs as static assets.

---

## Decision 7 — Draft and Preliminary NFHL

**Preliminary NFHL: query on-demand only. Do not materialize to PMTiles.**

The Pending NFHL MapServer (`/PrelimPending/Pending_NFHL/MapServer`) is queried per-parcel as a second ArcGIS request during the on-demand flood analysis workflow, alongside the effective NFHL query. The result is stored as `pending_zones JSONB` in the parcel flood analysis record and surfaced in the UI as a "pending remapping" flag. This is high-value information for a real estate analysis context.

**Draft NFHL: skip entirely.** Draft maps are pre-preliminary — too early in the revision lifecycle to be actionable for property-level risk assessment.

**Implementation pattern (R):**

```r
query_parcel_flood_hazard <- function(parcel_geom) {
  filter_qry <- arcgislayers::prepare_spatial_filter(
    filter_geom = parcel_geom,
    crs = sf::st_crs(4269),
    predicate = "intersects"
  )

  # Effective NFHL — Layer 28 (S_FLD_HAZ_AR)
  effective <- httr2::request(
    "https://hazards.fema.gov/arcgis/rest/services/public/NFHL/MapServer/28/query"
  ) |>
    httr2::req_url_query(where = "1=1", outFields = "*", f = "pbf", !!!filter_qry) |>
    httr2::req_perform() |>
    arcpbf::resp_body_pbf()

  # Pending NFHL — equivalent layer in Pending service
  # Note: layer index may differ; confirm via get_all_layers() on the pending service
  pending_svc <- arcgislayers::arc_open(
    "https://hazards.fema.gov/arcgis/rest/services/PrelimPending/Pending_NFHL/MapServer"
  )
  pending_layers <- arcgislayers::get_all_layers(pending_svc)
  # Query the pending S_FLD_HAZ_AR equivalent using same filter

  list(effective = effective, pending = pending_layers)
}
```

---

## Decision 8 — Additional GPServer Artifacts

### Supported Artifacts

| Artifact | Source | Trigger | Format |
|---|---|---|---|
| FIRMette | `msc_print` GPServer | Per-parcel analysis request | PDF + PNG |
| Preliminary Comparison | `msc_preliminary` GPServer | Per-parcel if pending data exists | PDF |
| LOMC Status | `S_LOMR` layer query (ArcGIS) | Per-parcel — not a GPServer call | Structured data |

**LOMC is NOT a separate GPServer call.** The `S_LOMR` layer in the effective NFHL MapServer (and separately in the LOMC-specific service on ArcGIS Hub) provides LOMA/LOMR data via a standard feature query. For per-parcel analysis, query `S_LOMR` with the same spatial filter as `S_FLD_HAZ_AR`. This gives structured LOMR data (case number, effective date, status) which is more useful than a PDF lookup. The LOMC batch files on MSC (weekly ZIP downloads) are relevant only if building a bulk LOMR tracking system — not needed for on-demand parcel analysis.

The `msc_preliminary` GPServer (Preliminary Comparison report) is already in the existing R implementation. It should be called conditionally: only if the pending NFHL query found active pending zones for the parcel's area.

---

## Decision 9 — PostgreSQL Schema

### Schema Organization

Three schemas cover the NFHL domain:

- `pipeline` — materialization job tracking (generic, reusable across all sources)
- `fema` — NFHL-specific analysis tables
- `storage` — blob artifact references (generic, reusable across all sources)

### pipeline.materialization_runs

Generic run tracking table — this is the pattern that generalizes to TIGER, NWI, SSURGO, and any other archive-sourced PMTiles workflow.

```sql
CREATE SCHEMA IF NOT EXISTS pipeline;

CREATE TABLE pipeline.materialization_runs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id       TEXT NOT NULL,         -- e.g., 'nfhl_state_13', 'tiger_state_13'
  source_type     TEXT NOT NULL,         -- 'nfhl_gdb', 'tiger_shp', 'overture_parquet'
  run_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at    TIMESTAMPTZ,
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','running','completed','failed')),
  source_url      TEXT NOT NULL,
  source_file     TEXT,                  -- filename component of source_url
  source_effective_date DATE,
  spec_storage_key TEXT,                 -- path to the JSON pipeline spec in object storage
  output_paths    JSONB,                 -- {"pmtiles": "tiles/nfhl/...", "geoparquet": "..."}
  output_sizes    JSONB,                 -- {"pmtiles": 45678901}
  feature_counts  JSONB,                 -- {"S_FLD_HAZ_AR": 257844, "S_FIRM_PAN": 1203}
  duration_secs   INTEGER,
  error_message   TEXT,
  metadata        JSONB                  -- source-specific metadata catch-all
);

CREATE INDEX idx_mat_runs_source_id   ON pipeline.materialization_runs(source_id);
CREATE INDEX idx_mat_runs_source_type ON pipeline.materialization_runs(source_type);
CREATE INDEX idx_mat_runs_status      ON pipeline.materialization_runs(status);
CREATE INDEX idx_mat_runs_run_at      ON pipeline.materialization_runs(run_at DESC);
```

### fema.nfhl_state_snapshots

NFHL-specific extension of the run record — tracks the current PMTiles serving state per state FIPS.

```sql
CREATE SCHEMA IF NOT EXISTS fema;

CREATE TABLE fema.nfhl_state_snapshots (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id          UUID NOT NULL REFERENCES pipeline.materialization_runs(id),
  state_fips      TEXT NOT NULL,
  state_name      TEXT,
  effective_date  DATE,
  source_file     TEXT NOT NULL,        -- NFHL_13_20260208.zip
  source_url      TEXT NOT NULL,
  layers_included TEXT[],              -- ['S_FLD_HAZ_AR', 'S_FIRM_PAN', ...]
  pmtiles_key     TEXT,                -- object storage key
  pmtiles_size_bytes BIGINT,
  is_current      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enforce single current snapshot per state
CREATE UNIQUE INDEX idx_nfhl_snapshots_current_state
  ON fema.nfhl_state_snapshots(state_fips)
  WHERE is_current = TRUE;

CREATE INDEX idx_nfhl_snapshots_state   ON fema.nfhl_state_snapshots(state_fips);
CREATE INDEX idx_nfhl_snapshots_run     ON fema.nfhl_state_snapshots(run_id);
```

### fema.parcel_flood_analyses

On-demand parcel flood analysis results. One row per parcel per analysis request. Supports historical records (`is_current = FALSE`) to track how flood risk changes over time.

```sql
CREATE TABLE fema.parcel_flood_analyses (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  parcel_id             UUID NOT NULL,  -- FK to core.parcels or equivalent
  analyzed_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Source metadata
  source                TEXT NOT NULL DEFAULT 'nfhl_arcgis_mapserver',
  arcgis_service_url    TEXT,
  arcgis_layer_index    INTEGER DEFAULT 28,

  -- Summary / derived
  is_sfha               BOOLEAN,
  primary_zone          TEXT,           -- FLD_ZONE of largest-area intersecting feature
  primary_zone_subtype  TEXT,           -- ZONE_SUBTY of primary zone
  has_floodway          BOOLEAN NOT NULL DEFAULT FALSE,
  has_pending_revision  BOOLEAN NOT NULL DEFAULT FALSE,

  -- Coverage metrics
  sfha_coverage_pct     NUMERIC(6,3),  -- % of parcel area in SFHA
  zone_x_coverage_pct   NUMERIC(6,3),  -- % in Zone X (minimal hazard)

  -- LOMR / LOMA data (from S_LOMR query)
  active_lomrs          JSONB,          -- [{case_no, status, eff_date, project_na}]
  has_active_lomr       BOOLEAN NOT NULL DEFAULT FALSE,

  -- Raw feature data
  intersecting_zones    JSONB NOT NULL, -- [{zone, subtype, sfha, coverage_pct, fld_ar_id}]
  pending_zones         JSONB,          -- from Pending NFHL query
  raw_pbf_features      JSONB,          -- full parsed PBF output if retained

  -- Staleness management
  is_current            BOOLEAN NOT NULL DEFAULT TRUE,

  -- Parcel geometry snapshot at time of analysis
  parcel_geometry       GEOMETRY(MULTIPOLYGON, 4326)
);

CREATE INDEX idx_pfa_parcel_id  ON fema.parcel_flood_analyses(parcel_id);
CREATE INDEX idx_pfa_current    ON fema.parcel_flood_analyses(parcel_id) WHERE is_current;
CREATE INDEX idx_pfa_sfha       ON fema.parcel_flood_analyses(is_sfha) WHERE is_current;
CREATE INDEX idx_pfa_zone       ON fema.parcel_flood_analyses(primary_zone) WHERE is_current;
CREATE INDEX idx_pfa_analyzed   ON fema.parcel_flood_analyses(analyzed_at DESC);
```

### storage.artifacts

Generic blob artifact table — used for FIRMette PDFs/PNGs and any other file-type outputs across the system (not FEMA-specific).

```sql
CREATE SCHEMA IF NOT EXISTS storage;

CREATE TABLE storage.artifacts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type     TEXT NOT NULL,   -- 'parcel', 'property', etc.
  entity_id       UUID NOT NULL,   -- FK to the relevant entity
  artifact_type   TEXT NOT NULL,   -- 'firmette', 'firm', 'preliminary_comparison', 'report'
  format          TEXT NOT NULL,   -- 'pdf', 'png', 'html', 'json'
  storage_bucket  TEXT NOT NULL,
  storage_key     TEXT NOT NULL,
  public_url      TEXT,            -- pre-signed or public URL if applicable
  file_size_bytes INTEGER,
  content_hash    TEXT,            -- SHA-256 of file content for dedup
  generated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at      TIMESTAMPTZ,     -- for signed URLs
  source_service  TEXT,            -- 'msc_gp_firmette', 'msc_gp_preliminary', etc.
  source_job_id   TEXT,            -- ArcGIS GP job ID
  source_metadata JSONB,           -- {latitude, longitude, firm_panel, effective_date, ...}
  tags            TEXT[],          -- ['fema', 'flood', 'firmette']
  is_current      BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_artifacts_entity     ON storage.artifacts(entity_type, entity_id);
CREATE INDEX idx_artifacts_type       ON storage.artifacts(artifact_type, format);
CREATE INDEX idx_artifacts_current    ON storage.artifacts(entity_id) WHERE is_current;
CREATE INDEX idx_artifacts_generated  ON storage.artifacts(generated_at DESC);

-- Unique current artifact per entity+type+format
CREATE UNIQUE INDEX idx_artifacts_current_unique
  ON storage.artifacts(entity_type, entity_id, artifact_type, format)
  WHERE is_current = TRUE;
```

### FIRMette artifact linkage to parcel analysis

The `storage.artifacts` table decouples artifact storage from domain tables. The linkage is through `entity_type = 'parcel'` and `entity_id = parcel_id`. An analysis workflow sets `source_metadata` to include the `analysis_id` from `fema.parcel_flood_analyses` for traceability without a hard FK.

---

## Decision 10 — Pattern Implications for Future Sources

This NFHL setup establishes three reusable patterns:

### Pattern A: Archive-Sourced PMTiles (NFHL → TIGER, NWI, SSURGO, NLCD)

The `pipeline.materialization_runs` + source-specific snapshot table + JSON pipeline spec + `tile-join` CONUS merge is the template for every archive-sourced vector tile layer. Future sources plug in by:
1. Writing a new source-type spec JSON following the NFHL spec schema
2. Deriving download URLs via the source's API (Census FTP for TIGER, USGS TNM API for NWI, etc.)
3. Selecting layers and field schemas from the source's layer catalog via `ogrinfo`
4. Adding a source-specific snapshot table (e.g., `census.tiger_state_snapshots`)
5. The `pipeline.materialization_runs` record handles everything else

### Pattern B: On-Demand ArcGIS PBF Feature Query (NFHL → EPA, NWI, SSURGO FeatureServers)

Any federal ArcGIS MapServer or FeatureServer that supports `f=pbf` follows the same query pattern: `prepare_spatial_filter` → `httr2` PBF request → `arcpbf::resp_body_pbf()` → `JSONB` storage in domain analysis table. The `fema.parcel_flood_analyses` schema is the template. Future sources (EPA Brownfields, NWI wetlands, SSURGO soils) get their own schema tables with entity FK references and `is_current` staleness management.

### Pattern C: GPServer Artifact Generation (NFHL FIRMette → Future Report Artifacts)

The `storage.artifacts` table with `entity_type` / `entity_id` / `artifact_type` / `format` is generic enough to hold any generated report or file artifact from any source. Future GPServer-style job-poll-download workflows (USGS water data reports, etc.) add only the domain-specific job submission logic — the artifact storage and lifecycle management is already in place.

---

## Open Items / Next Decisions

1. **CONUS PMTiles update trigger logic** — How to detect when a state's NFHL source file has changed (compare `product_FILE_PATH` embedded date against current `fema.nfhl_state_snapshots.source_file`). Recommend a lightweight scheduled poll of the MSC API per state, diff the date component, trigger re-materialization only on change.

2. **Pending NFHL layer index mapping** — The Pending NFHL MapServer layer indices need to be confirmed via `get_all_layers()` to map the equivalent of `S_FLD_HAZ_AR` in that service. The effective NFHL uses index 28; Pending may differ.

3. **Floodway hatch sprite** — The floodway fill-pattern style requires a sprite asset (hatch PNG) bundled with the MapLibre style. This is a small asset but needs to be generated and added to the style sprite sheet.

4. **`core.parcels` FK definition** — The `parcel_id` references in `fema.parcel_flood_analyses` and `storage.artifacts` assume a `core.parcels` table with a UUID PK. This FK constraint should be enabled once the parcel schema is finalized.
