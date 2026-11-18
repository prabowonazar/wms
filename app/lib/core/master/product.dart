/// Master produk versi aplikasi (mirror `products/{productId}`).
///
/// Sengaja hanya memuat field yang dipakai layar scan & pencarian. `note`,
/// `warehouseIds`, dan `schemaVersion` tidak dibutuhkan di device.
class Product {
  const Product({
    required this.id,
    required this.code,
    required this.name,
    required this.type,
    required this.uom,
    required this.active,
    required this.updatedAt,
    this.minStock = 0,
    this.barcodes = const <String>[],
  });

  final String id;
  final String code;
  final String name;
  final String type;
  final String uom;
  final int minStock;
  final bool active;
  final DateTime updatedAt;
  final List<String> barcodes;
}

/// Produk + saldo lokal pada gudang pengguna.
///
/// Saldo berasal dari `v_product_balance`, yaitu turunan ledger lokal. Pada
/// VS-1 ledger masih kosong sehingga nilainya 0 - bukan bug, tetapi memang
/// belum ada transaksi yang boleh dibuat.
class ProductView {
  const ProductView({required this.product, required this.balance});

  final Product product;
  final int balance;

  String get code => product.code;
  String get name => product.name;
  String get type => product.type;
  String get uom => product.uom;

  factory ProductView.fromRow(Map<String, Object?> row) {
    final balance = row['ending_qty'];
    return ProductView(
      product: Product(
        id: row['product_id']! as String,
        code: row['code']! as String,
        name: row['name']! as String,
        type: row['type']! as String,
        uom: row['uom']! as String,
        minStock: (row['min_stock'] as int?) ?? 0,
        active: (row['active'] as int?) == 1,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          row['updated_at']! as int,
          isUtc: true,
        ),
      ),
      balance: balance is int ? balance : 0,
    );
  }
}

/// Normalisasi kode produk: buang spasi tepi, ubah ke huruf besar.
///
/// Sama dengan aturan import (docs/product-import-spec.md) dan document ID
/// `barcodes/{barcode}`, sehingga pencarian lokal tidak pernah meleset karena
/// perbedaan huruf besar/kecil atau spasi tak sengaja.
String normalizeCode(String value) => value.trim().toUpperCase();

/// Barcode 1D dibaca dalam huruf besar; QR bisa peka huruf, tetapi master
/// menyimpan semuanya ternormalisasi agar satu barcode = satu produk
/// (FR-MST-05).
String normalizeBarcode(String value) => normalizeCode(value);
