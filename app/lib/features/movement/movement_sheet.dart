import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/auth/auth_models.dart';
import '../../core/master/product.dart';
import '../../core/observability/telemetry.dart';
import '../../core/sync/uuid7.dart';
import '../../core/transactions/outbox_sync.dart';
import '../../core/transactions/stock_transaction.dart';
import '../../core/transactions/transaction_repository.dart';

/// SCR-04: lembar jenis transaksi + qty. Mengembalikan `true` bila tersimpan.
Future<bool?> showMovementSheet(
  BuildContext context, {
  required ProductView view,
  required TransactionRepository transactions,
  required OutboxSyncService outbox,
  required UserProfile profile,
  required Telemetry telemetry,
  required int balance,
  String source = 'scan',
  TransactionType? initialType,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _MovementSheet(
      view: view,
      transactions: transactions,
      outbox: outbox,
      profile: profile,
      telemetry: telemetry,
      balance: balance,
      source: source,
      initialType: initialType,
    ),
  );
}

class _MovementSheet extends StatefulWidget {
  const _MovementSheet({
    required this.view,
    required this.transactions,
    required this.outbox,
    required this.profile,
    required this.telemetry,
    required this.balance,
    required this.source,
    this.initialType,
  });

  final ProductView view;
  final TransactionRepository transactions;
  final OutboxSyncService outbox;
  final UserProfile profile;
  final Telemetry telemetry;
  final int balance;
  final String source;

  /// Jenis yang sudah dipilih dari tombol lembar produk. `null` bila lembar
  /// dibuka langsung tanpa konteks (pengguna memilih sendiri).
  final TransactionType? initialType;

  @override
  State<_MovementSheet> createState() => _MovementSheetState();
}

class _MovementSheetState extends State<_MovementSheet> {
  /// Satu ID per lembar. Tap ganda memakai ID sama, jadi tetap satu baris
  /// (BR-04). ID juga bertahan saat dialog stok tidak cukup muncul.
  final String _transactionId = uuid7();

  final TextEditingController _qtyController =
      TextEditingController(text: '1');
  final TextEditingController _noteController = TextEditingController();

  late TransactionType? _type = widget.initialType;
  int _qty = 1;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _qtyController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _setQty(int value) {
    final next = value < 1 ? 1 : value;
    setState(() {
      _qty = next;
      _qtyController.text = '$next';
      _error = null;
    });
  }

