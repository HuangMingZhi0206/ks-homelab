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

### Tujuan di luar Pi

`backup.sh` mengirim ke luar kalau `restic` terpasang dan `RESTIC_REPOSITORY` diisi
di `.env`. Tanpa itu, backup hanya tersimpan di Pi yang sama, dan itu **tidak dihitung
sebagai backup** untuk vault ini.

Yang dipasang (2026-11-07): restic dari Pi ke host Proxmox (Dell) lewat SFTP.

- Di Dell ada user `resticbak`: password terkunci, tanpa shell, dan `authorized_keys`-nya
  berisi `restrict,command="internal-sftp"` di depan kunci Pi. Kunci itu hanya bisa SFTP:
  `ssh dell-backup 'echo x'` dijawab `This service allows sftp connections only.`
  Repositorinya `/srv/backup-pi/restic`.
- Skrip **harus dijalankan sebagai root**: `authelia/users_database.yml` milik root dengan
  izin 600, dan `tar` sebagai `ubuntu` gagal dengan `Permission denied`. Karena itu kunci,
  `known_hosts`, dan alias `dell-backup` juga ada di `/root/.ssh`.
- Di `.env`: `RESTIC_REPOSITORY=sftp:dell-backup:/srv/backup-pi/restic` dan
  `RESTIC_PASSWORD_FILE=/home/ubuntu/.restic-password`.
- **Password repositori dibuat acak di Pi dan harus dicatat di kertas**, di tempat fisik
  yang aman. Backup terenkripsi dengan password itu. Kalau Pi rusak dan password hanya ada
  di file di Pi, isi backup tidak bisa dibuka, dan tidak ada cara memulihkannya. Jangan
  simpan di vault yang sedang dibackup (melingkar).
- Jadwal (cron milik root, `sudo crontab -e`):
  `30 3 * * * cd /opt/homelab && ./scripts/backup.sh >> /var/log/homelab-backup.log 2>&1`

Batasnya, supaya tidak terlihat lebih aman dari kenyataan: Dell dan Pi berada di rumah dan
sumber listrik yang sama, jadi kebakaran, pencurian, atau lonjakan listrik mengenai
keduanya. SFTP juga bukan append-only: Pi yang dibobol bisa menghapus backup di Dell.
Karena itu perlu satu salinan terenkripsi ketiga di luar rumah atau offline (misalnya
repositori restic lain di flash drive yang disimpan terpisah).

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

## Hasil uji restore pertama (2026-11-07)

Snapshot `8fa2a20a` (5 file, 65 MiB) dipulihkan dari repositori di Dell ke volume
terpisah. Basis data dihitung langsung:

| File di dalam backup | Integritas | Jumlah pengguna |
|---|---|---|
| `db_..._114756.sqlite3` (sebelum akun dibuat) | ok | 0 |
| `db_..._122026.sqlite3` (dari `backup.sh`, sesudah akun dibuat) | ok | 1 |
| `db.sqlite3` (hasil menyalin salinan konsisten itu) | ok | 1 |

Lalu instance Vaultwarden dijalankan dari volume hasil restore: `/alive` menjawab 200. Itu
membuktikan akun tersimpan dan basis datanya utuh. **Belum** dicoba: login dengan master
password ke instance hasil restore (terowongan SSH di atas), yang menguji sampai ke sisi
klien.

## Sudah terbukti di Pi ini, dan yang belum

Terbukti (2026-11-07): `cap_drop: ALL` cukup untuk Vaultwarden 1.37.5; `/vaultwarden
backup` menulis `db_YYYYMMDD_HHMMSS.sqlite3`; `internal-only` meloloskan laptop lewat
Tailscale (`100.122.139.28` terbaca benar di log Traefik) dan menolak (`403`) permintaan
dari dalam Docker.

Belum terbukti:

- Header IP klien (`IP_HEADER`, bawaan `X-Real-IP`) di belakang Traefik. Kalau salah,
  rate limit login menganggap semua klien sebagai satu alamat. Cek dengan melihat
  `docker logs vaultwarden` sesudah login gagal dari laptop dan dari HP.
- Login dengan master password ke instance hasil restore (lihat hasil uji restore).
- Akses dari luar rumah (bagian "Dari luar rumah").

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
