<#
.SYNOPSIS
    Menghasilkan CSV tiket dari docs/vertical-slice-backlog.md.

.DESCRIPTION
    Sumber kebenaran tiket adalah dokumen Markdown. Script ini membacanya dan
    menulis ulang CSV, sehingga CSV tidak pernah "basi" bila dijalankan ulang.

    Kolom: id, epic, ringkasan, jenis, ref, estimasi_hari, milestone,
           opsional, acceptance_criteria

.PARAMETER MarkdownPath
    Default: ..\docs\vertical-slice-backlog.md relatif terhadap script.

.PARAMETER OutputPath
    Default: ..\backlog\vertical-slice-tickets.csv relatif terhadap script.

.EXAMPLE
    .\export-tickets.ps1
#>
[CmdletBinding()]
param(
    [string]$MarkdownPath,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
if (-not $MarkdownPath) { $MarkdownPath = Join-Path $root 'docs\vertical-slice-backlog.md' }
if (-not $OutputPath) {
    $OutputPath = Join-Path $root 'backlog\vertical-slice-tickets.csv'
}

if (-not (Test-Path -LiteralPath $MarkdownPath)) {
    throw "Dokumen tidak ditemukan: $MarkdownPath"
}

$lines = Get-Content -LiteralPath $MarkdownPath -Encoding UTF8

# --------------------------- Peta slice -> nama & gate -----------------------

$epicNames = @{}
$epicGate = @{}
$currentSlice = $null

foreach ($line in $lines) {
    if ($line -match '^###\s+(VS-\d)\s+\u2014\s+(.+)$') {
        $currentSlice = $matches[1]
        $epicNames[$currentSlice] = $matches[2].Trim()
        $epicGate[$currentSlice] = 'G' + $matches[1].Substring(3, 1)
    }
}

# --------------------------- Parse baris tiket -------------------------------

$rows = New-Object System.Collections.Generic.List[object]

foreach ($line in $lines) {
    if ($line -notmatch '^\|\s*(VS\d-\d{2})\s*\|') { continue }

    $cells = $line -split '\|' | ForEach-Object { $_.Trim() }
    # cells[0] dan cells[-1] kosong karena baris diawali & diakhiri '|'
    if ($cells.Count -lt 7) { continue }

    $id = $cells[1]
    $ringkasan = $cells[2]
    $ref = $cells[3]
    $estimateRaw = $cells[4]
    $acceptance = $cells[5]

    $slice = 'VS-' + $id.Substring(2, 1)
    $optional = $false
    if ($estimateRaw -match '^\((.+)\)$') {
        $estimateRaw = $matches[1]
        $optional = $true
    }

    $jenis = 'Feature'
    if ($ref -match 'NFR') { $jenis = 'Enabler' }
    elseif ($ref -match '^M\d') { $jenis = 'Measurement' }

    $clean = {
        param([string]$s)
        $s = $s -replace '`', ''
        $s = $s -replace '\*', ''
        return $s.Trim()
    }

    $ringkasanClean = & $clean $ringkasan
    $refClean = & $clean $ref
    if ($refClean -eq '-' -or
        $refClean -eq [string][char]0x2014 -or
        $refClean -eq [string][char]0x2013) {
        $refClean = ''
    }

    $days = [double]$estimateRaw
    $hours = $days * 8
    $hoursText = if ($hours -eq [math]::Floor($hours)) { [string][int]$hours } else { [string]$hours }

    $rows.Add([pscustomobject]@{
            id                  = $id
            epic                = if ($epicNames.ContainsKey($slice)) { $epicNames[$slice] } else { $slice }
            judul               = "[$id] $ringkasanClean"
            jenis               = $jenis
            ref                 = $refClean
            estimasi_hari       = $estimateRaw
            estimasi_jam        = $hoursText
            milestone           = if ($epicGate.ContainsKey($slice)) { $epicGate[$slice] } else { '' }
            opsional            = if ($optional) { 'ya' } else { 'tidak' }
            acceptance_criteria = (& $clean $acceptance)
        })
}

if ($rows.Count -eq 0) {
    throw "Tidak ada tiket yang terbaca. Periksa format tabel di $MarkdownPath"
}

# --------------------------- Tulis CSV (UTF-8 tanpa BOM) ---------------------

function ConvertTo-CsvField {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if ($Value -match '[",\r\n]') {
        return '"' + ($Value -replace '"', '""') + '"'
    }
    return $Value
}

$columns = @('id', 'epic', 'judul', 'jenis', 'ref', 'estimasi_hari', 'estimasi_jam', 'milestone', 'opsional', 'acceptance_criteria')

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine(($columns -join ','))

foreach ($row in $rows) {
    $fields = foreach ($col in $columns) {
        ConvertTo-CsvField ([string]$row.$col)
    }
    [void]$sb.AppendLine(($fields -join ','))
}

$dir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

[IO.File]::WriteAllText($OutputPath, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))

# --------------------------- Ringkasan ---------------------------------------

$perSlice = $rows | Group-Object { $_.id.Substring(0, 3) } | Sort-Object Name
$totalEstimate = ($rows | ForEach-Object { [double]$_.estimasi_hari } | Measure-Object -Sum).Sum

Write-Host ''
Write-Host "Sumber    : $MarkdownPath"
Write-Host "Output    : $OutputPath"
Write-Host "Tiket     : $($rows.Count)"
Write-Host "Hari-dev  : $totalEstimate"
foreach ($g in $perSlice) {
    $sum = ($g.Group | ForEach-Object { [double]$_.estimasi_hari } | Measure-Object -Sum).Sum
    Write-Host ("  {0} : {1,2} tiket, {2} hari-dev" -f $g.Name, $g.Count, $sum)
}
Write-Host ''
