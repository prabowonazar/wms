<#
.SYNOPSIS
    Verifikasi statis VS-0: file wajib, JSON, skema, rules, tiket, kredensial.

.DESCRIPTION
    Script ini TIDAK menggantikan CI. Ia memeriksa hal yang bisa diperiksa
    tanpa Flutter/Dart/Node: kelengkapan file, JSON valid, jumlah objek SQL,
    pola rules penting, duplikat tiket, dan tidak adanya kredensial.

    Gunakan -RunTests untuk menjalankan flutter analyze/test dan node --test
    bila toolchain tersedia.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-vs0.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-vs0.ps1 -RunTests
#>
[CmdletBinding()]
param(
    [switch]$RunTests
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir

$failures = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Add-Warning {
    param([string]$Message)
    $warnings.Add($Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Get-RelativePath {
    param([string]$FullName)
    return $FullName.Substring($root.Length + 1)
}

Write-Host ''
Write-Host '== 1. File wajib VS-0 ==' -ForegroundColor Cyan

$requiredFiles = @(
    '.gitignore',
    'app/pubspec.yaml',
    'app/analysis_options.yaml',
    'app/sqlite_schema.sql',
    'app/lib/main.dart',
    'app/lib/app.dart',
    'app/lib/bootstrap/bootstrap.dart',
    'app/lib/bootstrap/app_services.dart',
    'app/lib/core/config/app_config.dart',
    'app/lib/core/sql/sql_script.dart',
    'app/lib/core/db/app_database.dart',
    'app/lib/core/db/schema_bootstrap.dart',
    'app/lib/core/security/db_key_store.dart',
    'app/lib/core/auth/auth_models.dart',
    'app/lib/core/auth/auth_repository.dart',
    'app/lib/core/auth/google_sign_in_adapter.dart',
    'app/lib/core/auth/role_policy.dart',
    'app/lib/core/storage/profile_cache.dart',
    'app/lib/core/observability/telemetry.dart',
    'app/lib/features/auth/login_screen.dart',
    'app/lib/features/auth/denied_screen.dart',
    'app/lib/features/home/home_screen.dart',
    'app/lib/features/splash/splash_screen.dart',
    'app/lib/features/bootstrap/config_missing_screen.dart',
    'app/lib/features/bootstrap/bootstrap_failure_screen.dart',
    'app/test/sql_script_test.dart',
    'app/test/schema_ffi_test.dart',
    'app/test/role_policy_test.dart',
    'app/test/profile_cache_test.dart',
    'app/test/user_profile_test.dart',
    'app/test/config_missing_screen_test.dart',
    'firebase/firebase.json',
    'firebase/firestore.rules',
    'firebase/firestore.indexes.json',
    'firebase/functions/package.json',
    'firebase/functions/index.js',
    'firebase/functions/lib/health.js',
    'firebase/functions/test/health.test.js',
    'firebase/test/package.json',
    'firebase/test/firestore.rules.test.js',
    '.github/workflows/ci.yml',
    'docs/runbook-vs0.md',
    'README.md',
    'tools/verify-schema-sqlite.ps1'
)

foreach ($relative in $requiredFiles) {
    $full = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $full)) {
        Add-Failure "File hilang: $relative"
        continue
    }
    $item = Get-Item -LiteralPath $full
    if ($item.Length -lt 32) {
        Add-Failure "File terlalu kecil (kemungkinan kosong): $relative"
    }
}

if ($failures.Count -eq 0) {
    Write-Host "OK: $($requiredFiles.Count) file wajib ada." -ForegroundColor Green
}

Write-Host ''
Write-Host '== 2. JSON valid ==' -ForegroundColor Cyan

$jsonFiles = @(
    'firebase/firebase.json',
    'firebase/firestore.indexes.json',
    'firebase/functions/package.json',
    'firebase/test/package.json',
    'apps-script/appsscript.json'
)

foreach ($relative in $jsonFiles) {
    $full = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $full)) {
        Add-Failure "JSON hilang: $relative"
        continue
    }
    try {
        $null = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Write-Host "OK: $relative"
    }
    catch {
        Add-Failure "JSON tidak valid: $relative -> $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host '== 3. Skema SQLite ==' -ForegroundColor Cyan

$schemaPath = Join-Path $root 'app/sqlite_schema.sql'
if (Test-Path -LiteralPath $schemaPath) {
    $schema = [IO.File]::ReadAllText($schemaPath, [Text.Encoding]::UTF8)

    $counts = [ordered]@{
        'CREATE TABLE'   = ([regex]::Matches($schema, '(?m)^CREATE TABLE')).Count
        'CREATE VIEW'    = ([regex]::Matches($schema, '(?m)^CREATE VIEW')).Count
        'CREATE TRIGGER' = ([regex]::Matches($schema, '(?m)^CREATE TRIGGER')).Count
        'CREATE INDEX'   = ([regex]::Matches($schema, '(?m)^CREATE INDEX')).Count
        'PRAGMA'         = ([regex]::Matches($schema, '(?m)^PRAGMA')).Count
    }

    foreach ($key in $counts.Keys) {
        Write-Host ("  {0,-15} {1}" -f $key, $counts[$key])
    }

    if ($counts['CREATE TABLE'] -ne 10) { Add-Failure 'Jumlah CREATE TABLE harus 10.' }
    if ($counts['CREATE VIEW'] -ne 3) { Add-Failure 'Jumlah CREATE VIEW harus 3.' }
    if ($counts['CREATE TRIGGER'] -ne 5) { Add-Failure 'Jumlah CREATE TRIGGER harus 5.' }
    if ($counts['PRAGMA'] -lt 1) { Add-Failure 'PRAGMA hilang; onConfigure membutuhkannya.' }

    if ($schema -match '(?im)^\s*DROP\s+TABLE') {
        Add-Failure 'Skema memuat DROP TABLE; migrasi harus tidak menghapus data.'
    }
    if ($schema -notmatch 'GENERATED ALWAYS AS') {
        Add-Failure 'Kolom generated (variance) tidak ditemukan.'
    }
    if ($schema -notmatch 'ON CONFLICT') {
        Add-Failure 'Seed idempoten (ON CONFLICT) tidak ditemukan.'
    }

    Write-Host 'OK: skema sesuai daftar objek VS-0.' -ForegroundColor Green
}

Write-Host ''
Write-Host '== 4. Firestore Rules ==' -ForegroundColor Cyan

$rulesPath = Join-Path $root 'firebase/firestore.rules'
if (Test-Path -LiteralPath $rulesPath) {
    $rules = [IO.File]::ReadAllText($rulesPath, [Text.Encoding]::UTF8)

    $requiredPatterns = @(
        @{ Name = 'transactions create-only'; Pattern = 'allow update, delete: if false;' },
        @{ Name = 'balances write false'; Pattern = 'match /balances/\{productId\}' },
        @{ Name = 'auditLogs write false'; Pattern = 'match /auditLogs/\{logId\}' },
        @{ Name = 'default deny'; Pattern = 'allow read, write: if false;' },
        @{ Name = 'profil sendiri bisa dibaca'; Pattern = 'request\.auth\.uid == uid \|\| isSupervisor\(\)' }
    )

    foreach ($entry in $requiredPatterns) {
        if ($rules -match $entry.Pattern) {
            Write-Host "OK: $($entry.Name)"
        }
        else {
            Add-Failure "Pola rules hilang: $($entry.Name)"
        }
    }

    if ($rules -match 'allow read, write: if true') {
        Add-Failure 'Ada aturan allow if true di rules.'
    }
}

Write-Host ''
Write-Host '== 5. Tiket vertical slice ==' -ForegroundColor Cyan

$backlogPath = Join-Path $root 'docs/vertical-slice-backlog.md'
if (Test-Path -LiteralPath $backlogPath) {
    $backlog = [IO.File]::ReadAllText($backlogPath, [Text.Encoding]::UTF8)
    $idMatches = [regex]::Matches($backlog, '(?m)^\|\s*(VS\d-\d{2})\s*\|')
    $ids = @($idMatches | ForEach-Object { $_.Groups[1].Value })
    $unique = @($ids | Select-Object -Unique)

    Write-Host "  Tiket: $($ids.Count) (unik: $($unique.Count))"
    if ($ids.Count -ne 47) { Add-Failure 'Jumlah tiket harus 47.' }
    if ($ids.Count -ne $unique.Count) { Add-Failure 'Ada ID tiket duplikat.' }

    foreach ($gate in @('G0', 'G1', 'G2', 'G3', 'G4', 'G5', 'G6')) {
        if ($backlog -notmatch "\| \*\*$gate") {
            Add-Warning "Gate $gate tidak ditemukan di tabel gate."
        }
    }
}

Write-Host ''
Write-Host '== 6. Kredensial & file terlarang ==' -ForegroundColor Cyan

$forbiddenNames = @(
    'google-services.json',
    'GoogleService-Info.plist',
    'service-account.json',
    'key.properties'
)

$allFiles = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.FullName -notmatch '\\node_modules\\|\\\.dart_tool\\|\\build\\' }

