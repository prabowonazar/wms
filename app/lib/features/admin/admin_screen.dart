import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/admin/admin_remote.dart';

/// SCR-19 (Admin): monitoring transaksi ditolak + kelola user.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, required this.remote});

  final AdminRemote remote;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  List<FailedServerTransaction> _failed = const <FailedServerTransaction>[];
  bool _loading = true;
  String? _error;

  final TextEditingController _uid = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  String _role = 'operator';
  bool _active = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _uid.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final failed = await widget.remote.listFailed();
      if (!mounted) {
        return;
      }
      setState(() {
        _failed = failed;
        _loading = false;
      });
    } on AdminException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _retry(FailedServerTransaction item) async {
    final reason = await _askReason('Alasan retry paksa');
    if (reason == null) {
      return;
    }
    try {
      await widget.remote.forceRetry(item.transactionId, reason);
      await _load();
      _snack('Retry paksa dikirim.');
    } on AdminException catch (error) {
      _snack(error.message);
    }
  }

  Future<void> _saveUser() async {
    if (_reason.text.trim().length < 10) {
      _snack('Alasan minimal 10 karakter.');
      return;
    }
    try {
      await widget.remote.updateUser(
        uid: _uid.text.trim(),
        role: _role,
        active: _active,
        reason: _reason.text.trim(),
      );
      _reason.clear();
      _snack('User diperbarui dan tercatat di audit log.');
    } on AdminException catch (error) {
      _snack(error.message);
    }
  }

  Future<String?> _askReason(String title) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
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
            child: const Text('Kirim'),
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
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Admin'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Transaksi ditolak'),
              Tab(text: 'Kelola user'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _loading
                ? const Center(child: CircularProgressIndicator())
                : _failed.isEmpty
                    ? const Center(child: Text('Tidak ada transaksi ditolak.'))
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _failed.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (context, index) {
                          final item = _failed[index];
                          return ListTile(
                            title: Text(item.productLabel),
                            subtitle: Text(
                              '${item.type} ${item.qty} · ${item.reason}',
                            ),
                            trailing: FilledButton.tonal(
                              onPressed: () => _retry(item),
                              child: const Text('Retry paksa'),
                            ),
                          );
                        },
                      ),
            if (_error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextField(
                    controller: _uid,
                    decoration: const InputDecoration(
                      labelText: 'UID Firebase / email user',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _role,
                    decoration: const InputDecoration(
                      labelText: 'Role',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'operator', child: Text('Operator')),
                      DropdownMenuItem(value: 'supervisor', child: Text('Supervisor')),
                      DropdownMenuItem(value: 'admin', child: Text('Admin')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _role = value);
                      }
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Akun aktif'),
                    value: _active,
                    onChanged: (value) => setState(() => _active = value),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _reason,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: 'Alasan perubahan (minimal 10 karakter)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _saveUser,
                    child: const Text('Simpan perubahan'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
