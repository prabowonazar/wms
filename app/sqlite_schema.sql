-- =============================================================================
-- SQLite Schema (device) — Warehouse Mobile App v2
-- Target: Android 8.0+ · Drift/Room · SQLCipher (AES-256)
--
-- Catatan keamanan:
--   Kunci SQLCipher HARUS di-set sebelum PRAGMA lain, diambil dari Android
--   Keystore, dan tidak pernah ditulis ke log:
--     PRAGMA key = '<key-from-keystore>';
--   File database tidak boleh berada di external storage.
--
-- Konvensi:
--   * ID = TEXT (UUIDv7 dari device untuk transaksi, agar terurut waktu).
--   * Waktu = INTEGER epoch milliseconds UTC.
--   * Kuantitas = INTEGER (BR-07, tanpa desimal).
--   * Semua nama tabel/kolom snake_case.
-- =============================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;          -- konkurensi baca/tulis saat sync
PRAGMA synchronous = NORMAL;        -- cukup aman dengan WAL
PRAGMA busy_timeout = 5000;

PRAGMA user_version = 1;

-- =============================================================================
-- 1. Metadata & identitas
-- =============================================================================

CREATE TABLE IF NOT EXISTS meta (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  INTEGER NOT NULL
);

-- Contoh isi: schema_version, device_id, last_master_sync_at,
--             last_tx_sync_at, app_version, active_warehouse_id.

CREATE TABLE IF NOT EXISTS user_profile (
    uid           TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    email         TEXT NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('operator','supervisor','admin')),
    warehouse_id  TEXT NOT NULL,
    active        INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
    fetched_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS warehouse (
    warehouse_id       TEXT PRIMARY KEY,
    code               TEXT NOT NULL,
    name               TEXT NOT NULL,
    timezone           TEXT NOT NULL DEFAULT 'Asia/Jakarta',
    current_period_key TEXT NOT NULL,
    fetched_at         INTEGER NOT NULL,
    CHECK (length(current_period_key) = 10)
);

-- =============================================================================
-- 2. Master produk (cache read-only dari Firestore)
-- =============================================================================

CREATE TABLE IF NOT EXISTS products (
    product_id   TEXT PRIMARY KEY,
    code         TEXT NOT NULL,
    name         TEXT NOT NULL,
    type         TEXT NOT NULL,
    uom          TEXT NOT NULL,
    min_stock    INTEGER NOT NULL DEFAULT 0,
    active       INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
    updated_at   INTEGER NOT NULL,   -- dari server, kunci delta sync
    synced_at    INTEGER NOT NULL,   -- kapan device menerima
    UNIQUE (code)
);

