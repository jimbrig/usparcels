#Requires -Version 7.0
<#
.SYNOPSIS
  Validates FlatGeoBuf parcel extractions and generates sidecar .fgb.json metadata files.

.DESCRIPTION
  For each specified state FGB:
    - Verifies file integrity, schema, feature count, geometry type, and CRS
      via pixi run ogrinfo -json
    - Cross-references feature count against manifest_state_rollup.csv
    - Generates a sidecar parcels.fgb.json alongside the FGB on disk
    - Appends results to data/meta/fgb_validation_report.csv

  Use -Deep to enable DuckDB-based geometry validity and statefp cross-checks
  (full table scan per FGB -- expensive, off by default).

.PARAMETER StateFips
  One or more 2-digit state FIPS codes to validate (e.g. "13" "37").

.PARAMETER All
  Validate all FGBs found under FgbRoot.

.PARAMETER Deep
  Run DuckDB-based checks: invalid geometry count and wrong-statefp row count.
  Implies a full table scan per FGB.

.PARAMETER FgbRoot
  Root directory for FGB files. Default: C:\GEODATA\output\flatgeobuf

.PARAMETER ManifestPath
  Path to manifest_state_rollup.csv. Default: data/meta/manifest_state_rollup.csv
  relative to the repo root.

.PARAMETER BboxPath
  Path to state_bboxes.csv. Default: data/meta/state_bboxes.csv.

.PARAMETER ReportPath
  Path to fgb_validation_report.csv. Default: data/meta/fgb_validation_report.csv.

.EXAMPLE
  .\Test-StateFGB.ps1 -StateFips "13"
  .\Test-StateFGB.ps1 -StateFips "13","37","48"
  .\Test-StateFGB.ps1 -All
  .\Test-StateFGB.ps1 -All -Deep
#>

