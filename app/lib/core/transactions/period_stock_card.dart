/// Salinan snapshot stock card dari server untuk periode yang sudah ditutup.
class PeriodStockCard {
  const PeriodStockCard({
    required this.productId,
    required this.periodKey,
    required this.opening,
    required this.incoming,
    required this.outgoing,
    required this.adjustment,
    required this.ending,
    this.productCode = '',
    this.productName = '',
    this.uom = '',
    this.transactionCount = 0,
  });

  final String productId;
  final String periodKey;
  final String productCode;
  final String productName;
  final String uom;
  final int opening;
  final int incoming;
  final int outgoing;
  final int adjustment;
  final int ending;
  final int transactionCount;

  bool get isConsistent => opening + incoming - outgoing + adjustment == ending;
}

/// Status periode hasil closing harian.
class PeriodInfo {
  const PeriodInfo({
    required this.periodKey,
    required this.status,
    this.transactionCount = 0,
    this.productCount = 0,
    this.checksum = '',
  });

  final String periodKey;
  final String status;
  final int transactionCount;
  final int productCount;
  final String checksum;

  bool get isClosed => status == 'closed';
}
