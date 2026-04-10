# ---- gpkg manifest creation --------------------------------------------------

gpkg_path <- "C:/GEODATA/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"
log_path <- "C:/GEODATA/parcels_manifest_creation.log"
county_manifest_path <- "C:/GEODATA/manifest_state_county.csv"
state_manifest_path <- "C:/GEODATA/manifest_state_rollup.csv"

.log <- function(..., log_file = log_path) {
  msg <- paste0("[", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "] ", paste(..., collapse = ""))
  message(msg)
  cat(msg, "\n", file = log_file, append = TRUE)
}

.log_df <- function(label, df, log_file = log_path) {
  .log(label, log_file = log_file)
  txt <- utils::capture.output(print(df))
  for (line in txt) {
    message("  ", line)
    cat("  ", line, "\n", file = log_file, append = TRUE)
  }
}

cat("", file = log_path)
.log("=== gpkg manifest creation script ===")
.log("gpkg path: ", gpkg_path)
.log("county manifest out: ", county_manifest_path)
.log("state manifest out: ", state_manifest_path)

.log("opening RO connection...")
conn <- DBI::dbConnect(RSQLite::SQLite(), gpkg_path, flags = RSQLite::SQLITE_RO)

.log("setting pragmas...")
DBI::dbExecute(conn, "PRAGMA journal_mode = WAL;")
DBI::dbExecute(conn, "PRAGMA cache_size = -4000000;")
DBI::dbExecute(conn, "PRAGMA temp_store = MEMORY;")
DBI::dbExecute(conn, "PRAGMA mmap_size = 8589934592;")

.log("running county manifest query...")
t_county <- system.time({
  county_manifest <- DBI::dbGetQuery(
    conn,
    "
    SELECT
      statefp AS state_fips,
      countyfp AS county_fips,
      statefp || countyfp AS geoid_county,
      COUNT(*) AS feature_count,
      SUM(CASE WHEN geom IS NULL THEN 1 ELSE 0 END) AS null_geom_count,
      MIN(lrid) AS min_lrid,
      MAX(lrid) AS max_lrid
    FROM lr_parcel_us
    GROUP BY statefp, countyfp
    ORDER BY statefp, countyfp
    "
  )
})

.log("county manifest query elapsed seconds: ", round(t_county["elapsed"], 1))
.log("county manifest rows: ", nrow(county_manifest))

.log("running state rollup query...")
t_state <- system.time({
  state_manifest <- DBI::dbGetQuery(
    conn,
    "
    WITH county_manifest AS (
      SELECT
        statefp AS state_fips,
        countyfp AS county_fips,
        COUNT(*) AS feature_count,
        SUM(CASE WHEN geom IS NULL THEN 1 ELSE 0 END) AS null_geom_count,
        MIN(lrid) AS min_lrid,
        MAX(lrid) AS max_lrid
      FROM lr_parcel_us
      GROUP BY statefp, countyfp
    ),
    state_rollup AS (
      SELECT
        state_fips,
        COUNT(*) AS county_count,
        SUM(feature_count) AS feature_count,
        SUM(null_geom_count) AS null_geom_count,
        MIN(min_lrid) AS min_lrid,
        MAX(max_lrid) AS max_lrid
      FROM county_manifest
      GROUP BY state_fips
    )
    SELECT
      state_fips,
      county_count,
      feature_count,
      null_geom_count,
      min_lrid,
      max_lrid,
      ROUND(feature_count * 100.0 / SUM(feature_count) OVER (), 3) AS pct_of_total,
      ROUND(SUM(feature_count) OVER (ORDER BY feature_count DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) * 100.0
        / SUM(feature_count) OVER (), 3) AS cumulative_pct,
      CASE WHEN feature_count > 4000000 THEN 1 ELSE 0 END AS large_state,
      ROUND(feature_count * 600.0 / 1048576.0) AS est_parquet_mb
    FROM state_rollup
    ORDER BY feature_count DESC
    "
  )
})

.log("state rollup query elapsed seconds: ", round(t_state["elapsed"], 1))
.log("state rollup rows: ", nrow(state_manifest))

.log("running sanity checks...")
total_from_manifest <- sum(county_manifest$feature_count)
total_from_gpkg <- DBI::dbGetQuery(conn, "SELECT feature_count FROM gpkg_ogr_contents WHERE table_name = 'lr_parcel_us'")[1, 1]
bad_geoid <- sum(county_manifest$geoid_county != paste0(county_manifest$state_fips, county_manifest$county_fips))
bad_state_len <- sum(nchar(county_manifest$state_fips) != 2)
bad_county_len <- sum(nchar(county_manifest$county_fips) != 3)

.log("total features from manifest: ", total_from_manifest)
.log("total features from gpkg_ogr_contents: ", total_from_gpkg)
.log("bad geoid rows: ", bad_geoid)
.log("bad state fips length rows: ", bad_state_len)
.log("bad county fips length rows: ", bad_county_len)

stopifnot(
  total_from_manifest == total_from_gpkg,
  bad_geoid == 0,
  bad_state_len == 0,
  bad_county_len == 0
)

.log("writing output csv files...")
utils::write.csv(county_manifest, county_manifest_path, row.names = FALSE)
utils::write.csv(state_manifest, state_manifest_path, row.names = FALSE)

.log_df("top 10 states by feature count:", utils::head(state_manifest, 10))

.log("disconnecting...")
DBI::dbDisconnect(conn)

.log("=== done ===")
.log("log file: ", log_path)
