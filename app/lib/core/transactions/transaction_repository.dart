import 'package:sqflite_common/sqlite_api.dart';

import '../auth/auth_models.dart';
import '../master/product.dart';
import '../sync/uuid7.dart';
import 'stock_transaction.dart';

/// Menyimpan dan membaca ledger lokal (outbox sekaligus sumber saldo).
///
/// Semua method hanya menyentuh SQLite, jadi aman dipanggil saat airplane mode.
/// Pengiriman ke Firestore ada di `outbox_sync.dart`.
class TransactionRepository {
  TransactionRepository({
    required Database database,
    required String warehouseId,
  })  : _database = database,
        _warehouseId = warehouseId;

  final Database _database;
  final String _warehouseId;

  /// Kunci `meta` untuk installation ID. Bukan Android ID mentah (privasi).
  static const String deviceIdKey = 'device_id';

  /// ID perangkat yang stabil selama aplikasi terpasang.
  Future<String> deviceId() async {
    final rows = await _database.query(
      'meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [deviceIdKey],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final value = rows.first['value'];
      if (value is String && value.isNotEmpty) {
        return value;
      }
    }

    final value = uuid7();
    await _database.insert(
      'meta',
      <String, Object?>{
        'key': deviceIdKey,
        'value': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return value;
  }

  /// Saldo berjalan dari view `v_product_balance` (BR-01).
  Future<BalanceSnapshot> balanceFor(String productId) async {
    final rows = await _database.rawQuery(
      'SELECT ending_qty, unsynced_qty FROM v_product_balance '
      'WHERE warehouse_id = ? AND product_id = ?',
      [_warehouseId, productId],
    );
    if (rows.isEmpty) {
      return const BalanceSnapshot(endingQty: 0, unsyncedQty: 0);
    }
    final row = rows.first;
    return BalanceSnapshot(
      endingQty: _int(row['ending_qty']),
      unsyncedQty: _int(row['unsynced_qty']),
    );
  }

  /// Stock card periode [periodKey] (default hari ini WIB). `null` bila belum
  /// ada transaksi pada periode itu.
  Future<StockCardDay?> stockCardFor(
    String productId, {
    String? periodKey,
    DateTime? now,
  }) async {
    final key = periodKey ?? periodKeyFor(now ?? DateTime.now());
    final rows = await _database.rawQuery(
      'SELECT * FROM v_stock_card '
      'WHERE warehouse_id = ? AND product_id = ? AND period_key = ?',
      [_warehouseId, productId, key],
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.first;
    return StockCardDay(
      periodKey: key,
      opening: _int(row['opening_qty']),
      incoming: _int(row['incoming_qty']),
      outgoing: _int(row['outgoing_qty']),
      adjustment: _int(row['adjustment_qty']),
      ending: _int(row['ending_qty']),
    );
  }

  /// Menulis satu transaksi secara atomik.
  ///
  /// Idempoten: [transactionId] adalah primary key, jadi tap ganda atau retry
  /// dengan ID yang sama mengembalikan baris yang sudah ada tanpa menulis
  /// ulang. Pemeriksaan saldo dilakukan di dalam transaksi SQLite yang sama
  /// dengan INSERT, sehingga dua submit berurutan tidak bisa sama-sama lolos.
  ///
  /// [overrideReason] hanya boleh diisi supervisor/admin; nilainya disimpan
  /// sebagai `approval.pending` dan divalidasi ulang di server (BR-03).
  Future<StockTransaction> recordMovement({
    required String transactionId,
    required ProductView product,
    required TransactionType type,
    required int qty,
    required UserProfile profile,
    String source = 'scan',
    String? note,
    String? overrideReason,
    DateTime? now,
  }) async {
    if (type != TransactionType.incoming && type != TransactionType.outgoing) {
      throw const InvalidMovementException(
        'Hanya transaksi masuk/keluar yang bisa dibuat dari layar ini.',
      );
    }
    if (qty <= 0) {
      throw const InvalidMovementException('Qty harus lebih dari 0.');
    }
    final signedQty = type.signedQtyFor(qty);
    if (signedQty == null) {
      throw const InvalidMovementException('Qty tidak sah untuk jenis ini.');
    }

    final trimmedReason = overrideReason?.trim();
    if (trimmedReason != null &&
        trimmedReason.isNotEmpty &&
        profile.role != UserRole.supervisor &&
        profile.role != UserRole.admin) {
      throw const InvalidMovementException(
        'Override stok hanya boleh dilakukan supervisor.',
      );
    }
    final hasOverride = trimmedReason != null && trimmedReason.isNotEmpty;

    final occurred = now ?? DateTime.now();
    final device = await deviceId();

    return _database.transaction((txn) async {
      // Replay dengan ID yang sama: jangan validasi ulang saldo, karena saldo
      // sudah berkurang oleh transaksi pertama.
      final existing = await txn.query(
        'transactions',
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        return StockTransaction.fromRow(existing.first);
      }

      final balanceRows = await txn.rawQuery(
        'SELECT ending_qty FROM v_product_balance '
        'WHERE warehouse_id = ? AND product_id = ?',
        [_warehouseId, product.product.id],
      );
      final balance =
          balanceRows.isEmpty ? 0 : _int(balanceRows.first['ending_qty']);

      if (type == TransactionType.outgoing && balance + signedQty < 0) {
        if (!hasOverride) {
          throw InsufficientStockException(
            productName: product.name,
            uom: product.uom,
            balance: balance,
            requested: qty,
          );
        }
      }

      final transaction = StockTransaction(
        transactionId: transactionId,
        warehouseId: _warehouseId,
        productId: product.product.id,
        productCode: product.code,
        productName: product.name,
        productType: product.type,
        uom: product.uom,
        type: type,
        qty: qty,
        signedQty: signedQty,
        periodKey: periodKeyFor(occurred),
        userId: profile.uid,
        userName: profile.displayName,
        deviceId: device,
        occurredAt: occurred.toUtc(),
        createdAtClient: occurred.toUtc(),
        createdAtLocal: occurred,
        note: (note ?? '').trim().isEmpty ? null : note!.trim(),
        approvalStatus: hasOverride ? 'pending' : 'not_required',
        approvalReason: hasOverride ? trimmedReason : null,
        source: source,
      );

      await txn.insert('transactions', transaction.toRow());
      return transaction;
    });
  }

  /// Transaksi yang belum diterima server, paling lama lebih dulu.
  ///
  /// Baris `syncing` ikut diambil: bila aplikasi mati saat mengirim, kiriman
  /// ulang aman karena dokumen Firestore bersifat create-only. Baris `failed`
  /// ikut diambil kembali setelah `next_retry_at` lewat (backoff sederhana).
  Future<List<StockTransaction>> pending({int limit = 20, DateTime? now}) async {
    final reference = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final rows = await _database.query(
      'transactions',
      where: "sync_status IN ('pending','syncing') "
          "OR (sync_status = 'failed' "
          'AND (next_retry_at IS NULL OR next_retry_at <= ?))',
      whereArgs: [reference],
      orderBy: 'occurred_at ASC',
      limit: limit,
    );
    return rows.map(StockTransaction.fromRow).toList(growable: false);
  }

  Future<int> pendingCount() async {
    final rows = await _database.rawQuery(
      'SELECT COUNT(*) AS total FROM transactions '
      "WHERE sync_status <> 'synced'",
    );
    return _int(rows.first['total']);
  }

  Future<void> markSyncing(String transactionId) async {
    await _updateSync(transactionId, <String, Object?>{
      'sync_status': 'syncing',
      'last_error': null,
      'next_retry_at': null,
    });
  }

  Future<void> markSynced(String transactionId, {DateTime? at}) async {
    await _updateSync(transactionId, <String, Object?>{
      'sync_status': 'synced',
      'synced_at': (at ?? DateTime.now()).millisecondsSinceEpoch,
      'last_error': null,
      'next_retry_at': null,
    });
  }

  /// Tandai gagal tanpa memajukan `retry_count` (mis. ditolak server).
  Future<void> markRejected(String transactionId, String reason) async {
    await _updateSync(transactionId, <String, Object?>{
      'sync_status': 'failed',
      'last_error': reason,
      'synced_at': null,
      'next_retry_at': null,
    });
  }

  /// Tandai gagal sementara (mis. jaringan) dan jadwalkan percobaan berikutnya.
  Future<void> markFailed(
    String transactionId,
    String error, {
    Duration delay = const Duration(minutes: 1),
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now();
    await _database.rawUpdate(
      'UPDATE transactions SET sync_status = ?, retry_count = retry_count + 1, '
      'last_error = ?, next_retry_at = ? WHERE transaction_id = ?',
      <Object?>[
        'failed',
        error,
        now.add(delay).millisecondsSinceEpoch,
        transactionId,
      ],
    );
  }

  /// Baris `syncing` yang tertinggal karena aplikasi mati dikembalikan ke
  /// `pending` saat aplikasi dibuka.
  Future<int> resetStuckSyncing() async {
    return _database.rawUpdate(
      "UPDATE transactions SET sync_status = 'pending' WHERE sync_status = 'syncing'",
    );
  }

  Future<List<StockTransaction>> recentForProduct(
    String productId, {
    int limit = 20,
  }) async {
    final rows = await _database.query(
      'transactions',
      where: 'warehouse_id = ? AND product_id = ? AND sync_status <> ?',
      whereArgs: [_warehouseId, productId, 'failed'],
      orderBy: 'occurred_at DESC',
      limit: limit,
    );
    return rows.map(StockTransaction.fromRow).toList(growable: false);
  }

  Future<void> _updateSync(
    String transactionId,
    Map<String, Object?> values,
  ) async {
    await _database.update(
      'transactions',
      values,
      where: 'transaction_id = ?',
      whereArgs: [transactionId],
    );
  }

  static int _int(Object? value) => value is int ? value : 0;
}
