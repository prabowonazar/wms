import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:warehouse_mobile/core/auth/auth_models.dart';
import 'package:warehouse_mobile/core/cycle_count/cycle_count.dart';
import 'package:warehouse_mobile/core/cycle_count/cycle_count_repository.dart';
import 'package:warehouse_mobile/core/master/product.dart';

import 'support/test_database.dart';

const UserProfile operatorProfile = UserProfile(
  uid: 'op1',
  name: 'Operator Satu',
  email: 'op1@example.com',
  role: UserRole.operator,
  warehouseIds: <String>['JKT-01'],
  active: true,
);

ProductView product(String id, String code) => ProductView(
      product: Product(
        id: id,
        code: code,
        name: 'Produk $code',
        type: 'consumable',
        uom: 'box',
        active: true,
        updatedAt: DateTime.utc(2026, 11, 19),
      ),
      balance: 0,
    );

void main() {
  late Database database;
  late CycleCountRepository repository;
  final p1 = product('p1', 'BRG-001');
  final p2 = product('p2', 'BRG-002');

  setUp(() async {
    database = await openTestDatabase();
    for (final view in <ProductView>[p1, p2]) {
      await database.insert('products', {
        'product_id': view.product.id,
        'code': view.product.code,
        'name': view.product.name,
        'type': view.product.type,
        'uom': view.product.uom,
        'min_stock': 0,
        'active': 1,
        'updated_at': DateTime.utc(2026, 11, 19).millisecondsSinceEpoch,
        'synced_at': DateTime.utc(2026, 11, 19).millisecondsSinceEpoch,
      });
    }
    repository = CycleCountRepository(
      database: database,
      warehouseId: 'JKT-01',
    );
  });

  tearDown(() async {
    await database.close();
  });

  test('hanya satu sesi open per gudang (BR-10)', () async {
    final first = await repository.startSession(
      profile: operatorProfile,
      now: DateTime.utc(2026, 11, 19, 2),
    );
    final second = await repository.startSession(profile: operatorProfile);

    expect(second.id, first.id);
    expect(first.status, CycleCountStatus.open);
    expect(first.periodKey, '2026-11-19');
    expect((await database.query('cycle_counts')).length, 1);
  });

  test('hitung ulang produk yang sama memperbarui baris, bukan menambah',
      () async {
    await insertLedgerRow(
      database,
      id: 'tx-in',
      productId: 'p1',
      signedQty: 10,
    );
    final session = await repository.startSession(profile: operatorProfile);

    await repository.saveLine(
      session: session,
      product: p1,
      countedQty: 8,
      profile: operatorProfile,
    );
    await repository.saveLine(
      session: session,
      product: p1,
      countedQty: 12,
      profile: operatorProfile,
    );

    final lines = await repository.lines(session.id);
    expect(lines, hasLength(1));
    expect(lines.single.systemQty, 10);
    expect(lines.single.countedQty, 12);
    expect(lines.single.variance, 2);
  });

  test('semua variance nol langsung approved tanpa adjustment', () async {
    final session = await repository.startSession(profile: operatorProfile);
    await repository.saveLine(
      session: session,
      product: p1,
      countedQty: 0,
      profile: operatorProfile,
    );

    final result = await repository.submitSession(
      session: session,
      allProducts: <ProductView>[p1, p2],
      profile: operatorProfile,
    );

    expect(result.autoApproved, isTrue);
    expect(result.autoFilledCount, 1);
    expect(result.session.status, CycleCountStatus.approved);
    final lines = await repository.lines(session.id);
    expect(lines, hasLength(2));
    expect(lines.last.isAutoFilled, isTrue);
  });

  test('variance bukan nol membuat sesi submitted dan mengunci baris', () async {
    await insertLedgerRow(
      database,
      id: 'tx-in',
      productId: 'p1',
      signedQty: 10,
    );
    final session = await repository.startSession(profile: operatorProfile);
    await repository.saveLine(
      session: session,
      product: p1,
      countedQty: 7,
      profile: operatorProfile,
    );

    final result = await repository.submitSession(
      session: session,
      allProducts: <ProductView>[p1, p2],
      profile: operatorProfile,
    );

    expect(result.autoApproved, isFalse);
    expect(result.session.status, CycleCountStatus.submitted);
    final afterSubmit = await repository.lines(session.id);
    expect(afterSubmit, hasLength(2));
    expect(afterSubmit.firstWhere((line) => line.productId == 'p1').variance, -3);
    expect(
      repository.saveLine(
        session: result.session,
        product: p1,
        countedQty: 9,
        profile: operatorProfile,
      ),
      throwsA(isA<Object>()),
    );
  });

  test('sesi ditolak bisa dibuka ulang untuk recount', () async {
    final session = await repository.startSession(profile: operatorProfile);
    await repository.saveLine(
      session: session,
      product: p1,
      countedQty: 1,
      profile: operatorProfile,
    );
    await repository.submitSession(
      session: session,
      allProducts: <ProductView>[p1],
      profile: operatorProfile,
    );

    await repository.applyServerStatus(
      session.id,
      CycleCountStatus.rejected,
      reviewedBy: 'sv1',
    );
    await repository.reopen(session.id);

    final reopened = await repository.findSession(session.id);
    expect(reopened?.status, CycleCountStatus.open);
    expect(reopened?.reviewedBy, isNull);
  });
}
