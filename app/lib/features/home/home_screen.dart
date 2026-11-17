import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../../bootstrap/app_services.dart';
import '../../core/auth/auth_models.dart';
import '../../core/auth/role_policy.dart';
import '../../core/config/app_config.dart';

const Map<String, IconData> _menuIcons = {
  'scan': Icons.qr_code_scanner,
  'stock': Icons.inventory_2_outlined,
  'history': Icons.receipt_long_outlined,
  'sync': Icons.sync,
  'approval': Icons.fact_check_outlined,
  'reports': Icons.table_chart_outlined,
  'users': Icons.group_outlined,
  'master': Icons.category_outlined,
  'monitoring': Icons.monitor_heart_outlined,
};

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.services,
    required this.profile,
  });

  final AppServices services;
  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final menu = RolePolicy.menuFor(profile.role);

    return Scaffold(
      appBar: AppBar(
        title: Text('Beranda ${profile.role.label}'),
        actions: [
          IconButton(
            tooltip: 'Pengaturan',
            onPressed: () => _openSettings(context),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: services.auth.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            _ProfileCard(profile: profile),
            const SizedBox(height: 20),
            Text('Menu', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final item in menu)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(_menuIcons[item.id] ?? Icons.widgets_outlined),
                  title: Text(item.title),
                  subtitle: Text(item.subtitle),
                  trailing: Chip(
                    label: Text(item.slice),
                    visualDensity: VisualDensity.compact,
                  ),
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '${item.title} belum aktif di VS-0. '
                          'Dijadwalkan pada ${item.slice}.',
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'VS-0 hanya membuktikan login, role, database '
                      'terenkripsi, dan sinkronisasi dasar. Menu di atas '
                      'menandai slice tempat fiturnya dibangun.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return _SettingsSheet(
          services: services,
          profile: profile,
          onSignOut: () {
            Navigator.of(sheetContext).pop();
            unawaited(_confirmSignOut(context));
          },
        );
      },
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
    await services.auth.signOut();
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                _initials(profile.displayName),
                style: TextStyle(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.displayName,
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(profile.email, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Chip(
                        label: Text(profile.role.label),
                        visualDensity: VisualDensity.compact,
                      ),
                      Chip(
                        label: Text('Gudang ${profile.warehouseId}'),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _initials(String value) {
    final parts = value.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) {
      return '?';
    }
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return '${parts.first.substring(0, 1)}${parts[1].substring(0, 1)}'
        .toUpperCase();
  }
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet({
    required this.services,
    required this.profile,
    required this.onSignOut,
  });

  final AppServices services;
  final UserProfile profile;
  final VoidCallback onSignOut;

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
                  await services.telemetry.crashForTesting();
                },
              ),
            const Divider(),
            FilledButton.tonalIcon(
              onPressed: onSignOut,
              icon: const Icon(Icons.logout),
              label: const Text('Keluar'),
            ),
          ],
        ),
      ),
    );
  }
}
