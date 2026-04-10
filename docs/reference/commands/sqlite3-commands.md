# SQLite3 Commands

## Set WAL and Synchronous Modes

```sh
sqlite3 /mnt/e/GEODATA/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL"
```