import 'dart:async';

import 'package:flutter/material.dart';

import '../../bootstrap/app_services.dart';
import '../../core/auth/auth_models.dart';
import '../../core/master/master_sync.dart';
import '../../core/master/product_repository.dart';
import '../../core/transactions/outbox_sync.dart';
import '../../core/transactions/transaction_repository.dart';
import '../scan/scan_screen.dart';

/// Beranda setelah login: layar scan (SCR-03) dengan dependensi per gudang
/// pengguna, plus pengiriman outbox otomatis selama aplikasi di depan.
///
/// WorkManager belum dipakai pada VS-2; lihat catatan di
/// `docs/vertical-slice-backlog.md` (VS2-03).
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.services,
    required this.profile,
    this.scannerBuilder,
    this.outboxInterval = const Duration(seconds: 60),
  });

  final AppServices services;
  final UserProfile profile;
  final ScannerBuilder? scannerBuilder;
  final Duration outboxInterval;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TransactionRepository _transactions = TransactionRepository(
    database: widget.services.database,
    warehouseId: widget.profile.warehouseId,
  );

  late final OutboxSyncService _outbox = OutboxSyncService(
    repository: _transactions,
    remote: widget.services.transactionRemote,
    telemetry: widget.services.telemetry,
  );

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_outbox.flush());
    _timer = Timer.periodic(
      widget.outboxInterval,
      (_) => unawaited(_outbox.flush()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScanScreen(
      database: widget.services.database,
      products: ProductRepository(
        database: widget.services.database,
        warehouseId: widget.profile.warehouseId,
      ),
      sync: MasterSyncService(
        database: widget.services.database,
        remote: widget.services.masterRemote,
        warehouseId: widget.profile.warehouseId,
        telemetry: widget.services.telemetry,
      ),
      transactions: _transactions,
      outbox: _outbox,
      telemetry: widget.services.telemetry,
      profile: widget.profile,
      onSignOut: widget.services.auth.signOut,
      scannerBuilder: widget.scannerBuilder,
    );
  }
}
