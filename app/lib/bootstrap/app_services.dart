import 'package:sqflite_common/sqlite_api.dart';

import '../core/auth/auth_repository.dart';
import '../core/master/master_remote.dart';
import '../core/observability/telemetry.dart';
import '../core/storage/profile_cache.dart';
import '../core/transactions/transaction_remote.dart';

/// Dependency yang hidup selama proses aplikasi berjalan.
class AppServices {
  const AppServices({
    required this.database,
    required this.profileCache,
    required this.auth,
    required this.telemetry,
    required this.masterRemote,
    required this.transactionRemote,
  });

  final Database database;
  final ProfileCache profileCache;
  final AuthRepository auth;
  final Telemetry telemetry;
  final MasterRemote masterRemote;

  /// Pengiriman transaksi global; repository per gudang dibuat setelah login
  /// karena butuh `warehouseId` pengguna.
  final TransactionRemote transactionRemote;

  Future<void> dispose() async {
    await auth.dispose();
    await database.close();
  }
}
