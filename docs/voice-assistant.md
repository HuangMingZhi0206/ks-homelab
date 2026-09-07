# Asisten suara lokal di Pi 5

Profile `voice`: Home Assistant + Whisper (STT) + Piper (TTS) + Ollama (LLM),
semuanya lokal, dua bahasa (Indonesia dan Inggris). Untuk pertanyaan harian —
jam berapa, suhu CPU, sisa NVMe, kondisi server.

## Baca ini dulu: mungkin kamu tidak butuh LLM-nya

Untuk pertanyaan yang jadi alasan awal — jam, suhu, sisa disk — **Assist bawaan
Home Assistant sudah menjawabnya tanpa LLM apa pun**, lewat pencocokan intent.
Responsnya milidetik, RAM tambahannya nol, dan yang penting: **intent matcher
tidak bisa mengarang angka**, sementara LLM yang merangkum sensor bisa keliru
menyebut suhu.

Jadi urutan yang disarankan:

1. Nyalakan Home Assistant + Whisper + Piper saja. Pakai Assist bawaan.
2. Pakai seminggu, **terutama dalam Bahasa Indonesia**.
3. Baru nyalakan Ollama kalau Assist sering tidak paham.

Alasan sebenarnya untuk memasang LLM bukan membaca sensor, melainkan cakupan
kalimat: `home-assistant-intents` punya template per bahasa, dan koleksi Bahasa
Indonesianya masih jauh lebih tipis daripada Inggris. Kalau kamu bicara
Indonesia dan dia sering bingung — **itu** justifikasinya.

## Mengapa CPU dipatok, bukan RAM

RAM bukan kendala di Pi 8 GB:

| | Perkiraan |
|---|---|
| Host + stack homelab yang sudah jalan | ~2,3 GB |
| Home Assistant | ~600 MB |
| Whisper `base` | ~1 GB |
| Piper | ~300 MB |
| Ollama + `qwen2.5:1.5b` | ~1,5 GB |
| **Total** | **~5,7 GB dari 8 GB** |

Yang jadi kendala **CPU**. Pi ini juga menjawab setiap kueri DNS di rumah dan
menjalankan Authelia serta Prometheus, sementara inferensi dengan senang hati
memakai keempat core sampai 100%. Tanpa pembatasan, setiap pertanyaan ke asisten
akan terasa sebagai internet melambat di seluruh rumah, plus alert palsu di
Grafana karena scrape timeout.

Karena itu di `docker-compose.yml` ketiga komponen berat dipatok:

```yaml
    cpuset: "2,3"
```

Core 0–1 tetap bebas untuk stack homelab. Ketiganya boleh berbagi core 2–3
karena **pipeline-nya berurutan** — suara jadi teks, lalu model, lalu teks jadi
suara; tidak pernah ada dua yang sibuk bersamaan. Home Assistant sendiri tidak
dipatok: dia sensitif latensi tapi murah.

Konsekuensinya inferensi jadi sekitar setengah kecepatan. Untuk pertanyaan
sependek "suhu berapa", selisih itu tidak terasa.

## Menyalakan

```bash
# di .env
COMPOSE_PROFILES=...,voice
```

```bash
docker compose up -d homeassistant wyoming-whisper wyoming-piper
docker compose logs -f homeassistant
```

Tambahkan override Unbound di OPNsense untuk `ha.lab.syonin.site` →
`192.168.200.11`, sama seperti hostname lab lainnya. Lalu buka
`https://ha.<domain>` dan selesaikan onboarding.

Whisper dan Piper mengunduh modelnya sendiri saat start pertama, jadi biarkan
beberapa menit dan pantau lognya.

### Menyalakan Ollama (kalau tahap 1 memang kurang)

```bash
docker compose up -d ollama
docker compose exec ollama ollama pull qwen2.5:1.5b     # ~1 GB
docker compose exec ollama ollama run qwen2.5:1.5b "Halo, jawab singkat."
```

`OLLAMA_KEEP_ALIVE=-1` sudah diset supaya model tetap tinggal di memori. Tanpa
itu, model dibongkar setelah lima menit menganggur dan pertanyaan pertama
sesudah jeda harus memuat ~1 GB dari NVMe sebelum menjawab — jeda yang justru
paling tidak boleh ada di asisten harian. Harganya ~1,5 GB tertahan permanen.

Lalu di Home Assistant: **Settings → Devices & Services → Add Integration →
Ollama**, URL `http://ollama:11434`, model `qwen2.5:1.5b`. Pasang sebagai
conversation agent di pipeline Assist.

## Menyambungkan pipeline suara

**Settings → Devices & Services → Add Integration → Wyoming Protocol**, dua kali:

