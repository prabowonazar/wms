/// Jenis transaksi ledger. Nilai `wireName` sama dengan Firestore, SQLite,
/// dan rules sehingga tidak perlu pemetaan tambahan.
enum TransactionType {
  incoming('incoming'),
  outgoing('outgoing'),
  adjustment('adjustment'),
  reversal('reversal');

  const TransactionType(this.wireName);

  final String wireName;

  static TransactionType? tryParse(Object? value) {
    if (value is! String) {
      return null;
    }
    for (final type in TransactionType.values) {
      if (type.wireName == value) {
        return type;
      }
    }
    return null;
  }

  String get label {
    switch (this) {
      case TransactionType.incoming:
        return 'Masuk';
      case TransactionType.outgoing:
        return 'Keluar';
      case TransactionType.adjustment:
        return 'Penyesuaian';
      case TransactionType.reversal:
        return 'Pembatalan';
    }
  }

  /// Qty bertanda sesuai BR-01: masuk positif, keluar negatif.
  ///
  /// `null` bila kombinasi jenis dan qty tidak sah (mis. qty 0 atau
  /// adjustment dengan qty 0), supaya CHECK di SQLite tidak pernah dilanggar
  /// oleh data yang dibuat aplikasi.
  int? signedQtyFor(int qty) {
    if (qty == 0) {
      return null;
    }
    switch (this) {
      case TransactionType.incoming:
        return qty > 0 ? qty : null;
      case TransactionType.outgoing:
        return qty > 0 ? -qty : null;
      case TransactionType.adjustment:
      case TransactionType.reversal:
        return qty;
    }
  }
}

