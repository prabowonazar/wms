import 'auth_models.dart';

/// Hak akses per role (PRD §4.1, FR-AUTH-04).
///
/// UI memakai ini untuk menyembunyikan aksi, tetapi keputusan akhir tetap di
/// Firestore Rules dan Function. Jangan pernah mengandalkan UI saja.
enum AppPermission {
  scan,
  viewStock,
  viewOwnHistory,
  viewAllHistory,
  reverseTransaction,
  approveAdjustment,
  resolveConflict,
  manageUsers,
  manageMasterData,
  exportReports,
}

/// Satu baris menu beranda.
///
/// [slice] menandai kapan menu benar-benar aktif. Di VS-0 semua menu masih
/// penanda; menampilkan labelnya membuat demo role tidak terlihat "rusak".
class HomeMenuItem {
  const HomeMenuItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.slice,
  });

  final String id;
  final String title;
  final String subtitle;
  final String slice;
}

class RolePolicy {
  const RolePolicy._();

  static const Set<AppPermission> _operatorPermissions = {
    AppPermission.scan,
    AppPermission.viewStock,
    AppPermission.viewOwnHistory,
  };

  static const Set<AppPermission> _supervisorPermissions = {
    AppPermission.scan,
    AppPermission.viewStock,
    AppPermission.viewOwnHistory,
    AppPermission.viewAllHistory,
    AppPermission.reverseTransaction,
    AppPermission.approveAdjustment,
    AppPermission.resolveConflict,
    AppPermission.exportReports,
  };

  static const Set<AppPermission> _adminPermissions = {
    AppPermission.scan,
    AppPermission.viewStock,
    AppPermission.viewOwnHistory,
    AppPermission.viewAllHistory,
    AppPermission.reverseTransaction,
    AppPermission.approveAdjustment,
    AppPermission.resolveConflict,
    AppPermission.manageUsers,
    AppPermission.manageMasterData,
    AppPermission.exportReports,
  };

  static const Map<UserRole, Set<AppPermission>> _grants = {
    UserRole.operator: _operatorPermissions,
    UserRole.supervisor: _supervisorPermissions,
    UserRole.admin: _adminPermissions,
  };

  static bool can(UserRole role, AppPermission permission) {
    return _grants[role]?.contains(permission) ?? false;
  }

  static List<HomeMenuItem> menuFor(UserRole role) {
    switch (role) {
      case UserRole.operator:
        return const [
          HomeMenuItem(
            id: 'scan',
            title: 'Scan barang',
            subtitle: 'Barang masuk & keluar dari barcode',
            slice: 'VS-1',
          ),
          HomeMenuItem(
            id: 'stock',
            title: 'Daftar stok',
            subtitle: 'Saldo per produk, tersedia offline',
            slice: 'VS-2',
          ),
          HomeMenuItem(
            id: 'history',
            title: 'Histori saya',
            subtitle: 'Transaksi yang Anda buat',
            slice: 'VS-3',
          ),
          HomeMenuItem(
            id: 'sync',
            title: 'Status sinkronisasi',
            subtitle: 'Transaksi menunggu terkirim',
            slice: 'VS-3',
          ),
        ];
      case UserRole.supervisor:
        return const [
          HomeMenuItem(
            id: 'scan',
            title: 'Scan barang',
            subtitle: 'Barang masuk & keluar dari barcode',
            slice: 'VS-1',
          ),
          HomeMenuItem(
            id: 'approval',
            title: 'Persetujuan',
            subtitle: 'Cycle count, konflik, override stok',
            slice: 'VS-5',
          ),
          HomeMenuItem(
            id: 'stock',
            title: 'Daftar stok',
            subtitle: 'Saldo seluruh gudang',
            slice: 'VS-2',
          ),
          HomeMenuItem(
            id: 'history',
            title: 'Histori gudang',
            subtitle: 'Semua transaksi, semua operator',
            slice: 'VS-3',
          ),
          HomeMenuItem(
            id: 'reports',
            title: 'Laporan & export',
            subtitle: 'Stock card dan export harian',
            slice: 'VS-4',
          ),
          HomeMenuItem(
            id: 'sync',
            title: 'Status sinkronisasi',
            subtitle: 'Transaksi gagal & antrean',
            slice: 'VS-3',
          ),
        ];
      case UserRole.admin:
        return const [
          HomeMenuItem(
            id: 'users',
            title: 'Kelola pengguna',
            subtitle: 'Tambah, nonaktifkan, atur role',
            slice: 'VS-4',
          ),
          HomeMenuItem(
            id: 'master',
            title: 'Master produk',
            subtitle: 'Import produk & barcode',
            slice: 'VS-1',
          ),
          HomeMenuItem(
            id: 'monitoring',
            title: 'Monitoring',
            subtitle: 'Transaksi gagal, konflik, audit',
            slice: 'VS-4',
          ),
          HomeMenuItem(
            id: 'reports',
            title: 'Laporan & export',
            subtitle: 'Rekonsiliasi dan export Sheets',
            slice: 'VS-4',
          ),
          HomeMenuItem(
            id: 'stock',
            title: 'Daftar stok',
            subtitle: 'Saldo seluruh gudang',
            slice: 'VS-2',
          ),
        ];
    }
  }
}
