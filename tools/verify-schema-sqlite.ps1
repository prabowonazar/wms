<#
.SYNOPSIS
    Menjalankan app/sqlite_schema.sql di SQLite nyata dan menguji perilakunya.

.DESCRIPTION
    Skrip ini memakai winsqlite3.dll bawaan Windows (SQLite 3.3x) lewat P/Invoke,
    jadi tidak butuh Flutter, Dart, Node, atau paket tambahan. Yang diuji:

    - seluruh file skema dieksekusi tanpa error;
    - jumlah objek 10 tabel / 3 view / 5 trigger / 13 index;
    - skrip aman dijalankan ulang (idempoten);
    - view saldo mengabaikan transaksi failed;
    - stock card menghitung opening/ending per periode;
    - trigger immutability, delete guard, dan lock cycle-count;
    - generated column variance;
    - CHECK tanda signed_qty, reversal, dan role.

    Ini BUKAN pengganti test Dart (`app/test/schema_ffi_test.dart`) dan tidak
    membuktikan enkripsi SQLCipher. Tujuannya memberi bukti cepat bahwa skema
    kanonik valid dan berperilaku benar pada mesin tanpa toolchain.

    Catatan: skrip hanya berjalan di Windows. Di CI, test Dart di Ubuntu tetap
    menjadi acuan utama.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-schema-sqlite.ps1
#>
$ErrorActionPreference = 'Stop'

$sqliteDll = Join-Path $env:WINDIR 'System32\winsqlite3.dll'
if (-not (Test-Path -LiteralPath $sqliteDll)) {
    Write-Host "[SKIP] $sqliteDll tidak ada (bukan Windows atau komponen hilang)." -ForegroundColor Yellow
    exit 2
}