/// Kunci periode `YYYY-MM-DD` menurut WIB (UTC+7, tanpa DST).
///
/// Device bisa memakai zona waktu apa pun; periode harus mengikuti jam gudang
/// agar stock card dan closing harian tidak berbeda antar device.
String periodKeyFor(DateTime instant) {
  final wib = instant.toUtc().add(const Duration(hours: 7));
  final year = wib.year.toString().padLeft(4, '0');
  final month = wib.month.toString().padLeft(2, '0');
  final day = wib.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

/// Satu baris ledger lokal = satu dokumen `transactions/{id}` di Firestore.
///
/// Field `serverStatus`/`createdAtServer` sengaja tidak ada: itu milik server
/// dan client dilarang menulisnya (lihat rules).
class StockTransaction {
  const StockTransaction({
    required this.transactionId,
    required this.warehouseId,
    required this.productId,
    required this.productCode,
    required this.productName,
    required this.productType,
    required this.uom,
    required this.type,
    required this.qty,
    required this.signedQty,
    required this.periodKey,
    required this.userId,
    required this.userName,
    required this.deviceId,
    required this.occurredAt,
    required this.createdAtClient,
    required this.createdAtLocal,
    required this.source,
    this.schemaVersion = 1,
    this.note,
    this.refTransactionId,
    this.cycleCountId,
    this.approvalStatus = 'not_required',
    this.approvalReason,
    this.syncStatus = 'pending',
    this.retryCount = 0,
    this.lastError,
    this.nextRetryAt,
    this.syncedAt,
  });

  factory StockTransaction.fromRow(Map<String, Object?> row) {
    final type = TransactionType.tryParse(row['type']);
    if (type == null) {
      throw FormatException('Jenis transaksi tidak dikenal: ${row['type']}');
    }
    return StockTransaction(
      transactionId: row['transaction_id']! as String,
      schemaVersion: (row['schema_version'] as int?) ?? 1,
      warehouseId: row['warehouse_id']! as String,
      productId: row['product_id']! as String,
      productCode: row['product_code']! as String,
      productName: row['product_name']! as String,
      productType: row['product_type']! as String,
      uom: row['uom']! as String,
      type: type,
      qty: row['qty']! as int,
      signedQty: row['signed_qty']! as int,
      periodKey: row['period_key']! as String,
      userId: row['user_id']! as String,
      userName: row['user_name']! as String,
      deviceId: row['device_id']! as String,
      occurredAt: _time(row['occurred_at'])!,
      createdAtClient: _time(row['created_at_client'])!,
      createdAtLocal: _time(row['created_at_local'])!,
      note: row['note'] as String?,
      refTransactionId: row['ref_transaction_id'] as String?,
      cycleCountId: row['cycle_count_id'] as String?,
      approvalStatus: (row['approval_status'] as String?) ?? 'not_required',
      approvalReason: row['approval_reason'] as String?,
      syncStatus: (row['sync_status'] as String?) ?? 'pending',
      retryCount: (row['retry_count'] as int?) ?? 0,
      lastError: row['last_error'] as String?,
      nextRetryAt: _time(row['next_retry_at']),
      syncedAt: _time(row['synced_at']),
      source: (row['source'] as String?) ?? 'scan',
    );
  }

  final String transactionId;
  final int schemaVersion;
  final String warehouseId;
  final String productId;
  final String productCode;
  final String productName;
  final String productType;
  final String uom;
  final TransactionType type;
  final int qty;
  final int signedQty;
  final String periodKey;
  final String userId;
  final String userName;
  final String deviceId;
  final DateTime occurredAt;
  final DateTime createdAtClient;
  final DateTime createdAtLocal;
  final String? note;
  final String? refTransactionId;
  final String? cycleCountId;
  final String approvalStatus;
  final String? approvalReason;
  final String source;
  final String syncStatus;
  final int retryCount;
  final String? lastError;
  final DateTime? nextRetryAt;
  final DateTime? syncedAt;

  bool get isPending => syncStatus == 'pending' || syncStatus == 'syncing';

  bool get needsOverrideApproval => approvalStatus == 'pending';

  Map<String, Object?> toRow() {
    return <String, Object?>{
      'transaction_id': transactionId,
      'schema_version': schemaVersion,
      'warehouse_id': warehouseId,
      'product_id': productId,
      'product_code': productCode,
      'product_name': productName,
      'product_type': productType,
      'uom': uom,
      'type': type.wireName,
      'qty': qty,
      'signed_qty': signedQty,
      'period_key': periodKey,
      'user_id': userId,
      'user_name': userName,
      'device_id': deviceId,
      'occurred_at': occurredAt.millisecondsSinceEpoch,
      'created_at_client': createdAtClient.millisecondsSinceEpoch,
      'created_at_local': createdAtLocal.millisecondsSinceEpoch,
      'note': note,
      'ref_transaction_id': refTransactionId,
      'cycle_count_id': cycleCountId,
      'approval_status': approvalStatus,
      'approval_reason': approvalReason,
      'source': source,
      'sync_status': syncStatus,
      'retry_count': retryCount,
      'last_error': lastError,
      'next_retry_at': nextRetryAt?.millisecondsSinceEpoch,
      'synced_at': syncedAt?.millisecondsSinceEpoch,
    };
  }

  static DateTime? _time(Object? value) {
    if (value is! int) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
}

/// Saldo lokal + bagian yang belum diterima server.
class BalanceSnapshot {
  const BalanceSnapshot({required this.endingQty, required this.unsyncedQty});

  final int endingQty;
  final int unsyncedQty;
}

/// Ringkasan stock card satu periode (SCR-13).
class StockCardDay {
  const StockCardDay({
    required this.periodKey,
    required this.opening,
    required this.incoming,
    required this.outgoing,
    required this.adjustment,
    required this.ending,
  });

  final String periodKey;
  final int opening;
  final int incoming;
  final int outgoing;
  final int adjustment;
  final int ending;

  /// BR-01: `opening + in - out + adj = ending`.
  bool get isConsistent => opening + incoming - outgoing + adjustment == ending;
}

/// Keluar melebihi saldo. UI memakai ini untuk SCR-08.
class InsufficientStockException implements Exception {
  const InsufficientStockException({
    required this.productName,
    required this.uom,
    required this.balance,
    required this.requested,
  });

  final String productName;
  final String uom;
  final int balance;
  final int requested;

  int get shortage => requested - balance;

  @override
  String toString() =>
      'InsufficientStockException($productName: saldo $balance, minta $requested)';
}

/// Input tidak sah sebelum menyentuh database.
class InvalidMovementException implements Exception {
  const InvalidMovementException(this.message);

  final String message;

  @override
  String toString() => 'InvalidMovementException: $message';
}
