# Scripts

- [pwsh](./pwsh/): PowerShell (Core) Scripts
- [python](./python/): Python Scripts
- [r](./r/): R Scripts
- [shell](./shell/): Shell Scripts
- [sql](./sql/): SQL Scripts

## Current Primary Scripts

The currently proven parcel workflow lives in `scripts/pwsh/`:

- `Extract-StateFGB.ps1` -- extracts one or more state FlatGeoBuf files from
  the source GeoPackage using `pixi run ogr2ogr`
- `Test-StateFGB.ps1` -- validates extracted FGBs, writes sidecar
  `parcels.fgb.json` metadata files, updates `data/meta/fgb_validation_report.csv`,
  and regenerates `data/output/flatgeobuf/catalog.json`
- `Test-TigrisFGB.ps1` -- confirms remote FGB access from Tigris via GDAL

## Notes

- The PowerShell scripts are the current execution substrate, not the final
  long-term orchestration layer.
- Bash scripts under `shell/` reflect earlier WSL-based work and remain useful
  as historical reference.
- As the workflow stabilizes further, the intent is to formalize the core logic
  in a higher-level interface while preserving these scripts as reference
  implementations.