  void _onQtyChanged(String raw) {
    final parsed = int.tryParse(raw);
    setState(() {
      _qty = parsed ?? 0;
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_saving) {
      return;
    }
    final type = _type;
    if (type == null) {
      setState(() => _error = 'Pilih Masuk atau Keluar dulu.');
      return;
    }
    if (_qty <= 0) {
      setState(() => _error = 'Qty harus lebih dari 0.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await _save(type);
    } on InsufficientStockException catch (error) {
      if (!mounted) {
        return;
      }
      // Hentikan spinner sebelum dialog: indikator yang terus berputar membuat
      // layar uji tidak pernah "settle" dan pengguna mengira masih menyimpan.
      setState(() => _saving = false);
      final overrideReason = await _askOverride(error);
      if (overrideReason == null) {
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() => _saving = true);
      try {
        await _save(type, overrideReason: overrideReason);
      } on Object catch (retryError) {
        if (!mounted) {
          return;
        }
        setState(() {
          _saving = false;
          _error = retryError is InvalidMovementException
              ? retryError.message
              : 'Gagal menyimpan. Coba lagi.';
        });
      }
    } on InvalidMovementException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _error = error.message;
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _error = 'Gagal menyimpan. Coba lagi.';
      });
    }
  }

  Future<void> _save(
    TransactionType type, {
    String? overrideReason,
  }) async {
    await widget.transactions.recordMovement(
      transactionId: _transactionId,
      product: widget.view,
      type: type,
      qty: _qty,
      profile: widget.profile,
      source: widget.source,
      note: _noteController.text,
      overrideReason: overrideReason,
    );

    await widget.telemetry.logEvent(
      TelemetryEvents.transactionSaved,
      parameters: {
        'type': type.wireName,
        'qty': _qty,
        'override': overrideReason == null ? 0 : 1,
      },
    );
    unawaited(widget.outbox.flushSoon());

    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  /// SCR-08 + SCR-09. Operator hanya diarahkan mengubah qty; supervisor boleh
  /// mengisi alasan override (BR-03).
  Future<String?> _askOverride(InsufficientStockException error) {
    final canOverride = widget.profile.role == UserRole.supervisor ||
        widget.profile.role == UserRole.admin;

    return showDialog<String>(
      context: context,
      builder: (_) => _OverrideDialog(error: error, canOverride: canOverride),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final product = widget.view.product;
    final valid = _type != null && _qty > 0;
    final remaining = widget.balance - _qty;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
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
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(product.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${product.type} · ${product.uom}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Saldo saat ini', style: theme.textTheme.bodyMedium),
                Text(
                  '${widget.balance} ${product.uom}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            SegmentedButton<TransactionType>(
              segments: const [
                ButtonSegment<TransactionType>(
                  value: TransactionType.incoming,
                  label: Text('MASUK'),
                  icon: Icon(Icons.south_west),
                ),
                ButtonSegment<TransactionType>(
                  value: TransactionType.outgoing,
                  label: Text('KELUAR'),
                  icon: Icon(Icons.north_east),
                ),
              ],
              selected: _type == null ? const <TransactionType>{} : {_type!},
              emptySelectionAllowed: true,
              onSelectionChanged: _saving
                  ? null
                  : (selection) => setState(() {
                        _type = selection.isEmpty ? null : selection.first;
                        _error = null;
                      }),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  tooltip: 'Kurangi',
                  onPressed: _saving ? null : () => _setQty(_qty - 1),
                  icon: const Icon(Icons.remove),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _qtyController,
                    enabled: !_saving,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: theme.textTheme.headlineSmall,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: _onQtyChanged,
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  tooltip: 'Tambah',
                  onPressed: _saving ? null : () => _setQty(_qty + 1),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'qty (${product.uom})',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            if (_type == TransactionType.outgoing) ...[
              const SizedBox(height: 8),
              Text(
                'Sisa: $remaining ${product.uom}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: remaining < 0 ? theme.colorScheme.error : null,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              enabled: !_saving,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Catatan (opsional)',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(
                _error!,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: valid && !_saving ? _submit : null,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('SIMPAN'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LabeledRow extends StatelessWidget {
  const _LabeledRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(
            value,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _OverrideDialog extends StatefulWidget {
  const _OverrideDialog({required this.error, required this.canOverride});

  final InsufficientStockException error;
  final bool canOverride;

  @override
  State<_OverrideDialog> createState() => _OverrideDialogState();
}

class _OverrideDialogState extends State<_OverrideDialog> {
  final TextEditingController _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = widget.error;
    final reason = _reasonController.text.trim();

    return AlertDialog(
      title: const Text('Stok tidak cukup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(error.productName),
          const SizedBox(height: 8),
          _LabeledRow(
            label: 'Saldo saat ini',
            value: '${error.balance} ${error.uom}',
          ),
          _LabeledRow(
            label: 'Diminta',
            value: '${error.requested} ${error.uom}',
          ),
          _LabeledRow(
            label: 'Kurang',
            value: '${error.shortage} ${error.uom}',
          ),
          const SizedBox(height: 8),
          Text(
            widget.canOverride
                ? 'Periksa jumlah fisik. Override wajib disertai alasan dan '
                    'tercatat di audit log.'
                : 'Periksa jumlah fisik, atau minta supervisor melakukan '
                    'override.',
            style: theme.textTheme.bodySmall,
          ),
          if (widget.canOverride) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _reasonController,
              autofocus: true,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Alasan override',
                hintText: 'Mis. barang sudah keluar tapi belum dicatat',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Ubah qty'),
        ),
        if (widget.canOverride)
          FilledButton(
            onPressed: reason.length < 10
                ? null
                : () => Navigator.of(context).pop(reason),
            child: const Text('Override'),
          ),
      ],
    );
  }
}
