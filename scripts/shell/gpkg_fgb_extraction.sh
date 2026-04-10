#!/usr/bin/env bash
# ---- gpkg to flatgeobuf extraction -----------------------------------------
# extracts a single state from the monolithic GPKG into a FlatGeoBuf file
# with Hilbert-packed spatial index and cleaned schema (drops: parcelstate,
# lrversion, halfbaths, fullbaths).
#
# uses state bboxes from data/meta/state_bboxes.csv (generated via TIGER/Census)
# as a spatial pre-filter to leverage the R-tree and exclude empty geometries.
#
# embeds provenance metadata into the FGB header via -dsco TITLE/DESCRIPTION/METADATA.
#
# usage:
#   ./scripts/gpkg_fgb_extraction.sh <state_fips>
#   ./scripts/gpkg_fgb_extraction.sh all          # extract all states
#
# requires: pixi environment with gdal >= 3.12.3
# gpkg path: /mnt/c/GEODATA/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg (NVMe)
# output:    /mnt/c/GEODATA/output/flatgeobuf/statefp=<fips>/parcels.fgb
# -------------------------------------------------------------------------

set -euo pipefail

GPKG_PATH="/mnt/c/GEODATA/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"
GPKG_NAME="LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"
BBOX_CSV="data/meta/state_bboxes.csv"
OUT_BASE="/mnt/c/GEODATA/output/flatgeobuf"
LOG_DIR="/tmp"

GDAL_VERSION=$(pixi run ogrinfo --version 2>/dev/null | head -1 | awk '{print $2}')
SCHEMA_VERSION="2026.1"
DROPPED_COLS='["parcelstate","lrversion","halfbaths","fullbaths"]'

export OGR_SQLITE_PRAGMA="cache_size=-4194304,temp_store=MEMORY,journal_mode=WAL"
export OGR_GPKG_NUM_THREADS="ALL_CPUS"
export GDAL_CACHEMAX="2048"

extract_state() {
  local fips="$1"
  local out_dir="${OUT_BASE}/statefp=${fips}"
  local out_file="${out_dir}/parcels.fgb"
  local log_file="${LOG_DIR}/fgb_statefp=${fips}.log"

  if [ -f "${out_file}" ] && [ -s "${out_file}" ]; then
    echo "[$(date +%Y-%m-%dT%H:%M:%S)] SKIP statefp=${fips}: FGB already exists ($(ls -lh "${out_file}" | awk '{print $5}'))"
    return 0
  fi

  local bbox_line
  bbox_line=$(grep "^\"${fips}\"," "${BBOX_CSV}" 2>/dev/null || true)
  if [ -z "${bbox_line}" ]; then
    echo "[$(date +%Y-%m-%dT%H:%M:%S)] ERROR statefp=${fips}: no bbox found in ${BBOX_CSV}"
    return 1
  fi

  local min_x min_y max_x max_y name
  min_x=$(echo "${bbox_line}" | cut -d',' -f3)
  min_y=$(echo "${bbox_line}" | cut -d',' -f4)
  max_x=$(echo "${bbox_line}" | cut -d',' -f5)
  max_y=$(echo "${bbox_line}" | cut -d',' -f6)
  name=$(echo "${bbox_line}" | cut -d',' -f2 | tr -d '"')

  local extract_ts
  extract_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local fgb_title="US Parcels - ${name} (statefp=${fips})"
  local fgb_desc="State-level parcel extract from ${GPKG_NAME}. Schema: ${SCHEMA_VERSION}. Drops: parcelstate, lrversion, halfbaths, fullbaths."
  local fgb_meta="{\"statefp\":\"${fips}\",\"state_name\":\"${name}\",\"source\":\"${GPKG_NAME}\",\"schema_version\":\"${SCHEMA_VERSION}\",\"extracted_at\":\"${extract_ts}\",\"gdal_version\":\"${GDAL_VERSION}\",\"drops\":${DROPPED_COLS},\"geometry_column\":\"geom\",\"crs\":\"EPSG:4326\",\"spatial_index\":\"hilbert\"}"

  mkdir -p "${out_dir}"

  echo "[$(date +%Y-%m-%dT%H:%M:%S)] extracting statefp=${fips} (${name})" | tee "${log_file}"
  echo "[$(date +%Y-%m-%dT%H:%M:%S)] bbox: ${min_x} ${min_y} ${max_x} ${max_y}" | tee -a "${log_file}"

  local start_time
  start_time=$(date +%s)

  pixi run ogr2ogr \
    -f FlatGeoBuf \
    -lco SPATIAL_INDEX=YES \
    -dsco TITLE="${fgb_title}" \
    -dsco DESCRIPTION="${fgb_desc}" \
    -dsco METADATA="${fgb_meta}" \
    -sql "SELECT
      parcelid, parcelid2, geoid, statefp, countyfp,
      taxacctnum, taxyear, usecode, usedesc, zoningcode, zoningdesc,
      numbldgs, numunits, yearbuilt, numfloors, bldgsqft,
      bedrooms,
      imprvalue, landvalue, agvalue, totalvalue, assdacres,
      saleamt, saledate,
      ownername, owneraddr, ownercity, ownerstate, ownerzip,
      parceladdr, parcelcity, parcelzip,
      legaldesc, township, section, qtrsection, range,
      plssdesc, book, page, block, lot, updated,
      centroidx, centroidy, surfpointx, surfpointy,
      geom
    FROM lr_parcel_us
    WHERE statefp = '${fips}'" \
    -spat ${min_x} ${min_y} ${max_x} ${max_y} \
    -nln parcels \
    -overwrite \
    "${out_file}" \
    "${GPKG_PATH}" \
    2>&1 | tee -a "${log_file}"

  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$(( end_time - start_time ))

  echo "[$(date +%Y-%m-%dT%H:%M:%S)] done statefp=${fips} (${name}) in ${elapsed}s" | tee -a "${log_file}"
  ls -lh "${out_file}" | tee -a "${log_file}"

  pixi run ogrinfo -so "${out_file}" parcels 2>&1 | head -8 | tee -a "${log_file}"
}

if [ "${1:-}" = "all" ]; then
  echo "[$(date +%Y-%m-%dT%H:%M:%S)] === batch FGB extraction ==="
  echo "[$(date +%Y-%m-%dT%H:%M:%S)] gpkg: ${GPKG_PATH}"
  echo "[$(date +%Y-%m-%dT%H:%M:%S)] output: ${OUT_BASE}"
  echo "[$(date +%Y-%m-%dT%H:%M:%S)] gdal: ${GDAL_VERSION}"
  echo ""
  tail -n +2 "${BBOX_CSV}" | cut -d',' -f1 | tr -d '"' | while read -r fips; do
    extract_state "${fips}" || echo "[$(date +%Y-%m-%dT%H:%M:%S)] FAILED statefp=${fips}"
    echo ""
  done
  echo "[$(date +%Y-%m-%dT%H:%M:%S)] === batch complete ==="
else
  extract_state "${1:?usage: $0 <state_fips|all>}"
fi
