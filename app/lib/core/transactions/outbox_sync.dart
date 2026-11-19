import 'dart:async';

import '../observability/telemetry.dart';
import 'sync_policy.dart';
import 'transaction_remote.dart';
import 'transaction_repository.dart';

class OutboxSyncResult {
  const OutboxSyncResult({
    this.sent = 0,
    this.failed = 0,
    this.rejected = 0,
    this.remaining = 0,
    this.skipped = false,
    this.error,
  });

  final int sent;

  /// Baris yang gagal pada putaran ini (termasuk yang ditolak server).
  final int failed;

  /// Baris yang ditolak server dan tidak akan dicoba otomatis lagi.
  final int rejected;

  final int remaining;

  /// `true` bila pemanggilan diabaikan karena kiriman lain sedang berjalan.
  final bool skipped;
  final String? error;

  bool get hasWork => sent > 0 || failed > 0;

  /// Semua baris sudah terkirim setelah putaran ini.
  bool get isClean => remaining == 0;

  String get summary {
    if (skipped) {
      return 'Sinkronisasi sedang berjalan.';
    }
    if (failed > 0) {
      return 'Selesai dengan $failed masalah.';
    }
    if (sent > 0) {
      return '$sent transaksi terkirim.';
    }
    return remaining == 0
        ? 'Semua transaksi sudah terkirim.'
        : 'Tidak ada perubahan. Data menunggu jaringan.';
  }
}

/// Mengirim outbox SQLite ke Firestore, satu batch kecil per putaran.
///
/// WorkManager belum dipakai: pengiriman otomatis berjalan saat app dibuka,
/// setelah transaksi disimpan, dan tiap 60 detik selama app di depan. Batasan
/// ini dicatat di `docs/vertical-slice-backlog.md` (VS2-03).
class OutboxSyncService {
  OutboxSyncService({
    required TransactionRepository repository,
    required TransactionRemote remote,
    required Telemetry telemetry,
    this.batchSize = 20,
    this.maxAttempts = maxSyncAttempts,
    this.retryDelay = syncRetryBaseDelay,
  })  : _repository = repository,
        _remote = remote,
        _telemetry = telemetry;

  final TransactionRepository _repository;
  final TransactionRemote _remote;
  final Telemetry _telemetry;
  final int batchSize;

  /// Batas percobaan otomatis per siklus (FR-SYN-02).
  final int maxAttempts;

  /// Jeda dasar backoff; test memakai `Duration.zero` agar deterministik.
  final Duration retryDelay;

  final StreamController<OutboxSyncResult> _results =
      StreamController<OutboxSyncResult>.broadcast();

  bool _running = false;

  bool get isRunning => _running;

  /// Hasil setiap putaran, dipakai UI untuk memperbarui badge/ringkasan.
  Stream<OutboxSyncResult> get results => _results.stream;

  /// Kirim semua baris `pending`/`syncing` sampai kosong atau jaringan gagal.
  ///
  /// Berhenti pada kegagalan pertama, bukan mencoba 300 transaksi buta: bila
  /// jaringan mati, mencoba sisanya hanya membakar waktu dan baterai.
  Future<OutboxSyncResult> flush({
    int maxBatches = 25,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (_running) {
      return const OutboxSyncResult(skipped: true);
    }
    _running = true;

    var sent = 0;
    var failed = 0;
    var rejected = 0;
    String? lastError;
    final sentIds = <String>[];

    // Perkiraan awal untuk progres "Mengirim x/y". Angka final tetap dari
    // penghitungan ulang setelah putaran selesai.
    late final int startedWith;

    try {
      startedWith = await _repository.pendingCount();
      onProgress?.call(0, startedWith);

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
            await _remote.create(
              transaction,
              // Function membandingkan angka ini dengan saldo server (BR-12).
              deviceEndingQty:
                  (await _repository.balanceFor(transaction.productId))
                      .endingQty,
            );
            await _repository.markSynced(transaction.transactionId);
            sent++;
            sentIds.add(transaction.transactionId);
            onProgress?.call(sent, startedWith);
          } catch (error) {
            lastError = describeSyncError(error);
            final attempt = transaction.retryCount + 1;
            final delay = retryDelayFor(
              attempt,
              base: retryDelay,
              maxAttempts: maxAttempts,
            );
            await _repository.markFailed(
              transaction.transactionId,
              lastError,
              delay: delay,
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

      // Keputusan Function biasanya langsung tersedia; bila belum, pemeriksaan
      // manual di `syncNow`/layar Sinkronisasi yang mengejar ketertinggalan.
      if (sentIds.isNotEmpty) {
        rejected += await _applyServerStates(sentIds);
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
          'rejected': rejected,
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

    final result = OutboxSyncResult(
      sent: sent,
      failed: failed,
      rejected: rejected,
      remaining: remaining,
      error: lastError,
    );
    if (!_results.isClosed) {
      _results.add(result);
    }
    return result;
  }

  /// Tombol "Sync sekarang" (FR-SYN-04).
  ///
  /// Selain mengirim antrean, menarik keputusan server untuk transaksi yang
  /// terkirim dalam 24 jam terakhir, sehingga penolakan tidak hilang diam-diam.
  Future<OutboxSyncResult> syncNow({
    void Function(int sent, int total)? onProgress,
  }) async {
    final result = await flush(onProgress: onProgress);
    if (!result.skipped) {
      await refreshServerStates();
    }
    return result;
  }

  /// Tarik `serverStatus` terbaru untuk transaksi yang baru terkirim.
  ///
  /// Mengembalikan jumlah transaksi yang ternyata ditolak server. Aman
  /// dipanggil berulang: baris yang sudah `synced` hanya berubah bila server
  /// menyatakan `rejected`.
  Future<int> refreshServerStates() async {
    final rows = await _repository.recentlySynced(limit: 20);
    if (rows.isEmpty) {
      return 0;
    }
    return _applyServerStates(
      rows.map((row) => row.transactionId).toList(growable: false),
    );
  }

  /// Tarik konflik saldo terbuka dari Firestore ke cache lokal (VS3-04).
  ///
  /// Hanya dipanggil untuk Supervisor; rules menolak pembacaan oleh operator.
  Future<int> pullConflicts() async {
    final conflicts = await _remote.openConflicts();
    await _repository.replaceOpenConflicts(conflicts);
    return conflicts.length;
  }

  Future<int> _applyServerStates(List<String> ids) async {
    Map<String, ServerTransactionState> states;
    try {
      states = await _remote.fetchStates(ids);
    } on Object {
      // Gagal membaca status tidak boleh membuat transaksi yang sudah terkirim
      // terlihat gagal. Percobaan berikutnya akan menariknya lagi.
      return 0;
    }

    var rejected = 0;
    for (final entry in states.entries) {
      if (!entry.value.isRejected) {
        continue;
      }
      final reason = entry.value.rejectedReason;
      final message = reason == null || reason.trim().isEmpty
          ? 'Server menolak transaksi ini.'
          : 'Server menolak: ${reason.trim()}';
      await _repository.markRejected(entry.key, message);
      rejected++;
    }
    return rejected;
  }

  /// Dipanggil setelah transaksi lokal tersimpan; jangan ditunggu UI.
  Future<void> flushSoon() async {
    await flush(maxBatches: 1);
  }

  Future<void> dispose() async {
    await _results.close();
  }
}
