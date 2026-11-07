# Vaultwarden di Pi (pengelola password)

Profile `vaultwarden`: server yang kompatibel dengan Bitwarden, di
`https://vault.<domain>`. Dipakai dengan aplikasi dan ekstensi Bitwarden biasa.

## Baca ini dulu

**Jangan memasukkan password asli sebelum backup pernah dipulihkan.** Ini
bukan formalitas. Catu daya Pi belum diganti (lihat [storage.md](storage.md):
brownout terbukti dan bisa merusak database yang sedang menulis), dan satu-satunya
salinan vault di server adalah database di Pi. Selama itu belum teratasi dan
belum ada backup yang teruji, pakai data uji saja.

Urutan yang aman:

1. Nyalakan, buat akun, coba semua klien dengan **data uji**.
2. Siapkan backup ke luar Pi dan **pulihkan sekali** (bagian "Uji restore").
3. Baru masukkan password asli.

## Menyalakan

```bash
# di .env: tambahkan vaultwarden ke COMPOSE_PROFILES, dan sementara:
#   VAULTWARDEN_SIGNUPS=true
docker compose up -d vaultwarden
```

Buka `https://vault.<domain>` dari laptop, lalu buat akun pemilik. Master password:
frasa panjang berisi 5 sampai 6 kata acak, tidak dipakai di tempat lain, tidak
disimpan di perangkat. Vault tidak bisa dipulihkan kalau master password hilang,
karena enkripsinya dilakukan di klien.

Lalu **tutup pendaftaran**: hapus baris `VAULTWARDEN_SIGNUPS` dari `.env` dan
jalankan lagi `docker compose up -d vaultwarden`. Buka halaman pendaftaran
dan pastikan ditolak. Setelah itu:

- Aktifkan 2FA (TOTP) di akun, dan **cetak kode pemulihannya** di kertas.
- Pasang klien: ekstensi browser di laptop, aplikasi Bitwarden di Android. Di
  layar login pilih server self-hosted dan isi `https://vault.<domain>`.

Sertifikat diterbitkan Let's Encrypt (DNS-01) pada permintaan pertama, jadi
halaman pertama bisa lambat beberapa detik.

## Apa yang membatasi akses

- **Tidak ada DNS publik dan tidak ada tunnel** untuk host ini. Itu lapis pertama.
- **`internal-only`** (`traefik/dynamic/middlewares.yml`): hanya `192.168.0.0/16`
  dan `100.64.0.0/10` (rumah dan Tailscale) yang boleh lewat. Subnet LAN tidak
  dicantumkan satu per satu karena laptop di Wi-Fi modem (`192.168.100.0/24`)
  menjangkau Pi (`192.168.200.0/24`) lewat routing, dan laptop yang sama juga datang
  lewat Tailscale.
- **Tidak lewat Authelia**, karena aplikasi Bitwarden tidak bisa mengikuti
  pengalihan SSO (alasan yang sama dengan Nextcloud).
- **Tanpa `ports:`**, `cap_drop: ALL`, `no-new-privileges`, batas memori 256 MB.
- **Halaman admin mati.** Ia hanya ada kalau `ADMIN_TOKEN` diisi, dan tidak diisi.
- Undangan, emergency access, dan Send dimatikan lewat variabel lingkungan. Ketiganya
  menyala secara bawaan meskipun pendaftaran ditutup.
- Rate limit login (60 detik, burst 10) sudah menyala secara bawaan.

Pemeriksaan sesudah menyala:

```bash
docker port vaultwarden                  # harus kosong: tidak ada port ke host
# Dari dalam Docker alamat sumbernya 172.x, jadi harus ditolak (403):
docker exec traefik wget -q -O /dev/null --no-check-certificate \
  --header 'Host: vault.<domain>' https://localhost/ ; echo "exit=$?"
```

## Dari luar rumah

**Belum selesai.** Aplikasi di HP butuh me-resolve `vault.<domain>` saat tidak di
rumah. Wildcard Unbound hanya berlaku di jaringan rumah. Lewat Tailscale itu perlu
split DNS (nameserver rumah untuk `lab.<domain>`) atau cara lain, dan itu belum
dikonfigurasi atau diuji. Sampai itu jalan, aplikasi hanya bekerja di rumah, dan
tetap bisa membaca salinan lokal vault di luar rumah (hanya baca).

