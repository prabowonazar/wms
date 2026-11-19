import '../observability/telemetry.dart';
import 'transaction_remote.dart';
import 'transaction_repository.dart';

class OutboxSyncResult {
  const OutboxSyncResult({
    this.sent = 0,
    this.failed = 0,
    this.remaining = 0,
    this.skipped = false,
    this.error,
  });

  final int sent;
  final int failed;
  final int remaining;

  /// `true` bila pemanggilan diabaikan karena kiriman lain sedang berjalan.
  final bool skipped;
  final String? error;

  bool get hasWork => sent > 0 || failed > 0;
}

/// Mengirim outbox SQLite ke Firestore, satu batch kecil per putaran.
///
/// Sengaja tidak memakai plugin WorkManager pada VS-2: pengiriman otomatis
/// berjalan saat app dibuka, setelah transaksi disimpan, dan tiap 60 detik
/// selama app di depan. Batasan ini dicatat di
/// `docs/vertical-slice-backlog.md` (VS2-03) dan wajib diganti WorkManager
/// sebelum rilis lapangan.
class OutboxSyncService {
  OutboxSyncService({
    required TransactionRepository repository,
    required TransactionRemote remote,
    required Telemetry telemetry,
    this.batchSize = 20,
    this.retryDelay = const Duration(minutes: 1),
  })  : _repository = repository,
        _remote = remote,
        _telemetry = telemetry;

  final TransactionRepository _repository;
  final TransactionRemote _remote;
  final Telemetry _telemetry;
  final int batchSize;

  /// Jeda sebelum baris `failed` dicoba lagi otomatis. VS-3 menggantinya
  /// dengan backoff eksponensial dan batas percobaan.
  final Duration retryDelay;

  bool _running = false;

  bool get isRunning => _running;

  /// Kirim semua baris `pending`/`syncing` sampai kosong atau jaringan gagal.
  ///
  /// Berhenti pada kegagalan pertama, bukan mencoba 300 transaksi buta: bila
  /// jaringan mati, mencoba sisanya hanya membakar waktu dan baterai.
  Future<OutboxSyncResult> flush({int maxBatches = 25}) async {
    if (_running) {
      return const OutboxSyncResult(skipped: true);
    }
    _running = true;

    var sent = 0;
    var failed = 0;
    String? lastError;

    try {
      // Baris yang tertinggal di `syncing` karena app mati dikembalikan ke
      // antrean. Create-only di server membuat kiriman ulang aman.
      await _repository.resetStuckSyncing();

      for (var batch = 0; batch < maxBatches; batch++) {
        final rows = await _repository.pending(limit: batchSize);
        if (rows.isEmpty) {
          break;
        }

        var networkFailed = false;
        for (final transaction in rows) {
          await _repository.markSyncing(transaction.transactionId);
          try {
            // `alreadyExists` juga dihitung terkirim: dokumennya sudah ada,
            // jadi replay tidak pernah menggandakan baris.
            await _remote.create(transaction);
            await _repository.markSynced(transaction.transactionId);
            sent++;
          } catch (error) {
            lastError = error.toString();
            await _repository.markFailed(
              transaction.transactionId,
              lastError,
              delay: retryDelay,
            );
            failed++;
            networkFailed = true;
            break;
          }
        }

        if (networkFailed || rows.length < batchSize) {
          break;
        }
      }
    } finally {
      _running = false;
    }

    final remaining = await _repository.pendingCount();
    if (sent > 0) {
      await _telemetry.logEvent(
        TelemetryEvents.outboxSyncCompleted,
        parameters: {
          'sent': sent,
          'failed': failed,
          'remaining': remaining,
        },
      );
    }
    if (failed > 0) {
      await _telemetry.logEvent(
        TelemetryEvents.outboxSyncFailed,
        parameters: {'failed': failed, 'remaining': remaining},
      );
      await _telemetry.recordError(
        StateError(lastError ?? 'outbox sync failed'),
        null,
        reason: 'outbox_sync_failed',
      );
    }

    return OutboxSyncResult(
      sent: sent,
      failed: failed,
      remaining: remaining,
      error: lastError,
    );
  }

  /// Dipanggil setelah transaksi lokal tersimpan; jangan ditunggu UI.
  Future<void> flushSoon() async {
    await flush(maxBatches: 1);
  }
}
