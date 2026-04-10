#!/usr/bin/env bash
# ---- validate flatgeobuf extraction outputs ---------------------------------
# checks each FGB for integrity, schema, feature count vs manifest,
# geometry validity, and generates a sidecar .fgb.json metadata file.
#
# usage:
#   ./scripts/validate_fgb.sh <state_fips>
#   ./scripts/validate_fgb.sh all
#
# requires: pixi environment with gdal >= 3.12.3 and duckdb-cli
# -------------------------------------------------------------------------

set -euo pipefail

FGB_BASE="/mnt/c/GEODATA/output/flatgeobuf"
FGB_BASE_LOCAL="data/output/flatgeobuf"
MANIFEST="data/meta/manifest_state_rollup.csv"
BBOX_CSV="data/meta/state_bboxes.csv"
REPORT_FILE="data/meta/fgb_validation_report.csv"

EXPECTED_COL_COUNT=47
DROPPED_COLS="parcelstate lrversion halfbaths fullbaths"
FGB_MAGIC="66:67:62:03:66:67:62:00"

find_fgb() {
  local fips="$1"
  for path in \
    "${FGB_BASE}/statefp=${fips}/parcels.fgb" \
    "${FGB_BASE_LOCAL}/statefp=${fips}/parcels.fgb" \
    "${FGB_BASE_LOCAL}/state=${fips}/parcels.fgb"; do
    if [ -f "$path" ]; then
      echo "$path"
      return 0
    fi
  done
  return 1
}

get_state_name() {
  local fips="$1"
  grep "^\"${fips}\"," "${BBOX_CSV}" 2>/dev/null | cut -d',' -f2 | tr -d '"'
}

init_report() {
  echo "statefp,state_name,status,fgb_features,manifest_features,feature_diff,fgb_size_mb,col_count,cols_ok,drops_ok,geom_type,crs,spatial_index,invalid_geom_count,wrong_statefp,notes" > "${REPORT_FILE}"
}

