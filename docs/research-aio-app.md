# Riset: Aplikasi All-In-One (AIO) untuk Homelab & Daily Use

> Status: draft riset — belum ada keputusan final.
> Tujuan: satu aplikasi untuk pemakaian harian yang bisa memantau **dan** mengendalikan seluruh infrastruktur (router TP-Link, server Proxmox, stack Docker di repo ini, DNS, notifikasi, dst.) dari satu tempat, idealnya dari HP.

---

## 1. Definisi masalah

"AIO" bisa berarti tiga level yang berbeda. Penting dipisah karena effort-nya beda jauh:

| Level | Contoh kemampuan | Effort |
|---|---|---|
| **L1 — Dashboard** | Lihat status semua service, link cepat, uptime, grafik ringkas | Rendah (sudah 80% ada via Homepage di repo ini) |
| **L2 — Kontrol** | Restart VM Proxmox, reboot router, blokir device di DNS, start/stop container | Menengah — butuh API tiap vendor |
| **L3 — Otomasi** | "Kalau internet mati → restart router → kirim ntfy", jadwal, scene | Tinggi — butuh engine otomasi + state |

Target riset ini: **L2 dengan jalan ke L3**, dipakai harian dari HP dan desktop.

---

## 2. Build vs Assemble — survei solusi yang sudah ada

Sebelum menulis kode, cek apakah kombinasi tool open-source sudah menutup kebutuhan:

### Dashboard (L1)
- **Homepage** (gethomepage.dev) — *sudah jalan di repo ini*. Punya **widget API native** untuk Proxmox, Portainer, AdGuard Home, Traefik, Grafana, ntfy, dan ±100 service lain. Artinya: bukan cuma link, tapi angka live (jumlah VM, CPU, query DNS diblokir, dll).
- **Homarr** — mirip Homepage tapi konfigurasi via UI drag-drop, ada integrasi Proxmox/Docker dengan tombol aksi terbatas.
- **Dashy / Heimdall / Flame** — lebih sederhana, murni link + status ping.

### Kontrol & otomasi (L2–L3)
- **Home Assistant (HA)** — kandidat terkuat untuk "AIO tanpa koding". Bukan cuma smart-home:
  - Integrasi **Proxmox VE** (monitor + start/stop/shutdown VM & LXC).
  - Integrasi **TP-Link Omada** (SDN controller) dan **TP-Link Kasa/Tapo** (smart plug/bulb).
  - Integrasi AdGuard Home (toggle proteksi, statistik), Docker (via addon/HACS), ntfy, Prometheus/Grafana.
  - **Automation engine** built-in (trigger–condition–action), companion app Android/iOS dengan push notification, widget, dan akses lokasi.
  - Bisa ditaruh di stack ini, di belakang Traefik + Authelia.
- **n8n / Node-RED** — engine otomasi generik berbasis flow; bagus untuk glue logic antar API, tapi bukan UI harian.
- **Cockpit / Portainer** — manajemen host/container, bukan agregator lintas vendor.

**Kesimpulan sementara:** Homepage (view) + Home Assistant (control & automation) menutup mayoritas kebutuhan tanpa menulis aplikasi baru. Aplikasi custom baru masuk akal kalau (a) UX gabungan satu-layar benar-benar prioritas, (b) ada perangkat yang tidak ada integrasinya, atau (c) memang ingin project untuk belajar.

---

## 3. Inventaris API per target integrasi

Bagian paling menentukan feasibility. Ringkasan per perangkat/layanan:

### 3.1 Proxmox VE ✅ (paling mudah)
- REST API resmi dan terdokumentasi lengkap: `https://<host>:8006/api2/json/...`
- Auth: **API Token** (`user@realm!tokenid=secret`) — tidak perlu password, bisa di-scope dengan role (`PVEAuditor` untuk read-only, `PVEVMAdmin` untuk start/stop).
- Semua bisa dilakukan: list node/VM/LXC, metrics, start/stop/reboot, snapshot, backup, console (via websocket VNC).
- Library matang: `proxmoxer` (Python), `go-proxmox` (Go), `proxmox-api` (Node).
- Risiko: hampir nol. Ini fondasi paling stabil.

### 3.2 TP-Link ⚠️ (tergantung lini produk — ini risiko terbesar)
TP-Link punya tiga ekosistem yang **sangat berbeda** tingkat keterbukaannya:

