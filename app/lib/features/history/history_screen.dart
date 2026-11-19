import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_models.dart';
import '../../core/observability/telemetry.dart';
import '../../core/ui/state_views.dart';
import '../../core/transactions/outbox_sync.dart';
import '../../core/transactions/stock_transaction.dart';
import '../../core/transactions/transaction_repository.dart';
import '../sync/sync_status_badge.dart';

/// SCR-10: histori transaksi dengan filter (FR-RPT-01, BR-09).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    required this.repository,
    required this.outbox,
    required this.profile,
    required this.telemetry,
  });

  final TransactionRepository repository;
  final OutboxSyncService outbox;
  final UserProfile profile;
  final Telemetry telemetry;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const int _pageSize = 50;

  int _days = 7;
  TransactionType? _type;
  String _query = '';
  List<StockTransaction> _rows = const <StockTransaction>[];
  bool _loading = false;
  bool _hasMore = false;
  Timer? _debounce;

  bool get _canSeeAll => widget.profile.role != UserRole.operator;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    if (_loading) {
      return;
    }
    setState(() => _loading = true);

    final now = DateTime.now();
    final rows = await widget.repository.history(
      from: _days <= 0 ? null : now.subtract(Duration(days: _days)),
      type: _type,
      userId: _canSeeAll ? null : widget.profile.uid,
      query: _query,
      limit: _pageSize,
      offset: 0,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _rows = rows;
      _hasMore = rows.length == _pageSize;
      _loading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) {
      return;
    }
    setState(() => _loading = true);
    final now = DateTime.now();
    final rows = await widget.repository.history(
      from: _days <= 0 ? null : now.subtract(Duration(days: _days)),
      type: _type,
      userId: _canSeeAll ? null : widget.profile.uid,
      query: _query,
      limit: _pageSize,
      offset: _rows.length,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _rows = <StockTransaction>[..._rows, ...rows];
      _hasMore = rows.length == _pageSize;
      _loading = false;
    });
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_reload());
    });
    setState(() => _query = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Histori'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _loading ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              onChanged: _onQueryChanged,
              decoration: const InputDecoration(
                labelText: 'Cari kode atau nama produk',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                for (final option in <int>[7, 30, 0])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(
                        option == 0 ? 'Semua' : '$option hari',
                      ),
                      selected: _days == option,
                      onSelected: (_) {
                        setState(() => _days = option);
                        unawaited(_reload());
                      },
                    ),
                  ),
                const SizedBox(width: 4),
                DropdownButton<TransactionType?>(
                  value: _type,
                  hint: const Text('Semua jenis'),
                  onChanged: (value) {
                    setState(() => _type = value);
                    unawaited(_reload());
                  },
                  items: [
                    const DropdownMenuItem<TransactionType?>(
                      value: null,
                      child: Text('Semua jenis'),
                    ),
                    for (final type in TransactionType.values)
                      DropdownMenuItem<TransactionType?>(
                        value: type,
                        child: Text(type.label),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (!_canSeeAll)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Hanya transaksi Anda sendiri yang tampil.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          Expanded(
            child: _rows.isEmpty
                ? _loading
                    ? const Center(child: CircularProgressIndicator())
                    : AppEmptyState(
                        title: 'Belum ada transaksi. Mulai dari Scan.',
                        icon: Icons.history,
                      )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: _rows.length + (_hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _rows.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: OutlinedButton(
                            onPressed: _loading ? null : _loadMore,
                            child: Text(_loading ? 'Muat…' : 'Muat lebih banyak'),
                          ),
                        );
                      }
                      final transaction = _rows[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: transaction.signedQty >= 0
                                ? theme.colorScheme.primaryContainer
                                : theme.colorScheme.errorContainer,
                            child: Icon(
                              transaction.signedQty >= 0
                                  ? Icons.south_west
                                  : Icons.north_east,
                            ),
                          ),
                          title: Text(
                            '${transaction.productCode} · '
                            '${transaction.type.label} '
                            '${transaction.qty.abs()} ${transaction.uom}',
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(transaction.productName),
                              const SizedBox(height: 4),
                              Text(
                                '${_formatDateTime(transaction.occurredAt.toLocal())}'
                                ' · ${transaction.userName}',
                              ),
                              const SizedBox(height: 4),
                              SyncStatusBadge(transaction: transaction),
                            ],
                          ),
                          isThreeLine: true,
                          onTap: () => _openDetail(transaction),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _openDetail(StockTransaction transaction) async {
    final reversed = await widget.repository.hasReversal(transaction.transactionId);
    if (!mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _DetailSheet(
        transaction: transaction,
        reversed: reversed,
        canReverse: _canSeeAll &&
            widget.profile.role != UserRole.operator &&
            transaction.type != TransactionType.reversal &&
            transaction.syncStatus == 'synced' &&
            !reversed,
        onReverse: (reason) => _reverse(transaction, reason),
      ),
    );
  }

  Future<void> _reverse(StockTransaction transaction, String reason) async {
    try {
      await widget.repository.recordReversal(
        original: transaction,
        profile: widget.profile,
        reason: reason,
      );
      unawaited(widget.outbox.flushSoon());
      await widget.telemetry.logEvent(
        TelemetryEvents.transactionReversed,
        parameters: {'type': transaction.type.wireName},
      );
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Transaksi dibatalkan.')),
        );
      }
    } on InvalidMovementException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    }
  }
}

