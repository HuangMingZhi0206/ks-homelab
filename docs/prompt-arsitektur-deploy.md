# Prompt: menjelaskan arsitektur deploy ke asisten lain

Prompt siap tempel untuk dipakai saat meminta bantuan AI lain (atau sesi baru)
men-deploy sebuah repo ke homelab ini. Isinya ringkasan dari
[coolify-deployments.md](coolify-deployments.md) — dokumen itu tetap sumber
kebenarannya. **Periksa ulang sebelum dipakai lagi:** prompt ini memotret
keadaan 9 Oktober 2026, dan prompt yang basi lebih berbahaya daripada tidak ada
prompt sama sekali, karena ia terdengar yakin.

Dibuat untuk kasus "uji coba deploy repo kerjaan", jadi ada satu bagian khusus
soal itu. Untuk repo pribadi, bagian **Yang berbeda untuk repo kerjaan ini**
bisa dihapus.

## Kenapa dua hal ini ada di dalamnya

**Paket GHCR harus privat.** Pola yang berjalan sekarang membuat paket GHCR
publik — itulah yang membuat Coolify bisa menarik image tanpa kredensial. Untuk
repo pribadi tidak masalah. Untuk repo perusahaan, artinya seluruh kode
sumbernya bisa ditarik siapa saja yang menebak nama paketnya, karena image
memuat hasil build beserta sumbernya. Tanpa disebut eksplisit, asisten mana pun
akan menyalin pola lama apa adanya — itu memang pekerjaan yang benar menurut
dokumen yang ia baca.

**Larangan menulis kode sebelum bertanya.** Tanpa itu, kebanyakan asisten
langsung mengarang `Dockerfile` dan workflow untuk framework yang ditebaknya
sendiri. Repo yang sudah berjalan hampir selalu punya kebutuhan yang tidak
terlihat dari luar: migrasi database, worker latar, build bertingkat.

## Prompt

```text
Saya punya homelab dan ingin mencoba men-deploy satu repo kerjaan ke server
saya sebagai uji coba. Di bawah ini arsitektur yang SUDAH berjalan. Pakai ini
sebagai dasar; jangan usulkan menggantinya kecuali ada alasan kuat.

## Perangkat keras dan jaringan
- Proxmox di sebuah Dell, 192.168.200.10
- VM 101: Coolify, 192.168.200.30, 1.5 vCPU — di sinilah aplikasi web berjalan
- Raspberry Pi 5 (8 GB, NVMe), 192.168.200.11 — stack homelab: Traefik,
  Authelia, Prometheus, Grafana, AdGuard, Home Assistant. Bukan tempat aplikasi.
- Rumah di belakang CGNAT: tidak ada port forwarding. Akses dari luar lewat
  Cloudflare Tunnel; dashboard Coolify dilindungi Cloudflare Access.
- Domain syonin.site di Cloudflare. lab.syonin.site internal (Traefik,
  sertifikat lewat DNS-01); sisanya publik lewat Tunnel.

## Cara aplikasi web dikelola sekarang
Aplikasi TIDAK dibangun di server. Polanya:

  push ke main → GitHub Actions build image → GHCR
               → Actions POST ke /api/v1/deploy milik Coolify
               → Coolify pull dan jalankan

- Build pack Coolify: Docker Compose.
- compose menunjuk :latest; tiap build juga didorong sebagai sha-<short>
  supaya rollback tinggal mengganti satu baris.
- Repo kode privat, jadi docker-compose.yml TIDAK berada di repo kode. Semua
  compose ada di repo publik terpisah: deploy-configs/<app>/docker-compose.yml.
  Coolify diarahkan ke repo itu. Alasannya: Coolify meng-clone repo untuk
  membaca compose, jadi repo itu harus terbaca tanpa kredensial.
- Compose hanya memuat nama image, port, dan NAMA variabel. Nilainya di Coolify.
- TLS diputus di Cloudflare, jadi kolom Domains di Coolify diisi http://...
- Public Hostname di Tunnel selalu localhost:80, berapa pun port internal
  aplikasinya. Yang menerima trafik adalah coolify-proxy.
- Database: pakai resource PostgreSQL milik Coolify, bukan service db di dalam
  compose. Aplikasi wajib Connect to Predefined Network agar sejaringan.
- Secret di repo aplikasi: COOLIFY_TOKEN dan COOLIFY_UUID. GITHUB_TOKEN
  disediakan Actions sendiri.

## Sudah terbukti, jangan diulang
- Webhook auto-deploy GitHub App SELALU ditolak "Invalid signature". Sudah
  diselidiki tuntas lalu ditinggalkan. Deploy dipicu lewat API dari Actions.
- Endpoint deploy wajib -X POST dan force=true. Tanpa force, Coolify bisa
  memakai ulang :latest yang sudah ada di disk dan menayangkan build lama —
  dan semuanya tetap terlihat hijau.
- Coolify tidak membaca ulang compose dari repo tiap deploy. Perubahan compose
  butuh tombol Load compose, jadi tidak ikut otomatis lewat push.
- Nama berkas .yaml vs .yml dan branch main vs master harus cocok persis
  dengan isian di Coolify, kalau tidak gagalnya tanpa penjelasan.
- Env var DATABASE_URL: matikan Interpolation. Sandi buatan Coolify bisa
  mengandung $ dan akan terpotong.

## Yang berbeda untuk repo kerjaan ini
Repo yang mau diuji milik perusahaan, bukan milik saya. Maka:
- Paket GHCR-nya HARUS privat. Pola saya sekarang membuat paket publik supaya
  Coolify bisa menarik tanpa kredensial — untuk repo ini artinya kode sumber
  perusahaan bisa ditarik siapa saja yang tahu namanya. Gantinya: docker login
  ghcr.io di VM Coolify agar daemon-nya punya kredensial.
- Compose-nya jangan ditaruh di deploy-configs yang publik kalau isinya
  mengungkap sesuatu. Usulkan alternatifnya.
- Tidak ada data produksi dan tidak ada secret produksi di server ini.

## Yang saya minta
1. Jelaskan ulang arsitektur di atas dengan bahasa Anda sendiri, supaya saya
   yakin Anda benar-benar memahaminya.
2. Tanyakan dulu apa yang perlu Anda ketahui tentang repo kerjaan itu:
   bahasa/framework, cara build, port, kebutuhan database, env var, apakah ada
   proses background atau migrasi.
3. Baru setelah itu susun langkah konkret untuk uji deploy-nya, termasuk apa
   yang harus saya ubah dari pola GHCR-publik di atas.

Jangan menulis kode atau workflow sebelum pertanyaan di langkah 2 terjawab.
```

## Sebelum memakainya untuk repo kerjaan

Repo dan image-nya akan berpindah ke GHCR pribadi lalu berjalan di server
rumah. Pastikan itu tidak melanggar aturan tempat kerja. Itu keputusan Kevin,
bukan keputusan teknis — tapi keputusannya diambil sekali, sebelum image
pertama didorong, bukan setelahnya.
