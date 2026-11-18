import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/observability/telemetry.dart';
import 'search_screen.dart';

enum UnknownReason {
  /// Barcode tidak ada di cache master.
  unknown,

  /// Barcode ada, tetapi produk ditandai nonaktif di server.
  inactive,
}

/// SCR-06: barcode tidak dikenal / produk nonaktif.
class UnknownBarcodeScreen extends StatefulWidget {
  const UnknownBarcodeScreen({
    super.key,
    required this.database,
    required this.telemetry,
    required this.warehouseId,
    required this.userId,
    required this.code,
    required this.reason,
  });

  final Database database;
  final Telemetry telemetry;
  final String warehouseId;
  final String userId;
  final String code;
  final UnknownReason reason;

  @override
  State<UnknownBarcodeScreen> createState() => _UnknownBarcodeScreenState();
}

class _UnknownBarcodeScreenState extends State<UnknownBarcodeScreen> {
  bool _reported = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inactive = widget.reason == UnknownReason.inactive;

    return Scaffold(
      appBar: AppBar(
        title: Text(inactive ? 'Produk tidak aktif' : 'Barang tidak dikenal'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              inactive ? Icons.block : Icons.help_outline,
              size: 64,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              inactive
                  ? 'Produk ini dinonaktifkan admin, jadi tidak bisa dipakai '
                      'untuk transaksi baru.'
                  : 'Barcode tidak ada di master produk perangkat ini. '
                      'Pastikan master sudah disinkronkan, lalu coba lagi.',
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Text('Kode terbaca', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            SelectableText(
              widget.code,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                letterSpacing: 1,
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan ulang'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openSearch,
              icon: const Icon(Icons.keyboard),
              label: const Text('Cari manual'),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _reported ? null : _report,
              icon: const Icon(Icons.flag_outlined),
              label: Text(_reported ? 'Sudah dilaporkan' : 'Lapor admin'),
            ),
          ],
        ),
      ),
    );
  }

  void _openSearch() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => SearchScreen(
          database: widget.database,
          warehouseId: widget.warehouseId,
          initialQuery: widget.code,
        ),
      ),
    );
  }

  Future<void> _report() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await widget.database.insert('error_log', {
      'level': 'warn',
      'code': widget.reason == UnknownReason.inactive
          ? 'INACTIVE_PRODUCT_SCAN'
          : 'UNKNOWN_BARCODE',
      'message': 'Operator melaporkan barcode tidak bisa dipakai.',
      'context': jsonEncode({
        'barcode': widget.code,
        'warehouseId': widget.warehouseId,
        'userId': widget.userId,
      }),
      'created_at': now,
      'sent': 0,
    });
    await widget.telemetry.logEvent(
      TelemetryEvents.unknownBarcodeReported,
      parameters: {
        'reason': widget.reason.name,
        'warehouse_id': widget.warehouseId,
      },
    );
    if (!mounted) {
      return;
    }
    setState(() => _reported = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Laporan tersimpan di perangkat dan ikut terkirim saat online.',
        ),
      ),
    );
  }
}
