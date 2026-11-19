import 'stock_transaction.dart';

/// Ringkasan antrean sync untuk badge beranda dan layar Sinkronisasi (SCR-20).
class SyncSummary {
  const SyncSummary({
    required this.pending,
    required this.syncing,
    required this.failed,
    required this.syncedToday,
    this.failedItems = const <StockTransaction>[],
    this.pendingItems = const <StockTransaction>[],
    this.lastSyncedAt,
  });

  /// Belum pernah dicoba atau menunggu jadwal retry.
  final int pending;

  /// Sedang dikirim saat ringkasan dibaca.
  final int syncing;

  /// Gagal sementara, ditolak server, atau sudah melewati batas percobaan.
  final int failed;

  final int syncedToday;

  /// Baris bermasalah, terbaru lebih dulu (maksimum 20).
  final List<StockTransaction> failedItems;

  /// Baris yang menunggu jaringan (maksimum 20).
  final List<StockTransaction> pendingItems;

  final DateTime? lastSyncedAt;

  int get unsynced => pending + syncing + failed;

  bool get allClear => unsynced == 0;

  /// Teks chip: "Semua terkirim" atau "N belum terkirim".
  String get chipLabel {
    if (allClear) {
      return 'Semua terkirim';
    }
    if (failed > 0) {
      return '$unsynced belum terkirim · $failed perlu tindakan';
    }
    return '$unsynced belum terkirim';
  }
}
