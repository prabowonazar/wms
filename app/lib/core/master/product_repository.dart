import 'package:sqflite_common/sqlite_api.dart';

import 'master_sync.dart';
import 'product.dart';

/// Batas umur master sebelum banner peringatan muncul (FR-MST-03).
const Duration masterMaxAge = Duration(hours: 24);

/// `true` bila master belum pernah disinkronkan atau lebih tua dari [maxAge].
///
/// Tepat 24 jam belum dianggap basi: PRD memakai "lebih dari 24 jam".
bool isMasterStale(
  DateTime? lastSyncedAt, {
  DateTime? now,
  Duration maxAge = masterMaxAge,
}) {
  if (lastSyncedAt == null) {
    return true;
  }
  final reference = now ?? DateTime.now();
  return reference.difference(lastSyncedAt) > maxAge;
}

/// Query lokal untuk layar scan & pencarian (VS1-02..05).
///
/// Semua metode hanya membaca SQLite, jadi tetap bekerja saat airplane mode.
class ProductRepository {
  ProductRepository({
    required Database database,
    required String warehouseId,
  })  : _database = database,
        _warehouseId = warehouseId;

  final Database _database;
  final String _warehouseId;

  static const String _selectProduct = 'SELECT p.*, '
      'COALESCE(b.ending_qty, 0) AS ending_qty '
      'FROM products p '
      'LEFT JOIN v_product_balance b '
      'ON b.product_id = p.product_id AND b.warehouse_id = ? ';

  /// Lookup barcode hasil scan. Barcode dinormalisasi lebih dulu.
  ///
  /// Mengembalikan produk nonaktif juga - layar pemanggil yang memutuskan
  /// menampilkan "Produk tidak aktif" (SCR-06) alih-alih lembar produk.
  Future<ProductView?> findByBarcode(String barcode) async {
    final key = normalizeBarcode(barcode);
    if (key.isEmpty) {
      return null;
    }
    final rows = await _database.rawQuery(
      '$_selectProduct '
      'JOIN product_barcodes pb ON pb.product_id = p.product_id '
      'WHERE pb.barcode = ? '
      'LIMIT 1',
      [_warehouseId, key],
    );
    return rows.isEmpty ? null : ProductView.fromRow(rows.first);
  }

  /// Lookup kode produk (untuk input manual / pencarian).
  Future<ProductView?> findByCode(String code) async {
    final key = normalizeCode(code);
    if (key.isEmpty) {
      return null;
    }
    final rows = await _database.rawQuery(
      '$_selectProduct WHERE p.code = ? LIMIT 1',
      [_warehouseId, key],
    );
    return rows.isEmpty ? null : ProductView.fromRow(rows.first);
  }

  /// Input manual boleh berupa kode produk **atau** barcode.
  Future<ProductView?> findByCodeOrBarcode(String value) async {
    final byCode = await findByCode(value);
    if (byCode != null) {
      return byCode;
    }
    return findByBarcode(value);
  }

  /// Cari berdasarkan awalan kode atau potongan nama; hanya produk aktif.
  Future<List<ProductView>> search(String query, {int limit = 30}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const <ProductView>[];
    }
    final codePrefix = '${normalizeCode(trimmed)}%';
    final namePart = '%$trimmed%';

    final rows = await _database.rawQuery(
      '$_selectProduct '
      'WHERE p.active = 1 AND (p.code LIKE ? OR p.name LIKE ?) '
      'ORDER BY CASE WHEN p.code LIKE ? THEN 0 ELSE 1 END, p.code '
      'LIMIT ?',
      [_warehouseId, codePrefix, namePart, codePrefix, limit],
    );
    return rows.map(ProductView.fromRow).toList(growable: false);
  }

  /// Daftar produk + saldo untuk layar stok (SCR-12).
  Future<List<ProductView>> listWithBalance({
    int limit = 500,
    bool onlyActive = true,
  }) async {
    final rows = await _database.rawQuery(
      '$_selectProduct '
      '${onlyActive ? 'WHERE p.active = 1 ' : ''}'
      'ORDER BY p.name LIMIT ?',
      [_warehouseId, limit],
    );
    return rows.map(ProductView.fromRow).toList(growable: false);
  }

  Future<int> productCount() async {
    final rows = await _database.rawQuery(
      'SELECT COUNT(*) AS total FROM products',
    );
    final value = rows.first['total'];
    return value is int ? value : 0;
  }

  /// Jumlah produk aktif dengan saldo di bawah `min_stock` (FR-RPT-05).
  Future<int> lowStockCount() async {
    final rows = await _database.rawQuery(
      'SELECT COUNT(*) AS total FROM products p '
      'LEFT JOIN v_product_balance b '
      'ON b.warehouse_id = ? AND b.product_id = p.product_id '
      'WHERE p.active = 1 AND COALESCE(b.ending_qty, 0) < p.min_stock',
      [_warehouseId],
    );
    final value = rows.first['total'];
    return value is int ? value : 0;
  }

  /// Kursor sync terakhir; dipakai banner "master data usang".
  Future<DateTime?> lastSyncedAt() async {
    final rows = await _database.query(
      'meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [MasterSyncService.lastSyncKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final raw = rows.first['value'];
    final millis = raw is String ? int.tryParse(raw) : null;
    return millis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }
}