| | Host | Port |
|---|---|---|
| Whisper (STT) | `wyoming-whisper` | `10300` |
| Piper (TTS) | `wyoming-piper` | `10200` |

Lalu **Settings → Voice assistants → Add assistant**: pilih Whisper untuk
speech-to-text, Piper untuk text-to-speech, dan Assist bawaan (atau Ollama)
sebagai conversation agent.

## Soal dua bahasa

**STT** sudah diatur `--language auto` di compose, jadi Whisper mendeteksi
Indonesia atau Inggris per ucapan, bukan terkunci satu bahasa. Modelnya `base`,
bukan `tiny`, karena akurasi `tiny` untuk Bahasa Indonesia buruk.

**TTS** memakai `id_ID-news_tts-medium` — **satu-satunya suara Indonesia yang
ada di Piper**, suara pria, kualitas medium. Tidak ada pilihan lain. Kalau ingin
jawaban Inggris dibacakan dengan suara Inggris, jalankan instance Piper kedua
dengan `--voice en_US-lessac-medium` dan buat pipeline Assist terpisah — satu
instance Piper hanya melayani satu suara.

## Sensor sistem: dari Prometheus, bukan dari dalam container

[`homeassistant/config/configuration.yaml`](../homeassistant/config/configuration.yaml)
membaca suhu, RAM, sisa NVMe, sisa HDD, dan load lewat **REST sensor ke
Prometheus**.

Integrasi System Monitor bawaan Home Assistant tidak dipakai karena tidak akan
benar di sini: container melihat `/proc` dan cgroup miliknya sendiri, bukan
milik host, jadi angkanya akan menggambarkan container — bukan Pi-nya.
Prometheus sudah men-scrape node-exporter di host ini, jadi lebih tepat
menanyakannya ke Prometheus. Home Assistant dan Prometheus dua-duanya ada di
network `proxy`, itu sebabnya nama `prometheus` bisa diresolusi.

Efek sampingnya menyenangkan: semua yang sudah kamu kumpulkan juga tersedia
untuk asisten — termasuk metrik Proxmox dan switch.

**Verifikasi nama metriknya dulu.** `node_thermal_zone_temp` itu khas ARM dan
label `zone`-nya bervariasi. Buka `https://prometheus.<domain>`, jalankan
kuerinya satu per satu, sesuaikan kalau kosong. Sensor yang kuerinya tidak
mengembalikan apa pun akan tampil `unavailable` di Home Assistant.

### Jumlah update APT belum termasuk

node-exporter tidak mengekspos itu secara bawaan. Perlu textfile collector plus
skrip cron di host — belum dikerjakan, dan butuh perubahan di sisi host yang
tidak bisa diuji dari repo ini.

## Home Assistant tidak di belakang Authelia

Router `homeassistant` sengaja **tanpa** `authelia@file`. Aplikasi Companion di
HP berbicara ke API secara langsung dan tidak bisa mengikuti redirect SSO —
alasan yang sama seperti ntfy. Home Assistant punya login sendiri; nyalakan 2FA
di **Profile → Multi-factor authentication**.

## `trusted_proxies` itu wajib

Ini sudah ada di config, tapi penting dipahami kalau suatu saat berubah: tanpa
blok `http:` itu, Home Assistant melihat header `X-Forwarded-For` dari Traefik,
menyimpulkan datang dari proxy tak tepercaya, dan menjawab **setiap** request
dengan `400: Bad Request` — termasuk layar onboarding. Jadi kamu tidak akan
pernah bisa masuk untuk memperbaikinya dari UI.

## Pantau undervoltage

`usb_max_current_enable=1` di Pi ini sudah mematikan pengaman firmware (lihat
[storage.md](storage.md)), dan beban CPU berkelanjutan seperti inferensi belum
pernah diuji di catu daya step-down 12V→5V itu. Sebelum dan sesudah percobaan
pertama:

```bash
sudo dmesg | grep -ic undervolt
vcgencmd get_throttled
```

`get_throttled` yang bukan `0x0` berarti sudah kena. Hentikan, dan urus catu
dayanya sebelum melanjutkan — stack ini boot dari NVMe.

## Kalau nanti Pi 4 dapat SSD

Pindahkan Home Assistant, Whisper, dan Piper ke sana (HAOS, dengan add-on
sekali klik), dan sisakan Pi 5 untuk melayani rumah. Kalau Ollama tetap di Pi 5,
dia tidak lagi berebut core dengan transkripsi suara. Jangan pasang HAOS di SD
card: recorder Home Assistant menulis ke SQLite terus-menerus, dan pola tulis
acak kecil itu membunuh SD card dalam bulanan.