CREATE TABLE IF NOT EXISTS product_barcodes (
    barcode     TEXT PRIMARY KEY,    -- sudah dinormalisasi (trim/uppercase)
    product_id  TEXT NOT NULL,
    format      TEXT NOT NULL DEFAULT 'UNKNOWN'
                CHECK (format IN ('CODE128','EAN13','QR','MANUAL','UNKNOWN')),
    updated_at  INTEGER NOT NULL,
    FOREIGN KEY (product_id) REFERENCES products(product_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_products_code
    ON products(code);

CREATE INDEX IF NOT EXISTS idx_products_updated
    ON products(updated_at);

CREATE INDEX IF NOT EXISTS idx_barcodes_product
    ON product_barcodes(product_id);

-- =============================================================================
-- 3. Ledger transaksi lokal (outbox + sumber saldo offline)
-- =============================================================================

CREATE TABLE IF NOT EXISTS transactions (
    transaction_id     TEXT PRIMARY KEY,           -- UUIDv7, = document ID Firestore
    schema_version     INTEGER NOT NULL DEFAULT 1,

    warehouse_id       TEXT NOT NULL,
    product_id         TEXT NOT NULL,
    product_code       TEXT NOT NULL,              -- snapshot (BR-11)
    product_name       TEXT NOT NULL,
    product_type       TEXT NOT NULL,
    uom                TEXT NOT NULL,

    type               TEXT NOT NULL
                       CHECK (type IN ('incoming','outgoing','adjustment','reversal')),
    qty                INTEGER NOT NULL CHECK (qty <> 0),
    signed_qty         INTEGER NOT NULL CHECK (signed_qty <> 0),
    period_key         TEXT NOT NULL
                       CHECK (period_key GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),

    user_id            TEXT NOT NULL,
    user_name          TEXT NOT NULL,
    device_id          TEXT NOT NULL,

    occurred_at        INTEGER NOT NULL,           -- waktu perangkat
    created_at_client  INTEGER NOT NULL,
    created_at_local   INTEGER NOT NULL,           -- saat baris ditulis

    note               TEXT,
    ref_transaction_id TEXT,
    cycle_count_id     TEXT,
    approval_status    TEXT NOT NULL DEFAULT 'not_required'
                       CHECK (approval_status IN ('not_required','pending','approved','rejected')),
    -- Alasan override stok negatif (BR-03). Wajib bila approval_status =
    -- 'pending'/'approved'; ikut dikirim sebagai approval.reason di Firestore.
    approval_reason    TEXT,
    source             TEXT NOT NULL DEFAULT 'scan'
                       CHECK (source IN ('scan','manual','cycle_count','server')),

    -- State machine sync (lihat docs/firestore-schema.md §6)
    sync_status        TEXT NOT NULL DEFAULT 'pending'
                       CHECK (sync_status IN ('pending','syncing','synced','failed')),
    retry_count        INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    last_error         TEXT,
    next_retry_at      INTEGER,
    synced_at          INTEGER,

    -- Konsistensi tanda: mencegah bug agregasi saldo
    CHECK (
        (type = 'incoming'   AND qty > 0 AND signed_qty =  qty) OR
        (type = 'outgoing'   AND qty > 0 AND signed_qty = -qty) OR
        (type IN ('adjustment','reversal') AND signed_qty = qty)
    ),
    -- Reversal wajib punya referensi; adjustment dari cycle-count wajib punya sesi
    CHECK (type <> 'reversal'   OR ref_transaction_id IS NOT NULL),
    CHECK (type <> 'adjustment' OR cycle_count_id IS NOT NULL),

    FOREIGN KEY (cycle_count_id) REFERENCES cycle_counts(cycle_count_id) ON DELETE RESTRICT
);

-- Outbox: ambil batch pending paling lama lebih dulu
CREATE INDEX IF NOT EXISTS idx_tx_outbox
    ON transactions(sync_status, occurred_at)
    WHERE sync_status IN ('pending','syncing');

CREATE INDEX IF NOT EXISTS idx_tx_retry
    ON transactions(next_retry_at)
    WHERE sync_status = 'failed';

CREATE INDEX IF NOT EXISTS idx_tx_product_period
    ON transactions(product_id, period_key);

CREATE INDEX IF NOT EXISTS idx_tx_warehouse_period
    ON transactions(warehouse_id, period_key);

CREATE INDEX IF NOT EXISTS idx_tx_user
    ON transactions(user_id, occurred_at);

CREATE INDEX IF NOT EXISTS idx_tx_ref
    ON transactions(ref_transaction_id)
    WHERE ref_transaction_id IS NOT NULL;

-- =============================================================================
-- 4. Cycle count
-- =============================================================================

CREATE TABLE IF NOT EXISTS cycle_counts (
    cycle_count_id  TEXT PRIMARY KEY,              -- UUIDv7 dari device
    warehouse_id    TEXT NOT NULL,
    period_key      TEXT NOT NULL
                    CHECK (period_key GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
    status          TEXT NOT NULL DEFAULT 'open'
                    CHECK (status IN ('open','submitted','approved','rejected','cancelled')),
    started_by      TEXT NOT NULL,
    started_at      INTEGER NOT NULL,
    submitted_by    TEXT,
    submitted_at    INTEGER,
    reviewed_by     TEXT,
    reviewed_at     INTEGER,
    note            TEXT,
    sync_status     TEXT NOT NULL DEFAULT 'pending'
                    CHECK (sync_status IN ('pending','syncing','synced','failed')),
    last_error      TEXT,
    created_at_local INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_cc_warehouse_status
    ON cycle_counts(warehouse_id, status, started_at);

CREATE TABLE IF NOT EXISTS cycle_count_lines (
    cycle_count_id  TEXT NOT NULL,
    product_id      TEXT NOT NULL,
    product_code    TEXT NOT NULL,
    product_name    TEXT NOT NULL,
    uom             TEXT NOT NULL,
    system_qty      INTEGER NOT NULL CHECK (system_qty >= 0),
    counted_qty     INTEGER NOT NULL CHECK (counted_qty >= 0),
    variance        INTEGER GENERATED ALWAYS AS (counted_qty - system_qty) STORED,
    counted_by      TEXT NOT NULL,
    counted_at      INTEGER NOT NULL,
    note            TEXT,
    adjustment_txn_id TEXT,
    PRIMARY KEY (cycle_count_id, product_id),
    FOREIGN KEY (cycle_count_id) REFERENCES cycle_counts(cycle_count_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_cc_lines_variance
    ON cycle_count_lines(cycle_count_id, variance);

-- =============================================================================
-- 5. Diagnostik & cache konflik
-- =============================================================================

CREATE TABLE IF NOT EXISTS error_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    level       TEXT NOT NULL CHECK (level IN ('debug','info','warn','error')),
    code        TEXT,
    message     TEXT NOT NULL,
    context     TEXT,                              -- JSON, tanpa data sensitif
    created_at  INTEGER NOT NULL,
    sent        INTEGER NOT NULL DEFAULT 0 CHECK (sent IN (0,1))
);

CREATE INDEX IF NOT EXISTS idx_error_unsent
    ON error_log(sent, created_at);

CREATE TABLE IF NOT EXISTS stock_conflicts_cache (
    conflict_id       TEXT PRIMARY KEY,
    warehouse_id      TEXT NOT NULL,
    product_id        TEXT NOT NULL,
    device_ending_qty INTEGER NOT NULL,
    server_ending_qty INTEGER NOT NULL,
    delta             INTEGER NOT NULL,
    detected_at       INTEGER NOT NULL,
    status            TEXT NOT NULL DEFAULT 'open'
                      CHECK (status IN ('open','resolved','ignored')),
    resolution        TEXT
);

CREATE INDEX IF NOT EXISTS idx_conflicts_open
    ON stock_conflicts_cache(status, detected_at);

-- =============================================================================
-- 6. View: saldo & stock card (dihitung dari ledger)
-- =============================================================================

-- Saldo berjalan per produk. Transaksi 'failed' tidak pernah diterima server,
-- sehingga tidak dihitung. 'pending'/'syncing' tetap dihitung (optimistik),
-- sesuai PRD BR-01 dan D5.
CREATE VIEW IF NOT EXISTS v_product_balance AS
SELECT
    t.warehouse_id,
    t.product_id,
    SUM(t.signed_qty)                       AS ending_qty,
    SUM(CASE WHEN t.sync_status IN ('pending','syncing') THEN t.signed_qty ELSE 0 END)
                                            AS unsynced_qty,
    COUNT(*)                                AS txn_count,
    MAX(t.occurred_at)                      AS last_occurred_at
FROM transactions t
WHERE t.sync_status <> 'failed'
GROUP BY t.warehouse_id, t.product_id;

-- Stock card per produk per periode.
-- Catatan: kolom 'adjustment_qty' mencakup transaksi adjustment DAN reversal,
-- karena keduanya adalah koreksi (BR-01, BR-06). Opening dihitung dari seluruh
-- periode sebelumnya (period_key bersifat lexicographic YYYY-MM-DD).
CREATE VIEW IF NOT EXISTS v_stock_card AS
SELECT
    t.warehouse_id,
    t.product_id,
    t.period_key,
    (SELECT COALESCE(SUM(t0.signed_qty), 0)
       FROM transactions t0
      WHERE t0.warehouse_id = t.warehouse_id
        AND t0.product_id = t.product_id
        AND t0.sync_status <> 'failed'
        AND t0.period_key < t.period_key)                    AS opening_qty,
    SUM(CASE WHEN t.type = 'incoming' THEN t.qty ELSE 0 END) AS incoming_qty,
    SUM(CASE WHEN t.type = 'outgoing' THEN t.qty ELSE 0 END) AS outgoing_qty,
    SUM(CASE WHEN t.type IN ('adjustment','reversal')
             THEN t.signed_qty ELSE 0 END)                   AS adjustment_qty,
    (SELECT COALESCE(SUM(t0.signed_qty), 0)
       FROM transactions t0
      WHERE t0.warehouse_id = t.warehouse_id
        AND t0.product_id = t.product_id
        AND t0.sync_status <> 'failed'
        AND t0.period_key <= t.period_key)                   AS ending_qty
FROM transactions t
WHERE t.sync_status <> 'failed'
GROUP BY t.warehouse_id, t.product_id, t.period_key;

CREATE VIEW IF NOT EXISTS v_outbox_pending AS
SELECT
    sync_status,
    COUNT(*)      AS jumlah,
    MIN(occurred_at) AS tertua,
    MAX(occurred_at) AS terbaru
FROM transactions
WHERE sync_status IN ('pending','syncing','failed')
GROUP BY sync_status;

-- =============================================================================
-- 7. Trigger: integritas & immutability
-- =============================================================================

-- Transaksi lokal bersifat immutable. Hanya kolom sync yang boleh berubah.
DROP TRIGGER IF EXISTS trg_transactions_immutable;
CREATE TRIGGER trg_transactions_immutable
BEFORE UPDATE ON transactions
FOR EACH ROW
WHEN NEW.transaction_id     IS NOT OLD.transaction_id
  OR NEW.warehouse_id       IS NOT OLD.warehouse_id
  OR NEW.product_id         IS NOT OLD.product_id
  OR NEW.type               IS NOT OLD.type
  OR NEW.qty                IS NOT OLD.qty
  OR NEW.signed_qty         IS NOT OLD.signed_qty
  OR NEW.period_key         IS NOT OLD.period_key
  OR NEW.occurred_at        IS NOT OLD.occurred_at
  OR NEW.user_id            IS NOT OLD.user_id
  OR NEW.ref_transaction_id IS NOT OLD.ref_transaction_id
  OR NEW.cycle_count_id     IS NOT OLD.cycle_count_id
BEGIN
    SELECT RAISE(ABORT,
        'Transaksi immutable: koreksi gunakan reversal, bukan update.');
END;

-- Hanya transaksi 'failed' (belum pernah diterima server) yang boleh dibuang.
DROP TRIGGER IF EXISTS trg_transactions_no_delete;
CREATE TRIGGER trg_transactions_no_delete
BEFORE DELETE ON transactions
FOR EACH ROW
WHEN OLD.sync_status <> 'failed'
BEGIN
    SELECT RAISE(ABORT,
        'Hanya transaksi gagal yang boleh dihapus; data tersinkron tidak boleh dihapus.');
END;

-- Baris cycle-count terkunci setelah sesi dikirim.
DROP TRIGGER IF EXISTS trg_cc_lines_locked_update;
CREATE TRIGGER trg_cc_lines_locked_update
BEFORE UPDATE ON cycle_count_lines
FOR EACH ROW
BEGIN
    SELECT RAISE(ABORT, 'Sesi cycle-count sudah dikirim; baris tidak boleh diubah.')
    WHERE (SELECT status FROM cycle_counts WHERE cycle_count_id = OLD.cycle_count_id) <> 'open';
END;

DROP TRIGGER IF EXISTS trg_cc_lines_locked_delete;
CREATE TRIGGER trg_cc_lines_locked_delete
BEFORE DELETE ON cycle_count_lines
FOR EACH ROW
BEGIN
    SELECT RAISE(ABORT, 'Sesi cycle-count sudah dikirim; baris tidak boleh dihapus.')
    WHERE (SELECT status FROM cycle_counts WHERE cycle_count_id = OLD.cycle_count_id) <> 'open';
END;

-- Status final tidak boleh berubah (approved/cancelled). 'rejected' -> 'open'
-- tetap diizinkan untuk recount (UC-STK-05 alt A1).
DROP TRIGGER IF EXISTS trg_cc_status_no_regress;
CREATE TRIGGER trg_cc_status_no_regress
BEFORE UPDATE OF status ON cycle_counts
FOR EACH ROW
WHEN OLD.status IN ('approved','cancelled')
 AND NEW.status <> OLD.status
BEGIN
    SELECT RAISE(ABORT, 'Status sesi final tidak boleh diubah.');
END;

-- =============================================================================
-- 8. Seed
-- =============================================================================

INSERT INTO meta (key, value, updated_at)
VALUES ('schema_version', '1', CAST(strftime('%s','now') AS INTEGER) * 1000)
ON CONFLICT(key) DO UPDATE SET
    value = excluded.value,
    updated_at = excluded.updated_at;
