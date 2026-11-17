import 'package:flutter_test/flutter_test.dart';
import 'package:warehouse_mobile/core/auth/auth_models.dart';

void main() {
  group('UserProfile.fromFirestore', () {
    test('membaca field lengkap', () {
      final profile = UserProfile.fromFirestore('uid-1', {
        'name': 'Budi Santoso',
        'email': 'budi@contoh.co.id',
        'role': 'supervisor',
        'warehouseIds': <dynamic>['wh1', 'wh2'],
        'active': true,
      });

      expect(profile.uid, 'uid-1');
      expect(profile.name, 'Budi Santoso');
      expect(profile.role, UserRole.supervisor);
      expect(profile.warehouseIds, ['wh1', 'wh2']);
      expect(profile.warehouseId, 'wh1');
      expect(profile.active, isTrue);
    });

    test('role tidak dikenal melempar FormatException', () {
      expect(
        () => UserProfile.fromFirestore('uid-1', {
          'role': 'owner',
          'warehouseIds': <dynamic>['wh1'],
          'active': true,
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('warehouseIds kosong atau bukan list menjadi list kosong', () {
      final missing = UserProfile.fromFirestore('uid-1', {
        'role': 'operator',
        'active': false,
      });
      expect(missing.warehouseIds, isEmpty);
      expect(missing.warehouseId, '');
      expect(missing.active, isFalse);

      final wrongType = UserProfile.fromFirestore('uid-2', {
        'role': 'operator',
        'warehouseIds': 'wh1',
        'active': true,
      });
      expect(wrongType.warehouseIds, isEmpty);
    });

    test('displayName memakai email bila nama kosong', () {
      final profile = UserProfile.fromFirestore('uid-1', {
        'name': '   ',
        'email': 'op1@contoh.co.id',
        'role': 'operator',
        'warehouseIds': <dynamic>['wh1'],
        'active': true,
      });
      expect(profile.displayName, 'op1@contoh.co.id');
    });
  });

  test('kode dan pesan setiap alasan penolakan unik', () {
    final codes = DenialReason.values.map((reason) => reason.code).toSet();
    final messages =
        DenialReason.values.map((reason) => reason.message).toSet();

    expect(codes.length, DenialReason.values.length);
    expect(messages.length, DenialReason.values.length);
    for (final reason in DenialReason.values) {
      expect(reason.code, isNotEmpty);
      expect(reason.message, isNotEmpty);
    }
  });
}
