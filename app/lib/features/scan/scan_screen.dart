import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/auth/auth_models.dart';
import '../../core/master/master_sync.dart';
import '../../core/master/product.dart';
import '../../core/master/product_repository.dart';
import '../../core/observability/telemetry.dart';
import '../../core/transactions/outbox_sync.dart';
import '../../core/transactions/transaction_remote.dart';
import '../../core/transactions/transaction_repository.dart';
import '../home/settings_sheet.dart';
import '../stock/stock_list_screen.dart';
import 'product_sheet.dart';
import 'scanner_panel.dart';
import 'search_screen.dart';
import 'unknown_barcode_screen.dart';

/// Membangun area kamera. Test menyuntikkan widget palsu yang memanggil
/// [onCode] tanpa perlu kamera fisik.
typedef ScannerBuilder = Widget Function(
  BuildContext context,
  ValueChanged<String> onCode,
);

/// SCR-03: beranda operator - scan barcode, saldo, dan status master.
class ScanScreen extends StatefulWidget {
  const ScanScreen({
    super.key,
    required this.database,
    required this.products,
    required this.sync,
    required this.transactions,
    required this.outbox,
    required this.telemetry,
    required this.profile,
    required this.onSignOut,
    this.scannerBuilder,
    this.remote,
  });

  final Database database;
  final ProductRepository products;
  final MasterSyncService sync;
  final TransactionRepository transactions;
  final OutboxSyncService outbox;
  final Telemetry telemetry;
  final UserProfile profile;
  final Future<void> Function() onSignOut;
  final ScannerBuilder? scannerBuilder;

  /// Remote untuk mengambil snapshot kartu stok periode tertutup.
  final TransactionRemote? remote;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  /// Barcode sama yang terbaca lagi dalam jendela ini diabaikan (VS1-02).
  static const Duration _duplicateWindow = Duration(milliseconds: 800);

  DateTime? _lastSyncedAt;
  bool _syncing = false;
  String? _syncError;

  String? _lastCode;
  DateTime? _lastCodeAt;
  bool _sheetOpen = false;

  ProductSheetDeps get _deps => ProductSheetDeps(
        transactions: widget.transactions,
        outbox: widget.outbox,
        profile: widget.profile,
        telemetry: widget.telemetry,
      );

  @override
  void initState() {
    super.initState();
    unawaited(_loadMasterState());
  }

  Future<void> _loadMasterState() async {
    final last = await widget.products.lastSyncedAt();
    if (!mounted) {
      return;
    }
    setState(() => _lastSyncedAt = last);
    if (isMasterStale(last)) {
      await _syncMaster(silent: true);
    }
  }

  Future<void> _syncMaster({bool silent = false}) async {
    if (_syncing) {
      return;
    }
    setState(() {
      _syncing = true;
      _syncError = null;
    });

    try {
      final result = await widget.sync.syncIfNeeded();
      final last = result.lastSyncedAt ?? await widget.products.lastSyncedAt();
      if (!mounted) {
        return;
      }
      setState(() => _lastSyncedAt = last);
      if (!silent) {
        _showSnack(
          'Master tersinkron: ${result.productCount} produk diperbarui.',
        );
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _syncError = 'Master gagal disinkronkan. Periksa jaringan.';
      });
      if (!silent) {
        _showSnack('Gagal sinkron. Periksa jaringan lalu coba lagi.');
      }
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _handleCode(String raw) async {
    final code = normalizeBarcode(raw);
    if (code.isEmpty || _sheetOpen) {
      return;
    }

    final now = DateTime.now();
    final lastAt = _lastCodeAt;
    if (_lastCode == code &&
        lastAt != null &&
        now.difference(lastAt) < _duplicateWindow) {
      return;
    }
    _lastCode = code;
    _lastCodeAt = now;

    final started = DateTime.now();
    final view = await widget.products.findByBarcode(code);
    final durationMs = DateTime.now().difference(started).inMilliseconds;
    if (!mounted) {
      return;
    }

    if (view == null) {
      unawaited(_recordScan(durationMs, 'unknown'));
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UnknownBarcodeScreen(
            database: widget.database,
            telemetry: widget.telemetry,
            warehouseId: widget.profile.warehouseId,
            userId: widget.profile.uid,
            code: code,
            reason: UnknownReason.unknown,
            deps: _deps,
          ),
        ),
      );
      _resetDebounce();
      return;
    }

    if (!view.product.active) {
      unawaited(_recordScan(durationMs, 'inactive'));
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UnknownBarcodeScreen(
            database: widget.database,
            telemetry: widget.telemetry,
            warehouseId: widget.profile.warehouseId,
            userId: widget.profile.uid,
            code: code,
            reason: UnknownReason.inactive,
            deps: _deps,
          ),
        ),
      );
      _resetDebounce();
      return;
    }

    unawaited(_recordScan(durationMs, 'found'));
    _sheetOpen = true;
    await showProductSheet(context, view: view, deps: _deps);
    _sheetOpen = false;
    _resetDebounce();
  }

  Future<void> _recordScan(int durationMs, String result) {
    return widget.telemetry.logEvent(
      TelemetryEvents.scanCompleted,
      parameters: {'duration_ms': durationMs, 'result': result},
    );
  }

  void _resetDebounce() {
    _lastCode = null;
    _lastCodeAt = null;
  }

  void _openSearch() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SearchScreen(
            database: widget.database,
            warehouseId: widget.profile.warehouseId,
            deps: _deps,
          ),
        ),
      ),
    );
  }

  void _openStockList() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => StockListScreen(
            products: widget.products,
            deps: _deps,
            remote: widget.remote,
            warehouseId: widget.profile.warehouseId,
          ),
        ),
      ),
    );
  }

  void _openSettings() {
    unawaited(
      showSettingsSheet(
        context,
        telemetry: widget.telemetry,
        onSignOut: widget.onSignOut,
        profile: widget.profile,
        lastSyncedAt: _lastSyncedAt,
        syncing: _syncing,
        onResync: () => _syncMaster(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = _lastSyncedAt;
    final stale = isMasterStale(last);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan'),
        actions: [
          IconButton(
            tooltip: 'Daftar stok',
            onPressed: _openStockList,
            icon: const Icon(Icons.inventory_2_outlined),
          ),
          if (_syncing)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Pengaturan',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          children: [
            if (stale)
              _StaleMasterBanner(
                lastSyncedAt: last,
                syncing: _syncing,
                error: _syncError,
                onSync: () => unawaited(_syncMaster()),
              ),
            Expanded(
              child: widget.scannerBuilder?.call(context, _handleCode) ??
                  ScannerPanel(onCode: _handleCode),
            ),
            const SizedBox(height: 8),
            Text(
              'Arahkan kamera ke barcode',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _openSearch,
                icon: const Icon(Icons.keyboard),
                label: const Text('Input manual'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StaleMasterBanner extends StatelessWidget {
  const _StaleMasterBanner({
    required this.lastSyncedAt,
    required this.syncing,
    required this.error,
    required this.onSync,
  });

  final DateTime? lastSyncedAt;
  final bool syncing;
  final String? error;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = lastSyncedAt;
    final title = last == null
        ? 'Master produk belum diunduh'
        : 'Master produk ${DateTime.now().difference(last).inHours} jam lalu';

    return Card(
      color: theme.colorScheme.tertiaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_outlined, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyMedium),
                  if (error != null)
                    Text(
                      error!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                ],
              ),
            ),
            if (syncing)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton(
                onPressed: onSync,
                child: const Text('Sync sekarang'),
              ),
          ],
        ),
      ),
    );
  }
}
