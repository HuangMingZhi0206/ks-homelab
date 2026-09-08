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

## Prioritas, bukan pembagian core

RAM bukan kendala di Pi 8 GB:

| | Perkiraan |
|---|---|
| Host + stack homelab yang sudah jalan | ~2,3 GB |
| Home Assistant | ~600 MB |
| Whisper `base` | ~1 GB |
| Piper | ~300 MB |
| Ollama + `qwen2.5:3b` | ~2,5 GB |
| **Total** | **~6,7 GB dari 8 GB** |

Yang jadi kendala **CPU**. Pi ini juga menjawab setiap kueri DNS di rumah dan
menjalankan Authelia serta Prometheus, sementara inferensi memakai keempat core
sampai 100%.

Versi awal menangani ini dengan `cpuset: "2,3"` — memaku ketiga komponen ke dua
core. **Itu salah dua kali**, dan terukur di Pi ini:

```
prompt eval rate:  11.53 tokens/s     <- membaca pertanyaan
eval rate:          0.46 tokens/s     <- menulis jawaban
```

Satu jawaban 29 token butuh **63 detik**.

Penyebabnya: **Ollama menentukan jumlah thread dari jumlah CPU host, bukan dari
cgroup tempat dia berjalan.** Jadi dengan `cpuset` dua core, dia tetap
menjalankan empat thread — empat thread berebut dua core. Generasi token
menyinkronkan seluruh thread **setiap token**, jadi setiap sinkronisasi harus
menunggu thread yang sedang tidak dijadwalkan. Prompt eval memproses banyak
token dalam satu batch sehingga hampir tidak terpengaruh — itulah kenapa
angkanya berbeda 25 kali pada model yang sama di proses yang sama.

Kesalahan kedua: `cpuset` membatasi bahkan saat Pi sedang menganggur, yang justru
kondisi mayoritas waktunya.

**Yang dipakai sekarang: keempat core, tapi `cpu_shares: 512`** — di bawah
default 1024. Bobot ini hanya berlaku saat ada rebutan, jadi inferensi berjalan
penuh saat Pi sepi dan langsung mengalah begitu Traefik atau AdGuard punya
pekerjaan. Jumlah thread diset eksplisit (`OLLAMA_NUM_THREADS=4`) supaya cocok
dengan core yang benar-benar tersedia, bukan disimpulkan sendiri.

Kalau suatu saat kamu mengubah salah satunya, ubah dua-duanya.

### Hasil terukur, sebelum dan sesudah

Model dan mesin yang sama, hanya konfigurasi CPU-nya yang berubah:

| | `cpuset: "2,3"` (4 thread di 2 core) | 4 core, `cpu_shares: 512` |
|---|---|---|
| prompt eval | 11,53 t/s | **59,80 t/s** |
| eval (generasi) | 0,46 t/s | **8,23 t/s** |
| Jawaban 29 token | 63 detik | ~3,5 detik |

**18 kali lebih cepat**, dari satu variabel saja. Suhu saat itu 52,9 °C, jadi
bukan soal throttling.

Pada permintaan kedua, `load duration` turun ke 877 µs dan `prompt eval cached`
menunjukkan 24 token — bukti `OLLAMA_KEEP_ALIVE=-1` menahan model di memori dan
prompt caching bekerja.

### Kualitas model, bukan kecepatannya, yang jadi batas sebenarnya

Pada kecepatan itu, `qwen2.5:1.5b` menjawab "sebutkan tiga warna" dengan:

> "Batu banting dengan warna hijau, putih, dan biru."

Warnanya benar, tapi ada frasa acak di depannya. Model 1,5 B memang segitu di
Bahasa Indonesia. Konsekuensinya bukan soal enak dibaca: **kalau dia menyisipkan
kata acak di pertanyaan sepele, dia juga bisa salah menyebut angka saat
merangkum sensor** — dan tidak ada cara membedakannya dari jawaban yang benar.

Karena itu pembagiannya tetap:

- **Assist bawaan** untuk pertanyaan angka (suhu, sisa disk). Dijawab langsung
  dari state sensor, tidak bisa dikarang.
