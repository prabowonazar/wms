import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_models.dart';
import '../../core/transactions/outbox_sync.dart';
import '../../core/transactions/stock_transaction.dart';
import '../../core/transactions/sync_summary.dart';
import '../../core/transactions/transaction_repository.dart';
import 'sync_status_badge.dart';

/// SCR-20: status per transaksi + tombol sinkronisasi manual (FR-SYN-03/04).
class SyncScreen extends StatefulWidget {
  const SyncScreen({
    super.key,
    required this.repository,
    required this.outbox,
    required this.profile,
  });

  final TransactionRepository repository;
  final OutboxSyncService outbox;
  final UserProfile profile;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  SyncSummary? _summary;
  bool _running = false;
  String? _progress;
  String? _error;

  StreamSubscription<OutboxSyncResult>? _subscription;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _subscription = widget.outbox.results.listen((_) {
      unawaited(_load());
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final summary = await widget.repository.syncSummary();
    if (!mounted) {
      return;
    }
    setState(() {
      _summary = summary;
      _error = null;
    });
  }

  Future<void> _syncNow() async {
    if (_running) {
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _progress = 'Memeriksa antrean…';
    });

    try {
      final result = await widget.outbox.syncNow(
        onProgress: (sent, total) {
          if (!mounted) {
            return;
          }
          setState(() {
            _progress = total <= 0
                ? 'Memeriksa antrean…'
                : 'Mengirim $sent/$total';
          });
        },
      );
      await _load();
      if (!mounted) {
        return;
      }
      _showSnack(result.summary);
    } on Object {
      if (mounted) {
        setState(() => _error = 'Sinkronisasi gagal. Coba lagi.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _retry(StockTransaction transaction) async {
    await widget.repository.retryNow(transaction.transactionId);
    await _syncNow();
  }

  Future<void> _discard(StockTransaction transaction) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Batalkan transaksi?'),
        content: Text(
          '${transaction.productName} · ${transaction.type.label} '
          '${transaction.qty} ${transaction.uom} akan dihapus dari antrean. '
          'Transaksi ini belum pernah diterima server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Kembali'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Hapus dari antrean'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.repository.discardFailed(transaction.transactionId);
    await _load();
    if (mounted) {
      _showSnack('Transaksi dihapus dari antrean.');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sinkronisasi'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _running ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: summary == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _SummaryCard(summary: summary),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: _running ? null : _syncNow,
                      icon: _running
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync),
                      label: Text(
                        _running ? (_progress ?? 'Mengirim…') : 'SYNC SEKARANG',
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (summary.failedItems.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Perlu tindakan (${summary.failed})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final transaction in summary.failedItems)
                      _QueueTile(
                        transaction: transaction,
                        onRetry: () => _retry(transaction),
                        onDiscard: () => _discard(transaction),
                      ),
                  ],
                  if (summary.pendingItems.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Menunggu jaringan (${summary.pending + summary.syncing})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final transaction in summary.pendingItems)
                      _QueueTile(transaction: transaction),
                  ],
                  if (summary.allClear) ...[
                    const SizedBox(height: 32),
                    const _AllClear(),
                  ],
                ],
              ),
            ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final SyncSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = summary.lastSyncedAt?.toLocal();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${summary.unsynced} belum terkirim',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              summary.failed > 0
                  ? '${summary.failed} gagal — perlu aksi'
                  : 'Tidak ada transaksi gagal',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: summary.failed > 0 ? theme.colorScheme.error : null,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${summary.syncedToday} terkirim hari ini',
              style: theme.textTheme.bodyMedium,
            ),
            if (last != null) ...[
              const SizedBox(height: 8),
              Text(
                'Terakhir terkirim ${_formatDateTime(last)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    required this.transaction,
    this.onRetry,
    this.onDiscard,
  });

  final StockTransaction transaction;
  final VoidCallback? onRetry;
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = transaction.lastError;
    final needsAdmin = transaction.syncStatus == 'failed' &&
        transaction.retryCount >= 5 &&
        !(error ?? '').startsWith('Server menolak');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${transaction.productCode} · '
                    '${transaction.type.label} ${transaction.qty.abs()} '
                    '${transaction.uom}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                SyncStatusBadge(transaction: transaction),
              ],
            ),
            const SizedBox(height: 4),
            Text(transaction.productName, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              _formatDateTime(transaction.occurredAt.toLocal()),
              style: theme.textTheme.bodySmall,
            ),
            if (error != null && error.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: transaction.syncStatus == 'failed'
                      ? theme.colorScheme.error
                      : null,
                ),
              ),
            ],
            if (transaction.syncStatus == 'failed') ...[
              const SizedBox(height: 4),
              Text(
                needsAdmin
                    ? 'Gagal ${transaction.retryCount}×. Hubungi admin atau '
                        'coba lagi saat jaringan membaik.'
                    : 'Percobaan ${transaction.retryCount}/5.',
                style: theme.textTheme.bodySmall,
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (onDiscard != null)
                      TextButton(
                        onPressed: onDiscard,
                        child: const Text('Batalkan'),
                      ),
                    const SizedBox(width: 4),
                    FilledButton.tonal(
                      onPressed: onRetry,
                      child: const Text('Coba lagi'),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _AllClear extends StatelessWidget {
  const _AllClear();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(
          Icons.cloud_done_outlined,
          size: 56,
          color: Colors.green.shade700,
        ),
        const SizedBox(height: 12),
        Text('Semua transaksi sudah terkirim.',
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Data tetap tersimpan di perangkat sampai server menerimanya.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}
