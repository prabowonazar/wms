import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_models.dart';
import '../../core/cycle_count/cycle_count.dart';
import '../../core/cycle_count/cycle_count_repository.dart';
import '../../core/cycle_count/cycle_count_remote.dart';
import '../../core/cycle_count/cycle_count_sync.dart';
import '../../core/master/product.dart';
import '../../core/master/product_repository.dart';

/// SCR-14..17: sesi hitung fisik → review → submit → approval.
class CycleCountScreen extends StatefulWidget {
  const CycleCountScreen({
    super.key,
    required this.repository,
    required this.sync,
    required this.products,
    required this.remote,
    required this.profile,
  });

  final CycleCountRepository repository;
  final CycleCountSyncService sync;
  final ProductRepository products;
  final CycleCountRemote remote;
  final UserProfile profile;

  @override
  State<CycleCountScreen> createState() => _CycleCountScreenState();
}

class _CycleCountScreenState extends State<CycleCountScreen> {
  List<CycleCountSession> _sessions = const <CycleCountSession>[];
  List<ProductView> _products = const <ProductView>[];
  List<CycleCountLine> _lines = const <CycleCountLine>[];
  CycleCountSession? _active;
  ProductView? _selected;
  final TextEditingController _counted = TextEditingController(text: '0');
  bool _loading = true;
  bool _busy = false;

  bool get _canReview =>
      widget.profile.role == UserRole.supervisor ||
      widget.profile.role == UserRole.admin;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _counted.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final sessions = await widget.repository.sessions();
    final products = await widget.products.listWithBalance(onlyActive: false);
    CycleCountSession? active;
    List<CycleCountLine> lines = const <CycleCountLine>[];
    for (final session in sessions) {
      if (session.isOpen) {
        active = session;
        lines = await widget.repository.lines(session.id);
        break;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _sessions = sessions;
      _products = products;
      _active = active;
      _lines = lines;
      _selected ??= products.isEmpty ? null : products.first;
      _loading = false;
    });
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      final session = await widget.repository.startSession(profile: widget.profile);
      try {
        await widget.sync.push(session, submit: false);
      } on Object {
        // Sesi tetap tersimpan lokal; tombol Kirim ulang tersedia.
      }
      await _load();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _saveLine() async {
    final session = _active;
    final product = _selected;
    if (session == null || product == null) {
      return;
    }
    final counted = int.tryParse(_counted.text.trim());
    if (counted == null || counted < 0) {
      _snack('Jumlah fisik harus angka ≥ 0.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.repository.saveLine(
        session: session,
        product: product,
        countedQty: counted,
        profile: widget.profile,
      );
      await _load();
      _snack('Baris tersimpan.');
    } on Object {
      _snack('Gagal menyimpan baris.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _submit() async {
    final session = _active;
    if (session == null) {
      return;
    }
    if (_lines.isEmpty) {
      _snack('Isi minimal satu baris sebelum submit.');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await widget.repository.submitSession(
        session: session,
        allProducts: _products,
        profile: widget.profile,
      );
      try {
        await widget.sync.push(result.session, submit: true);
      } on Object {
        // Status lokal tetap submitted; flush ulang saat app dibuka berikutnya.
      }
      await _load();
      _snack(
        result.autoApproved
            ? 'Semua sesuai. Sesi langsung disetujui tanpa adjustment '
                '(${result.autoFilledCount} produk otomatis).'
            : 'Sesi dikirim. Menunggu persetujuan Supervisor '
                '(${result.autoFilledCount} produk otomatis).',
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _approve(CycleCountSession session) async {
    setState(() => _busy = true);
    try {
      await widget.remote.approve(session.id);
      await widget.repository.applyServerStatus(
        session.id,
        CycleCountStatus.approved,
        reviewedBy: widget.profile.uid,
      );
      await _load();
      _snack('Sesi disetujui; adjustment dibuat bila ada selisih.');
    } on CycleCountException catch (error) {
      _snack(error.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _reject(CycleCountSession session) async {
    final reason = await _askReason();
    if (reason == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.remote.reject(session.id, reason);
      await widget.repository.applyServerStatus(
        session.id,
        CycleCountStatus.rejected,
        reviewedBy: widget.profile.uid,
      );
      await widget.repository.reopen(session.id);
      await _load();
      _snack('Sesi ditolak dan dibuka kembali untuk recount.');
    } on CycleCountException catch (error) {
      _snack(error.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<String?> _askReason() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Alasan penolakan'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 200,
          decoration: const InputDecoration(
            labelText: 'Alasan (minimal 10 karakter)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Kembali'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.length >= 10) {
                Navigator.of(context).pop(text);
              }
            },
            child: const Text('Tolak sesi'),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cycle count'),
        actions: [
          IconButton(
            tooltip: 'Kirim ulang',
            onPressed: _busy
                ? null
                : () async {
                    final pushed = await widget.sync.flushPending();
                    _snack('$pushed sesi berhasil dikirim ulang.');
                    await _load();
                  },
            icon: const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_active == null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Belum ada sesi aktif',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Sesi dibuat untuk ${_products.length} produk. '
                            'Hanya satu sesi boleh aktif per gudang.',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _busy ? null : _start,
                            child: const Text('Mulai sesi baru'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ] else ...[
                  _countingCard(theme),
                  const SizedBox(height: 12),
                  _linesCard(theme),
                ],
                const SizedBox(height: 20),
                Text(
                  'Riwayat sesi',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                for (final session in _sessions) _sessionTile(session, theme),
              ],
            ),
    );
  }

  Widget _countingCard(ThemeData theme) {
    final session = _active!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Sesi ${session.periodKey} · ${_lines.length}/${_products.length} dihitung',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ProductView>(
              value: _selected,
              decoration: const InputDecoration(
                labelText: 'Produk',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final product in _products)
                  DropdownMenuItem<ProductView>(
                    value: product,
                    child: Text('${product.code} · ${product.name}'),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selected = value);
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _counted,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Jumlah fisik',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _busy ? null : _saveLine,
              child: const Text('Simpan hitungan'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: const Text('Review & submit'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _linesCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Baris terhitung', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final line in _lines)
              ListTile(
                dense: true,
                title: Text('${line.productCode} · ${line.productName}'),
                subtitle: Text(
                  'Sistem ${line.systemQty} · Fisik ${line.countedQty}',
                ),
                trailing: Text(
                  '${line.variance > 0 ? '+' : ''}${line.variance}',
                  style: TextStyle(
                    color: line.variance == 0 ? null : theme.colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sessionTile(CycleCountSession session, ThemeData theme) {
    final submitted = session.status == CycleCountStatus.submitted;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text('${session.periodKey} · ${session.status.label}'),
        subtitle: Text(
          'Mulai ${session.startedBy} · sinkron ${session.syncStatus}'
          '${session.note == null ? '' : ' · ${session.note}'}',
        ),
        trailing: submitted && _canReview
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _reject(session),
                    child: const Text('Tolak'),
                  ),
                  FilledButton.tonal(
                    onPressed: _busy ? null : () => _approve(session),
                    child: const Text('Setujui'),
                  ),
                ],
              )
            : null,
      ),
    );
  }
}
