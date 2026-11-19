/// Konflik saldo device vs server yang dibuat Function (BR-12).
///
/// Supervisor tidak pernah mengubah angka secara diam-diam: setiap konflik
/// ditutup dengan resolution + reason yang turut tercatat di `auditLogs`.
class StockConflict {
  const StockConflict({
    required this.conflictId,
    required this.productId,
    required this.deviceEndingQty,
    required this.serverEndingQty,
    required this.detectedAt,
    this.productCode = '',
    this.productName = '',
    this.transactionId,
    this.status = 'open',
    this.resolution,
    this.reason,
  });

  final String conflictId;
  final String productId;
  final String productCode;
  final String productName;
  final int deviceEndingQty;
  final int serverEndingQty;
  final DateTime detectedAt;
  final String? transactionId;
  final String status;

  /// `accept_server` | `adjust_to_device` | `ignore`.
  final String? resolution;
  final String? reason;

  int get delta => deviceEndingQty - serverEndingQty;

  String get label => productCode.isEmpty
      ? productId
      : '$productCode · $productName';
}
