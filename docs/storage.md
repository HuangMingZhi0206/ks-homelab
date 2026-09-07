# Penyimpanan bersama di Pi 5

HDD USB dipasang di Raspberry Pi 5 (`192.168.200.11`) dan dibagikan lewat Samba.
Pi dipilih karena sudah menyala 24 jam, hemat daya, dan stack Docker-nya memang
di situ — tidak ada mesin baru yang perlu dirawat.

## Batas daya USB Pi 5

Ini yang paling banyak memakan waktu, dan tidak akan Anda temukan dengan menebak.

Pi 5 menentukan batas arus USB dari **negosiasi USB Power Delivery**, bukan dari
kemampuan sumber dayanya. Catu daya di sini adalah step-down 12 V ke 5 V yang
tidak bisa bernegosiasi, sehingga firmware jatuh ke asumsi teraman dan mengunci
seluruh port USB di 600 mA:

```
max_current              = 900
usb_max_current_enable   = 0
usbpd_power_data_objects = 0 0 0 0 0 0 0
```

HDD 2.5 inci menarik sekitar 900 mA saat mulai berputar, jadi pengaman port
memutusnya sebelum sempat dikenali. Gejalanya `lsusb` kosong sama sekali, dan
`dmesg` dipenuhi salah satu dari dua ini:

- `Undervoltage detected!` berulang — catu dayanya yang melorot
- `usb usb4-port1: over-current change #N` — catu daya tegak, tapi pengaman port
  yang memutus

Membaca nilainya:

```bash
for f in /proc/device-tree/chosen/power/*; do echo -n "$(basename $f) = "; od -An -tu4 --endian=big "$f" 2>/dev/null || echo "?"; done
```

**Pemecahannya di sini:** `usb_max_current_enable=1` ditambahkan ke
`/boot/firmware/config.txt`. Sesudah reboot, HDD langsung terbaca dan tidak ada
satu pun pesan undervoltage — jadi step-down-nya memang mampu, hanya firmware
yang menahan.

Konsekuensinya harus disadari: **pengaman itu sekarang mati.** Kalau catu daya
melemah seiring umur, tidak ada lagi yang memutus, dan brownout saat NVMe
menulis bisa merusak sistem. Periksa sesudah penyalinan besar:

```bash
sudo dmesg | grep -ic undervolt
```

Angka selain 0 berarti catu dayanya sudah tidak sanggup lagi. Saat itu tiba,
gantinya bukan menyetel ulang firmware melainkan memberi disk dayanya sendiri —
USB hub berdaya atau docking station, yang keduanya punya PSU sendiri.

## Memasang disk

Disknya NTFS dan berisi data lama dari Windows, jadi tidak diformat.

```bash
sudo mkdir -p /srv/hdd
echo 'UUID=<uuid> /srv/hdd ntfs3 defaults,nofail,uid=1000,gid=1000,umask=022,windows_names,x-systemd.device-timeout=10 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount -a
```

UUID diambil dari `lsblk -f`.

Tiga pilihan yang disengaja:

- **`ntfs3`**, driver NTFS di dalam kernel — bukan `ntfs-3g` yang lewat FUSE.
  Jauh lebih cepat dan tidak menghabiskan CPU Pi.
- **`nofail`** — tanpa ini, Pi yang boot tanpa HDD tersangkut di emergency mode
  dan seluruh stack ikut mati sampai ada yang mencolokkan layar.
- **`uid=1000,gid=1000`** — NTFS tidak menyimpan kepemilikan ala Unix, jadi
  ditetapkan ke user `ubuntu`.

Kalau `mount` menolak menulis dan menyebut volume kotor, Windows terakhir kali
melepasnya dengan Fast Startup. Colok ke Windows, Eject dengan benar, ulangi.
Itu pengaman, bukan kerusakan.

## Samba

```bash
sudo apt install -y samba
```

Tambahkan di `/etc/samba/smb.conf`:

```ini
[hdd]
   path = /srv/hdd
   browseable = yes
   read only = no
   valid users = ubuntu
   force user = ubuntu
```

Sandi Samba **terpisah** dari sandi login Linux:

```bash
sudo smbpasswd -a ubuntu
sudo systemctl restart smbd && sudo systemctl enable smbd
```

## Dari Windows

Menelusuri "Network" di Explorer tidak akan menampilkan mesin Linux — Windows
sudah mematikan protokol penemuan lama. Ketik alamatnya langsung, dengan
backslash:

```
\\192.168.200.11\hdd
```

Atau pasang sebagai drive tetap:

```bash
net use Z: \\192.168.200.11\hdd /user:ubuntu /persistent:yes
```

Dua hal yang menjebak di sisi Windows:

- Dialog kredensial kadang menawarkan sertifikat atau smart card. Klik
  **More choices → Use a different account** untuk mendapat kolom biasa.
- Kalau login ditolak padahal sandinya benar, tulis penggunanya sebagai
  `192.168.200.11\ubuntu`. Tanpa awalan itu Windows mengirim kredensial akun
  Windows-nya sendiri.

Memastikan share-nya benar-benar dilayani, dijalankan dari Windows:

```bash
net view \\192.168.200.11
```

