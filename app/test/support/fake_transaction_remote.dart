import 'package:warehouse_mobile/core/observability/telemetry.dart';
import 'package:warehouse_mobile/core/transactions/stock_transaction.dart';
import 'package:warehouse_mobile/core/transactions/transaction_remote.dart';

/// Remote palsu: menyimpan dokumen di memori dan bisa dibuat "offline".
class FakeTransactionRemote implements TransactionRemote {
  final Map<String, StockTransaction> stored = <String, StockTransaction>{};
  bool offline = false;
  int createCalls = 0;
  int alreadyExisted = 0;

  @override
  Future<TransactionPushResult> create(StockTransaction transaction) async {
    createCalls++;
    if (offline) {
      throw StateError('tidak ada jaringan');
    }
    if (stored.containsKey(transaction.transactionId)) {
      alreadyExisted++;
      return TransactionPushResult.alreadyExists;
    }
    stored[transaction.transactionId] = transaction;
    return TransactionPushResult.created;
  }
}

/// Telemetri yang mencatat nama event, bukan mengirim ke Firebase.
class RecordingTelemetry implements Telemetry {
  final List<String> events = <String>[];
  final List<String> errors = <String>[];

  @override
  Future<void> logEvent(String name, {Map<String, Object>? parameters}) async {
    events.add(name);
  }

  @override
  Future<void> recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
    bool fatal = false,
  }) async {
    errors.add(reason ?? error.toString());
  }

  @override
  Future<void> setUser(String? uid) async {}

  @override
  Future<void> crashForTesting() async {}
}
