# Deploy aplikasi lewat Coolify

Coolify jalan di VM tersendiri (`192.168.200.30`, VMID 101 di Proxmox), terpisah
dari stack homelab karena dia memasang reverse proxy sendiri yang menuntut port
80 dan 443.

Aplikasi tidak dibangun di server. Kita membangun image di laptop, mendorongnya
ke GitHub Container Registry, lalu Coolify tinggal menariknya. Alasannya dua:
VM itu hanya diberi 1.5 CPU, dan yang tayang jadi persis yang sudah diuji.

```
laptop: build image  →  ghcr.io  →  Coolify pull  →  container jalan
```

## Sekali saja, per aplikasi baru

### 1. Tiga berkas di repo

`Dockerfile` — contoh untuk situs statis:

```dockerfile
FROM nginx:1.29-alpine
COPY . /usr/share/nginx/html
EXPOSE 80
```

`.dockerignore`:

```
.git
.github
.dockerignore
Dockerfile
docker-compose.yaml
README.md
```

`docker-compose.yaml` — **namanya harus `.yaml`**, Coolify tidak mengenali `.yml`:

```yaml
services:
  web:
    image: ghcr.io/huangmingzhi0206/<repo>:v1.0.0
    restart: unless-stopped
    environment:
      - SERVICE_FQDN_WEB_80
    expose:
      - "80"
```

Baris `SERVICE_FQDN_WEB_80` memberi tahu Coolify layanan dan port mana yang
perlu diberi domain.

### 2. Izin dorong ke registry

Sekali per komputer. Buat Personal Access Token (classic) dengan scope
`write:packages`, lalu:

```bash
docker login ghcr.io -u HuangMingZhi0206
```

Password diisi token itu, bukan kata sandi GitHub.

### 3. Resource di Coolify

Projects → environment → **+ New** → **Public Git Repository**.

```
Repository URL          : https://github.com/HuangMingZhi0206/<repo>
Branch                  : master
Build Pack              : Docker Compose
Docker compose location : /docker-compose.yaml
```

Tekan **Load compose**, Save, lalu Deploy.

### 4. Domain

Tab **Domains**, isi `http://<nama>.syonin.site` — tetap `http`, karena TLS
diputus di Cloudflare.

Lalu daftarkan hostname-nya di Cloudflare Tunnel: Zero Trust → Networks →
Tunnels → `coolify` → Public Hostname → Add.

```
Subdomain : <nama>
Domain    : syonin.site
Type      : HTTP
URL       : localhost:80
```

`localhost:80` selalu, berapa pun port internal aplikasinya. Yang menerima
trafik adalah coolify-proxy di port 80; dia yang meneruskan ke container.

## Setiap rilis

Misalnya menaikkan ke `v1.1.0`:

```bash
git add -A && git commit -m "<perubahannya>"
```

```bash
docker build -t ghcr.io/huangmingzhi0206/<repo>:v1.1.0 .
```

```bash
docker push ghcr.io/huangmingzhi0206/<repo>:v1.1.0
```

Ubah baris `image:` di `docker-compose.yaml` ke `v1.1.0`, lalu:

```bash
git tag v1.1.0 && git add docker-compose.yaml && git commit -m "Naikkan ke v1.1.0" && git push origin master --tags
```

Di Coolify: **Load compose** → **Save changes** → **Deploy**.

`Load compose` wajib ditekan. Tanpa itu Coolify masih memegang salinan compose
yang lama dan akan menjalankan versi sebelumnya.

Jangan pernah menimpa tag yang sudah dipakai — begitu ditimpa, versi lama tidak
bisa dipanggil kembali.

## Rollback

Kembalikan baris `image:` ke tag sebelumnya, commit, push, Load compose, Deploy.
Sekitar tiga puluh detik, tanpa build ulang.

## Jebakan yang sudah memakan waktu

**`unauthorized` saat pull.** Paket di GHCR masih privat. Buka
`github.com/HuangMingZhi0206?tab=packages` → paketnya → Package settings →
Danger Zone → Change visibility → Public. Kalau memang harus privat, jalankan
`docker login ghcr.io` di VM Coolify supaya daemon-nya punya kredensial.

**"Failed to read the Docker Compose file from the repository."** Hampir selalu
nama berkas: Coolify mencari `docker-compose.yaml`, bukan `.yml`. Periksa juga
branch — Coolify default ke `main`, sementara repo lama sering `master`.

**404 padahal deploy sukses.** Domain yang sama masih terpasang di resource
lain. Satu domain hanya boleh dipegang satu resource; kosongkan di yang lama
dulu.

**Kolom yang isinya contoh.** Banyak form Coolify menampilkan contoh abu-abu
yang terlihat seperti isi sungguhan — `php artisan migrate`,
`ghcr.io/your-org/your-app`, `3000:3000`, `192.168.1.100, 10.0.0.0/8`. Jangan
pernah menyimpannya.

**Perubahan memori VM.** Diubah lewat `qm set` tidak berlaku pada VM yang sedang
jalan; harus dimatikan dan dinyalakan ulang. Gejala kalau lupa: Coolify menjawab
"did not receive a response" karena kehabisan memori.

## Repo privat

Butuh GitHub App sebagai sumber, bukan Public GitHub. Buat lewat **Manual
installation** — alur otomatisnya mengarahkan browser kembali ke alamat instance
yang tidak terjangkau di belakang CGNAT.

Webhook auto-deploy dari GitHub App **belum pernah berhasil** di instance ini;
selalu ditolak `Invalid signature`. Yang sudah terbukti bukan penyebabnya:
Cloudflare Tunnel dan Access, ukuran payload, header delivery, nilai secret di
sisi Coolify, dan App-nya sendiri. Jangan mengulang lima langkah itu. Deploy
ditekan manual, dan itu memang pilihan yang disengaja sekarang.
