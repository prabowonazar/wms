<#
.SYNOPSIS
    Validator template import produk (Warehouse Mobile App v2).

.DESCRIPTION
    Memeriksa file CSV produk sebelum diimpor. Menghasilkan laporan CSV berisi
    satu baris per masalah (error/warning) dan exit code 1 jika ada error.

    Aturan lengkap: docs/product-import-spec.md

.PARAMETER Path
    File CSV yang akan divalidasi.

.PARAMETER OutputPath
    Lokasi laporan. Default: <nama-file>.errors.csv di folder yang sama.

.PARAMETER ExistingProductsCsv
    Opsional. CSV produk yang sudah ada dengan kolom:
    kode_produk,barcode_1,barcode_2,barcode_3
    Dipakai untuk mendeteksi barcode yang sudah dimiliki produk lain.

.PARAMETER Warehouses
    Daftar kode gudang yang valid. Default: JKT-01

.EXAMPLE
    .\validate-products.ps1 ..\templates\product-import-template.csv

.EXAMPLE
    .\validate-products.ps1 ..\templates\product-import-template.csv -Warehouses JKT-01,JKT-02
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [string]$OutputPath,

    [string]$ExistingProductsCsv,

    [string[]]$Warehouses = @('JKT-01')
)

$ErrorActionPreference = 'Stop'

# ----------------------------- Konfigurasi aturan ----------------------------

$ExpectedColumns = @(
    'kode_produk', 'nama_produk', 'tipe', 'uom',
    'barcode_1', 'barcode_2', 'barcode_3',
    'stok_minimum', 'status', 'kode_gudang', 'keterangan'
)
$AllowedTypes = @('consumable', 'spare_part', 'tool', 'packaging', 'other')
$AllowedUom = @('pcs', 'box', 'pack', 'roll', 'kg', 'g', 'liter', 'ml', 'meter', 'set', 'unit')
$AllowedStatus = @('aktif', 'nonaktif')
$CodePattern = '^[A-Z0-9][A-Z0-9._-]{2,31}$'
$BarcodePattern = '^[A-Z0-9._-]{4,48}$'
$MaxRows = 5000
$MaxBytes = 2MB
$MinNameLength = 3
$MaxNameLength = 200
$MaxNoteLength = 200
$MaxMinStock = 1000000

# ----------------------------- Persiapan -------------------------------------

if (-not (Test-Path -LiteralPath $Path)) {
    throw "File tidak ditemukan: $Path"
}

$file = Get-Item -LiteralPath $Path
if (-not $OutputPath) {
    $OutputPath = [IO.Path]::Combine(
        $file.DirectoryName,
        [IO.Path]::GetFileNameWithoutExtension($file.Name) + '.errors.csv'
    )
}

$issues = New-Object System.Collections.Generic.List[object]

function Add-Issue {
    param(
        [int]$Row,
        [string]$Code,
        [ValidateSet('error', 'warning')][string]$Level,
        [string]$Column,
        [string]$Value,
        [string]$Message
    )
    $issues.Add([pscustomobject]@{
            baris      = $Row
            kode_error = $Code
            tingkat    = $Level
            kolom      = $Column
            nilai      = $Value
            pesan      = $Message
        })
}

