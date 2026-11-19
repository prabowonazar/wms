import 'package:sqflite_common/sqlite_api.dart';

import '../auth/auth_models.dart';
import '../master/product.dart';
import '../sync/uuid7.dart';
import '../transactions/stock_transaction.dart' show periodKeyFor;
import 'cycle_count.dart';

/// Ledger lokal sesi cycle-count (FR-STK-03..06, BR-02/10).
///
/// Semua tulisan terjadi di SQLite sehingga hitung fisik tetap jalan saat
/// airplane mode. Pengiriman ke Firestore dan approval mengikuti di remote.
class CycleCountRepository {
  CycleCountRepository({
    required Database database,
    required String warehouseId,
  })  : _database = database,
        _warehouseId = warehouseId;

  final Database _database;
  final String _warehouseId;

  Future<CycleCountSession?> openSession() async {
    final rows = await _database.query(
      'cycle_counts',
      where: 'warehouse_id = ? AND status = ?',
      whereArgs: [_warehouseId, 'open'],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return CycleCountSession.fromRow(rows.first);
  }

  Future<CycleCountSession?> findSession(String id) async {
    final rows = await _database.query(
      'cycle_counts',
      where: 'cycle_count_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return CycleCountSession.fromRow(rows.first);
  }

  /// BR-10: hanya satu sesi `open` per gudang; pemanggilan ulang mengembalikan
  /// sesi yang sudah ada (idempoten, aman saat offline).
  Future<CycleCountSession> startSession({
    required UserProfile profile,
    DateTime? now,
  }) async {
    final existing = await openSession();
    if (existing != null) {
      return existing;
    }
    final id = uuid7();
    final at = now ?? DateTime.now();
    final millis = at.millisecondsSinceEpoch;
    await _database.insert('cycle_counts', <String, Object?>{
      'cycle_count_id': id,
      'warehouse_id': _warehouseId,
      'period_key': periodKeyFor(at),
      'status': 'open',
      'started_by': profile.uid,
      'started_at': millis,
      'created_at_local': millis,
      'sync_status': 'pending',
    });
    return CycleCountSession(
      id: id,
      warehouseId: _warehouseId,
      periodKey: periodKeyFor(at),
      status: CycleCountStatus.open,
      startedBy: profile.uid,
      startedAt: at,
    );
  }

  Future<List<CycleCountLine>> lines(String sessionId) async {
    final rows = await _database.query(
      'cycle_count_lines',
      where: 'cycle_count_id = ?',
      whereArgs: [sessionId],
      orderBy: 'product_id ASC',
    );
    return rows.map(CycleCountLine.fromRow).toList(growable: false);
  }

  /// Simpan/update satu baris hitungan. `systemQty` snapshot diambil sekali;
  /// hitung ulang produk yang sama memperbarui baris, bukan menambah.
  Future<CycleCountLine> saveLine({
    required CycleCountSession session,
    required ProductView product,
    required int countedQty,
    required UserProfile profile,
    String? note,
    DateTime? now,
  }) async {
    if (!session.isOpen) {
      throw StateError('Sesi sudah dikirim; baris tidak bisa diubah.');
    }
    if (countedQty < 0) {
      throw ArgumentError.value(countedQty, 'countedQty', 'Harus >= 0');
    }
    final existing = await _database.query(
      'cycle_count_lines',
      columns: ['system_qty', 'note'],
      where: 'cycle_count_id = ? AND product_id = ?',
      whereArgs: [session.id, product.product.id],
      limit: 1,
    );
    final systemQty = existing.isEmpty
        ? await _balanceFor(product.product.id)
        : (existing.first['system_qty'] as int?) ?? 0;
    final at = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    final row = <String, Object?>{
      'cycle_count_id': session.id,
      'product_id': product.product.id,
      'product_code': product.product.code,
      'product_name': product.product.name,
      'uom': product.product.uom,
      'system_qty': systemQty,
      'counted_qty': countedQty,
      'counted_by': profile.uid,
      'counted_at': at,
      'note': note?.trim().isEmpty ?? true ? null : note!.trim(),
    };
    await _database.insert(
      'cycle_count_lines',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return CycleCountLine.fromRow({
      ...row,
      'variance': countedQty - systemQty,
    });
  }

  /// Submit sesi. Produk yang tidak dihitung diisi `countedQty = systemQty`;
  /// bila semua variance nol, sesi langsung `approved` tanpa adjustment.
  Future<CycleCountSubmitResult> submitSession({
    required CycleCountSession session,
    required List<ProductView> allProducts,
    required UserProfile profile,
    DateTime? now,
  }) async {
    if (!session.isOpen) {
      throw StateError('Hanya sesi open yang bisa dikirim.');
    }
    final current = await lines(session.id);
    final counted = <String>{for (final line in current) line.productId};
    var autoFilled = 0;
    for (final view in allProducts) {
      if (counted.contains(view.product.id)) {
        continue;
      }
      final systemQty = await _balanceFor(view.product.id);
      await _database.insert('cycle_count_lines', <String, Object?>{
        'cycle_count_id': session.id,
        'product_id': view.product.id,
        'product_code': view.product.code,
        'product_name': view.product.name,
        'uom': view.product.uom,
        'system_qty': systemQty,
        'counted_qty': systemQty,
        'counted_by': profile.uid,
        'counted_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
        'note': CycleCountLine.autoFilledNote,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      autoFilled++;
    }

    final all = await lines(session.id);
    final hasVariance = all.any((line) => line.variance != 0);
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final values = <String, Object?>{
      'status': hasVariance ? 'submitted' : 'approved',
      'submitted_by': profile.uid,
      'submitted_at': at,
      'sync_status': 'pending',
    };
    if (!hasVariance) {
      values['reviewed_by'] = 'system';
      values['reviewed_at'] = at;
    }
    await _database.update(
      'cycle_counts',
      values,
      where: 'cycle_count_id = ?',
      whereArgs: [session.id],
    );

    final updated = await findSession(session.id);
    if (updated == null) {
      throw StateError('Sesi hilang setelah submit.');
    }
    return CycleCountSubmitResult(
      session: updated,
      autoApproved: !hasVariance,
      autoFilledCount: autoFilled,
    );
  }

  /// Buka kembali sesi yang ditolak supervisor untuk dihitung ulang.
  Future<void> reopen(String sessionId) async {
    await _database.update(
      'cycle_counts',
      <String, Object?>{
        'status': 'open',
        'submitted_by': null,
        'submitted_at': null,
        'reviewed_by': null,
        'reviewed_at': null,
        'note': null,
        'sync_status': 'pending',
      },
      where: 'cycle_count_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<List<CycleCountSession>> sessions({int limit = 20}) async {
    final rows = await _database.query(
      'cycle_counts',
      where: 'warehouse_id = ?',
      whereArgs: [_warehouseId],
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map(CycleCountSession.fromRow).toList(growable: false);
  }

  Future<List<CycleCountSession>> pendingSessions({int limit = 10}) async {
    final rows = await _database.query(
      'cycle_counts',
      where: 'warehouse_id = ? AND sync_status <> ?',
      whereArgs: [_warehouseId, 'synced'],
      orderBy: 'started_at ASC',
      limit: limit,
    );
    return rows.map(CycleCountSession.fromRow).toList(growable: false);
  }

  Future<void> markSessionSynced(String sessionId) async {
    await _database.update(
      'cycle_counts',
      <String, Object?>{'sync_status': 'synced', 'last_error': null},
      where: 'cycle_count_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> markSessionFailed(String sessionId, String error) async {
    await _database.update(
      'cycle_counts',
      <String, Object?>{'sync_status': 'failed', 'last_error': error},
      where: 'cycle_count_id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Tulis status akhir hasil approval Server ke cache lokal.
  Future<void> applyServerStatus(
    String sessionId,
    CycleCountStatus status, {
    String? reviewedBy,
  }) async {
    await _database.update(
      'cycle_counts',
      <String, Object?>{
        'status': status.wireName,
        'reviewed_by': reviewedBy,
        'sync_status': 'synced',
      },
      where: 'cycle_count_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<int> _balanceFor(String productId) async {
    final rows = await _database.rawQuery(
      'SELECT ending_qty FROM v_product_balance '
      'WHERE warehouse_id = ? AND product_id = ?',
      [_warehouseId, productId],
    );
    if (rows.isEmpty) {
      return 0;
    }
    final value = rows.first['ending_qty'];
    return value is int ? value : 0;
  }
}
