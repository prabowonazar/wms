# Runbook VS-0 - Fondasi & walking skeleton

| Field | Nilai |
|---|---|
| Versi | 1.0 |
| Tanggal | 17 November 2026 |
| Tiket | VS0-01..VS0-06 |
| Dokumen acuan | `vertical-slice-backlog.md` §6, `PRD-v2.md` FR-AUTH-01..05, `ux-flow-spec.md` SCR-01/02/21 |
| Status | Scaffold kode selesai; **belum dikompilasi di mesin developer ini** (tidak ada Flutter/Dart/Node/Java) |

> **Baca ini dulu.** Repo berisi kode VS-0 yang ditulis lengkap, tetapi belum pernah
> melewati `flutter pub get`, `flutter analyze`, `flutter test`, atau build Android.
> Verifikasi yang sudah dilakukan: statis (`tools/verify-vs0.ps1`) untuk kelengkapan file,
> JSON, pola rules, tiket, dan kredensial; serta `tools/verify-schema-sqlite.ps1` yang
> menjalankan skema kanonik di SQLite 3.43.2 nyata (view, trigger, CHECK, generated column).
> Yang belum: kompilasi Dart, test Dart, build APK, login Google, dan SQLCipher di device.
> **VS-0 belum boleh disebut selesai sampai CI hijau dan demo di 2 device dijalankan.**

---

## 1. Apa yang sudah ada

| Area | File | Isi |
|---|---|---|
| Bootstrap | `app/lib/main.dart`, `app/lib/app.dart` | Error handler global, config gate, AuthGate berbasis stream |
| Firebase | `app/lib/bootstrap/bootstrap.dart` | `Firebase.initializeApp` dari `--dart-define`, emulator opsional, Crashlytics, buka DB |
| Login | `app/lib/core/auth/auth_repository.dart`, `google_sign_in_adapter.dart` | Google Sign-In v7 -> ID token -> Firebase credential -> profil |
| Role | `app/lib/core/auth/role_policy.dart`, `auth_models.dart` | Permission per role, menu beranda berbeda, alasan penolakan |
| Profil | `app/lib/core/storage/profile_cache.dart` | Cache `user_profile` agar sesi tetap jalan saat offline |
| Database | `app/lib/core/db/app_database.dart`, `schema_bootstrap.dart` | SQLCipher, skema v1 dari asset, PRAGMA di `onConfigure` |
| Kunci DB | `app/lib/core/security/db_key_store.dart` | 32 byte acak -> base64Url -> `flutter_secure_storage` |
| Layar | `app/lib/features/**` | Login, akun ditolak, beranda per role, pengaturan, config hilang, bootstrap gagal |
| Test | `app/test/**` | SQL splitter, skema via FFI, profil, role policy, widget config |
| Functions | `firebase/functions/**` | `health` callable + unit test murni |
| Rules test | `firebase/test/**` | 33 kasus izin/tolak di emulator |
| CI | `.github/workflows/ci.yml` | analyze/test/APK, Functions, rules emulator |
| Verifikasi | `tools/verify-vs0.ps1` | Pemeriksaan statis + opsi `-RunTests` |
| Verifikasi skema | `tools/verify-schema-sqlite.ps1` | Menjalankan `sqlite_schema.sql` di SQLite 3.43.2 nyata (Windows, tanpa toolchain) |

Yang **tidak** dikerjakan di VS-0 (sesuai tiket): scan, stok, sync, notifikasi, import UI.

---

## 2. Prasyarat

| Alat | Versi minimum | Catatan |
|---|---|---|
| Flutter | 3.27 (disarankan 3.32.x) | `google_sign_in` 7.x butuh Dart modern; CI memakai 3.32.5 |
| Dart | 3.6+ | Ikut Flutter |
| JDK | 17 | Gradle Android + Firestore emulator |
| Android SDK | API 34 | Android 8.0 (API 26) tetap jadi target minimum |
| Node.js | 20 LTS | Functions & rules test |
| Firebase CLI | 13.x | `npm install -g firebase-tools` |
| Git | terbaru | Belum terpasang di mesin ini |
| Device | 2 Android (1 low-end) | Untuk demo gate G0 |

