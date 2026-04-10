#!/usr/bin/env bash
# ---- upload FGB files to Tigris blob storage --------------------------------
# uploads a single state FGB to the noclocks-parcels bucket using rclone
# via the Windows rclone.exe (pre-configured with tigris remote).
#
# usage:
#   ./scripts/tigris_upload_fgb.sh <state_fips>
#   ./scripts/tigris_upload_fgb.sh all          # upload all existing FGBs
#
# layout on tigris:
#   noclocks-parcels/flatgeobuf/statefp=13/parcels.fgb
#   noclocks-parcels/flatgeobuf/statefp=37/parcels.fgb
#
# requires: rclone.exe accessible from WSL with 'tigris' remote configured
# -------------------------------------------------------------------------

set -euo pipefail

BUCKET="noclocks-parcels"
FORMAT_PREFIX="flatgeobuf"
FGB_BASE="data/output/flatgeobuf"
LOG_DIR="/tmp"

upload_state() {
  local fips="$1"
  local src="${FGB_BASE}/state=${fips}/parcels.fgb"
  local dest="tigris:${BUCKET}/${FORMAT_PREFIX}/statefp=${fips}/"
  local log="${LOG_DIR}/upload_fgb_${fips}.log"

  if [ ! -f "$src" ]; then
    echo "[$(date +%Y-%m-%dT%H:%M:%S)] SKIP state=${fips}: no FGB file at ${src}"
    return 1
  fi

  local size
  size=$(ls -lh "$src" | awk '{print $5}')
  echo "[$(date +%Y-%m-%dT%H:%M:%S)] uploading state=${fips} (${size}) -> ${dest}" | tee "${log}"

  local win_src
  win_src=$(wslpath -w "$src")

  rclone.exe copy \
    "${win_src}" \
    "${dest}" \
    --progress \
    --s3-no-check-bucket \
    2>&1 | tee -a "${log}"

  echo "[$(date +%Y-%m-%dT%H:%M:%S)] done state=${fips}" | tee -a "${log}"
}

if [ "${1:-}" = "all" ]; then
  for dir in ${FGB_BASE}/state=*/; do
    fips=$(basename "$dir" | sed 's/state=//')
    upload_state "$fips" || true
  done
else
  STATE_FIPS="${1:?usage: $0 <state_fips|all>}"
  upload_state "$STATE_FIPS"
fi
