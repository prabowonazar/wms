import 'package:cloud_firestore/cloud_firestore.dart';

import '../config/app_config.dart';
import 'stock_transaction.dart';

enum TransactionPushResult {
  /// Dokumen dibuat oleh permintaan ini.
  created,

  /// Dokumen dengan ID sama sudah ada; anggap sukses (BR-04).
  alreadyExists,
}

/// Pengiriman satu transaksi ke penyimpanan pusat.
abstract class TransactionRemote {
  Future<TransactionPushResult> create(StockTransaction transaction);

  /// Membaca status akhir dari server untuk [transactionIds].
  ///
  /// Dipakai VS-3 untuk menarik keputusan Function `applyBalance`: transaksi
  /// bisa diterima (`applied`) atau ditolak (`rejected`) setelah dibuat.
  /// Dokumen yang belum diproses tidak dikembalikan.
  Future<Map<String, ServerTransactionState>> fetchStates(
    List<String> transactionIds,
  );
}

/// Status transaksi versi server (subset yang dibutuhkan device).
class ServerTransactionState {
  const ServerTransactionState({
    required this.status,
    this.rejectedReason,
  });

  /// `applied` atau `rejected` (nilai lain diabaikan pemanggil).
  final String status;
  final String? rejectedReason;

  bool get isRejected => status == 'rejected';
}

/// Implementasi Firestore dengan semantik **create-only**.
///
/// `set()` biasa akan menimpa dokumen; itu bukan idempotensi yang dimaksud
/// BR-04. Jadi dokumen dibaca lebih dulu di dalam transaksi Firestore, dan
/// hanya ditulis bila belum ada. Replay 10x tetap menghasilkan satu dokumen.
class FirestoreTransactionRemote implements TransactionRemote {
  FirestoreTransactionRemote(this._firestore);

  final FirebaseFirestore _firestore;

  /// Batas `whereIn` Firestore adalah 30 nilai.
  static const int _chunkSize = 30;

  @override
  Future<TransactionPushResult> create(StockTransaction transaction) async {
    final reference =
        _firestore.collection('transactions').doc(transaction.transactionId);
    final payload = buildTransactionPayload(transaction);

    return _firestore.runTransaction<TransactionPushResult>((tx) async {
      final snapshot = await tx.get(reference);
      if (snapshot.exists) {
        return TransactionPushResult.alreadyExists;
      }
      tx.set(reference, payload);
      return TransactionPushResult.created;
    });
  }

  @override
  Future<Map<String, ServerTransactionState>> fetchStates(
    List<String> transactionIds,
  ) async {
    final result = <String, ServerTransactionState>{};
    if (transactionIds.isEmpty) {
      return result;
    }

    for (var start = 0; start < transactionIds.length; start += _chunkSize) {
      final end = (start + _chunkSize).clamp(0, transactionIds.length);
      final chunk = transactionIds.sublist(start, end);
      final snapshot = await _firestore
          .collection('transactions')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final status = data['serverStatus'];
        if (status is! String) {
          continue;
        }
        final reason = data['rejectedReason'];
        result[doc.id] = ServerTransactionState(
          status: status,
          rejectedReason: reason is String ? reason : null,
        );
      }
    }
    return result;
  }
}

/// Payload Firestore sesuai `docs/firestore-schema.md` §2.6 dan rules
/// `transactions`.
///
/// Tidak memuat `serverStatus`, `createdAtServer`, atau `syncedAt`: ketiganya
/// ditulis Function, dan client dilarang mengirimkannya.
Map<String, Object?> buildTransactionPayload(StockTransaction transaction) {
  final payload = <String, Object?>{
    'schemaVersion': transaction.schemaVersion,
    'warehouseId': transaction.warehouseId,
    'productId': transaction.productId,
    'productCode': transaction.productCode,
    'productName': transaction.productName,
    'productType': transaction.productType,
    'uom': transaction.uom,
    'type': transaction.type.wireName,
    'qty': transaction.qty,
    'signedQty': transaction.signedQty,
    'periodKey': transaction.periodKey,
    'userId': transaction.userId,
    'userName': transaction.userName,
    'deviceId': transaction.deviceId,
    'occurredAt': Timestamp.fromDate(transaction.occurredAt),
    'createdAtClient': Timestamp.fromDate(transaction.createdAtClient),
    'appVersion': AppConfig.appVersion,
    'source': transaction.source,
  };

  final note = transaction.note;
  if (note != null && note.isNotEmpty) {
    payload['note'] = note;
  }
  final ref = transaction.refTransactionId;
  if (ref != null) {
    payload['refTransactionId'] = ref;
  }
  final cycleCountId = transaction.cycleCountId;
  if (cycleCountId != null) {
    payload['cycleCountId'] = cycleCountId;
  }
  if (transaction.approvalStatus != 'not_required') {
    // Rules hanya mengizinkan status 'pending' dari client; keputusan akhir
    // (approved/rejected) diambil Function.
    payload['approval'] = <String, Object?>{
      'status': 'pending',
      if (transaction.approvalReason != null)
        'reason': transaction.approvalReason,
    };
  }

  return payload;
}
