import 'package:cloud_firestore/cloud_firestore.dart';

import 'product.dart';

/// Satu halaman hasil query master produk.
class MasterPage {
  const MasterPage({
    required this.products,
    required this.newestUpdatedAt,
    required this.hasMore,
  });

  final List<Product> products;

  /// `updatedAt` terbaru pada halaman ini; dipakai sebagai kursor delta.
  final DateTime? newestUpdatedAt;

  /// `true` bila halaman penuh - kemungkinan masih ada data berikutnya.
  final bool hasMore;
}

/// Sumber master produk di server. Dipisah dari Firestore agar sync bisa
/// diuji tanpa emulator.
abstract class MasterRemote {
  Future<MasterPage> fetchProducts({
    required String warehouseId,
    DateTime? updatedAfter,
    int limit = 500,
  });
}

/// Implementasi Firestore: `products` milik gudang, diurutkan `updatedAt`.
///
/// Query ini memakai composite index `products(warehouseIds CONTAINS,
/// updatedAt ASC)` yang sudah ada di `firebase/firestore.indexes.json`.
class FirestoreMasterRemote implements MasterRemote {
  FirestoreMasterRemote(this._firestore);

  final FirebaseFirestore _firestore;

  @override
  Future<MasterPage> fetchProducts({
    required String warehouseId,
    DateTime? updatedAfter,
    int limit = 500,
  }) async {
    Query<Map<String, dynamic>> query = _firestore
        .collection('products')
        .where('warehouseIds', arrayContains: warehouseId);

    if (updatedAfter != null) {
      query = query.where(
        'updatedAt',
        isGreaterThan: Timestamp.fromDate(updatedAfter),
      );
    }

    final snapshot = await query.orderBy('updatedAt').limit(limit).get();
    final products = <Product>[];
    DateTime? newest;

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final updatedAt = _timestamp(data['updatedAt']);
      if (updatedAt == null) {
        // Tanpa `updatedAt` produk tidak bisa ikut delta sync; lebih baik
        // dilewati daripada menyimpan data yang tidak pernah diperbarui.
        continue;
      }

      final barcodes = <String>{};
      final rawBarcodes = data['barcodes'];
      if (rawBarcodes is List<Object?>) {
        for (final raw in rawBarcodes) {
          if (raw is! String) {
            continue;
          }
          final normalized = normalizeBarcode(raw);
          if (normalized.isNotEmpty) {
            barcodes.add(normalized);
          }
        }
      }

      products.add(
        Product(
          id: doc.id,
          code: normalizeCode(_string(data['code'])),
          name: _string(data['name']),
          type: _string(data['type']),
          uom: _string(data['uom']),
          minStock: _int(data['minStock']),
          active: _bool(data['active'], fallback: true),
          updatedAt: updatedAt,
          barcodes: barcodes.toList(growable: false),
        ),
      );

      if (newest == null || updatedAt.isAfter(newest)) {
        newest = updatedAt;
      }
    }

    return MasterPage(
      products: products,
      newestUpdatedAt: newest,
      hasMore: snapshot.docs.length == limit,
    );
  }

  static String _string(Object? value) => value is String ? value : '';

  static int _int(Object? value) => value is num ? value.toInt() : 0;

  static bool _bool(Object? value, {required bool fallback}) =>
      value is bool ? value : fallback;

  static DateTime? _timestamp(Object? value) =>
      value is Timestamp ? value.toDate() : null;
}