| Lini | API | Catatan |
|---|---|---|
| **Omada SDN** (controller + EAP/switch/gateway ER-series) | ✅ **OpenAPI resmi** sejak Omada Controller v5.9+ (client_id/secret, token) | Full: klien, SSID, ACL, reboot AP, dsb. Kalau serius mau kontrol jaringan via API, **migrasi ke Omada adalah jalur yang didukung vendor** |
| **Router consumer** (Archer AX/C series) | ❌ Tidak ada API resmi/publik | Opsi: library komunitas **`tplinkrouterc6u`** (Python, reverse-engineered web UI — support banyak model Archer: status, klien WiFi, reboot, toggle WiFi/LED), atau protokol app Tether (unofficial). **Rapuh: bisa putus tiap update firmware**, auth-nya encrypted-payload yang di-reverse |
| **Kasa / Tapo** (smart plug, bulb, cam) | ✅ Protokol lokal sudah sangat matang di komunitas | `python-kasa` — de-facto standard, dipakai Home Assistant |

Keputusan yang harus diambil: model router yang dipakai sekarang masuk lini mana? Kalau consumer Archer → terima ketergantungan pada lib unofficial (dan pin versi firmware), atau batasi fitur router ke "reboot + lihat klien" saja, atau jadwalkan upgrade ke Omada/MikroTik/OpenWrt yang API-nya jelas.

### 3.3 Stack yang sudah ada di repo ini ✅
Semua sudah expose API dan tinggal dipakai:

| Service | API | Auth |
|---|---|---|
| Traefik | `GET /api/http/routers`, dsb. (dashboard API) | via forward-auth Authelia |
| Prometheus | HTTP API `/api/v1/query` — sumber metric universal | — |
| Grafana | HTTP API (dashboard, alerting, datasource) | service account token |
| AdGuard Home (profile) | REST API: statistik, toggle proteksi, blokir/unblokir domain & client | basic auth |
| Portainer (profile) | REST API penuh untuk container ops (lebih aman daripada expose docker.sock) | API key |
| ntfy (profile) | Publish notifikasi = `POST https://ntfy.<domain>/<topic>` | token |
| Authelia | Bertindak sebagai SSO gateway untuk app AIO-nya sendiri; header `Remote-User`/`Remote-Groups` bisa dipakai app untuk authz | — |

### 3.4 Target lain yang umum menyusul ("dan lain-lain")
- **TrueNAS / Synology** — REST API resmi, bagus.
- **MikroTik** — REST API resmi (RouterOS v7); alternatif router paling API-friendly.
- **Tuya/Tapo/ESPHome IoT** — lebih baik lewat Home Assistant daripada integrasi langsung.
- **UPS (NUT)**, **Wake-on-LAN** — protokol sederhana, mudah ditambahkan sebagai adapter.

---

## 4. Arsitektur kalau tetap build aplikasi custom

### 4.1 Prinsip desain
1. **Adapter pattern** — satu interface umum (`getStatus()`, `listEntities()`, `invokeAction()`), satu adapter per vendor. Vendor rapuh (TP-Link consumer) terisolasi: kalau putus, sisanya tetap jalan.
2. **Backend yang pegang kredensial, bukan client** — HP/browser tidak pernah menyimpan token Proxmox/router.
3. **PWA dulu, bukan native** — installable di Android/iOS, push notification bisa dilewatkan ntfy. Flutter/React Native hanya kalau butuh fitur native (mis. deteksi WiFi SSID untuk auto-switch URL lokal/remote).
4. **Read-path lewat Prometheus** kalau bisa — jangan poll tiap device dari app; Prometheus sudah jadi agregator metric. App custom fokus di **write-path** (aksi) + view real-time.

### 4.2 Sketsa arsitektur

```
                    ┌─────────────────────────────┐
   HP / Desktop ───▶│  PWA (Next.js / SvelteKit)  │
   (via Traefik +   └──────────────┬──────────────┘
    Authelia SSO)                  │ REST + WebSocket/SSE
                    ┌──────────────▼──────────────┐
                    │   Backend "Integration Hub"  │
                    │  (Go atau Node/TS; NestJS)   │
                    │  - registry adapter          │
                    │  - credential vault (enc.)   │
                    │  - poller + cache            │
                    │  - action audit log          │
                    │  - rule engine (fase 3)      │
                    └───┬────┬────┬────┬────┬─────┘
             adapters:  │    │    │    │    │
                  Proxmox  TP-Link  AdGuard  Portainer  ntfy
                  (REST)  (omada API │ tplinkrouterc6u)  ...
                                   │
                    Prometheus ◀───┘ (read-path metrik)
```

- **Bahasa backend:** Go (binary kecil, cocok untuk network tooling, `go-proxmox` tersedia) atau **TypeScript/NestJS** (satu bahasa dengan frontend, ekosistem lib integrasi luas). Python (FastAPI) menang di library integrasi (`proxmoxer`, `tplinkrouterc6u`, `python-kasa` semuanya Python) → **kalau prioritasnya kecepatan integrasi, Python adalah pilihan pragmatis.**
- **State:** SQLite cukup (konfigurasi, audit log, cache); tidak perlu Postgres di awal.
- **Realtime:** SSE lebih sederhana daripada WebSocket dan cukup untuk status feed.
- **Deploy:** satu container di `docker-compose.yml` repo ini, network `proxy` + label `authelia@file` — auth, HTTPS, dan rate-limit sudah beres dari stack yang ada.