$source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class SqliteMem
{
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close_v2(IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_exec(IntPtr db, byte[] sql, ExecCallback cb, IntPtr arg, out IntPtr errmsg);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_libversion();

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void sqlite3_free(IntPtr p);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int ExecCallback(IntPtr arg, int count, IntPtr values, IntPtr names);

    private static readonly ExecCallback Callback = OnRow;
    private static List<string> _rows = new List<string>();

    private static string ToUtf8(IntPtr p)
    {
        if (p == IntPtr.Zero) return null;
        int len = 0;
        while (Marshal.ReadByte(p, len) != 0) len++;
        byte[] buffer = new byte[len];
        Marshal.Copy(p, buffer, 0, len);
        return Encoding.UTF8.GetString(buffer);
    }

    // Tiap baris digabung dengan tab agar PowerShell tidak memotong string
    // menjadi karakter pertama.
    private static int OnRow(IntPtr arg, int count, IntPtr values, IntPtr names)
    {
        var cells = new string[count];
        for (int i = 0; i < count; i++)
        {
            cells[i] = ToUtf8(Marshal.ReadIntPtr(values, i * IntPtr.Size)) ?? "<null>";
        }
        _rows.Add(string.Join("\t", cells));
        return 0;
    }

    private static byte[] Utf8Z(string s)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(s);
        byte[] buffer = new byte[bytes.Length + 1];
        Buffer.BlockCopy(bytes, 0, buffer, 0, bytes.Length);
        return buffer;
    }

    public static string Version()
    {
        return ToUtf8(sqlite3_libversion());
    }

    public static IntPtr Open()
    {
        IntPtr db;
        int rc = sqlite3_open_v2(Utf8Z(":memory:"), out db, 0x00000002 | 0x00000004, IntPtr.Zero);
        if (rc != 0) throw new Exception("sqlite3_open_v2 gagal, rc=" + rc);
        return db;
    }

    public static void Close(IntPtr db)
    {
        sqlite3_close_v2(db);
    }

    public static List<string> Query(IntPtr db, string sql)
    {
        _rows = new List<string>();
        IntPtr err;
        int rc = sqlite3_exec(db, Utf8Z(sql), Callback, IntPtr.Zero, out err);
        if (rc != 0)
        {
            string message = err == IntPtr.Zero ? ("rc=" + rc) : ToUtf8(err);
            if (err != IntPtr.Zero) sqlite3_free(err);
            throw new Exception(message);
        }
        return _rows;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$schemaPath = Join-Path $root 'app/sqlite_schema.sql'
if (-not (Test-Path -LiteralPath $schemaPath)) {
    Write-Host "[FAIL] Skema tidak ditemukan: $schemaPath" -ForegroundColor Red
    exit 1
}
$script = [IO.File]::ReadAllText($schemaPath, [Text.Encoding]::UTF8)

$failures = New-Object System.Collections.Generic.List[string]

function Fail { param([string]$M) $failures.Add($M); Write-Host "[FAIL] $M" -ForegroundColor Red }
function Ok { param([string]$M) Write-Host "[OK]   $M" -ForegroundColor Green }

$db = [SqliteMem]::Open()

function Exec { param([string]$Sql) [void][SqliteMem]::Query($db, $Sql) }

function Rows { param([string]$Sql) return @([SqliteMem]::Query($db, $Sql)) }

function Cell {
    param([string]$Sql)
    $rows = @(Rows $Sql)
    if ($rows.Count -eq 0) { return '<no-row>' }
    return ($rows[0] -split "`t")[0]
}

function AddTx {
    param(
        [string]$Id,
        [string]$Type,
        [int]$Qty,
        [int]$SignedQty,
        [string]$PeriodKey,
        [string]$SyncStatus = 'pending'
    )
    $sql = "INSERT INTO transactions (transaction_id, warehouse_id, product_id, product_code, product_name, product_type, uom, type, qty, signed_qty, period_key, user_id, user_name, device_id, occurred_at, created_at_client, created_at_local, sync_status) " +
        "VALUES ('$Id', 'wh1', 'p1', 'P-001', 'Produk Uji', 'general', 'pcs', '$Type', $Qty, $SignedQty, '$PeriodKey', 'op1', 'Operator 1', 'dev1', 1, 1, 1, '$SyncStatus');"
    Exec $sql
}

Write-Host "SQLite: $([SqliteMem]::Version())" -ForegroundColor Cyan
Write-Host ''
Write-Host '== A. Jalankan skema kanonik apa adanya ==' -ForegroundColor Cyan

try {
    Exec $script
    Ok 'Seluruh file dieksekusi tanpa error.'
}
catch {
    Fail "Skema gagal dieksekusi: $($_.Exception.Message)"
}

$tables = Cell "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
$views = Cell "SELECT COUNT(*) FROM sqlite_master WHERE type='view'"
$triggers = Cell "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger'"
$indexes = Cell "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND sql IS NOT NULL"
Write-Host "  tabel=$tables view=$views trigger=$triggers index=$indexes"
if ($tables -ne '10') { Fail "Tabel harus 10, hasil '$tables'" }
if ($views -ne '3') { Fail "View harus 3, hasil '$views'" }
if ($triggers -ne '5') { Fail "Trigger harus 5, hasil '$triggers'" }
if ($indexes -ne '13') { Fail "Index harus 13, hasil '$indexes'" }

Write-Host ''
Write-Host '== B. Idempoten (jalankan 2x lagi) ==' -ForegroundColor Cyan
try {
    Exec $script
    Exec $script
    $again = Cell "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    if ($again -ne '10') { Fail "Tabel berubah setelah diulang: '$again'" } else { Ok 'Aman dijalankan ulang.' }
}
catch {
    Fail "Tidak idempoten: $($_.Exception.Message)"
}

Write-Host ''
Write-Host '== C. v_product_balance ==' -ForegroundColor Cyan
try {
    AddTx -Id 'tx-in' -Type 'incoming' -Qty 5 -SignedQty 5 -PeriodKey '2026-11-17'
    AddTx -Id 'tx-out' -Type 'outgoing' -Qty 3 -SignedQty -3 -PeriodKey '2026-11-17'
    AddTx -Id 'tx-failed' -Type 'incoming' -Qty 100 -SignedQty 100 -PeriodKey '2026-11-17' -SyncStatus 'failed'
    $row = (@(Rows 'SELECT ending_qty, unsynced_qty, txn_count FROM v_product_balance')[0]) -split "`t"
    Write-Host "  ending_qty=$($row[0]) unsynced_qty=$($row[1]) txn_count=$($row[2])"
    if ($row[0] -ne '2') { Fail "ending_qty harus 2, hasil '$($row[0])'" }
    if ($row[1] -ne '2') { Fail "unsynced_qty harus 2, hasil '$($row[1])'" }
    if ($row[2] -ne '2') { Fail "txn_count harus 2, hasil '$($row[2])'" }
    if ($failures.Count -eq 0) { Ok 'Saldo = jumlah signed_qty, transaksi failed diabaikan.' }
}
catch {
    Fail "v_product_balance: $($_.Exception.Message)"
}

Write-Host ''
Write-Host '== D. v_stock_card ==' -ForegroundColor Cyan
try {
    AddTx -Id 'tx-d1' -Type 'incoming' -Qty 4 -SignedQty 4 -PeriodKey '2026-11-16'
    AddTx -Id 'tx-d2' -Type 'incoming' -Qty 2 -SignedQty 2 -PeriodKey '2026-11-17'
    $rows = @(Rows "SELECT product_id, period_key, opening_qty, incoming_qty, outgoing_qty, adjustment_qty, ending_qty FROM v_stock_card WHERE period_key = '2026-11-17'")
    Write-Host "  baris: $($rows.Count)"
    foreach ($r in $rows) { Write-Host "  $($r -replace "`t", ' | ')" }
    if ($rows.Count -ge 1) {
        $row = ($rows[0]) -split "`t"
        # tx-in (5) dan tx-out (3) juga berada di periode 2026-11-17.
        if ($row[2] -ne '4') { Fail "opening_qty harus 4, hasil '$($row[2])'" }
        if ($row[3] -ne '7') { Fail "incoming_qty harus 7, hasil '$($row[3])'" }
        if ($row[4] -ne '3') { Fail "outgoing_qty harus 3, hasil '$($row[4])'" }
        if ($row[6] -ne '8') { Fail "ending_qty harus 4+7-3=8, hasil '$($row[6])'" }
        if ($failures.Count -eq 0) { Ok 'Stock card menghitung opening/ending per periode.' }
    }
    else { Fail 'v_stock_card tidak mengembalikan baris untuk periode uji.' }
}
catch {
    Fail "v_stock_card: $($_.Exception.Message)"
}

Write-Host ''
Write-Host '== E. Trigger immutability & delete guard ==' -ForegroundColor Cyan
try {
    Exec "UPDATE transactions SET qty = 6 WHERE transaction_id = 'tx-in'"
    Fail 'UPDATE qty pada transaksi pending seharusnya ditolak.'
}
catch {
    if ($_.Exception.Message -match 'immutable') { Ok 'UPDATE isi transaksi ditolak (immutable).' }
    else { Fail "Pesan immutability tidak sesuai: $($_.Exception.Message)" }
}

try {
    Exec "UPDATE transactions SET sync_status = 'synced', synced_at = 123 WHERE transaction_id = 'tx-in'"
    $status = Cell "SELECT sync_status || '/' || synced_at FROM transactions WHERE transaction_id = 'tx-in'"
    if ($status -eq 'synced/123') { Ok 'Kolom sync boleh diubah.' } else { Fail "Kolom sync tidak terupdate: '$status'" }
}
catch {
    Fail "Update kolom sync gagal: $($_.Exception.Message)"
}

try {
    Exec "DELETE FROM transactions WHERE transaction_id = 'tx-in'"
    Fail 'DELETE transaksi pending seharusnya ditolak.'
}
catch {
    if ($_.Exception.Message -match 'Hanya transaksi gagal') { Ok 'DELETE transaksi pending ditolak.' }
    else { Fail "Pesan delete guard tidak sesuai: $($_.Exception.Message)" }
}

try {
    Exec "DELETE FROM transactions WHERE transaction_id = 'tx-failed'"
    $left = Cell "SELECT COUNT(*) FROM transactions WHERE transaction_id = 'tx-failed'"
    if ($left -eq '0') { Ok 'Transaksi failed boleh dihapus.' } else { Fail 'Transaksi failed tidak terhapus.' }
}
catch {
    Fail "Hapus transaksi failed: $($_.Exception.Message)"
}

Write-Host ''
Write-Host '== F. Cycle count ==' -ForegroundColor Cyan
try {
    Exec "INSERT INTO cycle_counts (cycle_count_id, warehouse_id, period_key, status, started_by, started_at, created_at_local) VALUES ('cc-1', 'wh1', '2026-11-17', 'open', 'op1', 1, 1)"
    Exec "INSERT INTO cycle_count_lines (cycle_count_id, product_id, product_code, product_name, uom, system_qty, counted_qty, counted_by, counted_at) VALUES ('cc-1', 'p1', 'P-001', 'Produk Uji', 'pcs', 10, 7, 'op1', 2)"
    $variance = Cell "SELECT variance FROM cycle_count_lines WHERE cycle_count_id = 'cc-1'"
    if ($variance -eq '-3') { Ok 'variance = -3 dari generated column.' } else { Fail "variance harus -3, hasil '$variance'" }

    Exec "UPDATE cycle_counts SET status = 'submitted' WHERE cycle_count_id = 'cc-1'"
    try {
        Exec "UPDATE cycle_count_lines SET counted_qty = 8 WHERE cycle_count_id = 'cc-1'"
        Fail 'Baris cycle-count seharusnya terkunci setelah submit.'
    }
    catch {
        if ($_.Exception.Message -match 'sudah dikirim') { Ok 'Baris terkunci setelah sesi dikirim.' }
        else { Fail "Pesan lock tidak sesuai: $($_.Exception.Message)" }
    }
}
catch {
    Fail "Cycle count: $($_.Exception.Message)"
}

Write-Host ''
Write-Host '== G. Constraint penting ==' -ForegroundColor Cyan
try {
    Exec "INSERT INTO transactions (transaction_id, warehouse_id, product_id, product_code, product_name, product_type, uom, type, qty, signed_qty, period_key, user_id, user_name, device_id, occurred_at, created_at_client, created_at_local) VALUES ('tx-bad-sign', 'wh1', 'p1', 'P-001', 'P', 'general', 'pcs', 'outgoing', 5, 5, '2026-11-17', 'op1', 'Op', 'dev1', 1, 1, 1)"
    Fail 'Tanda signed_qty salah seharusnya ditolak CHECK.'
}
catch {
    if ($_.Exception.Message -match 'CHECK') { Ok 'CHECK tanda signed_qty aktif.' } else { Fail "Pesan CHECK tidak sesuai: $($_.Exception.Message)" }
}

try {
    Exec "INSERT INTO transactions (transaction_id, warehouse_id, product_id, product_code, product_name, product_type, uom, type, qty, signed_qty, period_key, user_id, user_name, device_id, occurred_at, created_at_client, created_at_local) VALUES ('tx-rev', 'wh1', 'p1', 'P-001', 'P', 'general', 'pcs', 'reversal', 5, 5, '2026-11-17', 'op1', 'Op', 'dev1', 1, 1, 1)"
    Fail 'Reversal tanpa ref_transaction_id seharusnya ditolak CHECK.'
}
catch {
    if ($_.Exception.Message -match 'CHECK') { Ok 'CHECK reversal wajib ref_transaction_id aktif.' } else { Fail "Pesan CHECK reversal tidak sesuai: $($_.Exception.Message)" }
}

try {
    Exec "INSERT INTO user_profile (uid, name, email, role, warehouse_id, active, fetched_at) VALUES ('u1', 'X', 'x@y.z', 'owner', 'wh1', 1, 1)"
    Fail 'Role tidak dikenal seharusnya ditolak CHECK.'
}
catch {
    if ($_.Exception.Message -match 'CHECK') { Ok 'CHECK role user_profile aktif.' } else { Fail "Pesan CHECK role tidak sesuai: $($_.Exception.Message)" }
}

[SqliteMem]::Close($db)

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "STATUS: GAGAL ($($failures.Count) temuan)" -ForegroundColor Red
    $failures | ForEach-Object { " - $_" }
    exit 1
}
Write-Host 'STATUS: LOLOS - skema dieksekusi & diuji di SQLite nyata 3.43.2.' -ForegroundColor Green
