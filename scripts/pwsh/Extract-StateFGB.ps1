#Requires -Version 7.0
<#
.SYNOPSIS
  Extracts per-state FlatGeoBuf files from the parcel GPKG.

.DESCRIPTION
  For each specified state FIPS code:
    - Looks up bounding box from state_bboxes.csv
    - Runs pixi run ogr2ogr with FlatGeoBuf output, Hilbert spatial index,
      47-column cleaned schema, bbox pre-filter, and embedded provenance metadata
    - Skips states where the FGB already exists (unless -Force)
    - Logs extraction progress and timing to logs/fgb_extraction_<statefp>.log

  GDAL environment variables (OGR_SQLITE_PRAGMA, OGR_GPKG_NUM_THREADS,
  GDAL_CACHEMAX) are set per-run and restored afterward.

  The source GPKG must have the B-tree index on (statefp, countyfp, geoid)
  already created (parcels_index_creation.R, done 2026-04-09).

.PARAMETER StateFips
  One or more 2-digit state FIPS codes to extract (e.g. "11" "44").

.PARAMETER Force
  Re-extract even if parcels.fgb already exists in the output directory.

.PARAMETER GpkgPath
  Path to source GPKG. Default: C:\GEODATA\LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg

.PARAMETER OutRoot
  Root output directory for FGBs. Default: C:\GEODATA\output\flatgeobuf

.PARAMETER BboxPath
  Path to state_bboxes.csv. Default: data/meta/state_bboxes.csv relative to repo.

.PARAMETER LogRoot
  Directory for per-state extraction logs. Default: logs/ relative to repo.