- **Ollama** untuk kalimat bebas yang intent-nya tidak dikenali.

Itu terkonfirmasi saat diuji, dan sebabnya `qwen2.5:3b` yang dipakai sekarang —
lihat perbandingannya di bawah.

### Model: 3b, bukan 1.5b

Diuji berdampingan di Pi ini, pertanyaan yang sama:

| | `qwen2.5:1.5b` | `qwen2.5:3b` |
|---|---|---|
| "Sebutkan tiga warna" | "**Batu banting** dengan warna hijau, putih, dan biru" | "Tiga warna adalah merah, hijau, dan biru" |
| eval rate | 8,2 t/s | 4,1–4,7 t/s |
| Jawaban pendek (16–22 token) | ~2,5 detik | 3,5–5,5 detik |
| Salah ketik ("Siapa kmu") | — | tetap dipahami |

1.5b dua kali lebih cepat tapi menyisipkan frasa acak. Selisih dua detik untuk
jawaban yang benar itu murah, jadi **3b yang dipakai**. `mem_limit` dinaikkan ke
4 GB untuk memberinya ruang.

### Lamanya jawaban, bukan pilihan model, yang menentukan lamanya menunggu

Ini tuas terbesar yang tersedia, dan sering terlewat. Pada ~4 t/s, waktu tunggu
kira-kira **lamanya jawaban dibagi 4**. Terukur di sini:

| Panjang jawaban | Waktu |
|---|---|
| 16 token | 3,4 detik |
| 22 token | 5,4 detik |
| 81 token | **19,8 detik** |

Yang 81 token itu jawaban bertele-tele untuk "siapa kamu" — tiga kalimat berisi
basa-basi. Isinya tidak lebih berguna daripada satu kalimat.

Jadi **instruksi ringkas mengalahkan tuning CPU apa pun**. Di integrasi Ollama
di Home Assistant, isi kolom prompt template dengan sesuatu seperti:

```
Jawab dalam satu kalimat, langsung ke inti, tanpa pembuka dan tanpa penutup.
Kalau ditanya angka, sebutkan angkanya saja beserta satuannya.
```

Itu memotong 81 token jadi belasan — dari 20 detik ke sekitar 4 detik, tanpa
mengubah model atau konfigurasi mesin sama sekali.

### Satu artefak di angka yang bisa membingungkan

Pada permintaan kedua yang prompt-nya sudah ter-cache, `prompt eval rate`
terbaca **3,62 t/s** — seolah jauh lebih lambat. Itu bukan regresi: 36 dari 37
token diambil dari cache, jadi yang benar-benar diproses hanya satu token, dan
pembagiannya tetap memakai durasi total. Yang perlu dibaca adalah `prompt eval
cached`, bukan rate-nya.

### Pelajaran umumnya

Untuk beban inferensi di mesin bersama, **turunkan prioritasnya, jangan potong
core-nya** — dan kalau memang harus memotong, beri tahu aplikasinya berapa core
yang dia dapat. Aplikasi yang membaca `nproc` tidak tahu apa-apa soal cgroup.
## Tahap 0: Home Assistant + Ollama saja, lewat teks

Selama belum ada mic dan speaker, Whisper dan Piper tidak ada gunanya — jangan
dinyalakan dulu. Assist bekerja dengan **mengetik** di web UI, dan itu cukup
untuk menguji seluruh lapisan yang penting: apakah sensornya benar, dan apakah
model paham cara kamu bertanya dalam Bahasa Indonesia.

```bash
# di .env
COMPOSE_PROFILES=...,voice
```

```bash
docker compose up -d homeassistant
docker compose logs -f homeassistant        # tunggu "Home Assistant initialized"
```

Buka `https://ha.<domain>`, selesaikan onboarding, lalu **nyalakan 2FA** di
Profile → Multi-factor authentication (router ini tidak di belakang Authelia,
jadi login HA adalah satu-satunya penjaga).