class _DetailSheet extends StatelessWidget {
  const _DetailSheet({
    required this.transaction,
    required this.reversed,
    required this.canReverse,
    required this.onReverse,
  });

  final StockTransaction transaction;
  final bool reversed;
  final bool canReverse;
  final Future<void> Function(String reason) onReverse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${transaction.productCode} · ${transaction.type.label}',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(transaction.productName, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            _detail('Jumlah', '${transaction.qty} ${transaction.uom}'),
            _detail('Dampak saldo', '${transaction.signedQty > 0 ? '+' : ''}'
                '${transaction.signedQty} ${transaction.uom}'),
            _detail('Waktu', _formatDateTime(transaction.occurredAt.toLocal())),
            _detail('Periode', transaction.periodKey),
            _detail('Operator', transaction.userName),
            _detail('Sumber', transaction.source),
            if (transaction.note != null && transaction.note!.isNotEmpty)
              _detail('Catatan', transaction.note!),
            if (transaction.refTransactionId != null)
              _detail('Referensi', transaction.refTransactionId!),
            if (transaction.lastError != null)
              _detail('Keterangan', transaction.lastError!),
            const SizedBox(height: 12),
            SyncStatusBadge(transaction: transaction),
            if (reversed) ...[
              const SizedBox(height: 12),
              Text(
                'Transaksi ini sudah dibatalkan.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 20),
            if (canReverse)
              FilledButton.tonalIcon(
                onPressed: () => _askReason(context),
                icon: const Icon(Icons.undo),
                label: const Text('Batalkan transaksi'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _detail(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(label)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Future<void> _askReason(BuildContext context) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _ReasonDialog(),
    );
    if (reason != null) {
      await onReverse(reason);
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog();

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _controller.text.trim().length >= 10;
    return AlertDialog(
      title: const Text('Alasan pembatalan'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Transaksi asli tetap tersimpan. Pembatalan dibuat sebagai '
            'transaksi baru dan dicatat di audit log.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLength: 200,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Alasan (minimal 10 karakter)',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Kembali'),
        ),
        FilledButton(
          onPressed: valid
              ? () => Navigator.of(context).pop(_controller.text.trim())
              : null,
          child: const Text('Batalkan transaksi'),
        ),
      ],
    );
  }
}

String _formatDateTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.day)}/${two(value.month)}/${value.year} '
      '${two(value.hour)}:${two(value.minute)}';
}
