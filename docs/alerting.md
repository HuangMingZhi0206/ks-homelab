# Alert

Aturan alert dan tujuan pengirimannya di-provision sebagai file di
`monitoring/grafana/provisioning/alerting/` — tidak ada yang perlu diklik, dan
semuanya ter-versioning di git seperti datasource dan dashboard.

## Kenapa Grafana, bukan Alertmanager

Alertmanager tidak bisa mengirim ke ntfy tanpa container jembatan tambahan, dan
Telegram-nya pun perlu Alertmanager sendiri. Itu berarti **dua container baru di
Pi yang catu dayanya sedang tidak sanggup** (lihat [storage.md](storage.md)).

Grafana sudah jalan dan punya alerting bawaan yang menanyakan Prometheus
langsung. Nol container baru.

## Kenapa Telegram, bukan ntfy

ntfy sudah ada di stack ini, tapi alamatnya `ntfy.lab.<domain>` — **internal
saja**, sengaja tanpa DNS publik. Artinya notifikasinya hanya sampai saat kamu
di rumah atau Tailscale aktif. Itu justru kebalikan dari gunanya alert.

Telegram **keluar saja**: Grafana memanggil `api.telegram.org` lewat HTTPS, dan
Telegram yang mengantar ke HP. Tidak ada port dibuka, tidak ada tunnel, tidak
ada nama DNS baru — dan CGNAT tidak jadi masalah sama sekali.

WhatsApp dipertimbangkan dan ditolak: tidak didukung Grafana, dan jalurnya
hanya lewat gateway berbayar atau library tidak resmi yang bisa membuat akun
diblokir. Kalau suatu saat tetap diinginkan, tambahkan receiver `webhook` ke
gateway — aturan alert-nya tidak perlu diubah.

## Menyiapkan (sekali, ~5 menit)

1. Di Telegram, kirim pesan ke **@BotFather** → `/newbot` → salin tokennya.
2. Kirim satu pesan apa saja ke bot barumu (bukan ke BotFather — itu cuma pabriknya).
3. Ambil chat id-nya. Cara tercepat: chat **@userinfobot**, dia membalas dengan `Id:`. Atau buka `https://api.telegram.org/bot<TOKEN>/getUpdates` dan cari `chat.id` — kosong berarti langkah 2 belum dilakukan.
4. Isi keduanya di `.env`, lalu jalankan `./scripts/bootstrap.sh` (atau render manual, lihat di bawah) dan `docker compose up -d grafana`.

### Kenapa di-render, bukan dibaca Grafana langsung

Grafana mengganti `$VAR` di dalam file provisioning **sebagai teks mentah,
sebelum YAML-nya diurai**. Chat id yang seluruhnya angka jadi tertulis sebagai
*number*, sementara receiver Telegram menuntut *string* — dan memberi kutip di
YAML tidak menolong, karena penggantinya terjadi lebih dulu.

Yang bikin jebakan ini sulit terlihat: **bottoken selamat**, karena token
mengandung huruf dan titik dua sehingga tetap string. Jadi separuh konfigurasi
tampak benar.

Dan kegagalannya tidak berhenti di receiver itu. Grafana membatalkan **seluruh
provisioner alerting**, jadi kelima aturan alert ikut tidak termuat. Satu-
satunya tanda ada di log:

```
cannot unmarshal number into Go struct field Config.chatid of type string
Stopped background service ... ProvisioningServiceImpl
```

Karena itu [`contact-points.yaml.tmpl`](../monitoring/grafana/provisioning/alerting/contact-points.yaml.tmpl)
di-render oleh `bootstrap.sh` — pola yang sama dengan `traefik.yml.tmpl`. Hasil
render-nya gitignored karena memuat token.

Render ulang tanpa menjalankan bootstrap penuh:

