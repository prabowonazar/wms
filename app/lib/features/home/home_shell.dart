import 'dart:async';

import 'package:flutter/material.dart';

import '../../bootstrap/app_services.dart';
import '../../core/admin/admin_remote.dart';
import '../../core/auth/auth_models.dart';
import '../../core/config/app_config.dart';
import '../../core/master/master_sync.dart';
import '../../core/master/product_repository.dart';
import '../../core/transactions/outbox_sync.dart';
import '../../core/transactions/sync_summary.dart';
import '../../core/transactions/transaction_repository.dart';
import '../history/history_screen.dart';
import '../admin/admin_screen.dart';
import '../scan/product_sheet.dart';
import '../scan/scan_screen.dart';
import '../stock/stock_list_screen.dart';
import '../sync/sync_screen.dart';
import 'dashboard_screen.dart';
import 'settings_sheet.dart';

/// Kerangka beranda VS-3: Scan, Histori, Stok, Lainnya + chip status sync.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.services,
    required this.profile,
    this.scannerBuilder,
    this.outboxInterval = const Duration(seconds: 60),
  });

  final AppServices services;
  final UserProfile profile;
  final ScannerBuilder? scannerBuilder;

  /// Berapa sering outbox otomatis dicoba saat aplikasi di depan.
  final Duration outboxInterval;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  SyncSummary? _summary;
  bool _masterSyncing = false;

  late final TransactionRepository _transactions = TransactionRepository(
    database: widget.services.database,
    warehouseId: widget.profile.warehouseId,
  );

  late final OutboxSyncService _outbox = OutboxSyncService(
    repository: _transactions,
    remote: widget.services.transactionRemote,
    telemetry: widget.services.telemetry,
  );

  late final ProductRepository _products = ProductRepository(
    database: widget.services.database,
    warehouseId: widget.profile.warehouseId,
  );

  late final MasterSyncService _master = MasterSyncService(
    database: widget.services.database,
    remote: widget.services.masterRemote,
    warehouseId: widget.profile.warehouseId,
    telemetry: widget.services.telemetry,
  );

  Timer? _timer;
  Timer? _outboxTimer;
  StreamSubscription<OutboxSyncResult>? _subscription;

  @override
  void initState() {
    super.initState();
    unawaited(_outbox.flush());
    unawaited(_loadSummary());
    _subscription = _outbox.results.listen((_) => unawaited(_loadSummary()));
    _timer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_loadSummary()),
    );
    _outboxTimer = Timer.periodic(
      widget.outboxInterval,
      (_) => unawaited(_outbox.flush()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _outboxTimer?.cancel();
    _subscription?.cancel();
    unawaited(_outbox.dispose());
    super.dispose();
  }

  Future<void> _loadSummary() async {
    final summary = await _transactions.syncSummary();
    if (!mounted) {
      return;
    }
    setState(() => _summary = summary);
  }

  Future<void> _resyncMaster() async {
    if (_masterSyncing) {
      return;
    }
    setState(() => _masterSyncing = true);
    try {
      await _master.syncIfNeeded();
    } on Object {
      // ScanScreen sudah punya penanganan error; di sini cukup mengembalikan
      // state tombol agar pengguna bisa mencoba lagi.
    } finally {
      if (mounted) {
        setState(() => _masterSyncing = false);
      }
    }
  }

  Future<void> _openSync() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SyncScreen(
          repository: _transactions,
          outbox: _outbox,
          profile: widget.profile,
          remote: widget.services.transactionRemote,
        ),
      ),
    );
    await _loadSummary();
  }

  Future<void> _openDashboard() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DashboardScreen(
          products: _products,
          transactions: _transactions,
        ),
      ),
    );
  }

  Future<void> _openAdmin() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AdminScreen(remote: AdminRemote()),
      ),
    );
  }

  Future<void> _openSettings() async {
    final last = await _products.lastSyncedAt();
    if (!mounted) {
      return;
    }
    await showSettingsSheet(
      context,
      telemetry: widget.services.telemetry,
      onSignOut: widget.services.auth.signOut,
      profile: widget.profile,
      lastSyncedAt: last,
      syncing: _masterSyncing,
      onResync: _resyncMaster,
    );
  }

  @override
  Widget build(BuildContext context) {
    final deps = ProductSheetDeps(
      transactions: _transactions,
      outbox: _outbox,
      profile: widget.profile,
      telemetry: widget.services.telemetry,
    );

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          ScanScreen(
            database: widget.services.database,
            products: _products,
            sync: _master,
            transactions: _transactions,
            outbox: _outbox,
            telemetry: widget.services.telemetry,
            profile: widget.profile,
            onSignOut: widget.services.auth.signOut,
            scannerBuilder: widget.scannerBuilder,
            remote: widget.services.transactionRemote,
          ),
          HistoryScreen(
            repository: _transactions,
            outbox: _outbox,
            profile: widget.profile,
            telemetry: widget.services.telemetry,
          ),
          StockListScreen(
            products: _products,
            deps: deps,
            remote: widget.services.transactionRemote,
            warehouseId: widget.profile.warehouseId,
          ),
          MoreScreen(
            profile: widget.profile,
            summary: _summary,
            onOpenSync: _openSync,
            onOpenDashboard: _openDashboard,
            onOpenAdmin: _openAdmin,
            onOpenSettings: _openSettings,
            onSignOut: widget.services.auth.signOut,
          ),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SyncStatusChip(
            summary: _summary,
            onTap: _openSync,
          ),
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (index) => setState(() => _index = index),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.qr_code_scanner_outlined),
                selectedIcon: Icon(Icons.qr_code_scanner),
                label: 'Scan',
              ),
              NavigationDestination(
                icon: Icon(Icons.history_outlined),
                selectedIcon: Icon(Icons.history),
                label: 'Histori',
              ),
              NavigationDestination(
                icon: Icon(Icons.inventory_2_outlined),
                selectedIcon: Icon(Icons.inventory_2),
                label: 'Stok',
              ),
              NavigationDestination(
                icon: Icon(Icons.more_horiz),
                label: 'Lainnya',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SyncStatusChip extends StatelessWidget {
  const _SyncStatusChip({required this.summary, required this.onTap});

  final SyncSummary? summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = summary?.failed ?? 0;
    final color = failed > 0 ? theme.colorScheme.error : theme.colorScheme.primary;
    final icon = failed > 0 ? Icons.error_outline : Icons.cloud_outlined;

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  summary?.chipLabel ?? 'Memeriksa status…',
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ),
              const Text('Lihat'),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

/// SCR-21: pintu masuk ke sinkronisasi, pengaturan, dan keluar.
class MoreScreen extends StatelessWidget {
  const MoreScreen({
    super.key,
    required this.profile,
    required this.summary,
    required this.onOpenSync,
    required this.onOpenDashboard,
    required this.onOpenAdmin,
    required this.onOpenSettings,
    required this.onSignOut,
  });

  final UserProfile profile;
  final SyncSummary? summary;
  final VoidCallback onOpenSync;
  final VoidCallback onOpenDashboard;
  final VoidCallback onOpenAdmin;
  final VoidCallback onOpenSettings;
  final Future<void> Function() onSignOut;

  Future<void> _confirmSignOut(BuildContext context) async {
    final unsynced = summary?.unsynced ?? 0;
    if (unsynced > 0) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Keluar dengan data belum terkirim?'),
          content: Text(
            'Ada $unsynced transaksi belum terkirim. Sebaiknya sinkronkan '
            'dulu. Jika tetap keluar, pastikan Anda menyadari risikonya.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Kembali'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Saya paham, tetap keluar'),
            ),
          ],
        ),
      );
      if (proceed != true) {
        return;
      }
    }
    await onSignOut();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Lainnya')),
      body: ListView(
        children: [
          UserAccountsDrawerHeader(
            currentAccountPicture: const CircleAvatar(
              child: Icon(Icons.person),
            ),
            accountName: Text(profile.displayName),
            accountEmail: Text('${profile.role.label} · ${profile.warehouseId}'),
            decoration: BoxDecoration(color: theme.colorScheme.primaryContainer),
            currentAccountPictureSize: const Size.square(48),
          ),
          ListTile(
            leading: const Icon(Icons.dashboard_outlined),
            title: const Text('Dashboard'),
            subtitle: const Text('Ringkasan produk & transaksi hari ini'),
            onTap: onOpenDashboard,
          ),
          if (profile.role == UserRole.admin)
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Admin'),
              subtitle: const Text('User & transaksi ditolak'),
              onTap: onOpenAdmin,
            ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Sinkronisasi'),
            subtitle: Text(summary?.chipLabel ?? 'Memeriksa status…'),
            onTap: onOpenSync,
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Pengaturan & diagnostik'),
            onTap: onOpenSettings,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Keluar'),
            onTap: () => _confirmSignOut(context),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Versi ${AppConfig.appVersion}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
