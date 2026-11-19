import 'package:sqflite_common/sqlite_api.dart';

import '../auth/auth_models.dart';
import '../master/product.dart';
import '../sync/uuid7.dart';
import 'stock_conflict.dart';
import 'stock_transaction.dart';
import 'sync_policy.dart';
import 'sync_summary.dart';

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
  /// ikut diambil kembali setelah `next_retry_at` lewat, tetapi berhenti
  /// otomatis setelah [maxSyncAttempts] percobaan (FR-SYN-02).
  Future<List<StockTransaction>> pending({int limit = 20, DateTime? now}) async {
    final reference = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final rows = await _database.query(
      'transactions',
      where: "sync_status IN ('pending','syncing') "
          "OR (sync_status = 'failed' "
          'AND retry_count < ? '
          'AND (next_retry_at IS NULL OR next_retry_at <= ?))',
      whereArgs: [maxSyncAttempts, reference],
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

  /// Tandai gagal permanen (mis. ditolak server) tanpa percobaan otomatis.
  ///
  /// `retry_count` diisi batas maksimum supaya `pending()` tidak mengambilnya
  /// lagi; aksi manual di layar Sinkronisasi yang memutuskan percobaan baru.
  Future<void> markRejected(String transactionId, String reason) async {
    await _database.rawUpdate(
      'UPDATE transactions SET sync_status = ?, retry_count = ?, '
      'last_error = ?, synced_at = NULL, next_retry_at = NULL '
      'WHERE transaction_id = ?',
      <Object?>['failed', maxSyncAttempts, reason, transactionId],
    );
  }

  /// Tandai gagal sementara (mis. jaringan) dan jadwalkan percobaan berikutnya.
  ///
  /// [delay] `null` berarti tidak ada percobaan otomatis lagi (batas tercapai).
  Future<void> markFailed(
    String transactionId,
    String error, {
    Duration? delay = const Duration(minutes: 1),
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now();
    await _database.rawUpdate(
      'UPDATE transactions SET sync_status = ?, retry_count = retry_count + 1, '
      'last_error = ?, next_retry_at = ? WHERE transaction_id = ?',
      <Object?>[
        'failed',
        error,
        delay == null ? null : now.add(delay).millisecondsSinceEpoch,
        transactionId,
      ],
    );
  }

  /// Aksi "Coba lagi" manual: buka siklus percobaan baru.
  ///
  /// Mengembalikan `false` bila baris sudah terkirim atau tidak ada.
  Future<bool> retryNow(String transactionId) async {
    final changed = await _database.rawUpdate(
      'UPDATE transactions SET sync_status = ?, retry_count = 0, '
      'last_error = NULL, next_retry_at = NULL '
      "WHERE transaction_id = ? AND sync_status = 'failed'",
      <Object?>['pending', transactionId],
    );
    return changed > 0;
  }

  /// Hapus transaksi `failed` yang tidak pernah diterima server.
  ///
  /// Trigger skema hanya mengizinkan DELETE untuk baris `failed`; transaksi
  /// yang sudah `synced` wajib dikoreksi lewat reversal (BR-06).
  Future<bool> discardFailed(String transactionId) async {
    final changed = await _database.delete(
      'transactions',
      where: 'transaction_id = ? AND sync_status = ?',
      whereArgs: [transactionId, 'failed'],
    );
    return changed > 0;
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

  /// Cache konflik saldo milik gudang ini (BR-12).
  ///
  /// Function adalah satu-satunya penulis di Firestore; perangkat hanya
  /// menyimpan salinan untuk ditampilkan Supervisor.
  Future<void> replaceOpenConflicts(List<StockConflict> conflicts) async {
    await _database.transaction((txn) async {
      await txn.delete(
        'stock_conflicts_cache',
        where: 'warehouse_id = ? AND status = ?',
        whereArgs: [_warehouseId, 'open'],
      );
      for (final conflict in conflicts) {
        await txn.insert(
          'stock_conflicts_cache',
          <String, Object?>{
            'conflict_id': conflict.conflictId,
            'warehouse_id': _warehouseId,
            'product_id': conflict.productId,
            'device_ending_qty': conflict.deviceEndingQty,
            'server_ending_qty': conflict.serverEndingQty,
            'delta': conflict.delta,
            'detected_at': conflict.detectedAt.millisecondsSinceEpoch,
            'status': 'open',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<List<StockConflict>> openConflicts() async {
    final rows = await _database.query(
      'stock_conflicts_cache',
      where: 'warehouse_id = ? AND status = ?',
      whereArgs: [_warehouseId, 'open'],
      orderBy: 'detected_at DESC',
      limit: 20,
    );
    return rows.map(_conflictFromRow).toList(growable: false);
  }

  /// Tandai konflik selesai di cache setelah server menerima resolusi.
  Future<void> markConflictResolved(
    String conflictId,
    String resolution,
    String reason,
  ) async {
    await _database.update(
      'stock_conflicts_cache',
      <String, Object?>{
        'status': resolution == 'ignore' ? 'ignored' : 'resolved',
        // Kolom resolution menyimpan "jenis|alasan" karena skema v1 tidak
        // punya kolom reason tersendiri.
        'resolution': '$resolution|$reason',
      },
      where: 'conflict_id = ?',
      whereArgs: [conflictId],
    );
  }

  static StockConflict _conflictFromRow(Map<String, Object?> row) {
    final stored = (row['resolution'] as String?) ?? '';
    final parts = stored.split('|');
    final rawTime = row['detected_at'];
    return StockConflict(
      conflictId: row['conflict_id']! as String,
      productId: (row['product_id'] as String?) ?? '',
      deviceEndingQty: (row['device_ending_qty'] as int?) ?? 0,
      serverEndingQty: (row['server_ending_qty'] as int?) ?? 0,
      detectedAt: rawTime is int
          ? DateTime.fromMillisecondsSinceEpoch(rawTime, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      resolution: parts.isEmpty ? null : parts.first,
      reason: parts.length < 2 ? null : parts.sublist(1).join('|'),
    );
  }

  /// Ringkasan status untuk badge beranda dan SCR-20 (FR-SYN-03).
  Future<SyncSummary> syncSummary({int listLimit = 20, DateTime? now}) async {
    final counts = await _database.rawQuery(
      'SELECT sync_status AS status, COUNT(*) AS total '
      'FROM transactions WHERE warehouse_id = ? GROUP BY sync_status',
      [_warehouseId],
    );
    final byStatus = <String, int>{
      for (final row in counts) (row['status'] as String): _int(row['total']),
    };

    final dayStart = periodKeyFor(now ?? DateTime.now());
    final syncedRows = await _database.rawQuery(
      'SELECT COUNT(*) AS total FROM transactions '
      "WHERE warehouse_id = ? AND sync_status = 'synced' AND period_key = ?",
      [_warehouseId, dayStart],
    );
    final lastSyncedRows = await _database.rawQuery(
      'SELECT MAX(synced_at) AS last FROM transactions '
      "WHERE warehouse_id = ? AND sync_status = 'synced'",
      [_warehouseId],
    );
    final lastSyncedRaw = lastSyncedRows.first['last'];

    final failedRows = await _database.query(
      'transactions',
      where: 'warehouse_id = ? AND sync_status = ?',
      whereArgs: [_warehouseId, 'failed'],
      orderBy: 'occurred_at DESC',
      limit: listLimit,
    );
    final pendingRows = await _database.query(
      'transactions',
      where: 'warehouse_id = ? AND sync_status IN (?, ?)',
      whereArgs: [_warehouseId, 'pending', 'syncing'],
      orderBy: 'occurred_at ASC',
      limit: listLimit,
    );

    return SyncSummary(
      pending: byStatus['pending'] ?? 0,
      syncing: byStatus['syncing'] ?? 0,
      failed: byStatus['failed'] ?? 0,
      syncedToday: _int(syncedRows.first['total']),
      failedItems:
          failedRows.map(StockTransaction.fromRow).toList(growable: false),
      pendingItems:
          pendingRows.map(StockTransaction.fromRow).toList(growable: false),
      lastSyncedAt: lastSyncedRaw is int
          ? DateTime.fromMillisecondsSinceEpoch(lastSyncedRaw, isUtc: true)
          : null,
    );
  }

  /// Histori transaksi (SCR-10) dengan filter tanggal, jenis, produk, operator.
  ///
  /// Operator wajib mengirim [userId] miliknya sendiri; supervisor boleh
  /// `null` untuk melihat seluruh gudang (BR-09). [query] mencocokkan kode
  /// atau nama produk.
  Future<List<StockTransaction>> history({
    DateTime? from,
    DateTime? to,
    TransactionType? type,
    String? productId,
    String? userId,
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    final clauses = <String>['warehouse_id = ?'];
    final args = <Object?>[_warehouseId];

    if (from != null) {
      clauses.add('occurred_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      clauses.add('occurred_at < ?');
      args.add(to.millisecondsSinceEpoch);
    }
    if (type != null) {
      clauses.add('type = ?');
      args.add(type.wireName);
    }
    if (productId != null) {
      clauses.add('product_id = ?');
      args.add(productId);
    }
    if (userId != null) {
      clauses.add('user_id = ?');
      args.add(userId);
    }
    final trimmed = query?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      clauses.add('(product_code LIKE ? OR product_name LIKE ?)');
      args.addAll(<String>['%$trimmed%', '%$trimmed%']);
    }

    final rows = await _database.query(
      'transactions',
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'occurred_at DESC, transaction_id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(StockTransaction.fromRow).toList(growable: false);
  }

  /// Transaksi `synced` dalam [within] terakhir, terbaru lebih dulu.
  ///
  /// Dipakai untuk menarik keputusan `serverStatus` (mis. penolakan stok dari
  /// Function) tanpa memindai seluruh histori.
  Future<List<StockTransaction>> recentlySynced({
    int limit = 20,
    Duration within = const Duration(hours: 24),
    DateTime? now,
  }) async {
    final reference = (now ?? DateTime.now()).subtract(within);
    final rows = await _database.query(
      'transactions',
      where: 'warehouse_id = ? AND sync_status = ? AND synced_at >= ?',
      whereArgs: [
        _warehouseId,
        'synced',
        reference.millisecondsSinceEpoch,
      ],
      orderBy: 'synced_at DESC',
      limit: limit,
    );
    return rows.map(StockTransaction.fromRow).toList(growable: false);
  }

  /// `true` bila [transactionId] sudah punya reversal di perangkat ini.
  Future<bool> hasReversal(String transactionId) async {
    final rows = await _database.query(
      'transactions',
      columns: ['transaction_id'],
      where: 'ref_transaction_id = ? AND type = ?',
      whereArgs: [transactionId, 'reversal'],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Membuat transaksi `reversal` untuk transaksi yang sudah terkirim (BR-06).
  ///
  /// Transaksi asli tidak diubah/dihapus; saldo kembali lewat baris baru
  /// bertanda berlawanan. Reversal ganda ditolak di perangkat ini dan di
  /// server (Function memeriksa `refTransactionId`).
  Future<StockTransaction> recordReversal({
    required StockTransaction original,
    required UserProfile profile,
    required String reason,
    String? transactionId,
    DateTime? now,
  }) async {
    if (profile.role != UserRole.supervisor &&
        profile.role != UserRole.admin) {
      throw const InvalidMovementException(
        'Pembatalan hanya boleh dilakukan supervisor.',
      );
    }
    if (original.warehouseId != _warehouseId) {
      throw const InvalidMovementException(
        'Transaksi ini bukan milik gudang Anda.',
      );
    }
    if (original.type == TransactionType.reversal) {
      throw const InvalidMovementException(
        'Transaksi pembatalan tidak bisa dibatalkan lagi.',
      );
    }
    final trimmedReason = reason.trim();
    if (trimmedReason.length < 10) {
      throw const InvalidMovementException(
        'Alasan pembatalan minimal 10 karakter.',
      );
    }

    final id = transactionId ?? uuid7();
    final occurred = now ?? DateTime.now();
    final device = await deviceId();

    return _database.transaction((txn) async {
      final existing = await txn.query(
        'transactions',
        where: 'transaction_id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        return StockTransaction.fromRow(existing.first);
      }

      final refreshed = await txn.query(
        'transactions',
        where: 'transaction_id = ?',
        whereArgs: [original.transactionId],
        limit: 1,
      );
      if (refreshed.isEmpty) {
        throw const InvalidMovementException('Transaksi asli tidak ditemukan.');
      }
      final source = StockTransaction.fromRow(refreshed.first);

      if (source.type == TransactionType.reversal) {
        throw const InvalidMovementException(
          'Transaksi pembatalan tidak bisa dibatalkan lagi.',
        );
      }
      if (source.syncStatus == 'failed') {
        throw const InvalidMovementException(
          'Transaksi yang gagal tidak bisa dibatalkan. Hapus saja dari antrean.',
        );
      }
      if (source.syncStatus != 'synced') {
        throw const InvalidMovementException(
          'Tunggu transaksi terkirim ke server sebelum dibatalkan.',
        );
      }

      final already = await txn.query(
        'transactions',
        columns: ['transaction_id'],
        where: 'ref_transaction_id = ? AND type = ?',
        whereArgs: [source.transactionId, 'reversal'],
        limit: 1,
      );
      if (already.isNotEmpty) {
        throw const InvalidMovementException(
          'Transaksi ini sudah dibatalkan sebelumnya.',
        );
      }

      final signed = -source.signedQty;
      final transaction = StockTransaction(
        transactionId: id,
        warehouseId: _warehouseId,
        productId: source.productId,
        productCode: source.productCode,
        productName: source.productName,
        productType: source.productType,
        uom: source.uom,
        type: TransactionType.reversal,
        qty: signed,
        signedQty: signed,
        periodKey: periodKeyFor(occurred),
        userId: profile.uid,
        userName: profile.displayName,
        deviceId: device,
        occurredAt: occurred.toUtc(),
        createdAtClient: occurred.toUtc(),
        createdAtLocal: occurred,
        note: trimmedReason,
        refTransactionId: source.transactionId,
        source: 'manual',
      );

      await txn.insert('transactions', transaction.toRow());
      return transaction;
    });
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
