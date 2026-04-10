# Parcels Source Dataset

## Overview

This document is the canonical source note for the parcel dataset currently
driving the project.

The project starts from the Kaggle-hosted
[`US Parcel Layer`](https://www.kaggle.com/datasets/landrecordsus/us-parcel-layer?select=LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg)
dataset published by `landrecordsus`, with additional source metadata captured
in [data/meta/us-parcel-layer-metadata.json](../../data/meta/us-parcel-layer-metadata.json).

For attribution and external reference only, see the
[Land Records documentation](https://landrecords.us/documentation).

## Source Artifact

| Property | Value |
|---|---|
| File | `LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg` |
| Upstream distribution | Kaggle ZIP download |
| Local working format | GeoPackage / SQLite |
| Layer | `lr_parcel_us` |
| Geometry type | `MultiPolygon` |
| CRS | `EPSG:4326` |
| Feature identifier | `lrid` (GeoPackage FID) |
| Feature count | 154,891,095 |
| State / territory groups | 55 |
| County groups | 3,229 |

The working location of the GeoPackage is environment-specific and deliberately
not part of the repository contract.

## Kaggle / Croissant Metadata

The Kaggle-specific metadata snapshot in
[data/meta/us-parcel-layer-metadata.json](../../data/meta/us-parcel-layer-metadata.json)
contains the following notable fields:

- dataset name: `US Parcel Layer`
- alternate name: `Landrecords.us US Nationwide Parcel Layer`
- creator: `landrecords.us`
- catalog: `Kaggle`
- license: `CC BY-NC-ND 4.0`
- Kaggle distribution URL for version `1`
- published / modified timestamps
- keyword tags and dataset description

This artifact is useful because it preserves source provenance independent of
the binary GeoPackage itself.

## Source Characteristics

### Storage and indexing

The upstream file is a single large SQLite-backed GeoPackage. The following
characteristics are established:

- the source already includes an R-tree spatial index
- the source did **not** include an attribute B-tree index suitable for
  `statefp` / `countyfp` / `geoid` grouping and filtering
- the project added a B-tree index:
  - `idx_parcel_state_county ON (statefp, countyfp, geoid)`
- WAL mode is enabled on the working GeoPackage

This indexing work is now part of the expected local preparation of the source
before downstream extraction.

### Partitioning fields

The source already contains the fields used to drive downstream partitioning:

- `statefp` -- 2-character state / territory FIPS
- `countyfp` -- 3-character county FIPS
- `geoid` -- 5-character county identifier (`statefp || countyfp`)

These fields were validated during initial analysis and are now treated as the
canonical partition keys for parcel workflows.

### Geometry behavior

Important geometry findings established from analysis:

- the layer contains a small number of empty / degenerate geometries
- these geometries are not `NULL`, but they are not spatially indexable in a
  useful way
- the extraction workflow combines:
  - `WHERE statefp = 'XX'`
  - state bounding box pre-filtering
- this combination naturally excludes the problematic empty geometries via the
  spatial index path

This is why small negative diffs between manifest counts and extracted FGB
counts are acceptable during validation.

## Source Schema

### Source identifiers and keys

- `lrid` (FID)
- `parcelid`
- `parcelid2`
- `geoid`
- `statefp`
- `countyfp`

### Assessment and land-use fields

- `taxacctnum`
- `taxyear`
- `usecode`
- `usedesc`
- `zoningcode`
- `zoningdesc`
- `numbldgs`
- `numunits`
- `yearbuilt`
- `numfloors`
- `bldgsqft`
- `bedrooms`
- `halfbaths`
- `fullbaths`
- `imprvalue`
- `landvalue`
- `agvalue`
- `totalvalue`
- `assdacres`
- `saleamt`
- `saledate`

### Ownership / mailing fields

- `ownername`
- `owneraddr`
- `ownercity`
- `ownerstate`
- `ownerzip`

### Parcel location and legal fields

- `parceladdr`
- `parcelcity`
- `parcelstate`
- `parcelzip`
- `legaldesc`
- `township`
- `section`
- `qtrsection`
- `range`
- `plssdesc`
- `book`
- `page`
- `block`
- `lot`

### Provenance / geometry-support fields

- `updated`
- `lrversion`
- `centroidx`
- `centroidy`
- `surfpointx`
- `surfpointy`
- `geom`

## Established Downstream Adjustments

The current FlatGeoBuf contract is a cleaned 47-column attribute schema plus
geometry, derived from the source as follows:

### Dropped fields

- `parcelstate`
- `lrversion`
- `halfbaths`
- `fullbaths`

These drops are based on source analysis and current downstream goals, not on a
claim that the original source fields are universally unimportant.

### Retained fields

All other non-FID source attributes are currently retained in the state FGBs.

### FID handling

- `lrid` remains the GeoPackage FID in the source
- `lrid` is not currently materialized into the FGB output schema

## Analysis Learnings Already Captured in Repo Artifacts

The following repo artifacts are the current source-derived analytical outputs:

- [data/meta/manifest_state_county.csv](../../data/meta/manifest_state_county.csv)
- [data/meta/manifest_state_rollup.csv](../../data/meta/manifest_state_rollup.csv)
- [data/meta/state_bboxes.csv](../../data/meta/state_bboxes.csv)
- [data/meta/fgb_validation_report.csv](../../data/meta/fgb_validation_report.csv)

Together these capture:

- state and county feature counts
- estimated output sizing
- extraction validation outcomes
- bounding boxes used for spatial pre-filtering

## What This Source Doc Does and Does Not Cover

This document covers:

- where the parcel source came from
- what the source artifact is
- what was learned from profiling and indexing it
- what schema and behavioral assumptions downstream workflows now rely on

This document does **not** attempt to fully document:

- every exploratory path taken before the current workflow settled
- future parquet partitioning details
- PMTiles or MapLibre delivery architecture
- generalized metadata/catalog strategy beyond how this specific source feeds it

Those topics belong in the workflow/spec docs.