[CmdletBinding(DefaultParameterSetName = 'ByFips')]
param(
    [Parameter(ParameterSetName = 'ByFips', Mandatory, Position = 0)]
    [string[]] $StateFips,

    [Parameter(ParameterSetName = 'All', Mandatory)]
    [switch] $All,

    [switch] $Deep,

    [string] $FgbRoot = 'C:\GEODATA\output\flatgeobuf',

    [string] $ManifestPath = (Join-Path $PSScriptRoot '..\..\data\meta\manifest_state_rollup.csv'),
    [string] $BboxPath     = (Join-Path $PSScriptRoot '..\..\data\meta\state_bboxes.csv'),
    [string] $ReportPath   = (Join-Path $PSScriptRoot '..\..\data\meta\fgb_validation_report.csv'),

    # repo path for version-controlled sidecar copies and catalog.json
    [string] $RepoFgbRoot  = (Join-Path $PSScriptRoot '..\..\data\output\flatgeobuf')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- constants ---------------------------------------------------------------

$EXPECTED_COL_COUNT = 47
$DROPPED_COLS       = @('parcelstate', 'lrversion', 'halfbaths', 'fullbaths')
$EXPECTED_GEOM_TYPE = 'MultiPolygon'
$EXPECTED_CRS_CODE  = 4326
$SOURCE_GPKG        = 'LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg'
$SCHEMA_VERSION     = '2026.1'
$REPORT_HEADER      = 'statefp,state_name,status,fgb_features,manifest_features,feature_diff,fgb_size_mb,col_count,cols_ok,drops_ok,geom_type,crs,has_header_meta,notes'

# ---- helpers -----------------------------------------------------------------

function Get-GdalVersion {
    $raw = pixi run ogrinfo --version 2>&1 | Select-Object -First 1 | Out-String
    if ($raw -match 'GDAL\s+([\d.]+)') { return $Matches[1] }
    return 'unknown'
}

function Import-ManifestLookup {
    param([string] $Path)
    if (-not (Test-Path $Path)) { throw "Manifest not found: $Path" }
    $lookup = @{}
    foreach ($row in (Import-Csv $Path)) {
        $lookup[$row.state_fips] = [long]$row.feature_count
    }
    return $lookup
}

function Import-BboxLookup {
    param([string] $Path)
    if (-not (Test-Path $Path)) { throw "State bboxes CSV not found: $Path" }
    $lookup = @{}
    foreach ($row in (Import-Csv $Path)) {
        $lookup[$row.statefp] = $row.name
    }
    return $lookup
}

function Initialize-Report {
    param([string] $Path)
    # always write the correct header (overwrites old/empty report schemas)
    $existing = if (Test-Path $Path) { Get-Content $Path } else { @() }
    $hasData  = ($existing | Where-Object { $_ -match '^\s*"' } | Measure-Object).Count -gt 0
    if (-not $hasData) {
        Set-Content -Path $Path -Value $REPORT_HEADER -Encoding UTF8
    }
}

function Update-FgbCatalog {
    param([string] $FgbRoot, [string] $RepoFgbRoot)

    $sidecars = @(Get-ChildItem -Path $FgbRoot -Recurse -Filter 'parcels.fgb.json' |
        Sort-Object { [int](($_.Directory.Name -split '=')[1]) })

    if ($sidecars.Count -eq 0) { return }

    $items = foreach ($sc in $sidecars) {
        $d    = Get-Content $sc.FullName -Raw | ConvertFrom-Json
        $fips = $d.statefp
        [ordered]@{
            statefp             = $fips
            state_name          = $d.state_name
            status              = $d.status
            validated_at        = $d.validated_at
            feature_count       = $d.feature_count
            file_size_bytes     = $d.file_size_bytes
            bbox                = @($d.bbox[0], $d.bbox[1], $d.bbox[2], $d.bbox[3])
            has_header_metadata = $d.has_header_metadata
            tigris_href         = "https://noclocks-parcels.t3.storage.dev/flatgeobuf/statefp=$fips/parcels.fgb"
            sidecar_href        = "https://noclocks-parcels.t3.storage.dev/flatgeobuf/statefp=$fips/parcels.fgb.json"
            local_href          = "./statefp=$fips/parcels.fgb"
            sidecar_local       = "./statefp=$fips/parcels.fgb.json"
        }
    }

    # union bbox across all states -- access per-element directly to avoid
    # PowerShell's single-item array unrolling flattening the bbox arrays
    $itemList = @($items)
    $minX = ($itemList | ForEach-Object { [double]$_.bbox[0] } | Measure-Object -Minimum).Minimum
    $minY = ($itemList | ForEach-Object { [double]$_.bbox[1] } | Measure-Object -Minimum).Minimum
    $maxX = ($itemList | ForEach-Object { [double]$_.bbox[2] } | Measure-Object -Maximum).Maximum
    $maxY = ($itemList | ForEach-Object { [double]$_.bbox[3] } | Measure-Object -Maximum).Maximum
    $updatedAt = ($items | ForEach-Object { $_.validated_at } | Sort-Object -Descending | Select-Object -First 1)

    $catalog = [ordered]@{
        type            = 'Collection'
        id              = 'us-parcels-flatgeobuf'
        title           = 'US Parcels - FlatGeoBuf'
        description     = 'Per-state FlatGeoBuf extractions from LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg. 47-column cleaned schema (drops: parcelstate, lrversion, halfbaths, fullbaths). Hilbert-packed spatial index. EPSG:4326.'
        schema_version  = '2026.1'
        source          = 'LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg'
        crs             = 'EPSG:4326'
        geometry_column = 'geom'
        spatial_index   = 'hilbert'
        column_count    = 47
        dropped_columns = @('parcelstate', 'lrversion', 'halfbaths', 'fullbaths')
        tigris_bucket   = 'noclocks-parcels'
        tigris_prefix   = 'flatgeobuf/'
        links           = @([ordered]@{ rel = 'self'; href = './catalog.json'; type = 'application/json' })
        extent          = [ordered]@{
            spatial = [ordered]@{ bbox = @(@($minX, $minY, $maxX, $maxY)) }
        }
        updated_at      = $updatedAt
        item_count      = $sidecars.Count
        items           = @($items)
    }

    $json = $catalog | ConvertTo-Json -Depth 8

    # write to GEODATA path
    Set-Content -Path (Join-Path $FgbRoot 'catalog.json') -Value $json -Encoding UTF8

    # write to repo path for version control
    if ($RepoFgbRoot -and (Test-Path $RepoFgbRoot)) {
        Set-Content -Path (Join-Path $RepoFgbRoot 'catalog.json') -Value $json -Encoding UTF8
    }

    Write-Host ("  catalog: {0} states, extent [{1:F4},{2:F4},{3:F4},{4:F4}]" -f `
        $sidecars.Count, $minX, $minY, $maxX, $maxY) -ForegroundColor DarkGray
}

function Write-ReportRow {
    param([string] $Path, [hashtable] $Row)
    $line = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},"{13}"' -f `
        $Row.statefp,
        $Row.state_name,
        $Row.status,
        $Row.fgb_features,
        $Row.manifest_features,
        $Row.feature_diff,
        $Row.fgb_size_mb,
        $Row.col_count,
        $Row.cols_ok,
        $Row.drops_ok,
        $Row.geom_type,
        $Row.crs,
        $Row.has_header_meta,
        $Row.notes
    Add-Content -Path $Path -Value $line -Encoding UTF8
}

# ---- core validation ---------------------------------------------------------

function Test-StateFgb {
    param(
        [string] $Fips,
        [string] $StateName,
        [long]   $ManifestCount,
        [string] $GdalVersion,
        [bool]   $RunDeep
    )

    $fgbPath     = Join-Path $FgbRoot "statefp=$Fips\parcels.fgb"
    $sidecarPath = "$fgbPath.json"
    $notes       = [System.Collections.Generic.List[string]]::new()
    $status      = 'pass'

    Write-Host ""
    Write-Host "=== statefp=$Fips ($StateName) ===" -ForegroundColor Cyan

    # 1. file integrity ---------------------------------------------------------

    if (-not (Test-Path $fgbPath)) {
        Write-Host "  SKIP: file not found at $fgbPath" -ForegroundColor Yellow
        return $null
    }

    $fileInfo   = Get-Item $fgbPath
    $fileSizeB  = $fileInfo.Length
    $fileSizeMb = [math]::Round($fileSizeB / 1MB, 1)

    if ($fileSizeB -lt 1024) {
        Write-Host "  FAIL: file too small ($fileSizeMb MB)" -ForegroundColor Red
        return 'fail'
    }

    Write-Host "  file: $fgbPath ($fileSizeMb MB)"

    # 2. ogrinfo -json ----------------------------------------------------------

    $rawJson = pixi run ogrinfo -json $fgbPath parcels -limit 0 2>&1 | Out-String
    if (-not $rawJson -or $rawJson.Trim() -eq '') {
        Write-Host "  FAIL: ogrinfo returned no output" -ForegroundColor Red
        return 'fail'
    }

    # GDAL uses "" (empty string) as the default metadata domain key in JSON output.
    # PowerShell's ConvertFrom-Json cannot handle empty-string property names; rename it.
    $rawJson = $rawJson -replace '(?<="metadata"\s*:\s*\{)\s*""\s*:', '"_gdal_default":'

    $info  = $rawJson | ConvertFrom-Json
    $layer = $info.layers[0]

    # 3. feature count ----------------------------------------------------------

    $fgbFeatures = [long]$layer.featureCount
    $featureDiff = $fgbFeatures - $ManifestCount

    Write-Host ("  features: {0:N0} (manifest: {1:N0}, diff: {2:+#;-#;0})" -f `
        $fgbFeatures, $ManifestCount, $featureDiff)

    if ($featureDiff -lt -1000) {
        $status = 'warn'
        $notes.Add("large feature deficit ($featureDiff)")
    } elseif ($featureDiff -lt 0) {
        $notes.Add("$featureDiff excluded (empty geom via -spat filter)")
    }

    # 4. schema -----------------------------------------------------------------

    $fieldNames  = $layer.fields | ForEach-Object { $_.name }
    $colCount    = $fieldNames.Count
    $colsOk      = ($colCount -eq $EXPECTED_COL_COUNT)
    $presentDrops = @($DROPPED_COLS | Where-Object { $fieldNames -contains $_ })
    $dropsAbsent = ($presentDrops.Count -eq 0)

    if (-not $colsOk) {
        $status = 'fail'
        $notes.Add("col_count=$colCount expected=$EXPECTED_COL_COUNT")
    }
    if (-not $dropsAbsent) {
        $status = 'fail'
        $notes.Add("dropped cols still present: $($presentDrops -join ',')")
    }

    $schemaColor = if ($colsOk -and $dropsAbsent) { 'Green' } else { 'Red' }
    Write-Host ("  schema: {0}/{1} cols, drops absent: {2}" -f `
        $colCount, $EXPECTED_COL_COUNT, $(if ($dropsAbsent) { 'OK' } else { 'FAIL' })) `
        -ForegroundColor $schemaColor

    # 5. geometry type + CRS ----------------------------------------------------

    $geoField = $layer.geometryFields[0]
    $geomType = $geoField.type
    $crsCode  = [int]$geoField.coordinateSystem.projjson.id.code
    $crsStr   = "EPSG:$crsCode"
    $geomOk   = ($geomType -eq $EXPECTED_GEOM_TYPE)
    $crsOk    = ($crsCode -eq $EXPECTED_CRS_CODE)
    $extent   = $geoField.extent   # [xmin, ymin, xmax, ymax]

    if (-not $geomOk) { $status = 'fail'; $notes.Add("unexpected geom type: $geomType") }
    if (-not $crsOk)  { $status = 'fail'; $notes.Add("unexpected CRS: $crsStr") }

    Write-Host "  geometry: $geomType, $crsStr" `
        -ForegroundColor $(if ($geomOk -and $crsOk) { 'Green' } else { 'Red' })

    # 6. header metadata --------------------------------------------------------
    # FGB TITLE/DESCRIPTION are layer creation options (GDAL >= 3.9) and appear
    # in layer metadata; arbitrary dataset metadata appears at the top level.

    # layer metadata comes back under the renamed _gdal_default domain key;
    # use PSObject.Properties to safely check existence under strict mode
    $layerDefaultProp = $layer.metadata.PSObject.Properties['_gdal_default']
    $layerDefault     = if ($null -ne $layerDefaultProp) { $layerDefaultProp.Value } else { $null }
    $layerMetaCount   = if ($null -ne $layerDefault) { ($layerDefault.PSObject.Properties | Measure-Object).Count } else { 0 }
    $topMetaCount     = ($info.metadata.PSObject.Properties | Measure-Object).Count
    $hasHeaderMeta    = ($layerMetaCount -gt 0) -or ($topMetaCount -gt 0)

    Write-Host "  header metadata: $(if ($hasHeaderMeta) { 'present' } else { 'none (expected for pre-dsco FGBs)' })" `
        -ForegroundColor $(if ($hasHeaderMeta) { 'Green' } else { 'DarkGray' })

    # 7. deep DuckDB checks (optional) ------------------------------------------

    $invalidGeomCount  = -1
    $wrongStateFpCount = -1

    if ($RunDeep) {
        Write-Host "  running deep DuckDB checks (full scan)..." -ForegroundColor DarkGray
        # forward slashes required for DuckDB path handling on Windows
        $fgbFwd = $fgbPath -replace '\\', '/'

        $duckInvalid  = "LOAD spatial; SELECT COUNT(*) FROM ST_Read('$fgbFwd') WHERE NOT ST_IsValid(geom);"
        $duckWrongFp  = "LOAD spatial; SELECT COUNT(*) FROM ST_Read('$fgbFwd') WHERE statefp != '$Fips';"

        try {
            $invalidGeomCount  = [long]((pixi run duckdb -csv -noheader -c $duckInvalid  2>&1 | Select-Object -Last 1).Trim())
            $wrongStateFpCount = [long]((pixi run duckdb -csv -noheader -c $duckWrongFp  2>&1 | Select-Object -Last 1).Trim())
        } catch {
            $notes.Add("deep checks failed: $_")
        }

        if ($wrongStateFpCount -gt 0) {
            $status = 'fail'
            $notes.Add("$wrongStateFpCount rows have wrong statefp")
        }
        if ($invalidGeomCount -gt 1000) {
            if ($status -eq 'pass') { $status = 'warn' }
            $notes.Add("high invalid geom count ($invalidGeomCount)")
        }

        Write-Host ("  deep: invalid_geom={0}, wrong_statefp={1}" -f $invalidGeomCount, $wrongStateFpCount)
    }

    # 8. overall status ---------------------------------------------------------

    $notesStr    = $notes -join '; '
    $statusColor = switch ($status) {
        'pass' { 'Green'  }
        'warn' { 'Yellow' }
        'fail' { 'Red'    }
    }

    Write-Host "  status: $($status.ToUpper())" -ForegroundColor $statusColor
    if ($notesStr) { Write-Host "  notes:  $notesStr" -ForegroundColor Yellow }

    # 9. sidecar .fgb.json ------------------------------------------------------

    $validatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $sidecarObj = [ordered]@{
        statefp             = $Fips
        state_name          = $StateName
        format              = 'FlatGeoBuf'
        source              = $SOURCE_GPKG
        schema_version      = $SCHEMA_VERSION
        validated_at        = $validatedAt
        gdal_version        = $GdalVersion
        file_size_bytes     = $fileSizeB
        feature_count       = $fgbFeatures
        manifest_count      = $ManifestCount
        count_diff          = $featureDiff
        geometry_type       = $geomType
        geometry_column     = 'geom'
        crs                 = $crsStr
        bbox                = @($extent[0], $extent[1], $extent[2], $extent[3])
        spatial_index       = 'hilbert'
        column_count        = $colCount
        dropped_columns     = $DROPPED_COLS
        has_header_metadata = $hasHeaderMeta
        status              = $status
        notes               = $notesStr
    }

    if ($RunDeep) {
        $sidecarObj['invalid_geom_count']  = $invalidGeomCount
        $sidecarObj['wrong_statefp_count'] = $wrongStateFpCount
    }

    $sidecarJson = $sidecarObj | ConvertTo-Json -Depth 4
    Set-Content -Path $sidecarPath -Encoding UTF8 -Value $sidecarJson
    Write-Host "  sidecar: $sidecarPath" -ForegroundColor DarkGray

    # copy sidecar to repo for version control
    if ($RepoFgbRoot) {
        $repoStateDir    = Join-Path $RepoFgbRoot "statefp=$Fips"
        $repoSidecarPath = Join-Path $repoStateDir 'parcels.fgb.json'
        New-Item -Path $repoStateDir -ItemType Directory -Force | Out-Null
        Set-Content -Path $repoSidecarPath -Encoding UTF8 -Value $sidecarJson
        Write-Host "  repo:    $repoSidecarPath" -ForegroundColor DarkGray
    }

    # 10. report row ------------------------------------------------------------

    Write-ReportRow -Path $ReportPath -Row @{
        statefp           = $Fips
        state_name        = $StateName
        status            = $status
        fgb_features      = $fgbFeatures
        manifest_features = $ManifestCount
        feature_diff      = $featureDiff
        fgb_size_mb       = $fileSizeMb
        col_count         = $colCount
        cols_ok           = ($colsOk).ToString().ToLower()
        drops_ok          = ($dropsAbsent).ToString().ToLower()
        geom_type         = $geomType
        crs               = $crsStr
        has_header_meta   = ($hasHeaderMeta).ToString().ToLower()
        notes             = $notesStr
    }

    return $status
}

# ---- main --------------------------------------------------------------------

Write-Host ""
Write-Host "FGB Validation" -ForegroundColor Cyan
Write-Host "  root:   $FgbRoot"

$gdalVersion    = Get-GdalVersion
$manifestLookup = Import-ManifestLookup -Path $ManifestPath
$bboxLookup     = Import-BboxLookup    -Path $BboxPath

Write-Host "  gdal:   $gdalVersion"
Write-Host "  deep:   $Deep"
Write-Host "  report: $ReportPath"

Initialize-Report -Path $ReportPath

# resolve which states to process
if ($All) {
    $fipsList = Get-ChildItem -Path $FgbRoot -Directory |
        Where-Object { $_.Name -match '^statefp=\d+$' } |
        ForEach-Object { ($_.Name -split '=')[1] } |
        Sort-Object
} else {
    $fipsList = $StateFips
}

if ($fipsList.Count -eq 0) {
    Write-Host "No FGB directories found under $FgbRoot" -ForegroundColor Yellow
    exit 0
}

Write-Host "  states: $($fipsList.Count)"

$results = @{ pass = 0; warn = 0; fail = 0; skip = 0 }

foreach ($fips in $fipsList) {
    $stateName     = if ($bboxLookup.ContainsKey($fips)) { $bboxLookup[$fips] } else { "unknown ($fips)" }
    $manifestCount = if ($manifestLookup.ContainsKey($fips)) { $manifestLookup[$fips] } else { 0L }

    $fgbPath = Join-Path $FgbRoot "statefp=$fips\parcels.fgb"
    if (-not (Test-Path $fgbPath)) {
        Write-Host ""
        Write-Host "  SKIP statefp=$fips ($stateName): no FGB found" -ForegroundColor Yellow
        $results['skip']++
        continue
    }

    try {
        $result = Test-StateFgb `
            -Fips          $fips `
            -StateName     $stateName `
            -ManifestCount $manifestCount `
            -GdalVersion   $gdalVersion `
            -RunDeep       ([bool]$Deep)

        if ($null -eq $result) {
            $results['skip']++
        } elseif ($results.ContainsKey($result)) {
            $results[$result]++
        }
    } catch {
        Write-Host "  ERROR processing statefp=$fips : $_" -ForegroundColor Red
        $results['fail']++
    }
}

Write-Host ""
Write-Host "=== summary ===" -ForegroundColor Cyan
Write-Host ("  total:  {0}" -f ($fipsList.Count - $results['skip']))
Write-Host ("  pass:   {0}" -f $results['pass']) -ForegroundColor $(if ($results['pass'] -gt 0) { 'Green'  } else { 'Gray' })
Write-Host ("  warn:   {0}" -f $results['warn']) -ForegroundColor $(if ($results['warn'] -gt 0) { 'Yellow' } else { 'Gray' })
Write-Host ("  fail:   {0}" -f $results['fail']) -ForegroundColor $(if ($results['fail'] -gt 0) { 'Red'    } else { 'Gray' })
Write-Host ("  skip:   {0}" -f $results['skip']) -ForegroundColor DarkGray
Write-Host ""
Write-Host "  report:  $ReportPath"
Write-Host "  sidecars: $FgbRoot\statefp=*\parcels.fgb.json"

# regenerate catalog.json from all validated sidecars on disk
if (($results['pass'] + $results['warn'] + $results['fail']) -gt 0) {
    Write-Host ""
    Write-Host "regenerating catalog.json..." -ForegroundColor DarkGray
    Update-FgbCatalog -FgbRoot $FgbRoot -RepoFgbRoot $RepoFgbRoot
    Write-Host "  catalog: $FgbRoot\catalog.json" -ForegroundColor DarkGray
    if ($RepoFgbRoot -and (Test-Path $RepoFgbRoot)) {
        Write-Host "  catalog: $RepoFgbRoot\catalog.json" -ForegroundColor DarkGray
    }
}
