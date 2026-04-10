# Data

> [!NOTE]
> *This folder (`data`) houses the project's data sources, processed data, and other data-related artifacts.*

## Contents

- [`cache`](cache) - Cached data
- [`meta`](meta) - Metadata or reference/lookup data
- [`output`](output) - Output data, organized by format (i.e. `geoparquet`, `flatgeobuf`, `pmtiles`, etc.)
- [`sources`](sources) - References to actual source data using the [OGR VRT Virtual Format](https://gdal.org/en/stable/drivers/vector/vrt.html)
- [`styles`](styles) - [Maplibre Style JSON](https://maplibre.org/maplibre-style-spec/) specific to the maps and layers/data sources used in the project

## FlatGeoBuf Output Conventions

The current Phase 1 output contract is:

- `data/output/flatgeobuf/statefp=XX/parcels.fgb`
- `data/output/flatgeobuf/statefp=XX/parcels.fgb.json`
- `data/output/flatgeobuf/catalog.json`

Where:

- `parcels.fgb` is the extracted per-state FlatGeoBuf
- `parcels.fgb.json` is the validation sidecar and metadata receipt
- `catalog.json` is the collection-level catalog generated from all validated
  sidecars

The sidecar JSON is currently the primary per-file metadata artifact and is
designed to be promotable to STAC items later without schema churn.

See also:

- [`docs/workflows/parcels-pipeline.md`](../docs/workflows/parcels-pipeline.md)
- [`docs/specs/fgb-metadata.md`](../docs/specs/fgb-metadata.md)
- [`docs/sources/parcels.md`](../docs/sources/parcels.md)

## Remote Layout

The corresponding Tigris layout is:

- `flatgeobuf/statefp=XX/parcels.fgb`
- `flatgeobuf/statefp=XX/parcels.fgb.json`
- `flatgeobuf/catalog.json`

The bucket is publicly readable, so both `/vsicurl/https://...` and
credentialed `/vsis3/` access patterns are part of the intended workflow.
