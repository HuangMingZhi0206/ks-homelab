# Toolkit dokumen di Pi (Stirling-PDF)

Profile `doctools`: Stirling-PDF di `https://docs.<domain>` untuk menggabung,
memisah, mengompres, mengonversi, OCR, dan menandatangani PDF. Alasan adanya:
dokumen tidak perlu diunggah ke Smallpdf atau iLovePDF. Semua pemrosesan terjadi
di Pi.

## Menyalakan

Urutannya penting, karena Docker membuat sumber bind-mount yang tidak ada sebagai
direktori kosong.

```bash
./scripts/fetch-tessdata.sh                 # sekali: bahasa Indonesia untuk OCR
# di .env tambahkan doctools ke COMPOSE_PROFILES
docker compose pull stirling-pdf
docker compose up -d stirling-pdf
docker compose up -d traefik                # sekali: Traefik perlu bergabung ke jaringan doctools
```

Langkah terakhir membuat ulang Traefik, jadi semua situs putus beberapa detik.
Lakukan saat sepi. Booting Java di Pi memakan sekitar 45 detik sebelum halaman
terbuka.

## Kenapa jaringannya internal

Container ini hanya ada di jaringan `doctools` (`internal: true`), tanpa jalan ke
internet. Tujuannya menjamin bahwa dokumen dan data pemakaian tidak bisa keluar,
apa pun isi pengaturan aplikasinya. Stirling punya telemetri opsional (PostHog dan
Scarf), dan `SYSTEM_ENABLEANALYTICS=false` hanya mematikannya di sisi aplikasi.
Jaringan itulah yang benar-benar menjamin.

Yang ikut mati karenanya: pengecekan pembaruan dan fitur URL ke PDF (yang memang
dimatikan, karena aplikasinya sendiri menandainya punya masalah keamanan).
Kebalikannya tidak berlaku: jangan menaruh container ini di jaringan `proxy`
hanya agar "lebih mudah", karena itu membuka kembali jalan keluarnya.

Pembuktian di Pi, dari dalam container: koneksi ke `traefik:80` berhasil
(kontrol), sedangkan ke `1.1.1.1:443` dan `8.8.8.8:53` gagal.

## Autentikasi

Login bawaan Stirling dimatikan (`DOCKER_ENABLE_SECURITY=false`). Yang menjaga
adalah Authelia, dan ini aman hanya selama tidak ada jalan lain ke container:
tanpa `ports:`, tanpa jaringan selain `doctools`. Jangan menambahkannya.

Berbeda dengan Nextcloud, Stirling hanya dipakai dari browser, jadi
pengalihan SSO tidak menjadi masalah.

## Batas sumber daya, dan angkanya

OCR adalah bagian yang berat, dan catu daya Pi ini sudah terbukti tidak sanggup
menahan beban puncak (lihat [storage.md](storage.md)). Karena itu batasnya
sengaja ketat: `cpus: 2`, `cpu_shares: 256`, `mem_limit: 3g`.

Pengukuran 2026-11-07, catu daya lama, satu PDF contoh 20 halaman dengan mode
Force (OCR ulang semua halaman):

| | Hasil |
|---|---|
| Suhu CPU | 49,6 → 60,6 °C |
| Load (4 core) | 0,70 → 4,32 |
| Memori container | puncak 1662 MiB |
| CPU container | 223 detik untuk pekerjaan itu |
| Batas 2 core | menahan proses sekitar 1000 kali |
| `undervolt`, OOM host, reboot | 0, 0, tidak ada |

Ini satu pengukuran, bukan jaminan. Memori puncak yang hampir menyentuh 2 GiB
adalah alasan batasnya 3 GiB. Dokumen yang lebih besar atau beresolusi lebih
tinggi bisa lebih berat, dan catu daya Pi belum diganti.

## OCR

- **Mode Auto** (bawaan) melewati halaman yang sudah punya lapisan teks. PDF
  yang teksnya sudah bisa diseleksi akan selesai dalam kurang dari satu detik
  dengan pesan `OCR skipped on page(s) ...`. Itu benar, bukan gagal. Untuk
  menguji beban atau mengganti teks yang buruk, pakai mode **Force**.
- **Bahasa:** `eng`, `deu`, `fra`, `por`, `chi_sim` ikut di image. `ind` ditambah
  oleh `scripts/fetch-tessdata.sh` dari `tessdata_fast`, yang lebih cepat dan
  kecil daripada `tessdata_best` tetapi kurang akurat pada teks buram atau
  kecil. Untuk dokumen campuran pilih `ind` dan `eng` sekaligus.
- File bahasa dipin ke satu commit dan dicek SHA-256-nya. Kalau berubah,
  skripnya berhenti.

## Tanda tangan

Tanda tangan dari alat ini (gambar tanda tangan atau sertifikat sendiri) umumnya
**bukan** tanda tangan elektronik tersertifikasi. Untuk dokumen resmi yang butuh
kekuatan hukum penuh di Indonesia, kemungkinan perlu penyelenggara tersertifikasi.
Aturan persisnya belum diverifikasi di sini, jadi cek sebelum dipakai untuk hal
penting. Mengirim dokumen ke orang lain untuk ditandatangani sengaja belum
ada: itu butuh endpoint publik, dan itu bertentangan dengan prinsip akses lewat
Tailscale saja.

## Tidak ada yang disimpan

Tidak ada volume. Unggahan hidup di `/tmp` dalam container dan hilang saat
container dibuat ulang, jadi tidak ada yang perlu dibackup. Kunci enkripsi
kredensial yang dibuat Stirling juga hilang saat container dibuat ulang, dan itu
tidak masalah selama kamu tidak menyimpan kredensial di aplikasi ini.

## Memperbarui versi

Image dipin ke tag dan digest. Untuk memperbarui: tarik versi baru, jalankan
sebentar, catat digest-nya (`docker inspect`), ganti baris `image:` di
`docker-compose.yml`, lalu uji OCR satu dokumen sebelum dipakai. Tanpa langkah itu,
`docker compose pull` tidak akan mengubah apa pun, yang memang tujuannya.

## Mundur

```bash
docker compose --profile doctools stop stirling-pdf
# lalu hapus doctools dari COMPOSE_PROFILES di .env
```

Traefik boleh tetap tergabung ke jaringan `doctools`. Jaringan kosong tidak
berbahaya.
