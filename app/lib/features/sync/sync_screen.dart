import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_models.dart';
import '../../core/transactions/outbox_sync.dart';
import '../../core/transactions/stock_conflict.dart';
import '../../core/transactions/stock_transaction.dart';
import '../../core/transactions/sync_summary.dart';
import '../../core/transactions/transaction_remote.dart';
import '../../core/transactions/transaction_repository.dart';
import 'sync_status_badge.dart';

/// SCR-20: status per transaksi + tombol sinkronisasi manual (FR-SYN-03/04).
class SyncScreen extends StatefulWidget {
  const SyncScreen({
    super.key,
    required this.repository,
    required this.outbox,
    required this.profile,
    required this.remote,
  });

  final TransactionRepository repository;
  final OutboxSyncService outbox;
  final UserProfile profile;
  final TransactionRemote remote;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  SyncSummary? _summary;
  List<StockConflict> _conflicts = const <StockConflict>[];
  bool _running = false;
  String? _progress;
  String? _error;

  bool get _isSupervisor => widget.profile.role != UserRole.operator;

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
    if (_isSupervisor) {
      try {
        await widget.outbox.pullConflicts();
      } on Object {
        // Tetap tampilkan cache konflik terakhir bila sedang offline.
      }
    }
    final conflicts = await widget.repository.openConflicts();
    final summary = await widget.repository.syncSummary();
    if (!mounted) {
      return;
    }
    setState(() {
      _summary = summary;
      _conflicts = conflicts;
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

  Future<void> _resolveConflict(StockConflict conflict) async {
    final choice = await showDialog<_ConflictResolution>(
      context: context,
      builder: (context) => const _ConflictDialog(),
    );
    if (choice == null) {
      return;
    }
    try {
      await widget.remote.resolveConflict(
        conflict.conflictId,
        resolution: choice.resolution,
        reason: choice.reason,
        uid: widget.profile.uid,
      );
      await widget.repository.markConflictResolved(
        conflict.conflictId,
        choice.resolution,
        choice.reason,
      );
      await _load();
      if (mounted) {
        _showSnack('Konflik ditutup dan tercatat di audit log.');
      }
    } on Object {
      if (mounted) {
        _showSnack('Gagal menutup konflik. Periksa jaringan lalu coba lagi.');
      }
    }
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
                  if (_isSupervisor && _conflicts.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Konflik saldo (${_conflicts.length})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final conflict in _conflicts)
                      _ConflictTile(
                        conflict: conflict,
                        onResolve: () => _resolveConflict(conflict),
                      ),
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

class _ConflictResolution {
  const _ConflictResolution({
    required this.resolution,
    required this.reason,
  });

  final String resolution;
  final String reason;
}

class _ConflictTile extends StatelessWidget {
  const _ConflictTile({required this.conflict, required this.onResolve});

  final StockConflict conflict;
  final VoidCallback onResolve;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deltaLabel = conflict.delta > 0
        ? '+${conflict.delta}'
        : '${conflict.delta}';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(conflict.label, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Device ${conflict.deviceEndingQty} · '
              'Server ${conflict.serverEndingQty} · Selisih $deltaLabel',
              style: theme.textTheme.bodyMedium,
            ),
            if (conflict.transactionId != null)
              Text(
                'Transaksi pemicu: ${conflict.transactionId}',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: onResolve,
                child: const Text('Selesaikan'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConflictDialog extends StatefulWidget {
  const _ConflictDialog();

  @override
  State<_ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<_ConflictDialog> {
  String _resolution = 'accept_server';
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _reason.text.trim().length >= 10;
    return AlertDialog(
      title: const Text('Selesaikan konflik saldo'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioListTile<String>(
            value: 'accept_server',
            groupValue: _resolution,
            title: const Text('Terima angka server'),
            onChanged: (value) {
              if (value != null) {
                setState(() => _resolution = value);
              }
            },
          ),
          RadioListTile<String>(
            value: 'ignore',
            groupValue: _resolution,
            title: const Text('Abaikan (eskalasi ke admin)'),
            onChanged: (value) {
              if (value != null) {
                setState(() => _resolution = value);
              }
            },
          ),
          TextField(
            controller: _reason,
            autofocus: true,
            maxLength: 200,
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
              ? () => Navigator.of(context).pop(
                    _ConflictResolution(
                      resolution: _resolution,
                      reason: _reason.text.trim(),
                    ),
                  )
              : null,
          child: const Text('Simpan keputusan'),
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