### 4.3 Keamanan (wajib, karena app ini "memegang kunci semua")
- Token per-integrasi dengan **least privilege** (contoh: mulai dengan `PVEAuditor`, baru naikkan saat fitur aksi dibuat).
- Kredensial dienkripsi at-rest (age/sops atau libsodium sealed box), master key via Docker secret — pola yang sama dengan `secrets/` di repo ini.
- **Audit log** untuk setiap aksi write (siapa, kapan, apa) — header `Remote-User` dari Authelia jadi identitas.
- Aksi berbahaya (shutdown node, reboot router) → konfirmasi dua langkah di UI.
- Jangan pernah expose API vendor langsung ke internet; hanya backend yang boleh menjangkaunya, idealnya via VLAN manajemen.
- Akses remote: lebih aman via **Tailscale/WireGuard** daripada membuka app ke internet publik, meski sudah di belakang Authelia.

---

## 5. Rekomendasi & roadmap bertahap

**Rekomendasi: jalur hibrida — assemble dulu, build sesudah jelas gap-nya.** Nilai terbesar (satu layar untuk semua) tercapai cepat, dan kalau lanjut build, fase awal sudah memvalidasi API mana yang stabil.

| Fase | Isi | Hasil |
|---|---|---|
| **0. Maksimalkan yang ada** (hari) | Aktifkan widget API di `homepage/config/services.yaml` (Proxmox, AdGuard, Portainer, Traefik, Grafana) — bukan cuma link tapi data live | L1 selesai |
| **1. Home Assistant sebagai control-plane** (minggu) | Tambah HA ke compose (profile `homeassistant`), pasang integrasi Proxmox + TP-Link + AdGuard + ntfy, buat dashboard mobile + beberapa automation | L2 + L3 dasar, tanpa koding |
| **2. Validasi TP-Link** (paralel) | PoC kecil: script Python `tplinkrouterc6u` ke router yang dipakai — catat model + versi firmware yang terbukti jalan | Risiko terbesar terjawab |
| **3. Custom app MVP** (bulan, opsional) | Backend hub + PWA: read-only view Proxmox & Docker & DNS dalam satu layar, SSO via Authelia | Ganti L1 dengan UX sendiri |
| **4. Aksi + otomasi** | Tombol aksi (start/stop VM, reboot router, toggle AdGuard) + audit log; rule engine sederhana; push via ntfy | AIO penuh |

### Open questions (perlu dijawab sebelum fase 3)
1. ~~Model router TP-Link yang dipakai persisnya apa?~~ ✅ **Terjawab (2026-08-27): TL-MR100 — didukung `tplinkrouterc6u`, lihat §6.**
2. Akses dari luar rumah: VPN (Tailscale) atau expose publik? → **Karena router-nya LTE (kemungkinan besar CGNAT), praktis wajib Tailscale/Cloudflare Tunnel — lihat §6.2.**
3. Siapa pengguna app — sendiri, atau ada user lain (istri/keluarga) yang butuh UI super sederhana? (mempengaruhi seberapa penting fase 3)
4. Kalau build: prioritas bahasa — Python (integrasi tercepat) vs Go/TS (runtime & DX)?

---

## 6. Profil hardware aktual & implikasinya (update 2026-08-27)

Perangkat yang benar-benar dipakai:

| Perangkat | Spesifikasi | Peran yang disarankan |
|---|---|---|
| **TP-Link TL-MR100** | Router 4G LTE, WiFi N300 | Gateway internet (LTE) |
| **D-Link DGS-1100-08V2** | Switch smart managed 8-port gigabit | Backbone LAN |
| **Dell Vostro 5459** | Laptop i5 gen-6 (2C/4T), SSD 500GB | **Proxmox host** — lab VM/LXC |
| **Raspberry Pi 5** | SSD NVMe 256GB | **Control plane always-on** — stack Docker repo ini |

### 6.1 TL-MR100 — terverifikasi didukung ✅
`tplinkrouterc6u` mendukung TL-MR100 lewat class **`TPLinkMRClient`** (seri MR/LTE). Artinya PoC fase 2 sudah jelas bentuknya: reboot router, toggle WiFi, daftar klien, status sinyal/data LTE — dan khusus seri MR ada **akses SMS** (kirim/baca SMS dari SIM), yang untuk operator Indonesia berguna buat cek/beli kuota langsung dari app. Catat versi hardware di label router (v1/v2/v3) dan pin versi firmware yang terbukti jalan.

