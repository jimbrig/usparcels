# Data

> [!NOTE]
> *This folder (`data`) houses the project's data sources, processed data, and other data-related artifacts.*

## Contents

- [`cache`](cache) - Cached data
- [`meta`](meta) - Metadata or reference/lookup data
- [`output`](output) - Output data, organized by format (i.e. `geoparquet`, `flatgeobuf`, `pmtiles`, etc.)
- [`sources`](sources) - References to actual source data using the [OGR VRT Virtual Format](https://gdal.org/en/stable/drivers/vector/vrt.html)
- [`styles`](styles) - [Maplibre Style JSON](https://maplibre.org/maplibre-style-spec/) specific to the maps and layers/data sources used in the project