## Backup

`scripts/backup.sh` memasukkan volume `vaultwarden_data` otomatis setelah volume itu
ada. Karena database SQLite terbuka saat Vaultwarden jalan, skrip lebih dulu
menjalankan perintah backup bawaan (`docker exec vaultwarden /vaultwarden backup`,
tersedia sejak 1.32.1) yang menulis salinan konsisten `db_*.sqlite3` ke dalam
volume. Tanpa `--stop`, jadi layanan lain tidak ikut mati. Skrip menyimpan 7 salinan
terbaru.

Yang masuk backup: `db.sqlite3` dan salinan `db_*.sqlite3`, `rsa_key*` (penanda
token login), `attachments/` kalau ada, dan `config.json` kalau ada.

**Belum ada tujuan di luar Pi.** `backup.sh` hanya mengirim ke luar kalau `restic`
terpasang dan `RESTIC_REPOSITORY` diisi. Tanpa itu, backup hanya tersimpan di Pi
yang sama, dan itu **tidak dihitung sebagai backup** untuk vault ini. Tujuan yang
direncanakan: Proxmox di Dell, ditambah satu salinan terenkripsi lain di luar rumah.

## Uji restore

Wajib dilakukan sekali sebelum data nyata, dan diulang berkala. Pulihkan ke
instance terpisah, jangan menimpa yang berjalan:

```bash
# 1. dari tarball volume ke volume uji
docker volume create vw_restore
docker run --rm -v vw_restore:/data -v <folder-backup>:/backup alpine \
  tar -xzf /backup/vaultwarden_data.tar.gz -C /data
# 2. pakai salinan yang KONSISTEN, bukan db.sqlite3 yang mungkin setengah tertulis
docker run --rm -v vw_restore:/data alpine sh -c \
  'f=$(ls -1t /data/db_*.sqlite3 | head -1); cp "$f" /data/db.sqlite3; rm -f /data/db.sqlite3-wal /data/db.sqlite3-shm'
# 3. jalankan di port lokal saja
docker run -d --name vw_restore -p 127.0.0.1:8081:80 -v vw_restore:/data \
  vaultwarden/server:1.37.5
```

Dari laptop, buat terowongan SSH (`ssh -L 8081:127.0.0.1:8081 ubuntu@<pi>`) lalu buka
`http://localhost:8081`. Alamat `localhost` dihitung sebagai konteks aman oleh
browser, jadi web vault bisa jalan tanpa HTTPS. Login dengan akun yang sama dan
pastikan data uji muncul. Bersihkan sesudahnya: `docker rm -f vw_restore` dan
`docker volume rm vw_restore`.

## Belum terverifikasi

Ditulis dari dokumentasi resmi, belum dijalankan di Pi ini:

- Bahwa `cap_drop: ALL` cukup untuk Vaultwarden. Kalau container gagal start,
  itulah yang pertama dicurigai.
- Pola nama `db_*.sqlite3` hasil `/vaultwarden backup` (dipakai untuk pemangkasan
  dan untuk langkah restore di atas). Cek nama file sebenarnya setelah backup
  pertama.
- Bahwa `internal-only` melihat alamat klien yang benar (LAN dan Tailscale) dan
  bukan alamat gateway Docker. Uji dari laptop (harus lolos) dan dari dalam
  Docker (harus ditolak).
- Header IP klien (`IP_HEADER`, bawaan `X-Real-IP`) di belakang Traefik. Kalau salah,
  rate limit menganggap semua klien sebagai satu alamat.

## Memperbarui versi

Image dipin ke tag dan digest. Baca catatan rilis dulu, lakukan **backup**, ganti
baris `image:`, `docker compose pull vaultwarden`, `docker compose up -d vaultwarden`,
lalu login dari semua klien. Jangan memakai `:latest`.

## Mundur

```bash
docker compose --profile vaultwarden stop vaultwarden
# hapus vaultwarden dari COMPOSE_PROFILES di .env
```

Volume `vaultwarden_data` tetap ada sampai dihapus dengan sengaja.
