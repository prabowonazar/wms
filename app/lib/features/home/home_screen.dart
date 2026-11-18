import 'package:flutter/material.dart';

import '../../bootstrap/app_services.dart';
import '../../core/auth/auth_models.dart';
import '../../core/master/master_sync.dart';
import '../../core/master/product_repository.dart';
import '../scan/scan_screen.dart';

/// Beranda setelah login: layar scan (SCR-03) dengan dependensi per gudang
/// pengguna.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.services,
    required this.profile,
    this.scannerBuilder,
  });

  final AppServices services;
  final UserProfile profile;
  final ScannerBuilder? scannerBuilder;

  @override
  Widget build(BuildContext context) {
    return ScanScreen(
      database: services.database,
      products: ProductRepository(
        database: services.database,
        warehouseId: profile.warehouseId,
      ),
      sync: MasterSyncService(
        database: services.database,
        remote: services.masterRemote,
        warehouseId: profile.warehouseId,
        telemetry: services.telemetry,
      ),
      telemetry: services.telemetry,
      profile: profile,
      onSignOut: services.auth.signOut,
      scannerBuilder: scannerBuilder,
    );
  }
}
