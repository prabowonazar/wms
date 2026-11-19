import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';

import '../config/app_config.dart';

/// Satu transaksi yang ditolak server (untuk monitoring Admin).
class FailedServerTransaction {
  const FailedServerTransaction({
    required this.transactionId,
    required this.productLabel,
    required this.type,
    required this.qty,
    required this.reason,
    this.userId = '',
  });

  final String transactionId;
  final String productLabel;
  final String type;
  final int qty;
  final String reason;
  final String userId;
}

/// Pemanggil Cloud Functions callable tanpa paket tambahan.
///
/// Function VS-4 memakai Admin SDK, jadi rules Firestore tidak terlibat;
/// identitas Admin diverifikasi dari token Firebase Auth di server.
class AdminRemote {
  const AdminRemote({this.region = 'asia-southeast2'});

  final String region;

  Uri _uri(String name) => Uri.parse(
        'https://$region-${AppConfig.projectId}.cloudfunctions.net/$name',
      );

  Future<Map<String, Object?>> _call(
    String name,
    Map<String, Object?> data,
  ) async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) {
      throw const AdminException('auth_required', 'Sesi habis. Masuk kembali.');
    }

    final client = HttpClient();
    try {
      final request = await client.postUrl(_uri(name))
        ..headers.contentType = ContentType.json
        ..headers.add('Authorization', 'Bearer $token');
      request.write(jsonEncode(data));
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(body) as Map<String, Object?>;
      if (response.statusCode != 200) {
        final error = decoded['error'];
        final message = error is Map
            ? (error['message'] as String?) ?? 'Permintaan ditolak server.'
            : 'Permintaan ditolak server.';
        throw AdminException('server_error', message);
      }
      final payload = decoded['data'];
      if (payload is! Map<String, Object?>) {
        throw const AdminException('bad_response', 'Balasan server tidak sah.');
      }
      return payload;
    } on AdminException {
      rethrow;
    } on Object {
      throw const AdminException(
        'network_error',
        'Tidak dapat menghubungi server. Periksa jaringan.',
      );
    } finally {
      client.close();
    }
  }

  Future<List<FailedServerTransaction>> listFailed() async {
    final data = await _call('adminListFailed', const <String, Object?>{});
    final items = data['items'];
    if (items is! List) {
      return const <FailedServerTransaction>[];
    }
    return items.whereType<Map>().map((raw) {
      return FailedServerTransaction(
        transactionId: (raw['transactionId'] as String?) ?? '',
        productLabel: [
          raw['productCode'],
          raw['productName'],
        ].whereType<String>().join(' · '),
        type: (raw['type'] as String?) ?? '',
        qty: (raw['qty'] as int?) ?? 0,
        reason: (raw['rejectedReason'] as String?) ?? '',
        userId: (raw['userId'] as String?) ?? '',
      );
    }).toList(growable: false);
  }

  Future<void> forceRetry(String transactionId, String reason) async {
    await _call('adminForceRetry', <String, Object?>{
      'transactionId': transactionId,
      'reason': reason,
    });
  }

  Future<void> updateUser({
    required String uid,
    String? role,
    bool? active,
    required String reason,
  }) async {
    await _call('adminUpdateUser', <String, Object?>{
      'uid': uid,
      if (role != null) 'role': role,
      if (active != null) 'active': active,
      'reason': reason,
    });
  }
}

class AdminException implements Exception {
  const AdminException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'AdminException($code): $message';
}
