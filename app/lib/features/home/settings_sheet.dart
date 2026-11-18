import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../../core/auth/auth_models.dart';
import '../../core/config/app_config.dart';
import '../../core/observability/telemetry.dart';

/// Lembar pengaturan dari layar scan: profil, status master, dan keluar.
Future<void> showSettingsSheet(
  BuildContext context, {
  required Telemetry telemetry,
  required Future<void> Function() onSignOut,
  required UserProfile profile,
  required DateTime? lastSyncedAt,
  required bool syncing,
  required Future<void> Function() onResync,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => _SettingsSheet(
      telemetry: telemetry,
      onSignOut: onSignOut,
      profile: profile,
      lastSyncedAt: lastSyncedAt,
      syncing: syncing,
      onResync: () {
        Navigator.of(sheetContext).pop();
        return onResync();
      },
    ),
  );
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet({
    required this.telemetry,
    required this.onSignOut,
    required this.profile,
    required this.lastSyncedAt,
    required this.syncing,
    required this.onResync,
  });

  final Telemetry telemetry;
  final Future<void> Function() onSignOut;
  final UserProfile profile;
  final DateTime? lastSyncedAt;
  final bool syncing;
  final Future<void> Function() onResync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Pengaturan', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline),
              title: Text(profile.displayName),
              subtitle: Text(profile.email),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Role'),
              trailing: Text(profile.role.label),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.warehouse_outlined),
              title: const Text('Gudang'),
              trailing: Text(profile.warehouseId),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sync),
              title: const Text('Master produk'),
              subtitle: Text(
                syncing
                    ? 'Menyinkronkan...'
                    : lastSyncedAt == null
                        ? 'Belum pernah disinkronkan'
                        : 'Terakhir ${_formatLocal(lastSyncedAt!)}',
              ),
              trailing: syncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      tooltip: 'Sinkronkan sekarang',
                      onPressed: () {
                        Navigator.of(context).pop();
                        unawaited(onResync());
                      },
                      icon: const Icon(Icons.refresh),
                    ),
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.info_outline),
              title: Text('Versi aplikasi'),
              trailing: Text(AppConfig.appVersion),
            ),
            if (kDebugMode)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('Uji crash (debug)'),
                subtitle: const Text(
                  'Membuktikan laporan crash sampai ke Crashlytics.',
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  await telemetry.crashForTesting();
                },
              ),
            const Divider(),
            FilledButton.tonalIcon(
              onPressed: () => _confirmSignOut(context),
              icon: const Icon(Icons.logout),
              label: const Text('Keluar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Keluar dari aplikasi?'),
          content: const Text(
            'Transaksi yang belum terkirim tetap tersimpan di perangkat ini. '
            'Anda perlu login lagi untuk melanjutkan.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Keluar'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }
    await onSignOut();
  }

  static String _formatLocal(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
