import 'package:flutter/material.dart';

import '../../core/transactions/stock_transaction.dart';

/// Ikon, warna, dan teks status sync (UX spec §6.1: jangan hanya warna).
class SyncStatusVisual {
  const SyncStatusVisual({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  static SyncStatusVisual of(StockTransaction transaction, ColorScheme scheme) {
    switch (transaction.syncStatus) {
      case 'syncing':
        return SyncStatusVisual(
          icon: Icons.sync,
          label: 'Mengirim…',
          color: scheme.primary,
        );
      case 'synced':
        return SyncStatusVisual(
          icon: Icons.check_circle_outline,
          label: 'Terkirim',
          color: Colors.green.shade700,
        );
      case 'failed':
        final serverRejected =
            (transaction.lastError ?? '').startsWith('Server menolak');
        return SyncStatusVisual(
          icon: Icons.error_outline,
          label: serverRejected
              ? 'Ditolak server — perlu tindakan'
              : 'Gagal — perlu tindakan',
          color: scheme.error,
        );
      default:
        return SyncStatusVisual(
          icon: Icons.schedule,
          label: 'Belum terkirim',
          color: scheme.outline,
        );
    }
  }
}

/// Badge kecil untuk baris histori dan daftar antrean.
class SyncStatusBadge extends StatelessWidget {
  const SyncStatusBadge({super.key, required this.transaction});

  final StockTransaction transaction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visual = SyncStatusVisual.of(transaction, scheme);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(visual.icon, size: 14, color: visual.color),
        const SizedBox(width: 4),
        Text(
          visual.label,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: visual.color),
        ),
      ],
    );
  }
}