Pasang di Windows (opsional, butuh winget):

```powershell
winget install --id Git.Git -e
winget install --id EclipseAdoptium.Temurin.17.JDK -e
winget install --id OpenJS.NodeJS.LTS -e
npm install -g firebase-tools
```

Flutter dipasang manual dari flutter.dev (zip + tambahkan `flutter\bin` ke `PATH`), lalu:

```powershell
flutter doctor -v
flutter doctor --android-licenses
```

Cek kesiapan repo tanpa toolchain:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-vs0.ps1
```

Dengan toolchain:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-vs0.ps1 -RunTests
```

---

## 3. Generate folder Android (sekali saja)

Folder `app/android/` **belum ada** di repo karena dibuat oleh Flutter SDK. Jangan
membuatnya manual. Cara paling aman (tidak menimpa `pubspec.yaml`, `lib/`, `test/`):

```powershell
Set-Location app
flutter create --platforms=android --org id.co.contoh --project-name warehouse_mobile _scaffold
Copy-Item .\_scaffold\android .\android -Recurse
Remove-Item .\_scaffold -Recurse -Force
```

Alternatif `flutter create .` juga bisa, tetapi akan menulis ulang beberapa file
(`analysis_options.yaml`, `.gitignore`, `pubspec.yaml`) dan menambah
`test/widget_test.dart`. Bila memilih cara itu, pulihkan file yang berubah dari git.

Setelah folder ada, edit tiga hal berikut.

### 3.1 `android/app/build.gradle` (atau `.kts`)

```gradle
android {
    defaultConfig {
        minSdk = 26          // target PRD: Android 8.0+
        targetSdk = 34
        applicationId = "id.co.contoh.warehouse_mobile"
    }
}
```

### 3.2 `android/app/src/main/AndroidManifest.xml`

Tambahkan izin internet di manifest **main** (template Flutter hanya menaruhnya di debug):

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

### 3.3 `android/app/proguard-rules.pro`

Wajib untuk build release; tanpa ini SQLCipher bisa ter-strip:

```
-keep class net.sqlcipher.** { *; }
```

### 3.4 Hanya bila memakai emulator Firebase

Android memblokir HTTP cleartext. Tambahkan di
`android/app/src/debug/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <application android:usesCleartextTraffic="true" />
</manifest>
```

Jangan tambahkan `usesCleartextTraffic` ke manifest release.

### 3.5 SHA-1 untuk Google Sign-In

```powershell
keytool -list -v `
  -keystore "$env:USERPROFILE\.android\debug.keystore" `
  -alias androiddebugkey -storepass android -keypass android
```

Salin **SHA1** ke Firebase Console -> Project settings -> Your apps -> Android app.
Tanpa langkah ini Google Sign-In gagal dengan `ApiException: 10`.

---

## 4. Firebase project

1. Buat dua project: `warehouse-dev` dan `warehouse-prod` (jangan dicampur).
2. Authentication -> Sign-in method -> aktifkan **Google**.
3. Authentication -> Settings -> **Web SDK configuration** -> salin **Web client ID**.
   Nilai ini menjadi `GOOGLE_SERVER_CLIENT_ID`. Tanpa nilai ini `idToken` null di Android.
4. Tambahkan Android app dengan package `id.co.contoh.warehouse_mobile` + SHA-1 debug.
5. Buat Firestore (mode production) di region `asia-southeast2`.
6. Aktifkan billing untuk Cloud Functions (deploy butuh Blaze).

Deploy rules & index setelah login CLI:

```powershell
Set-Location firebase
firebase login
firebase use --add           # pilih warehouse-dev, alias "dev"
firebase deploy --only firestore:rules,firestore:indexes
```

### 4.1 Mendaftarkan pengguna (wajib sebelum demo)

Aplikasi **tidak** membuat profil sendiri; Admin yang membuat (FR-AUTH-04). Urutan:

1. Jalankan app, login dengan akun Google operator.
2. Login akan ditolak dengan pesan "Akun Anda belum terdaftar" - **ini benar** (SCR-02).
3. Buka Firebase Console -> Authentication -> Users, salin **UID** akun tersebut.
4. Firestore -> buat dokumen `users/{uid}`:

