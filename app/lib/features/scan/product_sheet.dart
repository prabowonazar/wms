import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_models.dart';
import '../../core/master/product.dart';
import '../../core/observability/telemetry.dart';
import '../../core/transactions/outbox_sync.dart';
import '../../core/transactions/stock_transaction.dart';
import '../../core/transactions/transaction_repository.dart';
import '../movement/movement_sheet.dart';

/// Dependensi yang dibutuhkan lembar produk untuk mencatat transaksi.
class ProductSheetDeps {
  const ProductSheetDeps({
    required this.transactions,
    required this.outbox,
    required this.profile,
    required this.telemetry,
  });

  final TransactionRepository transactions;
  final OutboxSyncService outbox;
  final UserProfile profile;
  final Telemetry telemetry;
}

/// SCR-13/SCR-04: lembar produk dengan saldo, kartu stok hari ini, dan tombol
/// masuk/keluar.
Future<void> showProductSheet(
  BuildContext context, {
  required ProductView view,
  required ProductSheetDeps deps,
  String source = 'scan',
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ProductSheet(view: view, deps: deps, source: source),
  );
}

class _ProductSheet extends StatefulWidget {
  const _ProductSheet({
    required this.view,
    required this.deps,
    required this.source,
  });

  final ProductView view;
  final ProductSheetDeps deps;
  final String source;

  @override
  State<_ProductSheet> createState() => _ProductSheetState();
}

class _ProductSheetState extends State<_ProductSheet> {
  late int _balance = widget.view.balance;
  int _unsynced = 0;
  StockCardDay? _card;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final snapshot =
        await widget.deps.transactions.balanceFor(widget.view.product.id);
    final card = await widget.deps.transactions
        .stockCardFor(widget.view.product.id);
    if (!mounted) {
      return;
    }
    setState(() {
      _balance = snapshot.endingQty;
      _unsynced = snapshot.unsyncedQty;
      _card = card;
    });
  }

  Future<void> _startMovement(TransactionType type) async {
    final saved = await showMovementSheet(
      context,
      view: widget.view,
      transactions: widget.deps.transactions,
      outbox: widget.deps.outbox,
      profile: widget.deps.profile,
      telemetry: widget.deps.telemetry,
      balance: _balance,
      source: widget.source,
    );
    if (!mounted || saved != true) {
      return;
    }
    await _refresh();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Transaksi ${type.label.toLowerCase()} tersimpan.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final product = widget.view.product;
    final card = _card;

    return SafeArea(
      child: SingleChildScrollView(
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
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Saldo saat ini', style: theme.textTheme.bodyMedium),
                      Text(
                        '$_balance ${product.uom}',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  if (_unsynced != 0) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Termasuk $_unsynced ${product.uom} yang belum '
                        'terkirim ke server.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _StockCardSummary(card: card, uom: product.uom),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: () =>
                          unawaited(_startMovement(TransactionType.incoming)),
                      icon: const Icon(Icons.south_west),
                      label: const Text('Masuk'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: FilledButton.tonalIcon(
                      onPressed: () =>
                          unawaited(_startMovement(TransactionType.outgoing)),
                      icon: const Icon(Icons.north_east),
                      label: const Text('Keluar'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextButton.icon(
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

class _StockCardSummary extends StatelessWidget {
  const _StockCardSummary({required this.card, required this.uom});

  final StockCardDay? card;
  final String uom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final day = card;
    if (day == null) {
      return Text(
        'Belum ada transaksi hari ini.',
        style: theme.textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Kartu stok hari ini', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            _Metric(label: 'Awal', value: '${day.opening}'),
            _Metric(label: 'Masuk', value: '${day.incoming}'),
            _Metric(label: 'Keluar', value: '${day.outgoing}'),
            _Metric(label: 'Penyesuaian', value: '${day.adjustment}'),
            _Metric(label: 'Akhir', value: '${day.ending}'),
          ],
        ),
        const SizedBox(height: 2),
        Text('satuan: $uom', style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: theme.textTheme.bodySmall),
        Text(
          value,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}
