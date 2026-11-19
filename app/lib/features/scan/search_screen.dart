import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/master/product.dart';
import '../../core/master/product_repository.dart';
import 'product_sheet.dart';

/// SCR-07: pencarian produk dan input kode manual.
///
/// Pencarian menunggu 250 ms setelah ketikan terakhir agar tidak menembak
/// SQLite pada setiap huruf, tetapi hasil tetap terasa instan.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.database,
    required this.warehouseId,
    required this.deps,
    this.initialQuery = '',
    this.debounce = const Duration(milliseconds: 250),
  });

  final Database database;
  final String warehouseId;
  final ProductSheetDeps deps;
  final String initialQuery;
  final Duration debounce;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final ProductRepository _products;
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  List<ProductView> _results = const <ProductView>[];
  bool _searching = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _products = ProductRepository(
      database: widget.database,
      warehouseId: widget.warehouseId,
    );
    if (widget.initialQuery.trim().isNotEmpty) {
      _controller.text = widget.initialQuery;
      unawaited(_runSearch(widget.initialQuery));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      setState(() {
        _results = const <ProductView>[];
        _message = query.isEmpty
            ? null
            : 'Ketik minimal 2 karakter, atau tekan cari untuk kode persis.';
      });
      return;
    }
    _debounce = Timer(widget.debounce, () => unawaited(_runSearch(query)));
  }

  Future<void> _runSearch(String query) async {
    if (!mounted) {
      return;
    }
    setState(() {
      _searching = true;
      _message = null;
    });
    final results = await _products.search(query);
    if (!mounted) {
      return;
    }
    setState(() {
      _searching = false;
      _results = results;
      if (results.isEmpty) {
        _message = 'Tidak ada produk yang cocok dengan "$query".';
      }
    });
  }

  Future<void> _submit(String value) async {
    final query = value.trim();
    if (query.isEmpty) {
      return;
    }
    _debounce?.cancel();
    setState(() {
      _searching = true;
      _message = null;
    });
    final view = await _products.findByCodeOrBarcode(query);
    if (!mounted) {
      return;
    }
    setState(() {
      _searching = false;
      _results = view == null ? const <ProductView>[] : <ProductView>[view];
      _message = view == null
          ? 'Kode "$query" tidak ditemukan. Periksa ejaan atau lapor admin.'
          : null;
    });
    if (view != null && view.product.active) {
      await showProductSheet(context, view: view, deps: widget.deps);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cari produk')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: (value) => unawaited(_submit(value)),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                labelText: 'Kode atau nama barang',
                hintText: 'mis. BRG-001 atau sarung',
                border: const OutlineInputBorder(),
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _controller,
                  builder: (context, value, _) {
                    if (value.text.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return IconButton(
                      tooltip: 'Bersihkan',
                      onPressed: () {
                        _controller.clear();
                        _onChanged('');
                      },
                      icon: const Icon(Icons.clear),
                    );
                  },
                ),
              ),
            ),
          ),
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _message!,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _results.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final view = _results[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(view.name),
                  subtitle: Text('${view.code} - ${view.type}'),
                  trailing: Text(
                    '${view.balance} ${view.uom}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  onTap: () =>
                      showProductSheet(context, view: view, deps: widget.deps),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
