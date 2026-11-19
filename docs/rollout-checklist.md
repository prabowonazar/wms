# Checklist rollout VS-6

Dokumen ini mengumpulkan bukti yang **tidak bisa dihasilkan mesin build**.
Semua angka di bawah wajib diisi dari project dev + device sebelum pilot.

## 1. Angka yang harus diukur di device

| Metrik | Target | Cara ukur | Status |
|---|---|---|---|
| M1 stock accuracy | ≥98% | `metrics/{period}` setelah 3 sesi cycle-count nyata | belum |
| M2 sync success rate | ≥99,5% | `metrics/{period}` | belum |
| M3 sync lag p95 | ≤15 menit | `metrics/{period}` | belum |
| M4 error transaksi | ≤0,5% | `metrics/{period}` | belum |
| M5 scan-to-saved p95 | ≤1,5 s | event `transaction_saved` di Analytics/DebugView | belum |
| M6 adopsi | ≥80% | `metrics/{period}` | belum |
| M7 durasi cycle-count | ≤1 hari kerja | `metrics/{period}` | belum |
| Lookup barcode p95 | ≤50 ms | 100 scan di device low-end | belum |
| Sync 2.000 SKU | ≤60 s @3 Mbps | pengukuran sekali pada install baru | belum |
| Tampilan dashboard | ≤2 s | stopwatch di device mid-range | belum |

Job `dailyMetrics` berjalan 03:00 WIB dan menulis `metrics/{periodKey}` beserta
`alarms`. Alarm juga tercatat di `auditLogs` sebagai `metrics.alarm`.
M5 belum otomatis: angka harus dibaca dari telemetri lokal/Analytics.

## 2. Regresi performa

Simpan hasil pengukuran baseline di tiket pilot. Aturan: kenaikan p95 >10%
dari baseline **menggagalkan rilis**. CI hanya menjaga kompilasi/test; CI
tidak mengukur performa device.

## 3. Aksesibilitas (minimal)

- [ ] Semua tombol aksi utama memiliki target sentuh ≥48×48 dp.
- [ ] Ikon status tidak hanya dibedakan warna (sudah ada teks: Belum
      terkirim/Mengirim/Terkirim/Gagal).
- [ ] `Semantics` aktif pada empty/error state (`core/ui/state_views.dart`).
- [ ] Kontras teks memenuhi AA (uji dengan TalkBack + pemeriksaan warna).
- [ ] Alur scan → Keluar → Simpan tetap ≤3 tap.
- [ ] Temuan P1 = 0 sebelum pilot.

## 4. Backup & restore (RTO ≤4 jam, RPO ≤15 menit)

Ganti `<project>` dan `<bucket>` dengan nilai project dev. **Jangan commit**
service account; gunakan akun gcloud login atau ADC.

```powershell
# Backup Firestore (ekspor penuh)
gcloud firestore export gs://<bucket>/backup/2026-11-19 --project=<project>

# Restore ke project recovery
gcloud firestore import gs://<bucket>/backup/2026-11-19 --project=<project-recovery>
```

Latihan wajib: pulihkan ke project kosong, verifikasi jumlah dokumen
`transactions`, `balances`, dan `products`, lalu ukur durasi total (RTO).
Untuk RPO ≤15 menit, jadwalkan ekspor inkremental atau gunakan pipeline
backup terkelola Firebase; pastikan ada bukti timestamp ekspor terakhir.

Rollback aplikasi: simpan SHA build APK rilis sebelumnya lalu pasang versi
tersebut di device uji. Karena skema device masih v1 dan migrasi sengaja
gagal keras, jangan menurunkan versi ke build dengan skema berbeda tanpa
panduan migrasi.

## 5. Seeding 100 SKU pilot

1. Isi template import produk sesuai `docs/product-import-spec.md`
   (kode unik, UoM, barcode, `active`).
2. Unggah ke Sheet yang sudah terhubung dengan `importProducts`, lalu panggil
   callable import dengan akun Admin.
3. Pastikan hasil `created=100`, `skipped=0`; import ulang file yang sama
   harus `created=0` (idempoten, BR-13).
4. Di device, lakukan sync master penuh dan cek 100 produk tampil di Stok.

## 6. Utang yang masih terbuka

- **WorkManager (VS2-03)**: sudah dipakai (task periodik 15 menit, constraint
  jaringan) untuk outbox dan cycle-count. Masih perlu diuji pada device OEM
  agresif; simpan bukti eksekusi task di logcat.
- **VS5-06**: tab konflik di layar persetujuan cycle-count belum dibuat;
  daftar konflik tersedia di SCR-20.
- **VS4-07**: ekspor PDF/CSV dipotong sesuai tiket Should.
- **M5**: otomatisasi pengambilan telemetri lokal belum tersedia.