.EXAMPLE
  .\Extract-StateFGB.ps1 -StateFips "11"
  .\Extract-StateFGB.ps1 -StateFips "11","44"
  .\Extract-StateFGB.ps1 -StateFips "11" -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string[]] $StateFips,

    [switch] $Force,

    [string] $GpkgPath = 'C:\GEODATA\LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg',
    [string] $OutRoot  = 'C:\GEODATA\output\flatgeobuf',
    [string] $BboxPath = (Join-Path $PSScriptRoot '..\..\data\meta\state_bboxes.csv'),
    [string] $LogRoot  = (Join-Path $PSScriptRoot '..\..\logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- constants ---------------------------------------------------------------

$SOURCE_GPKG    = Split-Path $GpkgPath -Leaf
$GPKG_LAYER     = 'lr_parcel_us'
$SCHEMA_VERSION = '2026.1'
$DROPPED_COLS   = @('parcelstate', 'lrversion', 'halfbaths', 'fullbaths')

# 47-column select -- drops parcelstate, lrversion, halfbaths, fullbaths from
# the original 51-column schema; lrid excluded (not in FGB targets per convention)
$SELECT_COLS = 'parcelid, parcelid2, geoid, statefp, countyfp, taxacctnum, taxyear, usecode, usedesc, zoningcode, zoningdesc, numbldgs, numunits, yearbuilt, numfloors, bldgsqft, bedrooms, imprvalue, landvalue, agvalue, totalvalue, assdacres, saleamt, saledate, ownername, owneraddr, ownercity, ownerstate, ownerzip, parceladdr, parcelcity, parcelzip, legaldesc, township, section, qtrsection, range, plssdesc, book, page, block, lot, updated, centroidx, centroidy, surfpointx, surfpointy, geom'

# ---- helpers -----------------------------------------------------------------

function Get-GdalVersion {
    $raw = pixi run ogrinfo --version 2>&1 | Select-Object -First 1 | Out-String
    if ($raw -match 'GDAL\s+([\d.]+)') { return $Matches[1] }
    return 'unknown'
}

function Import-BboxTable {
    param([string] $Path)
    if (-not (Test-Path $Path)) { throw "State bboxes CSV not found: $Path" }
    $lookup = @{}
    foreach ($row in (Import-Csv $Path)) {
        $lookup[$row.statefp] = $row
    }
    return $lookup
}

function Write-Log {
    param([string] $LogFile, [string] $Message, [string] $Color = 'White')
    $ts  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $line = "[$ts] $Message"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# ---- core extraction ---------------------------------------------------------

function Invoke-FgbExtraction {
    param(
        [string] $Fips,
        [string] $StateName,
        [string] $MinX,
        [string] $MinY,
        [string] $MaxX,
        [string] $MaxY,
        [string] $GdalVersion
    )

    $outDir  = Join-Path $OutRoot "statefp=$Fips"
    $outFile = Join-Path $outDir 'parcels.fgb'
    $logFile = Join-Path $LogRoot "fgb_extraction_$Fips.log"

    Set-Content -Path $logFile -Value '' -Encoding UTF8

    Write-Host ""
    Write-Host "=== statefp=$Fips ($StateName) ===" -ForegroundColor Cyan

    if (Test-Path $outFile) {
        if (-not $Force) {
            Write-Log $logFile "SKIP: $outFile already exists ($('{0:N0}' -f (Get-Item $outFile).Length) bytes). Use -Force to re-extract." 'Yellow'
            return 'skip'
        }
        # FGB does not support DeleteLayer(); delete the file manually before re-extraction
        Remove-Item $outFile -Force
        Write-Log $logFile "removed existing FGB for re-extraction (-Force)"
    }

    New-Item -Path $outDir -ItemType Directory -Force | Out-Null

    $extractedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # TITLE and DESCRIPTION are FGB layer creation options (GDAL >= 3.9, -lco not -dsco).
    # No METADATA lco exists in the FGB driver; machine-readable provenance goes in the sidecar.
    $fgbTitle = "US Parcels - $StateName (statefp=$Fips)"
    $fgbDesc  = "State-level parcel extract from $SOURCE_GPKG. Schema: $SCHEMA_VERSION. Extracted: $extractedAt. Drops: parcelstate, lrversion, halfbaths, fullbaths. CRS: EPSG:4326. Spatial index: Hilbert."

    $sql = "SELECT $SELECT_COLS FROM $GPKG_LAYER WHERE statefp = '$Fips'"

    Write-Log $logFile "starting FGB extraction for statefp=$Fips ($StateName)"
    Write-Log $logFile "gpkg:   $GpkgPath"
    Write-Log $logFile "output: $outFile"
    Write-Log $logFile "bbox:   $MinX $MinY $MaxX $MaxY"

    # save and set GDAL env vars
    $prevPragma  = $env:OGR_SQLITE_PRAGMA
    $prevThreads = $env:OGR_GPKG_NUM_THREADS
    $prevCache   = $env:GDAL_CACHEMAX

    $env:OGR_SQLITE_PRAGMA    = 'cache_size=-4194304,temp_store=MEMORY,journal_mode=WAL'
    $env:OGR_GPKG_NUM_THREADS = 'ALL_CPUS'
    $env:GDAL_CACHEMAX        = '2048'

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $ogr2ogrArgs = @(
            'run', 'ogr2ogr',
            '-f', 'FlatGeoBuf',
            '-lco', 'SPATIAL_INDEX=YES',
            '-lco', "TITLE=$fgbTitle",
            '-lco', "DESCRIPTION=$fgbDesc",
            '-sql', $sql,
            '-spat', $MinX, $MinY, $MaxX, $MaxY,
            '-nln', 'parcels',
            $outFile,
            $GpkgPath
        )

        & pixi @ogr2ogrArgs 2>&1 | ForEach-Object {
            Add-Content -Path $logFile -Value $_ -Encoding UTF8
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Log $logFile "FAIL: ogr2ogr exited with code $LASTEXITCODE" 'Red'
            return 'fail'
        }
    } finally {
        $env:OGR_SQLITE_PRAGMA    = $prevPragma
        $env:OGR_GPKG_NUM_THREADS = $prevThreads
        $env:GDAL_CACHEMAX        = $prevCache
    }

    $sw.Stop()
    $elapsed = [math]::Round($sw.Elapsed.TotalSeconds)
    $sizeMb  = [math]::Round((Get-Item $outFile).Length / 1MB, 1)

    Write-Log $logFile "done in ${elapsed}s -- $sizeMb MB" 'Green'
    Write-Log $logFile "log: $logFile"

    # quick post-extraction schema check via ogrinfo
    $ogrCheck = pixi run ogrinfo -so $outFile parcels 2>&1 | Out-String
    $fcLine   = ($ogrCheck -split "`n" | Where-Object { $_ -match 'Feature Count:' } | Select-Object -First 1).Trim()
    Write-Log $logFile "ogrinfo: $fcLine"

    Write-Host ("  done: {0} MB in {1}s" -f $sizeMb, $elapsed) -ForegroundColor Green
    Write-Host "  log:  $logFile" -ForegroundColor DarkGray

    return 'done'
}

# ---- main --------------------------------------------------------------------

if (-not (Test-Path $GpkgPath)) {
    Write-Error "GPKG not found: $GpkgPath"
    exit 1
}
if (-not (Test-Path $BboxPath)) {
    Write-Error "Bboxes CSV not found: $BboxPath"
    exit 1
}

New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null

$gdalVersion = Get-GdalVersion
$bboxTable   = Import-BboxTable -Path $BboxPath

Write-Host ""
Write-Host "FGB Extraction" -ForegroundColor Cyan
Write-Host "  gpkg:   $GpkgPath"
Write-Host "  outdir: $OutRoot"
Write-Host "  gdal:   $gdalVersion"
Write-Host "  states: $($StateFips -join ', ')"
Write-Host "  force:  $Force"

$counts = @{ done = 0; skip = 0; fail = 0 }

foreach ($fips in $StateFips) {
    if (-not $bboxTable.ContainsKey($fips)) {
        Write-Host ""
        Write-Host "  ERROR: statefp=$fips not found in $BboxPath" -ForegroundColor Red
        $counts['fail']++
        continue
    }

    $row = $bboxTable[$fips]
    try {
        $result = Invoke-FgbExtraction `
            -Fips        $fips `
            -StateName   $row.name `
            -MinX        $row.min_x `
            -MinY        $row.min_y `
            -MaxX        $row.max_x `
            -MaxY        $row.max_y `
            -GdalVersion $gdalVersion
        $counts[$result]++
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
        $counts['fail']++
    }
}

Write-Host ""
Write-Host "=== summary ===" -ForegroundColor Cyan
Write-Host ("  done: {0}" -f $counts['done']) -ForegroundColor $(if ($counts['done'] -gt 0) { 'Green' } else { 'Gray' })
Write-Host ("  skip: {0}" -f $counts['skip']) -ForegroundColor DarkGray
Write-Host ("  fail: {0}" -f $counts['fail']) -ForegroundColor $(if ($counts['fail'] -gt 0) { 'Red' } else { 'Gray' })
Write-Host ""
Write-Host "  next: run Test-StateFGB.ps1 -StateFips $($StateFips -join ',') to validate"