### 6.2 Konsekuensi terbesar: internet via LTE = kemungkinan besar CGNAT ⚠️
Operator seluler (Telkomsel/XL/Indosat dkk.) umumnya menaruh pelanggan di belakang **Carrier-Grade NAT** — tidak ada IP publik. Dampaknya ke seluruh stack ini:

- **Port 80/443 tidak bisa diakses dari internet** → port forwarding percuma.
- **Let's Encrypt HTTP-01 challenge (konfigurasi Traefik saat ini) akan GAGAL** → harus ganti ke **DNS-01 challenge** (mis. domain di Cloudflare, `dnsChallenge` dengan API token). Bonus: bisa wildcard cert `*.domain`.
- **Akses remote** → pakai **Tailscale** (install di Pi 5 + Vostro; gratis, tembus CGNAT) atau **Cloudflare Tunnel** kalau ada layanan yang memang mau dibuka publik.

Cara memastikan: bandingkan IP WAN di halaman admin MR100 dengan hasil `curl ifconfig.me` — kalau beda, berarti CGNAT. *(Selesai 2026-08-31: `traefik/traefik.yml.tmpl` sudah memakai dnsChallenge Cloudflare.)*

### 6.3 DGS-1100-08V2 — monitoring via SNMP ✅
Seri DGS-1100 punya dukungan **SNMP MIB** (aktifkan dulu di web UI switch). Tidak ada REST API — konfigurasi VLAN dsb. tetap manual via web UI — tapi untuk kebutuhan AIO (traffic per port, status link, error counter) cukup lewat **`snmp_exporter` → Prometheus → widget di dashboard**. Kontrol write via SNMP di kelas ini terbatas; anggap switch sebagai *monitor-only*.

### 6.4 Pembagian peran dua mesin
Prinsip: **control plane dipisah dari lab** supaya dashboard/DNS/VPN tetap hidup saat Proxmox dioprek.

```
Internet 4G (CGNAT?)
      │
  TL-MR100 ─── DGS-1100-08V2 ─┬─ Dell Vostro 5459 → Proxmox VE
      (LTE)      (switch,     │    ├─ LXC/VM lab, Home Assistant OS (fase 1)
                  SNMP)       │    └─ pve_exporter → discrape Prometheus di Pi
                              └─ Raspberry Pi 5 (NVMe) → stack Docker repo ini
                                   ├─ Traefik + Authelia + Grafana + Prometheus
                                   ├─ AdGuard Home (DNS LAN) + Homepage + ntfy
                                   └─ Tailscale (pintu akses remote)
```

- **Pi 5 = rumah stack repo ini.** Semua image di compose sudah multi-arch ARM64, jadi tinggal deploy. AdGuard di Pi jadi DNS untuk seluruh LAN (set DHCP di MR100 agar mengumumkan IP Pi sebagai DNS).
- **Vostro = Proxmox.** Catatan laptop-as-server: i5-6200U cuma 2C/4T → utamakan **LXC** daripada VM penuh; set `HandleLidSwitch=ignore`, matikan suspend; baterai laptop = UPS gratisan (tapi cek kesehatan baterai tua — kembung = lepas saja); batasi charge threshold kalau BIOS mendukung.
- Scrape tambahan untuk Prometheus (menyusul): `pve-exporter` (Proxmox), `snmp_exporter` (switch), exporter kecil custom berbasis `tplinkrouterc6u` (router — sekalian jadi PoC fase 2).

## 7. Referensi

- Proxmox VE API viewer: `https://pve.proxmox.com/pve-docs/api-viewer/`
- Omada OpenAPI: menu *Settings → Platform Integration → Open API* di Omada Controller (v5.9+)
- `tplinkrouterc6u`: `https://github.com/AlexandrErohin/TP-Link-Archer-C6U` (daftar model — TL-MR100 didukung via `TPLinkMRClient`)
- Spesifikasi TL-MR100: `https://service-provider.tp-link.com/lte-router/tl-mr100/`
- DGS-1100-08V2 (seri dengan SNMP MIB): `https://www.dlink.com/us/en/products/dgs-1100-08v2-8-port-gigabit-smart-managed-switch`
- `python-kasa`: `https://github.com/python-kasa/python-kasa`
- Homepage widgets: `https://gethomepage.dev/widgets/`
- Home Assistant integrations: `https://www.home-assistant.io/integrations/` (cari: proxmoxve, tplink_omada, tplink, adguard, ntfy)
- AdGuard Home API: `https://github.com/AdguardTeam/AdGuardHome/tree/master/openapi`
- Portainer API: `https://docs.portainer.io/api/docs`

> Catatan: versi/fitur di atas sesuai kondisi awal 2026 — verifikasi ulang halaman resminya saat mulai implementasi, terutama daftar model `tplinkrouterc6u` dan versi minimum Omada Controller.