## Akses lewat browser (Filebrowser)

SMB nyaman dari Windows tapi canggung dari HP. Filebrowser memberi antarmuka web
di atas folder yang sama — telusuri, unduh, unggah, pratinjau foto.

Dia berjalan sebagai profil opsional di stack ini:

```bash
# di .env
COMPOSE_PROFILES=...,filebrowser
STORAGE_PATH=/srv/hdd
```

```bash
docker compose up -d filebrowser
```

Lalu tambahkan override Unbound di OPNsense untuk `files.lab.syonin.site` →
`192.168.200.11`, sama seperti hostname lab lainnya.

**Ini sengaja tidak dibuka ke internet.** Tidak ada catatan DNS publik dan tidak
ada Cloudflare Tunnel. Dari luar rumah, jangkau lewat Tailscale — persis seperti
Grafana. Alasannya bukan kemalasan: share ini berisi seluruh arsip foto
keluarga, dan pengelola berkas yang menghadap internet adalah sasaran yang jauh
lebih besar daripada sebuah dasbor.

Login pertama: Filebrowser membuat user `admin` dengan sandi acak yang dicetak
ke lognya.

```bash
docker compose logs filebrowser | head -20
```

Ganti sandinya lewat Settings begitu masuk. Authelia sudah menjaga di depan,
tapi lapisan kedua ini yang menahan kalau suatu saat label middleware-nya
terhapus tanpa sengaja.

### Kalau isinya terlihat kosong

Filebrowser akan dengan senang hati menyajikan direktori kosong kalau disknya
belum ter-mount di host. Itu tampak seperti data hilang, padahal bukan. Periksa
dulu di Pi:

```bash
df -h /srv/hdd
```

Harus menunjuk `/dev/sda1`, bukan `/dev/nvme0n1p2`.

## Nextcloud di atas disk yang sama (profile `nextcloud`)

Nextcloud memakai disk ini sebagai **External Storage**, bukan sebagai data
directory-nya sendiri. Data directory dan database tetap di volume Docker (NVMe),
karena Nextcloud melakukan chown dan file locking di sana — dua hal yang tidak
bisa diungkapkan NTFS.

```bash
# di .env
COMPOSE_PROFILES=...,nextcloud
STORAGE_PATH=/srv/hdd
```

```bash
docker compose up -d nextcloud
```

Sandi admin awal ada di `secrets/nextcloud_admin_password` (dibuat
`bootstrap.sh`), user `admin`. Alamatnya `https://cloud.<domain>`.

### Wajib: longgarkan permission mount

Ini syaratnya, dan kalau dilewat gejalanya membingungkan — file terlihat di
Nextcloud tapi setiap unggahan gagal.

Mount di atas memakai `umask=022`, yang berarti berkas jadi `644` milik uid 1000.
Nextcloud berjalan sebagai `www-data` (uid 33), jadi ia hanya kebagian bit
"others": **bisa baca, tidak bisa tulis**. NTFS tidak punya permission per-berkas
ala Unix — seluruh filesystem memakai satu pemilik dari opsi mount — sehingga
tidak ada cara memberi izin ke uid 33 saja.

Ganti `umask=022` di `/etc/fstab` menjadi:

```
fmask=0111,dmask=0000
```

Berkas jadi `666`, direktori `777`. Dengan begitu ketiga pemakainya bisa menulis:
Samba (uid 1000), Filebrowser (root), dan Nextcloud (uid 33).

```bash
sudo systemctl daemon-reload && sudo mount -o remount /srv/hdd
ls -ld /srv/hdd    # harus drwxrwxrwx
```

Konsekuensinya jujur: setiap pengguna lokal di Pi bisa menulis ke disk ini. Untuk
NAS rumah satu pengguna itu wajar — disk ini toh sudah terbuka lewat Samba — tapi
jangan tiru polanya di mesin dengan banyak akun.

### Menambahkan disknya di Nextcloud

1. Aktifkan aplikasi **External storage support** (Apps → Disabled).
2. Administration settings → External storage → Add: tipe **Local**, folder
   `/mnt/hdd`, beri nama misalnya "HDD".

### File dari Samba tidak muncul? Jalankan scan

Nextcloud menyimpan indeks berkas di database. Berkas yang masuk lewat Samba atau
Filebrowser tidak lewat Nextcloud, jadi indeksnya tidak tahu. Ini sumber
kebingungan paling sering — berkas jelas ada di disk, tapi tidak tampak di web.

```bash
docker compose exec -u www-data nextcloud php occ files:scan --all
```

Jadwalkan lewat cron di host, misalnya tiap 15 menit:

```
*/15 * * * * cd /path/ke/repo && docker compose exec -T -u www-data nextcloud php occ files:scan --all >/dev/null 2>&1
```

### Kenapa tanpa Authelia

Router `nextcloud` sengaja tidak memakai `authelia@file`. Klien sync desktop dan
aplikasi HP berbicara WebDAV, bukan sesi browser, jadi mereka tidak bisa
mengikuti redirect SSO — alasan yang sama dengan ntfy. Yang menjaganya login
Nextcloud sendiri; nyalakan 2FA di pengaturannya.