Periksa dulu kelima sensor Prometheus muncul dengan angka, bukan `unavailable`:
**Developer tools → States**, cari `sensor.pi_`. Yang `unavailable` berarti
kuerinya tidak mengembalikan apa pun — betulkan nama metriknya di
`configuration.yaml`.

### Ollama

Unduhan modelnya ~1 GB lewat koneksi LTE. Lakukan dengan sadar, bukan sambil
mengerjakan hal lain yang butuh bandwidth.

```bash
docker compose up -d ollama
docker compose exec ollama ollama pull qwen2.5:3b
docker compose exec ollama ollama run qwen2.5:3b "Jawab singkat: apa itu NVMe?"
```

Kalau jawabannya keluar, model sudah sehat. Lalu di Home Assistant:

1. **Settings → Devices & Services → Add Integration → Ollama**
2. URL: `http://ollama:11434`
3. Model: `qwen2.5:3b`
4. Di opsi integrasinya, aktifkan **Assist** dan izinkan mengontrol Home
   Assistant — tanpa itu model tidak punya akses ke sensor apa pun dan hanya
   akan mengarang.
5. **Settings → Voice assistants**: buat asisten baru, conversation agent-nya
   Ollama. Biarkan STT dan TTS kosong.

Uji dengan mengetik di ikon Assist (pojok kanan atas). Bandingkan dengan
asisten bawaan: buat dua asisten, satu Ollama satu Assist bawaan, tanyakan hal
yang sama, lihat mana yang lebih tepat. Untuk pertanyaan angka, yang bawaan
biasanya menang — dan itu memang kesimpulan yang diharapkan.

### Ekspektasi kecepatan

Dengan empat core dan model 1,5 B di Pi 5, hitungan beberapa detik per jawaban,
bukan di bawah satu detik. Pertanyaan pertama setelah `pull` lebih lama karena
model dimuat ke memori; sesudahnya tetap tinggal di sana karena
`OLLAMA_KEEP_ALIVE=-1`.

Sambil menguji, pantau apakah Pi kewalahan:

```bash
docker stats --no-stream
vcgencmd get_throttled        # bukan 0x0 = sudah kena undervoltage/throttle
```

## Menyalakan pipeline suara lengkap (kalau mic dan speaker sudah ada)

```bash
# di .env
COMPOSE_PROFILES=...,voice
```

```bash
docker compose up -d homeassistant wyoming-whisper wyoming-piper
docker compose logs -f homeassistant
```

Tidak perlu menambahkan apa pun di DNS. Wildcard Unbound yang sudah ada
(`*` -> `lab.syonin.site` -> `192.168.200.11`) sudah mencakup nama ini.

**Jangan menambahkan host override spesifik di bawah zona itu.** Wildcard
membuat Unbound memperlakukannya sebagai *redirect zone*, dan di zona semacam
itu semua local-data harus berada di puncak zona. Menambahkan satu nama saja
menghasilkan `local-data in redirect zone must reside at top of zone` lalu
`Could not set up local zones` — Unbound gagal start dan **seluruh DNS rumah
mati**, bukan cuma nama barunya.

Whisper dan Piper mengunduh modelnya sendiri saat start pertama, jadi biarkan
beberapa menit dan pantau lognya.

### Menyalakan Ollama (kalau tahap 1 memang kurang)

```bash
docker compose up -d ollama
docker compose exec ollama ollama pull qwen2.5:3b     # ~1,9 GB
docker compose exec ollama ollama run qwen2.5:3b "Halo, jawab singkat."
```

`OLLAMA_KEEP_ALIVE=-1` sudah diset supaya model tetap tinggal di memori. Tanpa
itu, model dibongkar setelah lima menit menganggur dan pertanyaan pertama
sesudah jeda harus memuat ~1 GB dari NVMe sebelum menjawab — jeda yang justru
paling tidak boleh ada di asisten harian. Harganya ~1,5 GB tertahan permanen.

Lalu di Home Assistant: **Settings → Devices & Services → Add Integration →
Ollama**, URL `http://ollama:11434`, model `qwen2.5:3b`. Pasang sebagai
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
