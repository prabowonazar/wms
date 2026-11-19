import 'package:warehouse_mobile/core/auth/auth_models.dart';

/// Status sesi cycle-count. Urutan mengikuti mesin status UC-STK-02..05.
enum CycleCountStatus {
  open('open'),
  submitted('submitted'),
  approved('approved'),
  rejected('rejected'),
  cancelled('cancelled');

  const CycleCountStatus(this.wireName);

  final String wireName;

  static CycleCountStatus? tryParse(Object? value) {
    if (value is! String) {
      return null;
    }
    for (final status in CycleCountStatus.values) {
      if (status.wireName == value) {
        return status;
      }
    }
    return null;
  }

  String get label {
    switch (this) {
      case CycleCountStatus.open:
        return 'Dihitung';
      case CycleCountStatus.submitted:
        return 'Menunggu persetujuan';
      case CycleCountStatus.approved:
        return 'Disetujui';
      case CycleCountStatus.rejected:
        return 'Ditolak';
      case CycleCountStatus.cancelled:
        return 'Dibatalkan';
    }
  }
}

class CycleCountSession {
  const CycleCountSession({
    required this.id,
    required this.warehouseId,
    required this.periodKey,
    required this.status,
    required this.startedBy,
    required this.startedAt,
    this.lineCount = 0,
    this.varianceLineCount = 0,
    this.reviewedBy,
    this.note,
    this.syncStatus = 'pending',
  });

  final String id;
  final String warehouseId;
  final String periodKey;
  final CycleCountStatus status;
  final String startedBy;
  final DateTime startedAt;
  final int lineCount;
  final int varianceLineCount;
  final String? reviewedBy;
  final String? note;
  final String syncStatus;

  bool get isOpen => status == CycleCountStatus.open;

  factory CycleCountSession.fromRow(Map<String, Object?> row) {
    final status = CycleCountStatus.tryParse(row['status']);
    if (status == null) {
      throw FormatException('Status cycle-count tidak dikenal: ${row['status']}');
    }
    return CycleCountSession(
      id: row['cycle_count_id']! as String,
      warehouseId: row['warehouse_id']! as String,
      periodKey: row['period_key']! as String,
      status: status,
      startedBy: (row['started_by'] as String?) ?? '',
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        (row['started_at'] as int?) ?? 0,
        isUtc: true,
      ),
      lineCount: 0,
      varianceLineCount: 0,
      reviewedBy: row['reviewed_by'] as String?,
      note: row['note'] as String?,
      syncStatus: (row['sync_status'] as String?) ?? 'pending',
    );
  }
}

class CycleCountLine {
  const CycleCountLine({
    required this.sessionId,
    required this.productId,
    required this.productCode,
    required this.productName,
    required this.uom,
    required this.systemQty,
    required this.countedQty,
    required this.countedBy,
    required this.countedAt,
    this.note,
  });

  final String sessionId;
  final String productId;
  final String productCode;
  final String productName;
  final String uom;
  final int systemQty;
  final int countedQty;
  final String countedBy;
  final DateTime countedAt;
  final String? note;

  int get variance => countedQty - systemQty;

  /// Baris yang tidak dihitung fisik diisi otomatis saat submit.
  bool get isAutoFilled => note == autoFilledNote;

  static const String autoFilledNote = 'tidak dihitung';

  factory CycleCountLine.fromRow(Map<String, Object?> row) {
    return CycleCountLine(
      sessionId: row['cycle_count_id']! as String,
      productId: row['product_id']! as String,
      productCode: (row['product_code'] as String?) ?? '',
      productName: (row['product_name'] as String?) ?? '',
      uom: (row['uom'] as String?) ?? '',
      systemQty: (row['system_qty'] as int?) ?? 0,
      countedQty: (row['counted_qty'] as int?) ?? 0,
      countedBy: (row['counted_by'] as String?) ?? '',
      countedAt: DateTime.fromMillisecondsSinceEpoch(
        (row['counted_at'] as int?) ?? 0,
        isUtc: true,
      ),
      note: row['note'] as String?,
    );
  }
}

/// Hasil pengajuan sesi; dipakai UI untuk pesan yang tepat.
class CycleCountSubmitResult {
  const CycleCountSubmitResult({
    required this.session,
    required this.autoApproved,
    required this.autoFilledCount,
  });

  final CycleCountSession session;
  final bool autoApproved;
  final int autoFilledCount;
}