```json
{
  "name": "Budi Santoso",
  "email": "budi@contoh.co.id",
  "role": "operator",
  "warehouseIds": ["wh_jkt01"],
  "active": true,
  "createdAt": "2026-11-17T08:00:00Z",
  "updatedAt": "2026-11-17T08:00:00Z"
}
```

5. Di layar penolakan, tekan **Coba lagi** (profil dimuat ulang tanpa login ulang).
6. Ulangi untuk `supervisor` dan `admin` dengan 3 akun Google berbeda.
7. Untuk menguji penolakan akun nonaktif, ubah `active` menjadi `false` pada akun keempat.

Catatan: `users/{uid}` boleh dibaca pemiliknya walau `active=false`; ini disengaja agar
aplikasi bisa menampilkan SCR-02, bukan error izin. Semua koleksi lain tetap tertutup.

---

## 5. Konfigurasi aplikasi (`--dart-define`)

Tidak ada `google-services.json` dan tidak ada kredensial di repo. Semua nilai masuk
saat build/run.

| Key | Wajib | Contoh | Keterangan |
|---|---|---|---|
| `FB_PROJECT_ID` | ya | `warehouse-dev` | Project ID Firebase |
| `FB_API_KEY` | ya | `AIza...` | Android API key (bukan service account) |
| `FB_APP_ID` | ya | `1:123:android:abc` | App ID Android |
| `FB_MESSAGING_SENDER_ID` | ya | `123456789` | Sender ID |
| `GOOGLE_SERVER_CLIENT_ID` | ya | `123-abc.apps.googleusercontent.com` | Web OAuth client |
| `FB_STORAGE_BUCKET` | tidak | `warehouse-dev.appspot.com` | Boleh kosong |
| `WAREHOUSE_ID` | tidak | `JKT-01` | Ditampilkan sebelum profil dimuat |
| `APP_VERSION` | tidak | `0.1.0` | Untuk event analytics |
| `USE_EMULATOR` | tidak | `true` | Menunjuk Auth/Firestore emulator |
| `EMULATOR_HOST` | tidak | `10.0.2.2` | Emulator Android -> host; device fisik: IP LAN |
| `AUTH_EMULATOR_PORT` | tidak | `9099` | Default sesuai `firebase.json` |
| `FIRESTORE_EMULATOR_PORT` | tidak | `8080` | Default sesuai `firebase.json` |

Buat `app/dart_defines/dev.json` (folder ini di-`.gitignore`):

```json
{
  "FB_PROJECT_ID": "warehouse-dev",
  "FB_API_KEY": "AIza...",
  "FB_APP_ID": "1:123:android:abc",
  "FB_MESSAGING_SENDER_ID": "123456789",
  "GOOGLE_SERVER_CLIENT_ID": "123-abc.apps.googleusercontent.com",
  "WAREHOUSE_ID": "JKT-01"
}
```

Jalankan:

```powershell
Set-Location app
flutter run --dart-define-from-file=dart_defines/dev.json
```

Build APK debug untuk device lain:

```powershell
flutter build apk --debug --dart-define-from-file=dart_defines/dev.json
```

Bila ada key yang kurang, aplikasi menampilkan layar
"Konfigurasi Firebase belum lengkap" beserta daftar key (tidak crash).

---

## 6. Emulator lokal (VS0-02)

```powershell
Set-Location firebase
npm --prefix functions install
firebase emulators:start --only auth,firestore,functions --project demo-warehouse
```

Lalu jalankan app dengan:

```powershell
flutter run `
  --dart-define-from-file=dart_defines/dev.json `
  --dart-define=USE_EMULATOR=true
```

**Batas penting:** Firebase Auth Emulator tidak bisa memvalidasi login Google native
end-to-end. Emulator dipakai untuk Firestore/Functions/rules; demo login 3 role
memakai project **dev** sungguhan. Jangan menulis di dokumentasi bahwa login Google
sudah diuji di emulator.

---

## 7. Test

### 7.1 Flutter

```powershell
Set-Location app
flutter pub get
dart format lib test
flutter analyze
flutter test --coverage
```

