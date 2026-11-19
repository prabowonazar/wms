import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../config/app_config.dart';
import 'cycle_count.dart';

/// Pengiriman sesi cycle-count ke Firestore + callable approval.
abstract class CycleCountRemote {
  Future<void> createSession(CycleCountSession session);
  Future<void> saveLine(
    String sessionId,
    CycleCountLine line, {
    required String countedBy,
  });
  Future<void> submitSession(String sessionId);
  Future<void> approve(String sessionId);
  Future<void> reject(String sessionId, String reason);
}

class FirestoreCycleCountRemote implements CycleCountRemote {
  const FirestoreCycleCountRemote(this._firestore, {this.region = 'asia-southeast2'});

  final FirebaseFirestore _firestore;
  final String region;

  DocumentReference<Map<String, dynamic>> _sessionRef(String id) =>
      _firestore.collection('cycleCounts').doc(id);

  @override
  Future<void> createSession(CycleCountSession session) async {
    await _sessionRef(session.id).set(<String, Object?>{
      'warehouseId': session.warehouseId,
      'periodKey': session.periodKey,
      'status': 'open',
      'startedBy': session.startedBy,
      'startedAt': Timestamp.fromDate(session.startedAt),
      'lineCount': 0,
      'varianceLineCount': 0,
      'totalVarianceQty': 0,
    });
  }

  @override
  Future<void> saveLine(
    String sessionId,
    CycleCountLine line, {
    required String countedBy,
  }) async {
    await _sessionRef(sessionId).collection('countLines').doc(line.productId).set(
      <String, Object?>{
        'productId': line.productId,
        'productCode': line.productCode,
        'productName': line.productName,
        'uom': line.uom,
        'systemQty': line.systemQty,
        'countedQty': line.countedQty,
        'variance': line.variance,
        'countedBy': countedBy,
        'countedAt': Timestamp.fromDate(line.countedAt),
        'note': line.note,
        'approvalStatus': 'none',
        'adjustmentTxnId': null,
      },
    );
  }

  @override
  Future<void> submitSession(String sessionId) async {
    await _sessionRef(sessionId).update(<String, Object?>{'status': 'submitted'});
  }

  Future<Map<String, Object?>> _call(
    String name,
    Map<String, Object?> data,
  ) async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) {
      throw const CycleCountException('auth_required', 'Sesi habis. Masuk kembali.');
    }
    final uri = Uri.parse(
      'https://$region-${AppConfig.projectId}.cloudfunctions.net/$name',
    );
    final client = HttpClient();
    try {
      final request = await client.postUrl(uri)
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
        throw CycleCountException('server_error', message);
      }
      return (decoded['data'] as Map?)?.cast<String, Object?>() ??
          <String, Object?>{};
    } on CycleCountException {
      rethrow;
    } on Object {
      throw const CycleCountException(
        'network_error',
        'Tidak dapat menghubungi server. Periksa jaringan.',
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<void> approve(String sessionId) async {
    await _call('approveCycleCount', <String, Object?>{'sessionId': sessionId});
  }

  @override
  Future<void> reject(String sessionId, String reason) async {
    await _call('rejectCycleCount', <String, Object?>{
      'sessionId': sessionId,
      'reason': reason,
    });
  }
}

class CycleCountException implements Exception {
  const CycleCountException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'CycleCountException($code): $message';
}