function Save-Report {
    param([string]$TargetPath, $Items)
    if ($Items.Count -gt 0) {
        $Items | Export-Csv -LiteralPath $TargetPath -NoTypeInformation -Encoding UTF8
    }
    else {
        Set-Content -LiteralPath $TargetPath -Encoding UTF8 `
            -Value 'baris,kode_error,tingkat,kolom,nilai,pesan'
    }
}

function Test-FormulaInjection {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    $first = [string]$Value[0]
    return @('=', '+', '-', '@') -contains $first
}

# ----------------------------- Header ----------------------------------------

if ($file.Length -gt $MaxBytes) {
    Add-Issue -Row 1 -Code 'E-FILE-SIZE' -Level 'error' -Column '-' -Value "$([math]::Round($file.Length / 1MB, 2)) MB" `
        -Message "Ukuran file melebihi 2 MB. Pecah menjadi beberapa file."
}

$firstLine = (Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8)
$fileEmpty = [string]::IsNullOrWhiteSpace($firstLine)

if ($fileEmpty) {
    Add-Issue -Row 1 -Code 'E-EMPTY' -Level 'error' -Column '-' -Value '' `
        -Message 'File kosong atau tidak memiliki header.'
    $actualColumns = @()
    $missing = @()
    $extra = @()
    $headerValid = $false
}
else {
    $firstLine = $firstLine.TrimStart([char]0xFEFF)
    $actualColumns = @($firstLine -split ',' | ForEach-Object { $_.Trim().Trim('"') })

    $missing = @($ExpectedColumns | Where-Object { $_ -notin $actualColumns })
    $extra = @($actualColumns | Where-Object { $_ -ne '' -and $_ -notin $ExpectedColumns })

    if ($missing.Count -gt 0) {
        Add-Issue -Row 1 -Code 'E-HEADER-MISSING' -Level 'error' -Column ($missing -join '|') -Value '' `
            -Message "Kolom wajib tidak ditemukan: $($missing -join ', ')."
    }
    if ($extra.Count -gt 0) {
        Add-Issue -Row 1 -Code 'E-HEADER-UNKNOWN' -Level 'error' -Column ($extra -join '|') -Value '' `
            -Message "Kolom tidak dikenal: $($extra -join ', '). Hapus atau ganti namanya."
    }

    $headerValid = ($missing.Count -eq 0 -and $extra.Count -eq 0)
}

# ----------------------------- Baca baris ------------------------------------

$rows = @()
if ($headerValid) {
    try {
        $rows = @(Import-Csv -LiteralPath $Path -Encoding UTF8)
    }
    catch {
        Add-Issue -Row 1 -Code 'E-PARSE' -Level 'error' -Column '-' -Value '' `
            -Message "File tidak dapat dibaca sebagai CSV: $($_.Exception.Message)"
        $headerValid = $false
    }
}

if ($headerValid -and $rows.Count -eq 0) {
    Add-Issue -Row 2 -Code 'E-EMPTY' -Level 'error' -Column '-' -Value '' `
        -Message 'File tidak berisi baris produk.'
}
if ($headerValid -and $rows.Count -gt $MaxRows) {
    Add-Issue -Row 1 -Code 'E-BATCH-SIZE' -Level 'error' -Column '-' -Value "$($rows.Count) baris" `
        -Message "Maksimum $MaxRows baris per file. Pecah file lalu impor bergiliran."
}

# ----------------------------- Produk existing -------------------------------

$existingCodes = @{}
$existingBarcodes = @{}
if ($ExistingProductsCsv -and (Test-Path -LiteralPath $ExistingProductsCsv)) {
    $existing = @(Import-Csv -LiteralPath $ExistingProductsCsv -Encoding UTF8)
    foreach ($e in $existing) {
        $ec = ([string]$e.kode_produk).Trim().ToUpperInvariant()
        if ($ec) { $existingCodes[$ec] = $true }
        foreach ($col in @('barcode_1', 'barcode_2', 'barcode_3')) {
            $eb = ([string]$e.$col).Trim().ToUpperInvariant()
            if ($eb) { $existingBarcodes[$eb] = $ec }
        }
    }
}

# ----------------------------- Validasi baris --------------------------------

$seenCodes = @{}
$seenBarcodes = @{}
$warehouseSet = @($Warehouses | ForEach-Object { $_.Trim().ToUpperInvariant() })