validate_state() {
  local fips="$1"
  local notes=""
  local status="pass"

  local state_name
  state_name=$(get_state_name "${fips}")

  local fgb_path
  fgb_path=$(find_fgb "${fips}" || true)
  if [ -z "${fgb_path}" ]; then
    echo "[$(date +%Y-%m-%dT%H:%M:%S)] SKIP statefp=${fips}: no FGB found"
    echo "\"${fips}\",\"${state_name}\",\"missing\",0,0,0,0,0,false,false,\"\",\"\",false,0,0,\"no FGB file\"" >> "${REPORT_FILE}"
    return 0
  fi

  echo "[$(date +%Y-%m-%dT%H:%M:%S)] validating statefp=${fips} (${state_name}): ${fgb_path}"

  # ---- level 1: file integrity ----
  local size_bytes size_mb
  size_bytes=$(stat -c%s "${fgb_path}" 2>/dev/null || echo 0)
  size_mb=$(echo "scale=1; ${size_bytes} / 1048576" | bc)

  if [ "${size_bytes}" -lt 1000 ]; then
    echo "  FAIL: file too small (${size_mb} MB)"
    echo "\"${fips}\",\"${state_name}\",\"fail\",0,0,0,${size_mb},0,false,false,\"\",\"\",false,0,0,\"file too small\"" >> "${REPORT_FILE}"
    return 1
  fi

  local magic
  magic=$(xxd -l 8 -p "${fgb_path}" 2>/dev/null | fold -w2 | paste -sd':')
  local magic_ok="true"
  if [ "${magic}" != "${FGB_MAGIC}" ]; then
    magic_ok="false"
    notes="${notes}bad magic bytes; "
    status="fail"
  fi

  # ---- level 2: ogrinfo schema ----
  local ogrinfo_out
  ogrinfo_out=$(pixi run ogrinfo -so "${fgb_path}" parcels 2>&1)

  local fgb_features
  fgb_features=$(echo "${ogrinfo_out}" | grep "Feature Count:" | awk '{print $3}')
  fgb_features="${fgb_features:-0}"

  local geom_type
  geom_type=$(echo "${ogrinfo_out}" | grep "^Geometry:" | sed 's/Geometry: //')

  local crs
  crs=$(echo "${ogrinfo_out}" | grep 'ID\["EPSG"' | head -1 | grep -oP '\d+' | tail -1)
  crs="${crs:-unknown}"

  local extent_line
  extent_line=$(echo "${ogrinfo_out}" | grep "^Extent:" | head -1)

  local has_spatial_index="false"
  if echo "${ogrinfo_out}" | grep -qi "hilbert\|spatial.*index"; then
    has_spatial_index="true"
  fi

  local col_lines col_count
  col_lines=$(echo "${ogrinfo_out}" | grep -E "^[a-z].*: (String|Integer|Integer64|Real|Date|DateTime)" || true)
  col_count=$(echo "${col_lines}" | grep -c . || echo 0)

  local cols_ok="true"
  if [ "${col_count}" -ne "${EXPECTED_COL_COUNT}" ]; then
    cols_ok="false"
    notes="${notes}col_count=${col_count} expected=${EXPECTED_COL_COUNT}; "
  fi

  local drops_ok="true"
  for col in ${DROPPED_COLS}; do
    if echo "${col_lines}" | grep -q "^${col}:"; then
      drops_ok="false"
      notes="${notes}dropped col ${col} still present; "
    fi
  done

  if [ "${cols_ok}" = "false" ] || [ "${drops_ok}" = "false" ]; then
    status="fail"
  fi

  # ---- level 3: manifest cross-reference ----
  local manifest_features
  manifest_features=$(grep "^\"${fips}\"," "${MANIFEST}" | cut -d',' -f3)
  manifest_features="${manifest_features:-0}"

  local feature_diff
  feature_diff=$(( fgb_features - manifest_features ))

  if [ "${feature_diff}" -lt -1000 ]; then
    status="warn"
    notes="${notes}large feature deficit (${feature_diff}); "
  elif [ "${feature_diff}" -lt 0 ]; then
    notes="${notes}${feature_diff} excluded (likely empty geom); "
  fi

  # ---- level 4: duckdb geometry + statefp checks ----
  local invalid_count=0
  local wrong_state=0

  if pixi run duckdb --version &>/dev/null; then
    invalid_count=$(pixi run duckdb -csv -noheader -c "
      INSTALL spatial; LOAD spatial;
      SELECT COUNT(*) FROM ST_Read('${fgb_path}') WHERE NOT ST_IsValid(geom);
    " 2>/dev/null || echo "-1")

    wrong_state=$(pixi run duckdb -csv -noheader -c "
      INSTALL spatial; LOAD spatial;
      SELECT COUNT(*) FROM ST_Read('${fgb_path}') WHERE statefp != '${fips}';
    " 2>/dev/null || echo "-1")
  fi

  if [ "${wrong_state}" -gt 0 ] 2>/dev/null; then
    notes="${notes}${wrong_state} rows wrong statefp; "
    status="fail"
  fi

  if [ "${invalid_count}" -gt 1000 ] 2>/dev/null; then
    notes="${notes}high invalid geom (${invalid_count}); "
    [ "${status}" = "pass" ] && status="warn"
  fi

  # ---- output ----
  echo "  magic: ${magic_ok}"
  echo "  features: ${fgb_features} (manifest: ${manifest_features}, diff: ${feature_diff})"
  echo "  columns: ${col_count}/${EXPECTED_COL_COUNT}, drops absent: ${drops_ok}"
  echo "  geom: ${geom_type}, CRS: EPSG:${crs}, index: ${has_spatial_index}"
  echo "  invalid geom: ${invalid_count}, wrong statefp: ${wrong_state}"
  echo "  size: ${size_mb} MB"
  echo "  status: ${status}"
  [ -n "${notes}" ] && echo "  notes: ${notes}"

  echo "\"${fips}\",\"${state_name}\",\"${status}\",${fgb_features},${manifest_features},${feature_diff},${size_mb},${col_count},${cols_ok},${drops_ok},\"${geom_type}\",\"EPSG:${crs}\",${has_spatial_index},${invalid_count},${wrong_state},\"${notes}\"" >> "${REPORT_FILE}"

  # ---- sidecar .fgb.json ----
  local sidecar="${fgb_path}.json"
  local bbox_xmin bbox_ymin bbox_xmax bbox_ymax
  if [ -n "${extent_line}" ]; then
    bbox_xmin=$(echo "${extent_line}" | grep -oP '[-0-9.]+' | sed -n '1p')
    bbox_ymin=$(echo "${extent_line}" | grep -oP '[-0-9.]+' | sed -n '2p')
    bbox_xmax=$(echo "${extent_line}" | grep -oP '[-0-9.]+' | sed -n '3p')
    bbox_ymax=$(echo "${extent_line}" | grep -oP '[-0-9.]+' | sed -n '4p')
  fi

  cat > "${sidecar}" <<ENDJSON
{
  "statefp": "${fips}",
  "state_name": "${state_name}",
  "source_gpkg": "LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg",
  "schema_version": "2026.1",
  "validated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "gdal_version": "$(pixi run ogrinfo --version 2>/dev/null | awk '{print $2}')",
  "file_size_bytes": ${size_bytes},
  "feature_count": ${fgb_features},
  "manifest_count": ${manifest_features},
  "count_match": $([ "${feature_diff}" -eq 0 ] && echo "true" || echo "false"),
  "count_diff": ${feature_diff},
  "geometry_type": "${geom_type}",
  "geometry_column": "geom",
  "crs": "EPSG:${crs}",
  "bbox": [${bbox_xmin:-0}, ${bbox_ymin:-0}, ${bbox_xmax:-0}, ${bbox_ymax:-0}],
  "hilbert_index": ${has_spatial_index},
  "column_count": ${col_count},
  "dropped_columns": ["parcelstate", "lrversion", "halfbaths", "fullbaths"],
  "schema_ok": $([ "${cols_ok}" = "true" ] && [ "${drops_ok}" = "true" ] && echo "true" || echo "false"),
  "invalid_geom_count": ${invalid_count},
  "wrong_statefp_count": ${wrong_state},
  "status": "${status}"
}
ENDJSON

  echo "  sidecar: ${sidecar}"
}

# ---- main -------------------------------------------------------------------

if [ "${1:-}" = "all" ]; then
  init_report
  echo "[$(date +%Y-%m-%dT%H:%M:%S)] === FGB validation batch ==="

  seen=""
  for dir in "${FGB_BASE}"/statefp=*/ "${FGB_BASE_LOCAL}"/statefp=*/ "${FGB_BASE_LOCAL}"/state=*/; do
    [ -d "$dir" ] || continue
    fips=$(basename "$dir" | sed 's/state\(fp\)\?=//')
    # deduplicate
    echo "${seen}" | grep -q ":${fips}:" && continue
    seen="${seen}:${fips}:"
    validate_state "${fips}" || true
    echo ""
  done

  echo "[$(date +%Y-%m-%dT%H:%M:%S)] === validation complete ==="
  echo "report: ${REPORT_FILE}"
  echo ""
  echo "summary:"
  echo "  total: $(tail -n +2 "${REPORT_FILE}" | wc -l)"
  echo "  pass:  $(grep -c ',"pass",' "${REPORT_FILE}" || echo 0)"
  echo "  warn:  $(grep -c ',"warn",' "${REPORT_FILE}" || echo 0)"
  echo "  fail:  $(grep -c ',"fail",' "${REPORT_FILE}" || echo 0)"
else
  init_report
  validate_state "${1:?usage: $0 <state_fips|all>}"
fi
