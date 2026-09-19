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
2. Kirim satu pesan apa saja ke bot barumu.
3. Buka `https://api.telegram.org/bot<TOKEN>/getUpdates` dan ambil
   `message.chat.id` dari JSON-nya.
4. Isi di `.env`:

```bash
TELEGRAM_BOT_TOKEN=123456:ABC...
TELEGRAM_CHAT_ID=987654321
```

```bash
docker compose up -d grafana
```

`up -d`, bukan `restart` — environment berubah, jadi container harus dibuat
ulang.

Uji tanpa menunggu ada yang rusak: **Alerting → Contact points → homelab →
Test**.

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

## Yang TIDAK tertangkap: Pi-nya sendiri mati

**Grafana jalan di Pi.** Kalau Pi mati, Grafana ikut mati, dan tidak ada alert
yang terkirim. Prometheus, ntfy, dan Home Assistant juga semuanya di sana.

Jadi sistem ini menangkap **Dell/Proxmox mati, switch mati, disk penuh, suhu
naik** — tapi tidak bisa memberi tahu bahwa dirinya sendiri hilang.

Untuk itu perlu sesuatu **di luar rumah**. Yang paling murah: **healthchecks.io**
(gratis). Cron di Pi mengirim ping tiap 5 menit; kalau ping berhenti, layanan
itu yang mengirim email ke kamu.

```bash
*/5 * * * * curl -fsS -m 10 --retry 3 https://hc-ping.com/<uuid> >/dev/null
```

Nol container, nol biaya, dan menutup satu-satunya lubang yang tidak bisa
ditutup dari dalam.