```bash
set -a; . ./.env; set +a
T=monitoring/grafana/provisioning/alerting/contact-points.yaml.tmpl
sed -e "s|__TELEGRAM_BOT_TOKEN__|$TELEGRAM_BOT_TOKEN|" \
    -e "s|__TELEGRAM_CHAT_ID__|$TELEGRAM_CHAT_ID|" "$T" > "${T%.tmpl}"
docker compose up -d --force-recreate grafana
```

## Aturannya

Lima saja, dan itu disengaja. Setiap alert yang kamu abaikan melatihmu
mengabaikan yang berikutnya.

| Aturan | Memicu saat | Tunda |
|---|---|---|
| **Instance down** | target Prometheus tidak menjawab | 5 menit |
| **Host rebooted** | mesin boot < 10 menit lalu | langsung |
| **Disk space low** | sisa < 10% | 15 menit |
| **Memory nearly exhausted** | `MemAvailable` < 10% | 15 menit |
| **CPU temperature high** | > 80 °C | 10 menit |

Yang **tidak** ada, dan sengaja: CPU persen, load average, dan RAM terpakai.
Ketiganya berfluktuasi wajar. RAM terpakai tinggi di Linux justru sehat —
kernel memakai sisanya sebagai cache — jadi alert di situ akan berbunyi tiap
hari tanpa ada yang salah.

Dua aturan yang lahir dari kejadian nyata:

- **Instance down** — Dell mati tiga hari dan baru ketahuan karena kebetulan
  ada yang dicoba. Aturan ini akan memberi tahu dalam 5 menit.
- **Host rebooted** — malam catu daya Pi terbukti gagal, dia reboot enam kali
  dalam sejam dan satu-satunya gejala adalah "asisten tidak pernah menjawab".

`repeat_interval` 4 jam: cukup sering untuk tidak terlupakan, cukup jarang
untuk tidak jadi kebisingan.

## Menutup lubang terakhir: heartbeat ke luar

**Grafana jalan di Pi.** Kalau Pi mati, Grafana ikut mati, dan tidak ada alert
yang terkirim. Prometheus dan ntfy juga di sana. Sistem alert di atas menangkap
Dell mati, switch mati, disk penuh, suhu naik — tapi **tidak bisa memberi tahu
bahwa dirinya sendiri hilang**.

Penutupnya harus dari luar rumah. [`scripts/heartbeat.sh`](../scripts/heartbeat.sh)
mengirim ping ke healthchecks.io tiap 5 menit; kalau ping berhenti, **mereka**
yang mengirim email ke kamu. Gratis, nol container.

### Bukan sekadar ping "masih hidup"

Pi yang menyala tapi Traefik-nya mati bukan sehat. Jadi script ini memeriksa
container inti — `traefik`, `authelia`, `redis`, `prometheus`, `grafana` — dan
kalau ada yang tidak `running`, dia melapor ke endpoint `/fail`, bukan diam
mengirim ping ceria.

Service berprofile sengaja tidak diperiksa: sifatnya memang opsional, jadi
mengalertkannya akan berbunyi di mesin yang cuma mematikannya.

Badan ping-nya juga membawa **jumlah undervoltage boot ini**, sehingga riwayat
di healthchecks.io menjadi catatan kesehatan catu daya dari waktu ke waktu —
yang di Pi ini sedang jadi masalah aktif (lihat [storage.md](storage.md)).

### Memasang

1. Daftar di healthchecks.io, buat satu check, salin **ping URL**-nya.
2. Di `.env` pada Pi:

```bash
HEALTHCHECKS_URL=https://hc-ping.com/<uuid>
```

3. Pasang cron-nya:

```bash
crontab -e
```

```
*/5 * * * * /opt/homelab/scripts/heartbeat.sh
```

4. Setel **Period 5 menit, Grace 10 menit** di healthchecks.io, supaya satu
   ping yang terlewat karena jaringan tidak langsung memicu alarm.

Uji sekali secara manual:

```bash
/opt/homelab/scripts/heartbeat.sh && echo terkirim
```

Tanpa `HEALTHCHECKS_URL` script-nya keluar diam-diam, jadi entri cron itu aman
walau belum dikonfigurasi.