Yang harus hijau:

| File | Cakupan |
|---|---|
| `test/sql_script_test.dart` | Splitter SQL: string, komentar, trigger `BEGIN...END`, filter PRAGMA, skema kanonik |
| `test/schema_ffi_test.dart` | 10 tabel/3 view/5 trigger, idempoten, view saldo, stock card, trigger immutability/lock |
| `test/profile_cache_test.dart` | Simpan/baca/ganti/hapus profil di SQLite |
| `test/role_policy_test.dart` | Permission & menu berbeda per role |
| `test/user_profile_test.dart` | Parsing profil & alasan penolakan |
| `test/config_missing_screen_test.dart` | Widget layar config |

Catatan Windows: `sqflite_common_ffi` membutuhkan `sqlite3.dll` yang kompatibel.
Bila test FFI gagal dengan pesan "sqlite3.dll not found", jalankan di CI (Ubuntu)
atau salin DLL resmi ke `C:\Windows\System32` / folder kerja. Jangan mengubah test
menjadi "skip" permanen.

### 7.2 Skema di SQLite nyata tanpa toolchain

Bila Flutter belum terpasang, skema kanonik tetap bisa diuji di Windows memakai
`winsqlite3.dll` bawaan sistem (SQLite 3.43):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify-schema-sqlite.ps1
```

Skrip ini menjalankan seluruh `app/sqlite_schema.sql`, lalu memeriksa: 10 tabel /
3 view / 5 trigger / 13 index, idempotensi, view saldo (transaksi `failed`
diabaikan), stock card, trigger immutability & delete guard, lock cycle-count,
generated column `variance`, serta CHECK tanda `signed_qty`, reversal, dan role.
Exit code `2` berarti skrip dilewati (bukan Windows).

Ini **bukan** pengganti `flutter test`: splitter SQL Dart, cache profil, widget,
dan enkripsi SQLCipher tetap harus dibuktikan lewat §7.1 dan device.

### 7.3 Rules (butuh Java 17)

```powershell
Set-Location firebase\test
npm install
Set-Location ..
firebase emulators:exec --only firestore --project demo-warehouse "node --test test/"
```

Harapan: 33 kasus lulus, emulator berhenti sendiri. Kasus mencakup:

- default deny untuk pengguna tanpa login;
- operator nonaktif tidak bisa membaca data, tetapi tetap bisa membaca profilnya;
- operator tidak bisa membaca transaksi operator lain; supervisor bisa;
- `transactions` create-only: update/delete ditolak, metadata server ditolak, qty 0 ditolak;
- `balances`, `auditLogs` hanya boleh ditulis Function;
- cycle-count: hanya status `open` yang bisa dibuat, approve tidak bisa dari client,
  `variance` harus cocok, kolom hasil approval tidak boleh diisi client;
- hanya admin yang bisa menulis master produk, profil, dan `appConfig`.

### 7.4 Functions

```powershell
Set-Location firebase\functions
npm install
node --check index.js
node --test test/
```

CI tidak menjalankan `npm install` untuk Functions karena hanya menguji logika murni;
deploy tetap membutuhkan dependency.

---

## 8. Bukti acceptance criteria

Simpan semua bukti di tiket/PR. Jangan mengklaim AC tanpa artefak.

| Tiket | Perintah / langkah | Bukti yang disimpan |
|---|---|---|
| **VS0-01** | Push ke GitHub, buka tab Actions | Screenshot 4 job hijau: `app`, `build-apk`, `functions`, `rules`; tautan run |
| **VS0-02** | `firebase emulators:start --only auth,firestore,functions` + app `USE_EMULATOR=true` | Log emulator menyala, chip "Mode emulator" di layar login |
| **VS0-03** | Login 3 akun (operator/supervisor/admin), lalu akun `active=false` | Screenshot 3 beranda berbeda, screenshot SCR-02, screenshot app dibuka ulang tanpa dialog Google |
| **VS0-04** | Perintah §7.3 | Output `node --test` (33 pass) + log job rules di CI |
| **VS0-05** | `tools/verify-schema-sqlite.ps1`, `flutter test test/schema_ffi_test.dart`, lalu cek file DB | Output kedua perintah; header file DB **bukan** `SQLite format 3` (lihat di bawah) |
| **VS0-06** | Pengaturan -> Uji crash (debug); login sukses; Analytics DebugView | Screenshot crash di Crashlytics; event `app_open` + `login_success` terlihat |

Cek file DB terenkripsi:

```powershell
adb exec-out run-as id.co.contoh.warehouse_mobile cat databases/warehouse.db > "$env:TEMP\warehouse.db"
Format-Hex -Path "$env:TEMP\warehouse.db" -Count 16
```

Header SQLite biasa adalah `53 51 4C 69 74 65 20 66 6F 72 6D 61 74 20 33 00`
("SQLite format 3"). File SQLCipher harus **tidak** dimulai dengan byte tersebut.

DebugView Analytics:

```powershell
adb shell setprop debug.firebase.analytics.app id.co.contoh.warehouse_mobile
```

Lalu buka Firebase Console -> Analytics -> DebugView.

Crashlytics: crash pertama bisa butuh beberapa menit muncul. Pastikan device online
dan `setCrashlyticsCollectionEnabled(true)` (sudah dipanggil di bootstrap).

---

## 9. CI

`.github/workflows/ci.yml` menjalankan empat job pada setiap push/PR:

| Job | Isi | Butuh |
|---|---|---|
| `app` | `flutter pub get`, `flutter analyze`, `flutter test --coverage` | Flutter 3.32.5 |
| `build-apk` | `flutter build apk --debug` dengan define dummy | JDK 17 + Android SDK runner |
| `functions` | `node --check index.js`, `node --test test/` | Node 20 |
| `rules` | `npm install` di `firebase/test`, lalu `firebase emulators:exec` | Node 20 + Java 17 |

Catatan `build-apk`: karena `app/android/` belum di-commit, job ini membuat folder
Android sementara lewat `flutter create` (hanya bila belum ada). Jadi ini **smoke
build** - minSdk 26, ProGuard SQLCipher, dan manifest final tetap dibuat di mesin
dev (bagian 3) dan dibuktikan di device. Setelah `app/android/` di-commit, langkah
scaffold otomatis dilewati.

Repo belum punya git. Inisialisasi:

```powershell
git init
git add .
git commit -m "VS-0: scaffold fondasi, auth, SQLCipher, rules, CI"
git branch -M main
git remote add origin <url-repo>
git push -u origin main
```

Jangan commit: `dart_defines/`, `google-services.json`, service account, `*.jks`,
`key.properties`, `node_modules/`, `app/build/`.

---

## 10. Status verifikasi (jujur)

| Hal | Status |
|---|---|
| File & struktur VS-0 | Selesai, diperiksa `verify-vs0.ps1` |
| JSON konfigurasi | Valid (dibaca PowerShell) |
| Jumlah objek SQL (10/3/5) | Cocok dengan skema |
| Skema dieksekusi di SQLite nyata | **Lolos** - `tools/verify-schema-sqlite.ps1` pada SQLite 3.43.2 (view, trigger, CHECK, generated column) |
| Pola rules penting | Ada (create-only, write false, default deny) |
| 47 tiket unik | Ya |
| Tidak ada kredensial ter-commit | Ya |
| Skrip ASCII | Ya |
| `flutter pub get` / resolusi dependency | **Belum dijalankan** |
| `flutter analyze` | **Belum dijalankan** |
| `flutter test` (termasuk FFI) | **Belum dijalankan** |
| Build APK Android | **Belum dijalankan** |
| Login Google nyata di device | **Belum dijalankan** |
| SQLCipher di device | **Belum dibuktikan** (baru desain + test non-enkripsi via FFI) |
| Rules test emulator | **Belum dijalankan** (butuh Node + Java) |
| Functions unit test | **Belum dijalankan** (butuh Node) |
| Crashlytics & Analytics | **Belum dibuktikan** |

---

## 11. Risiko yang masih terbuka

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Versi paket Firebase/google_sign_in belum di-resolve | `pub get` bisa memilih versi yang tidak kompatibel dengan Flutter 3.32 | Jalankan `flutter pub get`, commit `pubspec.lock`; naikkan Flutter bila perlu |
| API `google_sign_in` v7 berubah antar patch | Compile error di adapter | Semua pemakaian terisolasi di `google_sign_in_adapter.dart` |
| Crashlytics tanpa `google-services.json` | Crash mungkin tidak terkirim / mapping tidak ter-upload | Uji di device; bila gagal, tambahkan plugin Google Services khusus build (tetap tanpa commit file) |
| SQLCipher ter-strip saat release | DB gagal dibuka di rilis | ProGuard keep rule + uji APK release |
| `minSdk` salah | Install gagal di Android 8 | Set 26 dan uji di device API 26 |
| Test FFI di Windows butuh `sqlite3.dll` | Test lokal gagal padahal kode benar | Jalankan di CI Ubuntu atau pasang DLL resmi |
| Timeout profil 8 detik saat offline pertama | Layar splash terasa lama | Cache profil setelah login pertama; pertimbangkan turunkan timeout setelah pengukuran |
| Login Google di emulator | Tidak bisa diuji end-to-end | Demo login di project dev; emulator untuk rules/Firestore |
| Analytics debug tidak muncul | Bukti VS0-06 kurang | `setprop debug.firebase.analytics.app` + tunggu beberapa menit |
| Data lama tidak bisa dibuka bila kunci hilang | Outbox hilang | Jangan hapus app; jangan rotasi kunci; dokumentasikan ke operator |

---

## 12. Troubleshooting

| Gejala | Penyebab umum | Tindakan |
|---|---|---|
| Layar "Konfigurasi Firebase belum lengkap" | `--dart-define` kurang | Lengkapi 5 key wajib; lihat §5 |
| Login: `id_token_missing` | `GOOGLE_SERVER_CLIENT_ID` bukan Web client ID | Salin ulang dari Firebase Authentication -> Google |
| Login: `ApiException: 10` | SHA-1 belum didaftarkan | Tambahkan SHA-1 debug ke Android app di Firebase |
| Login ditolak "belum terdaftar" | `users/{uid}` belum dibuat | Buat dokumen sesuai §4.1, tekan Coba lagi |
| Login ditolak "dinonaktifkan" | `active=false` | Set `true` bila memang boleh masuk |
| `permission-denied` saat baca profil | Rules lama ter-deploy | `firebase deploy --only firestore:rules` |
| DB gagal dibuka / "file is not a database" | Kunci berubah atau file rusak | Jangan hapus data; pulihkan kunci/backup, hubungi tech lead |
| `database is locked` | Dua proses menulis bersamaan | Pastikan hanya satu isolate menulis; WAL + `busy_timeout` sudah aktif |
| `flutter test` FFI gagal di Windows | `sqlite3.dll` tidak ditemukan | Jalankan di CI Ubuntu atau pasang DLL resmi |
| Emulator rules gagal start | Java bukan 17 | Set `JAVA_HOME` ke JDK 17 |
| App tidak connect ke emulator di device fisik | `10.0.2.2` hanya untuk emulator Android | Pakai IP LAN host + `EMULATOR_HOST` |

---

## 13. Definition of Done VS-0

- [ ] CI 4 job hijau di commit terakhir.
- [ ] `tools/verify-schema-sqlite.ps1` hijau dan `flutter test` hijau di CI.
- [ ] APK dipasang di 2 device fisik; login 3 role berhasil.
- [ ] Akun `active=false` menampilkan SCR-02, bukan crash.
- [ ] Tutup-buka app tetap login tanpa dialog Google.
- [ ] Rules test >= 12 kasus hijau di emulator (target aktual 33).
- [ ] File DB tidak bisa dibaca tanpa kunci (dibuktikan dengan `Format-Hex`).
- [ ] Crash uji muncul di Crashlytics; `app_open` & `login_success` tercatat.
- [ ] `docs/` diperbarui bila ada perilaku yang berubah.
- [ ] Tidak ada kredensial di repo (`verify-vs0.ps1` + review manual).

Setelah semua tercentang, baru lanjut ke **VS-1: scan & master data offline**.
