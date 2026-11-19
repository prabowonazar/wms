import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

class TelemetryEvents {
  const TelemetryEvents._();

  static const String appOpen = 'app_open';
  static const String loginSuccess = 'login_success';
  static const String loginFailed = 'login_failed';
  static const String loginCancelled = 'login_cancelled';
  static const String dbOpened = 'db_opened';
  static const String dbOpenFailed = 'db_open_failed';

  /// VS1-01/VS1-07: hasil sinkronisasi master produk.
  static const String masterSyncCompleted = 'master_sync_completed';
  static const String masterSyncFailed = 'master_sync_failed';

  /// VS1-07: durasi `scan_start -> product_shown` beserta hasilnya.
  static const String scanCompleted = 'scan_completed';
  static const String unknownBarcodeReported = 'unknown_barcode_reported';

  /// VS2-02/VS2-03: transaksi tersimpan lokal dan hasil kiriman outbox.
  static const String transactionSaved = 'transaction_saved';
  static const String outboxSyncCompleted = 'outbox_sync_completed';
  static const String outboxSyncFailed = 'outbox_sync_failed';
}

/// Titik masuk tunggal untuk analytics & crash reporting.
///
/// Semua implementasi wajib menelan error sendiri: telemetri tidak boleh
/// menjatuhkan alur operator.
abstract class Telemetry {
  Future<void> logEvent(String name, {Map<String, Object>? parameters});

  Future<void> recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  });

  Future<void> setUser(String? uid);

  /// Memicu crash buatan untuk membuktikan Crashlytics menerima laporan
  /// (VS0-06). Hanya dipanggil dari menu debug.
  Future<void> crashForTesting();
}

class NoopTelemetry implements Telemetry {
  const NoopTelemetry();

  @override
  Future<void> logEvent(String name, {Map<String, Object>? parameters}) async {}

  @override
  Future<void> recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) async {}

  @override
  Future<void> setUser(String? uid) async {}

  @override
  Future<void> crashForTesting() async {}
}

class FirebaseTelemetry implements Telemetry {
  const FirebaseTelemetry();

  @override
  Future<void> logEvent(String name, {Map<String, Object>? parameters}) async {
    try {
      await FirebaseAnalytics.instance.logEvent(
        name: name,
        parameters: parameters,
      );
    } catch (_) {
      // Analytics tidak tersedia (mis. build tanpa Firebase): abaikan.
    }
  }

  @override
  Future<void> recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) async {
    try {
      await FirebaseCrashlytics.instance.recordError(
        error,
        stackTrace,
        reason: reason,
        fatal: fatal,
      );
    } catch (_) {
      // Crashlytics tidak tersedia: jangan menutupi error asli.
    }
  }

  @override
  Future<void> setUser(String? uid) async {
    try {
      await FirebaseCrashlytics.instance.setUserIdentifier(uid ?? '');
      await FirebaseAnalytics.instance.setUserId(id: uid);
    } catch (_) {
      // Abaikan.
    }
  }

  @override
  Future<void> crashForTesting() {
    // `crash()` bertipe void di crashlytics 4.x, jadi tidak boleh di-await.
    FirebaseCrashlytics.instance.crash();
    return Future<void>.value();
  }
}
