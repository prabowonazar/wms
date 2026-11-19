import 'package:warehouse_mobile/core/observability/telemetry.dart';
import 'package:warehouse_mobile/core/transactions/stock_transaction.dart';
import 'package:warehouse_mobile/core/transactions/transaction_remote.dart';

/// Remote palsu: menyimpan dokumen di memori dan bisa dibuat "offline".
class FakeTransactionRemote implements TransactionRemote {
  final Map<String, StockTransaction> stored = <String, StockTransaction>{};

  /// Status yang "dilaporkan server" untuk ID tertentu (mis. `rejected`).
  final Map<String, ServerTransactionState> serverStates =
      <String, ServerTransactionState>{};

  bool offline = false;
  int createCalls = 0;
  int alreadyExisted = 0;
  int fetchCalls = 0;

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

  @override
  Future<Map<String, ServerTransactionState>> fetchStates(
    List<String> transactionIds,
  ) async {
    fetchCalls++;
    if (offline) {
      throw StateError('tidak ada jaringan');
    }
    return <String, ServerTransactionState>{
      for (final id in transactionIds)
        if (serverStates.containsKey(id)) id: serverStates[id]!,
    };
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
