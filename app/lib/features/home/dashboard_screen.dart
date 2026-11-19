import 'package:flutter/material.dart';

import '../../core/master/product_repository.dart';
import '../../core/transactions/transaction_repository.dart';

/// SCR ringkas: angka kunci gudang hari ini (FR-RPT-05).
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.products,
    required this.transactions,
  });

  final ProductRepository products;
  final TransactionRepository transactions;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _productCount = 0;
  int _todayCount = 0;
  int _lowStockCount = 0;
  List<String> _lowStockLabels = const <String>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final productCount = await widget.products.productCount();
    final todayCount = await widget.transactions.transactionsTodayCount();
    final lowCount = await widget.products.lowStockCount();
    final views = await widget.products.listWithBalance();
    final low = views
        .where(
          (view) =>
              view.product.minStock > 0 &&
              view.balance <= view.product.minStock,
        )
        .map((view) => '${view.code} · ${view.balance} ${view.uom}')
        .take(5)
        .toList();

    if (!mounted) {
      return;
    }
    setState(() {
      _productCount = productCount;
      _todayCount = todayCount;
      _lowStockCount = lowCount;
      _lowStockLabels = List<String>.unmodifiable(low);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _MetricCard(
                        icon: Icons.inventory_2_outlined,
                        label: 'Total produk',
                        value: '$_productCount',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricCard(
                        icon: Icons.receipt_long_outlined,
                        label: 'Transaksi hari ini',
                        value: '$_todayCount',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _MetricCard(
                  icon: Icons.warning_amber_outlined,
                  label: 'Perlu restock',
                  value: '$_lowStockCount',
                  color: _lowStockCount > 0 ? theme.colorScheme.error : null,
                ),
                if (_lowStockLabels.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Prioritas restock',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final label in _lowStockLabels)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.arrow_right),
                      title: Text(label),
                    ),
                ],
              ],
            ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color ?? theme.colorScheme.primary),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(color: color),
            ),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