foreach ($file in $allFiles) {
    if ($forbiddenNames -contains $file.Name) {
        Add-Failure "File rahasia tidak boleh ada di repo: $(Get-RelativePath $file.FullName)"
    }
}

$secretPatterns = @(
    '-----BEGIN PRIVATE KEY-----',
    '-----BEGIN RSA PRIVATE KEY-----',
    '"private_key_id"'
)

$scannedExtensions = @('.json', '.js', '.dart', '.ps1', '.yaml', '.yml')
foreach ($file in $allFiles) {
    if ($scannedExtensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
    # Script ini memuat pola pencarian itu sendiri; jangan menuduh dirinya.
    if ($file.Name -eq 'verify-vs0.ps1') { continue }
    $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    foreach ($pattern in $secretPatterns) {
        if ($text.Contains($pattern)) {
            Add-Failure "Pola kredensial '$pattern' di $(Get-RelativePath $file.FullName)"
        }
    }
}

if (($failures | Where-Object { $_ -like '*kredensial*' -or $_ -like '*rahasia*' }).Count -eq 0) {
    Write-Host 'OK: tidak ada kredensial ter-commit.' -ForegroundColor Green
}

Write-Host ''
Write-Host '== 7. Skrip harus ASCII ==' -ForegroundColor Cyan

$scriptExtensions = @('.ps1', '.js', '.yml', '.yaml')
foreach ($file in $allFiles) {
    if ($scriptExtensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 })
    if ($nonAscii.Count -gt 0) {
        Add-Failure "Non-ASCII ($($nonAscii.Count) byte) di $(Get-RelativePath $file.FullName)"
    }
}
if (($failures | Where-Object { $_ -like '*Non-ASCII*' }).Count -eq 0) {
    Write-Host 'OK: skrip dan workflow murni ASCII.' -ForegroundColor Green
}

