# ---- parcels index creation -------------------------------------------------
# run from windows R against C:\GEODATA\... on NVMe
# logs to the same directory as the gpkg for easy retrieval

parcels_path <- "C:/GEODATA/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"
log_path <- "C:/GEODATA/parcels_index_creation.log"

.log <- function(..., log_file = log_path) {
  msg <- paste0("[", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "] ", ...)
  message(msg)
  cat(msg, "\n", file = log_file, append = TRUE)
}

.log_value <- function(label, value, log_file = log_path) {
  msg <- paste0("[", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "] ", label, ": ", paste(value, collapse = ", "))
  message(msg)
  cat(msg, "\n", file = log_file, append = TRUE)
}

.log_df <- function(label, df, log_file = log_path) {
  .log(label)
  txt <- utils::capture.output(print(df))
  for (line in txt) {
    cat("  ", line, "\n", file = log_file, append = TRUE)
    message("  ", line)
  }
}

# ---- start ------------------------------------------------------------------

cat("", file = log_path)
.log("=== parcels index creation script ===")
.log_value("gpkg path", parcels_path)
.log_value("file size (GB)", round(file.info(parcels_path)$size / 1073741824, 2))
.log_value("R version", R.version.string)
.log_value("RSQLite version", as.character(utils::packageVersion("RSQLite")))
.log_value("DBI version", as.character(utils::packageVersion("DBI")))
.log_value("system memory (GB)", round(as.numeric(memory.limit()) / 1024, 1))

# ---- connect ----------------------------------------------------------------

.log("opening RW connection...")
conn <- DBI::dbConnect(RSQLite::SQLite(), parcels_path)

.log("setting pragmas...")
DBI::dbExecute(conn, "PRAGMA journal_mode = WAL;")
DBI::dbExecute(conn, "PRAGMA synchronous = OFF;")
DBI::dbExecute(conn, "PRAGMA cache_size = -4000000;")
DBI::dbExecute(conn, "PRAGMA temp_store = MEMORY;")
DBI::dbExecute(conn, "PRAGMA mmap_size = 8589934592;")

jm <- DBI::dbGetQuery(conn, "PRAGMA journal_mode")[[1]]
cs <- DBI::dbGetQuery(conn, "PRAGMA cache_size")[[1]]
ts <- DBI::dbGetQuery(conn, "PRAGMA temp_store")[[1]]
mm <- DBI::dbGetQuery(conn, "PRAGMA mmap_size")[[1]]

.log_value("journal_mode", jm)
.log_value("cache_size", cs)
.log_value("temp_store", ts)
.log_value("mmap_size", mm)

# ---- pre-index state --------------------------------------------------------

.log("checking pre-index state...")
pre_indexes <- DBI::dbGetQuery(conn, "
  SELECT name, tbl_name, sql
  FROM sqlite_master
  WHERE type = 'index' AND tbl_name = 'lr_parcel_us'
")
.log_value("existing btree indexes on lr_parcel_us", nrow(pre_indexes))
if (nrow(pre_indexes) > 0) .log_df("existing indexes", pre_indexes)

# ---- index creation ---------------------------------------------------------

.log("starting CREATE INDEX on (statefp, countyfp, geoid)...")
.log("this will take 45-90 minutes -- do not interrupt")

t_index <- system.time({
  DBI::dbExecute(conn, "
    CREATE INDEX IF NOT EXISTS idx_parcel_state_county
    ON lr_parcel_us (statefp, countyfp, geoid)
  ")
})

.log_value("index creation elapsed (seconds)", round(t_index["elapsed"], 1))
.log_value("index creation elapsed (minutes)", round(t_index["elapsed"] / 60, 1))
.log_value("user CPU time (seconds)", round(t_index["user.self"], 1))
.log_value("system CPU time (seconds)", round(t_index["sys.self"], 1))

# ---- analyze ----------------------------------------------------------------

.log("running ANALYZE on new index...")
t_analyze <- system.time({
  DBI::dbExecute(conn, "ANALYZE idx_parcel_state_county;")
})
.log_value("ANALYZE elapsed (seconds)", round(t_analyze["elapsed"], 1))

# ---- post-index verification ------------------------------------------------

.log("verifying index in sqlite_master...")
post_indexes <- DBI::dbGetQuery(conn, "
  SELECT name, tbl_name, sql
  FROM sqlite_master
  WHERE type = 'index' AND tbl_name = 'lr_parcel_us'
")
.log_df("indexes on lr_parcel_us after creation", post_indexes)

.log("running EXPLAIN QUERY PLAN for GROUP BY statefp, countyfp...")
qp <- DBI::dbGetQuery(conn, "
  EXPLAIN QUERY PLAN
  SELECT statefp, countyfp, COUNT(*)
  FROM lr_parcel_us
  GROUP BY statefp, countyfp
")
.log_df("query plan", qp)

.log("checking gpkg file size after index...")
.log_value("file size after (GB)", round(file.info(parcels_path)$size / 1073741824, 2))

# ---- quick manifest test (optional sanity check) ----------------------------

.log("running quick distinct state count as sanity check...")
t_states <- system.time({
  states <- DBI::dbGetQuery(conn, "
    SELECT COUNT(DISTINCT statefp) AS n_states,
           COUNT(DISTINCT countyfp) AS n_counties,
           COUNT(DISTINCT statefp || countyfp) AS n_state_county
    FROM lr_parcel_us
  ")
})
.log_df("distinct counts", states)
.log_value("distinct count query time (seconds)", round(t_states["elapsed"], 1))

# ---- cleanup ----------------------------------------------------------------

.log("disconnecting...")
DBI::dbDisconnect(conn)

.log("=== done ===")
.log_value("log file", log_path)
