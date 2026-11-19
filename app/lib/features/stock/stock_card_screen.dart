import 'package:flutter/material.dart';

import '../../core/master/product_repository.dart';
import '../../core/transactions/period_stock_card.dart';
import '../../core/transactions/stock_transaction.dart';
import '../../core/transactions/transaction_remote.dart';
import '../../core/transactions/transaction_repository.dart';

/// SCR-13: kartu stok periode. Periode tertutup memakai snapshot server;
/// periode berjalan dihitung dari ledger lokal dan diberi label "sementara".
class StockCardScreen extends StatefulWidget {
  const StockCardScreen({
    super.key,
    required this.products,
    required this.transactions,
    required this.remote,
    required this.warehouseId,
  });

  final ProductRepository products;
  final TransactionRepository transactions;
  final TransactionRemote remote;
  final String warehouseId;

  @override
  State<StockCardScreen> createState() => _StockCardScreenState();
}

class _StockCardScreenState extends State<StockCardScreen> {
  late String _periodKey = periodKeyFor(DateTime.now());
  PeriodInfo? _periodInfo;
  List<PeriodStockCard> _cards = const <PeriodStockCard>[];
  bool _loading = true;
  String? _error;

  List<String> get _periodOptions {
    final now = DateTime.now();
    return List<String>.generate(
      7,
      (index) => periodKeyFor(now.subtract(Duration(days: index))),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await widget.remote.fetchPeriod(
        widget.warehouseId,
        _periodKey,
      );
      final List<PeriodStockCard> cards;
      if (info != null && info.isClosed) {
        cards = await widget.remote.fetchStockCards(
          widget.warehouseId,
          _periodKey,
        );
      } else {
        final products = await widget.products.listWithBalance(onlyActive: false);
        final local = <PeriodStockCard>[];
        for (final view in products) {
          final card = await widget.transactions.stockCardFor(
            view.product.id,
            periodKey: _periodKey,
          );
          if (card == null) {
            continue;
          }
          local.add(
            PeriodStockCard(
              productId: view.product.id,
              periodKey: card.periodKey,
              productCode: view.product.code,
              productName: view.product.name,
              uom: view.product.uom,
              opening: card.opening,
              incoming: card.incoming,
              outgoing: card.outgoing,
              adjustment: card.adjustment,
              ending: card.ending,
            ),
          );
        }
        cards = local;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _periodInfo = info;
        _cards = cards;
        _loading = false;
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Kartu stok tidak dapat dimuat. Periksa jaringan.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final closed = _periodInfo?.isClosed ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kartu stok'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              value: _periodKey,
              decoration: const InputDecoration(
                labelText: 'Periode (WIB)',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final period in _periodOptions)
                  DropdownMenuItem<String>(
                    value: period,
                    child: Text(period),
                  ),
              ],
              onChanged: (value) {
                if (value == null || value == _periodKey) {
                  return;
                }
                setState(() => _periodKey = value);
                unawaited(_load());
              },
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: closed
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                closed
                    ? 'Periode tertutup · snapshot server (read-only)'
                    : 'Sementara · dihitung dari ledger lokal, belum closing',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _cards.isEmpty
                      ? const Center(
                          child: Text('Belum ada mutasi pada periode ini.'),
                        )
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SingleChildScrollView(
                            child: DataTable(
                              columns: const [
                                DataColumn(label: Text('Kode')),
                                DataColumn(label: Text('Nama')),
                                DataColumn(label: Text('Awal'), numeric: true),
                                DataColumn(label: Text('Masuk'), numeric: true),
                                DataColumn(label: Text('Keluar'), numeric: true),
                                DataColumn(label: Text('Adj'), numeric: true),
                                DataColumn(label: Text('Akhir'), numeric: true),
                              ],
                              rows: [
                                for (final card in _cards)
                                  DataRow(
                                    cells: [
                                      DataCell(Text(card.productCode)),
                                      DataCell(Text(card.productName)),
                                      DataCell(Text('${card.opening}')),
                                      DataCell(Text('${card.incoming}')),
                                      DataCell(Text('${card.outgoing}')),
                                      DataCell(Text('${card.adjustment}')),
                                      DataCell(Text('${card.ending}')),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
