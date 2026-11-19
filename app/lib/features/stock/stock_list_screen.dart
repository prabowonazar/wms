import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/master/product.dart';
import '../../core/master/product_repository.dart';
import '../../core/transactions/transaction_remote.dart';
import '../../core/ui/state_views.dart';
import '../scan/product_sheet.dart';
import 'stock_card_screen.dart';

/// SCR-12: daftar stok per produk, dihitung dari ledger lokal.
class StockListScreen extends StatefulWidget {
  const StockListScreen({
    super.key,
    required this.products,
    required this.deps,
    required this.warehouseId,
    this.remote,
  });

  final ProductRepository products;
  final ProductSheetDeps deps;

  /// Sumber snapshot kartu stok periode tertutup (opsional untuk test).
  final TransactionRemote? remote;
  final String warehouseId;

  @override
  State<StockListScreen> createState() => _StockListScreenState();
}

class _StockListScreenState extends State<StockListScreen> {
  List<ProductView>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rows = await widget.products.listWithBalance();
      if (!mounted) {
        return;
      }
      setState(() {
        _rows = rows;
        _error = null;
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'Gagal membaca stok lokal.');
    }
  }

  Future<void> _open(ProductView view) async {
    await showProductSheet(context, view: view, deps: widget.deps);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows;

    final Widget body;
    if (_error != null) {
      body = AppErrorState(message: _error!, onRetry: _load);
    } else if (rows == null) {
      body = const AppLoadingState(label: 'Memuat daftar stok');
    } else if (rows.isEmpty) {
      body = const AppEmptyState(
        title: 'Master produk belum tersinkron.',
        message: 'Hubungi Admin atau buka Pengaturan untuk sync master.',
        icon: Icons.inventory_2_outlined,
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: rows.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final view = rows[index];
          final low = view.product.minStock > 0 &&
              view.balance <= view.product.minStock;
          return ListTile(
            title: Text(view.name),
            subtitle: Text('${view.code} · ${view.type}'),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${view.balance} ${view.uom}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: view.balance < 0 ? theme.colorScheme.error : null,
                  ),
                ),
                if (low)
                  Text(
                    'Di bawah minimum',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
            onTap: () => unawaited(_open(view)),
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stok'),
        actions: [
          if (widget.remote != null)
            IconButton(
              tooltip: 'Kartu stok',
              onPressed: () => unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => StockCardScreen(
                      products: widget.products,
                      transactions: widget.deps.transactions,
                      remote: widget.remote!,
                      warehouseId: widget.warehouseId,
                    ),
                  ),
                ),
              ),
              icon: const Icon(Icons.table_chart_outlined),
            ),
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: () => unawaited(_load()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: body,
    );
  }
}
