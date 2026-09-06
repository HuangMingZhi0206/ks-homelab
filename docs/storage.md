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