Write-Host ''
Write-Host '== 8. Ringkasan kode ==' -ForegroundColor Cyan

$dartFiles = @(Get-ChildItem -Path (Join-Path $root 'app/lib') -Recurse -File -Filter '*.dart')
$testFiles = @(Get-ChildItem -Path (Join-Path $root 'app/test') -Recurse -File -Filter '*.dart')
$testCases = 0
foreach ($file in $testFiles) {
    $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    $testCases += ([regex]::Matches($text, '\b(test|testWidgets)\(')).Count
}

Write-Host "  lib/*.dart   : $($dartFiles.Count) file"
Write-Host "  test/*.dart  : $($testFiles.Count) file, ~$testCases kasus"
Write-Host '  rules test   : lihat firebase/test/firestore.rules.test.js'

Write-Host ''
Write-Host '== 9. Toolchain ==' -ForegroundColor Cyan

$tools = [ordered]@{
    'git'      = $false
    'flutter'  = $false
    'dart'     = $false
    'java'     = $false
    'node'     = $false
    'firebase' = $false
}

foreach ($tool in @($tools.Keys)) {
    $command = Get-Command $tool -ErrorAction SilentlyContinue
    if ($command) {
        $tools[$tool] = $true
        Write-Host "  $tool => $($command.Source)"
    }
    else {
        Write-Host "  $tool => TIDAK ADA"
    }
}

