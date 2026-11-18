import 'package:flutter/material.dart';

import '../../core/master/product.dart';

/// Lembar produk yang terbuka setelah scan/pencarian berhasil.
///
/// VS-1 hanya menampilkan data master + saldo lokal. Tombol masuk/keluar
/// sengaja belum ada karena pencatatan transaksi adalah VS-2 (lihat
/// docs/vertical-slice-backlog.md).
Future<void> showProductSheet(
  BuildContext context, {
  required ProductView view,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => _ProductSheet(view: view),
  );
}

class _ProductSheet extends StatelessWidget {
  const _ProductSheet({required this.view});

  final ProductView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final product = view.product;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    product.code,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Tutup',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(product.name, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Chip(
                  label: Text(product.type),
                  visualDensity: VisualDensity.compact,
                ),
                Chip(
                  label: Text(product.uom),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Saldo saat ini', style: theme.textTheme.bodyMedium),
                  Text(
                    '${view.balance} ${product.uom}',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Saldo dihitung dari transaksi yang tersimpan di perangkat. '
              'Pencatatan barang masuk/keluar menyusul pada tahap '
              'berikutnya.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan lagi'),
            ),
          ],
        ),
      ),
    );
  }
}
