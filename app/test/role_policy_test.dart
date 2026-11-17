import 'package:flutter_test/flutter_test.dart';
import 'package:warehouse_mobile/core/auth/auth_models.dart';
import 'package:warehouse_mobile/core/auth/role_policy.dart';

void main() {
  group('RolePolicy.can', () {
    test('operator hanya boleh scan, lihat stok, dan histori sendiri', () {
      expect(RolePolicy.can(UserRole.operator, AppPermission.scan), isTrue);
      expect(RolePolicy.can(UserRole.operator, AppPermission.viewStock), isTrue);
      expect(
        RolePolicy.can(UserRole.operator, AppPermission.viewOwnHistory),
        isTrue,
      );
      expect(
        RolePolicy.can(UserRole.operator, AppPermission.viewAllHistory),
        isFalse,
      );
      expect(
        RolePolicy.can(UserRole.operator, AppPermission.approveAdjustment),
        isFalse,
      );
      expect(
        RolePolicy.can(UserRole.operator, AppPermission.manageUsers),
        isFalse,
      );
    });

    test('supervisor boleh menyetujui dan melihat semua histori', () {
      expect(
        RolePolicy.can(UserRole.supervisor, AppPermission.approveAdjustment),
        isTrue,
      );
      expect(
        RolePolicy.can(UserRole.supervisor, AppPermission.viewAllHistory),
        isTrue,
      );
      expect(
        RolePolicy.can(UserRole.supervisor, AppPermission.reverseTransaction),
        isTrue,
      );
      expect(
        RolePolicy.can(UserRole.supervisor, AppPermission.manageUsers),
        isFalse,
      );
    });

    test('admin punya semua permission yang dikenal', () {
      for (final permission in AppPermission.values) {
        expect(
          RolePolicy.can(UserRole.admin, permission),
          isTrue,
          reason: 'admin harus punya $permission',
        );
      }
    });
  });

  group('RolePolicy.menuFor', () {
    test('menu tiap role berbeda dan tidak kosong', () {
      final operatorMenu = RolePolicy.menuFor(UserRole.operator);
      final supervisorMenu = RolePolicy.menuFor(UserRole.supervisor);
      final adminMenu = RolePolicy.menuFor(UserRole.admin);

      expect(operatorMenu, isNotEmpty);
      expect(supervisorMenu, isNotEmpty);
      expect(adminMenu, isNotEmpty);

      final operatorIds = operatorMenu.map((item) => item.id).toSet();
      final supervisorIds = supervisorMenu.map((item) => item.id).toSet();
      final adminIds = adminMenu.map((item) => item.id).toSet();

      expect(operatorIds, isNot(equals(adminIds)));
      expect(supervisorIds, isNot(equals(adminIds)));
      expect(operatorIds.contains('users'), isFalse);
      expect(adminIds.contains('users'), isTrue);
    });

    test('setiap item punya slice dan id unik di dalam role', () {
      for (final role in UserRole.values) {
        final menu = RolePolicy.menuFor(role);
        final ids = menu.map((item) => item.id).toList();
        expect(ids.toSet().length, ids.length, reason: 'id duplikat di $role');
        for (final item in menu) {
          expect(item.title, isNotEmpty);
          expect(item.slice, startsWith('VS-'));
        }
      }
    });
  });
}
