# FGB Metadata and Artifact Contracts

## Purpose

This document defines the current metadata and artifact contracts for the
state-level FlatGeoBuf workflow.

These contracts exist so future work does not have to infer behavior from
scripts or terminal history.

## Artifact Set

For each validated state extract, the expected artifact set is:

```text
statefp=XX/
  parcels.fgb
  parcels.fgb.json
```

At the collection level:

```text
data/meta/fgb_validation_report.csv
data/output/flatgeobuf/catalog.json
```

## `parcels.fgb`

### Format

- FlatGeoBuf
- single layer named `parcels`
- `EPSG:4326`
- packed Hilbert spatial index

### Schema contract

- 47 retained attribute fields plus geometry
- dropped fields:
  - `parcelstate`
  - `lrversion`
  - `halfbaths`
  - `fullbaths`
- `lrid` is not materialized into the output schema

### Header metadata contract

There are currently two valid states of the world:

1. **legacy extracts**
   - no embedded header metadata
   - still valid if sidecar and catalog metadata exist
2. **current extracts**
   - `TITLE` and `DESCRIPTION` embedded via FGB layer creation options

The presence of header metadata is currently informational, not a pass/fail
criterion.

## `parcels.fgb.json`

### Purpose

The sidecar JSON is the machine-readable validation receipt for an individual
state FGB.

It records facts that are only known after extraction and validation:

- file size
- final feature count
- diff against the manifest
- validation status
- whether header metadata is embedded

### Current schema

```json
{
  "statefp": "44",
  "state_name": "Rhode Island",
  "format": "FlatGeoBuf",
  "source": "LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg",
  "schema_version": "2026.1",
  "validated_at": "2026-04-10T19:38:42Z",
  "gdal_version": "3.12.3",
  "file_size_bytes": 115248960,
  "feature_count": 195465,
  "manifest_count": 195474,
  "count_diff": -9,
  "geometry_type": "MultiPolygon",
  "geometry_column": "geom",
  "crs": "EPSG:4326",
  "bbox": [-71.8598237, 41.147906, -71.1210433, 41.9091718],
  "spatial_index": "hilbert",
  "column_count": 47,
  "dropped_columns": ["parcelstate", "lrversion", "halfbaths", "fullbaths"],
  "has_header_metadata": true,
  "status": "pass",
  "notes": "-9 excluded (empty geom via -spat filter)"
}
```

### Field meanings

| Field | Meaning |
|---|---|
| `statefp` | state / territory FIPS |
| `state_name` | human-readable state name |
| `format` | current artifact type |
| `source` | source GeoPackage filename |
| `schema_version` | current schema contract version |
| `validated_at` | UTC validation timestamp |
| `gdal_version` | GDAL version used during validation |
| `file_size_bytes` | on-disk FGB size |
| `feature_count` | final feature count in the FGB |
| `manifest_count` | expected count from the manifest |
| `count_diff` | `feature_count - manifest_count` |
| `geometry_type` | geometry type reported by GDAL |
| `geometry_column` | current geometry field name |
| `crs` | current CRS string |
| `bbox` | extracted extent from GDAL |
| `spatial_index` | expected index type |
| `column_count` | retained attribute count |
| `dropped_columns` | intentionally removed source fields |
| `has_header_metadata` | whether FGB header metadata exists |
| `status` | validation outcome |
| `notes` | human-readable validation notes |

### STAC compatibility

This sidecar schema is intentionally close to what a future STAC Item would
need:

- `bbox` maps directly
- `validated_at` can map into `properties.datetime`
- `statefp`, `state_name`, `feature_count`, and `status` become item properties
- the FGB and sidecar paths become STAC assets

This means the sidecar is not a dead-end custom format; it is a practical
intermediate contract.

## `fgb_validation_report.csv`

### Purpose

This CSV is the current collection-wide validation board for state FGBs.

### Columns

- `statefp`
- `state_name`
- `status`
- `fgb_features`
- `manifest_features`
- `feature_diff`
- `fgb_size_mb`
- `col_count`
- `cols_ok`
- `drops_ok`
- `geom_type`
- `crs`
- `has_header_meta`
- `notes`

### Semantics

- `pass` means the file conforms to the current extraction/validation contract
- `warn` is reserved for acceptable but notable deviations
- `fail` means the artifact does not satisfy the current contract

## `catalog.json`

### Purpose

The collection catalog is the current top-level inventory for validated FGB
artifacts.

### Role

- collection-wide summary
- stable index of currently validated state artifacts
- precursor to a future STAC collection / item layout

### Current top-level fields

- `type`
- `id`
- `title`
- `description`
- `schema_version`
- `source`
- `crs`
- `geometry_column`
- `spatial_index`
- `column_count`
- `dropped_columns`
- `tigris_bucket`
- `tigris_prefix`
- `links`
- `extent`
- `updated_at`
- `item_count`
- `items`

### Item entries

Each item currently includes:

- identity (`statefp`, `state_name`)
- validation status and timestamp
- file size and feature count
- bbox
- header metadata state
- local and Tigris locations for the FGB and sidecar

## Current Validation Rules

An FGB currently passes validation if:

- the file exists and is non-trivially sized
- the attribute count is 47
- dropped fields are absent
- the geometry type is `MultiPolygon`
- the CRS resolves to `EPSG:4326`

Small negative `count_diff` values are acceptable because the extraction
workflow intentionally excludes a small number of empty / degenerate geometries
through the spatial filtering path.

## Current Stable State Set

The current validated state set is:

- `11` District of Columbia
- `13` Georgia
- `37` North Carolina
- `44` Rhode Island
- `48` Texas

These artifacts are the current baseline for any future change to extraction,
validation, metadata generation, or catalog generation behavior.
