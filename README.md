# US Parcels

<!-- BADGES:START -->
[![Automate Changelog](https://github.com/jimbrig/usparcels/actions/workflows/changelog.yml/badge.svg)](https://github.com/jimbrig/usparcels/actions/workflows/changelog.yml)
<!-- BADGES:END -->

Geospatial data engineering workspace for processing a nationwide US parcel
GeoPackage into cloud-native distribution formats hosted on Tigris.

## Overview

The current workflow starts from the Kaggle-hosted
[`US Parcel Layer`](https://www.kaggle.com/datasets/landrecordsus/us-parcel-layer?select=LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg)
GeoPackage:

- file: `LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg`
- size: ~96.85 GB after local indexing
- features: 154,891,095
- layer: `lr_parcel_us`
- CRS: `EPSG:4326`

The pipeline is intentionally staged:

1. Audit and index the source GeoPackage.
2. Extract per-state FlatGeoBuf files with a cleaned 47-column schema.
3. Validate each FGB and generate sidecar metadata plus a collection catalog.
4. Upload validated artifacts to Tigris.
5. Use remote FGBs as the Phase 2 input for GeoParquet creation.

## Project Goals

The project currently has three primary goals:

1. Build a best-practice cloud-native parcel data platform that transforms a
   monolithic source GeoPackage into remote-hosted, open-standard data
   artifacts.
2. Build the visualization side of the platform around MapLibre, PMTiles, and
   modern MLT encoding.
3. Extend the same platform and workflow patterns to additional sources such as
   TIGER and FEMA, while gradually formalizing reusable R package interfaces.

## Current State

Completed and stable:

- GeoPackage indexing and manifests under `data/meta/`
- PowerShell extraction workflow in `scripts/pwsh/Extract-StateFGB.ps1`
- PowerShell validation workflow in `scripts/pwsh/Test-StateFGB.ps1`
- Sidecar metadata files `parcels.fgb.json`
- FlatGeoBuf collection catalog at `data/output/flatgeobuf/catalog.json`

Validated state FGBs currently include:

- `11` District of Columbia
- `13` Georgia
- `37` North Carolina
- `44` Rhode Island
- `48` Texas

## Canonical Docs

Use these as the primary source of truth:

- [Parcel source documentation](docs/sources/parcels.md)
- [Current parcels pipeline spec](docs/workflows/parcels-pipeline.md)
- [FGB metadata and artifact contracts](docs/specs/fgb-metadata.md)
- [Reference materials and copied standards](docs/reference/README.md)

## Data Layout

Relevant committed artifacts:

- `data/meta/manifest_state_county.csv`
- `data/meta/manifest_state_rollup.csv`
- `data/meta/state_bboxes.csv`
- `data/meta/fgb_validation_report.csv`
- `data/output/flatgeobuf/catalog.json`
- `data/output/flatgeobuf/statefp=*/parcels.fgb.json`

Large binary artifacts such as `.gpkg`, `.fgb`, `.parquet`, and `.pmtiles` are
gitignored unless deliberately copied into the repo for reference.

## Remote Access

The Tigris bucket is intentionally public for reads.

- Use `/vsicurl/https://noclocks-parcels.t3.storage.dev/...` for public HTTPS
  range-request access.
- Use `/vsis3/noclocks-parcels/...` for credentialed S3 API access and writes.

Once all per-state FGBs are uploaded, downstream work is expected to move to a
remote-first model.