for ($i = 0; $i -lt $rows.Count; $i++) {
    $rowNo = $i + 2
    $r = $rows[$i]

    # Lewati baris yang benar-benar kosong (sama seperti validator Apps Script)
    $allBlank = $true
    foreach ($prop in $r.PSObject.Properties) {
        if (-not [string]::IsNullOrWhiteSpace([string]$prop.Value)) { $allBlank = $false; break }
    }
    if ($allBlank) { continue }

    $codeRaw = [string]$r.kode_produk
    $nameRaw = [string]$r.nama_produk
    $noteRaw = [string]$r.keterangan

    $code = $codeRaw.Trim().ToUpperInvariant()
    $name = $nameRaw.Trim()
    $type = ([string]$r.tipe).Trim().ToLowerInvariant()
    $uom = ([string]$r.uom).Trim().ToLowerInvariant()
    $status = ([string]$r.status).Trim().ToLowerInvariant()
    $wh = ([string]$r.kode_gudang).Trim().ToUpperInvariant()
    $note = $noteRaw.Trim()

    # Kode produk
    if ([string]::IsNullOrWhiteSpace($code)) {
        Add-Issue $rowNo 'E-CODE-REQUIRED' 'error' 'kode_produk' $codeRaw 'Kode produk wajib diisi.'
    }
    elseif ($code -notmatch $CodePattern) {
        Add-Issue $rowNo 'E-CODE-FORMAT' 'error' 'kode_produk' $codeRaw `
            'Kode harus 3-32 karakter: huruf/angka, titik, garis bawah, atau strip; diawali huruf/angka.'
    }
    else {
        if ($seenCodes.ContainsKey($code)) {
            Add-Issue $rowNo 'E-CODE-DUPLICATE' 'error' 'kode_produk' $code `
                "Kode sudah dipakai di baris $($seenCodes[$code])."
        }
        else {
            $seenCodes[$code] = $rowNo
        }
    }

    # Nama produk
    if ([string]::IsNullOrWhiteSpace($name)) {
        Add-Issue $rowNo 'E-NAME-REQUIRED' 'error' 'nama_produk' $nameRaw 'Nama produk wajib diisi.'
    }
    else {
        if ($name.Length -lt $MinNameLength) {
            Add-Issue $rowNo 'E-NAME-LENGTH' 'error' 'nama_produk' $nameRaw `
                "Nama minimal $MinNameLength karakter."
        }
        if ($name.Length -gt $MaxNameLength) {
            Add-Issue $rowNo 'E-NAME-LENGTH' 'error' 'nama_produk' "$($name.Length) karakter" `
                "Nama maksimum $MaxNameLength karakter."
        }
        if (Test-FormulaInjection $name) {
            Add-Issue $rowNo 'E-CSV-INJECTION' 'error' 'nama_produk' $nameRaw `
                'Nilai diawali =, +, -, atau @ (berisiko formula). Ganti dengan teks biasa.'
        }
    }

    # Tipe
    if ($type -notin $AllowedTypes) {
        Add-Issue $rowNo 'E-TYPE-INVALID' 'error' 'tipe' $type `
            "Tipe harus salah satu: $($AllowedTypes -join ', ')."
    }

    # UoM
    if ($uom -notin $AllowedUom) {
        Add-Issue $rowNo 'E-UOM-INVALID' 'error' 'uom' $uom `
            "Satuan harus salah satu: $($AllowedUom -join ', ')."
    }

    # Barcode
    $rowBarcodes = @()
    foreach ($col in @('barcode_1', 'barcode_2', 'barcode_3')) {
        $bcRaw = ([string]$r.$col).Trim()
        if ($bcRaw -eq '') { continue }
        $bc = $bcRaw.ToUpperInvariant()
        if ($bc -notmatch $BarcodePattern) {
            Add-Issue $rowNo 'E-BARCODE-FORMAT' 'error' $col $bcRaw `
                'Barcode harus 4-48 karakter: huruf/angka, titik, garis bawah, atau strip.'
            continue
        }
        $rowBarcodes += $bc
    }

    if ($rowBarcodes.Count -eq 0) {
        Add-Issue $rowNo 'E-BARCODE-REQUIRED' 'error' 'barcode_1' '' `
            'Minimal satu barcode wajib diisi (barcode_1).'
    }

    $uniqueRowBarcodes = @($rowBarcodes | Select-Object -Unique)
    if ($uniqueRowBarcodes.Count -lt $rowBarcodes.Count) {
        Add-Issue $rowNo 'W-BARCODE-SELF' 'warning' 'barcode_*' '' `
            'Barcode yang sama diulang dalam satu produk; hanya satu yang disimpan.'
    }

    foreach ($bc in $uniqueRowBarcodes) {
        if ($seenBarcodes.ContainsKey($bc)) {
            Add-Issue $rowNo 'E-BARCODE-DUPLICATE' 'error' 'barcode_*' $bc `
                "Barcode sudah dipakai di baris $($seenBarcodes[$bc])."
        }
        else {
            $seenBarcodes[$bc] = $rowNo
        }
        if ($existingBarcodes.ContainsKey($bc) -and $existingBarcodes[$bc] -ne $code) {
            Add-Issue $rowNo 'E-BARCODE-EXISTS' 'error' 'barcode_*' $bc `
                "Barcode sudah dimiliki produk $($existingBarcodes[$bc]) yang sudah ada."
        }
    }

    # Stok minimum
    $minRaw = ([string]$r.stok_minimum).Trim()
    if ($minRaw -ne '') {
        $parsed = 0
        if (-not [int]::TryParse($minRaw, [ref]$parsed)) {
            Add-Issue $rowNo 'E-MINSTOCK-NUMBER' 'error' 'stok_minimum' $minRaw `
                'Stok minimum harus bilangan bulat.'
        }
        elseif ($parsed -lt 0 -or $parsed -gt $MaxMinStock) {
            Add-Issue $rowNo 'E-MINSTOCK-RANGE' 'error' 'stok_minimum' $minRaw `
                "Stok minimum harus antara 0 dan $MaxMinStock."
        }
    }

    # Status
    if ($status -notin $AllowedStatus) {
        Add-Issue $rowNo 'E-STATUS-INVALID' 'error' 'status' $status `
            "Status harus 'aktif' atau 'nonaktif'."
    }

    # Gudang
    if ($wh -eq '' -or $wh -notin $warehouseSet) {
        Add-Issue $rowNo 'E-WAREHOUSE-INVALID' 'error' 'kode_gudang' $wh `
            "Kode gudang tidak dikenal. Pilihan: $($warehouseSet -join ', ')."
    }

    # Keterangan
    if ($note.Length -gt $MaxNoteLength) {
        Add-Issue $rowNo 'E-NOTE-LENGTH' 'error' 'keterangan' "$($note.Length) karakter" `
            "Keterangan maksimum $MaxNoteLength karakter."
    }
    if (Test-FormulaInjection $note) {
        Add-Issue $rowNo 'E-CSV-INJECTION' 'error' 'keterangan' $noteRaw `
            'Nilai diawali =, +, -, atau @ (berisiko formula).'
    }
}

# ----------------------------- Laporan & exit --------------------------------

Save-Report -TargetPath $OutputPath -Items $issues

$errorCount = @($issues | Where-Object { $_.tingkat -eq 'error' }).Count
$warningCount = @($issues | Where-Object { $_.tingkat -eq 'warning' }).Count

Write-Host ""
Write-Host "File       : $Path"
Write-Host "Baris data : $($rows.Count)"
Write-Host "Error      : $errorCount"
Write-Host "Warning    : $warningCount"
Write-Host "Laporan    : $OutputPath"

if ($errorCount -gt 0) {
    Write-Host ""
    Write-Host "HASIL: DITOLAK. Perbaiki semua error lalu jalankan ulang." -ForegroundColor Red
    exit 1
}

if ($warningCount -gt 0) {
    Write-Host ""
    Write-Host "HASIL: LULUS dengan peringatan." -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Host "HASIL: LULUS. File siap diimpor." -ForegroundColor Green
}
exit 0