if (-not $tools['flutter']) {
    Add-Warning 'Flutter tidak ada: kode Dart belum dikompilasi/diuji di mesin ini.'
}
if (-not $tools['node']) {
    Add-Warning 'Node tidak ada: Functions & rules test belum dijalankan lokal.'
}
if (-not $tools['java']) {
    Add-Warning 'Java tidak ada: Firestore emulator (rules test) butuh Java 17.'
}

Write-Host ''
Write-Host '== 10. Checklist bukti AC VS-0 ==' -ForegroundColor Cyan
Write-Host '  VS0-01  CI hijau (analyze, test, Functions, rules, APK) - .github/workflows/ci.yml'
Write-Host '  VS0-02  firebase emulators:start --only auth,firestore,functions'
Write-Host '  VS0-03  Login 3 role + akun nonaktif -> SCR-02 + sesi bertahan'
Write-Host '  VS0-04  firebase emulators:exec ... "node --test test/" (>= 12 kasus)'
Write-Host '  VS0-05  tools/verify-schema-sqlite.ps1 (skema di SQLite nyata) + flutter test test/schema_ffi_test.dart'
Write-Host '  VS0-06  Menu Pengaturan > Uji crash (debug) + event app_open/login_success'

Write-Host ''
Write-Host '== Hasil ==' -ForegroundColor Cyan

if ($RunTests) {
    if ($tools['flutter']) {
        Write-Host 'Menjalankan flutter analyze & test...' -ForegroundColor Cyan
        Push-Location (Join-Path $root 'app')
        try {
            & flutter pub get
            if ($LASTEXITCODE -ne 0) { Add-Failure 'flutter pub get gagal.' }
            & flutter analyze
            if ($LASTEXITCODE -ne 0) { Add-Failure 'flutter analyze gagal.' }
            & flutter test
            if ($LASTEXITCODE -ne 0) { Add-Failure 'flutter test gagal.' }
        }
        finally {
            Pop-Location
        }
    }
    else {
        Add-Warning 'Lewati flutter test: Flutter tidak terpasang.'
    }

    if ($tools['node']) {
        Write-Host 'Menjalankan Functions unit test...' -ForegroundColor Cyan
        Push-Location (Join-Path $root 'firebase/functions')
        try {
            & node --check index.js
            if ($LASTEXITCODE -ne 0) { Add-Failure 'node --check index.js gagal.' }
            & node --test test/
            if ($LASTEXITCODE -ne 0) { Add-Failure 'Functions unit test gagal.' }
        }
        finally {
            Pop-Location
        }
    }
    else {
        Add-Warning 'Lewati Functions test: Node tidak terpasang.'
    }

    if ($tools['firebase'] -and $tools['java']) {
        Write-Host 'Menjalankan rules test...' -ForegroundColor Cyan
        Push-Location (Join-Path $root 'firebase')
        try {
            & firebase emulators:exec --only firestore --project demo-warehouse "node --test test/"
            if ($LASTEXITCODE -ne 0) { Add-Failure 'Rules test gagal.' }
        }
        finally {
            Pop-Location
        }
    }
    else {
        Add-Warning 'Lewati rules test: butuh firebase CLI + Java 17 + dependensi npm.'
    }
}

Write-Host "  Failure: $($failures.Count)"
Write-Host "  Warning: $($warnings.Count)"

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'STATUS: GAGAL - perbaiki item [FAIL] di atas.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'STATUS: LOLOS verifikasi statis.' -ForegroundColor Green
Write-Host 'Ingat: verifikasi statis bukan bukti AC. Jalankan CI / -RunTests.' -ForegroundColor Yellow
exit 0
