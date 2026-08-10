# Pterodactyl Auto-Installer

Jawab beberapa soalan. Ia pasang **Panel + Wings + node + allocation + egg**,
serta **Node.js** dan **Python 3**, sampai siap.

```bash
git clone https://github.com/earltiktokofficial04-jpg/agent-plugins.git
cd agent-plugins/pterodactyl-autoinstall
sudo ./install.sh
```

Selepas itu, `sudo pterodactyl-doctor` menyemak pemasangan dan membaiki apa yang
boleh dibaiki, bila-bila masa.

## Yang jujur perlu kau tahu dulu

Tiada script boleh "prediksi segala error". Apa yang script ini buat ialah
memberi **beberapa kaedah untuk setiap langkah rapuh**, dan mencuba kaedah
seterusnya sendiri apabila yang pertama gagal:

```
▸ (2/17) PHP dan sambungannya
   → PHP 8.2/8.3 — kaedah 1/5: repo yang sudah dikonfigurasi
   ! kaedah 1 gagal
   → PHP 8.2/8.3 — kaedah 2/5: PPA ondrej/php
   ✔ berjaya melalui PPA ondrej/php
```

Tiga perkara ia **tidak** boleh selesaikan sendiri, dan akan beritahu kau
dengan jelas apabila ia berlaku:

1. **DNS domain kau belum menunjuk ke server ini** — HTTPS akan dilangkau, panel
   diteruskan atas HTTP, dan kau diberi arahan tepat untuk pasang sijil kemudian.
2. **VPS OpenVZ atau LXC** — Docker tidak berfungsi di situ, jadi Wings tidak
   boleh menjalankan game server. Ini dikesan **sebelum** apa-apa dipasang.
3. **GitHub menghadkan muat turun tanpa token** — ia cuba `--prefer-source`
   dahulu; kalau itu pun gagal, kau diminta beri `--github-token`.

## Soalan yang ditanya

Enam, dan semuanya ada default kecuali email:

| Soalan | Default |
|---|---|
| Alamat panel — domain atau IP | IP awam server, dikesan automatik |
| Pasang HTTPS Let's Encrypt? | ya (dilangkau terus kalau alamatnya IP) |
| Email admin | — (satu-satunya yang mesti kau taip) |
| Username admin | `admin` |
| Password admin | dijana automatik (tekan Enter) |
| Pasang Wings juga? | ya |
| Pasang Node.js + Python? | ya |

Semua yang lain dikesan: zon waktu, RAM dan disk untuk saiz node, port bebas,
subnet Docker yang tidak bertindih, julat allocation, nama node daripada
hostname, password pangkalan data. Kau nampak semuanya dalam ringkasan
**sebelum** apa-apa disentuh, dan kena tekan `y` untuk teruskan.

## Mod lain

```bash
sudo ./install.sh --doctor        # semak dan baiki pemasangan sedia ada
sudo ./install.sh --dry-run       # tunjuk rancangan, jangan ubah apa-apa
sudo ./install.sh --reconfigure   # tanya semula soalan
sudo ./install.sh --uninstall     # buang
sudo ./install.sh --config f.conf --non-interactive   # tanpa pengawasan
```

Jawapan disimpan, jadi jalankan semula tidak bertanya lagi. Kemajuan disimpan
per fasa, jadi jalankan semula arahan yang sama menyambung dari tempat gagal.

## Keperluan

| Perkara | Nilai |
|---|---|
| OS | Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12 |
| Seni bina | x86_64 atau aarch64 |
| RAM | 1GB minimum, 2GB+ disyorkan |
| Disk | 5GB kosong |
| Akses | root (`sudo`) |
| Wings | KVM atau bare metal. **Bukan** OpenVZ/LXC. |

## Rantaian fallback

| Langkah | Kaedah, mengikut urutan |
|---|---|
| PHP 8.2/8.3 | repo distro → PPA ondrej → sury.org → baiki pakej rosak → apa-apa PHP 8.x |
| Composer | pemasang rasmi (checksum) → phar terus → pakej distro |
| Node.js | NodeSource → pakej distro → tarball rasmi nodejs.org |
| Python 3 | python3 distro → python3-full → PPA deadsnakes |
| Pangkalan data | mariadb-server → cipta semula dir socket → mysql-server |
| Akaun DB | akaun untuk `127.0.0.1` **dan** `localhost` → hos `%` |
| Redis | pakej distro → lancar terus → jatuh ke cache/session fail |
| Fail panel | curl → wget → versi tetap yang diketahui baik |
| Composer panel | biasa → `--prefer-source` → `--ignore-platform-req` → kosongkan cache |
| Migrasi | `migrate --seed` → migrate, kemudian seed berasingan |
| Pelayan web | nginx → nginx tanpa IPv6 → nginx port ganti → Apache + fcgi |
| HTTPS | pasang semula sijil ada → certbot nginx → webroot → standalone → turun ke HTTP |
| Service | unit systemd → script pelancar tanpa systemd |
| Docker | daemon ada → get.docker.com → docker.io distro → repo apt rasmi |
| Binari Wings | curl → wget → versi tetap |
| Node panel | `p:node:make` → cuba semula dengan skema http |
| Wings jalan | mula → buang rangkaian tersangkut → tukar subnet → tukar port |

Setiap kaedah disahkan selepas dijalankan — "berjaya" bermakna semakan lulus,
bukan sekadar arahan keluar dengan kod 0.

## Pengesahan dan pembaikan diri

Pada penghujung, 15–18 semakan dijalankan. Yang gagal dicuba baiki dahulu
(bounded — satu pusingan per strategi, tidak boleh berpusing selamanya):

panel menjawab HTTP · aset frontend dimuatkan · **log masuk admin sebenar
melalui HTTP** · pangkalan data · Redis · akaun admin · egg · queue worker ·
scheduler · Node.js · Python · Docker · binari Wings · config Wings · node
berdaftar · allocation · proses Wings · Wings mendengar pada portnya

Kalau ada yang masih gagal, script **enggan** melaporkan "siap" — ia senaraikan
apa yang gagal dan beritahu kau jalankan `pterodactyl-doctor`.

## Keselamatan

Perkara yang script ini buat berbeza daripada panduan pemasangan biasa:

- **Scheduler berjalan sebagai `www-data`, bukan root.** Panduan upstream letak
  `php artisan schedule:run` dalam crontab root, tetapi seluruh direktori panel
  dimiliki `www-data` — jadi sesiapa yang menguasai proses web boleh menulis
  `artisan` dan mendapat root pada minit berikutnya.
- `.env` ditulis 0600 milik `www-data` (`.env.example` datang 0644).
- `storage/` 0750, bukan 0755 — log Laravel bukan bacaan awam.
- Log pemasang 0600, dan password diredaksi daripada apa yang dilog.
- Password pangkalan data tidak dihantar pada baris arahan (`ps` menampakkannya)
  — ia melalui fail `defaults-extra-file` 0600 sementara.
- Fail sementara guna `mktemp`, bukan nama tetap dalam `/tmp` yang boleh diteka
  lalu dilaksanakan sebagai root.
- Pemasang Composer disemak terhadap checksum rasmi sebelum dijalankan.
- Nilai daripada sumber luar (nama dalam fail egg) di-escape sebelum masuk SQL.

## Status ujian

Diuji hujung-ke-hujung dalam container Ubuntu 24.04 yang bersih — tanpa `curl`,
`ss`, `php`, `python3`, `node` atau `sudo` pada mulanya.

**Disahkan berfungsi:** wizard interaktif (jawapan diterima, auto-kesan, plan,
pengesahan), preflight, PHP 8.3 + semua sambungan, Composer, **Node.js 22 via
NodeSource**, **Python 3.12 + venv**, MariaDB dengan akaun dua-hos dan log masuk
diuji, Redis, muat turun panel, **fallback composer benar-benar berfungsi**
(kaedah 1 kena rate-limit GitHub, kaedah 2 `--prefer-source` mengambil alih
sendiri), `.env` + migrasi + egg rasmi, akaun admin, nginx + PHP-FPM, queue
worker, Docker, binari Wings, node + allocation + `config.yml`, handshake
Wings↔Panel, import egg custom, dan log masuk HTTP sebenar.

Rantaian fallback yang benar-benar dilihat berjalan semasa ujian, bukan sekadar
ditulis:

- **Composer**: kaedah 1 kena rate-limit GitHub → kaedah 2 `--prefer-source`
  mengambil alih sendiri dan berjaya.
- **Docker**: kaedah 1 (daemon sedia ada) gagal → kaedah 2 `get.docker.com`
  berjaya.
- **Queue worker**: unit systemd gagal (tiada systemd) → script pelancar berjaya.
- **Subnet Wings**: mengesan pertindihan dan mencuba 172.19 → 172.20 → 172.21
  → 172.22 → 172.23 berturut-turut, dengan had 5 cubaan.

**Tidak dapat diuji dalam persekitaran itu:**

1. **Sijil Let's Encrypt** — perlukan domain awam sebenar.
2. **Wings hidup sepenuhnya** — kernel VM ujian dibina **tanpa IPv6**, jadi
   Docker tidak boleh mencipta bridge sama sekali. Rantaian subnet berjaya
   melepasi ralat "Pool overlaps", kemudian terserempak had kernel ini. Script
   melaporkan puncanya dengan tepat dan tidak berpura-pura berjaya. Pada VPS
   KVM biasa `/proc/sys/net/ipv6` memang wujud dan langkah ini berfungsi.
3. **UFW/fail2ban** — tidak diaktifkan dalam container.

## Dari mana pembetulan datang

Kod ini melalui audit adversarial empat lensa (semantik bash di bawah
`set -Eeuo pipefail`, keselamatan ulang-jalan, keselamatan, ketepatan
merentas distro), dan setiap penemuan disemak semula untuk menolak yang palsu.
Antara pepijat sebenar yang ditemui dan dibaiki:

- `cmd | grep -q` di bawah `pipefail` melaporkan "tidak jumpa" pada padanan yang
  ADA, kerana penulis di hulu dapat SIGPIPE. Ini merosakkan pengesanan PHP,
  `port_owner`, dan semakan scheduler.
- Pada `--force`, fasa webserver menulis semula vhost dan memusnahkan suntingan
  certbot, sementara semakan SSL masih nampak folder sijil — HTTPS mati senyap.
- `> config.yml` memotong fail sebelum `artisan` jalan, jadi satu kegagalan
  memusnahkan config Wings yang berfungsi.
- `$(tail -c1)` membuang newline, jadi ujian "fail berakhir dengan newline?"
  sentiasa benar dan satu baris kosong ditambah pada `.env` setiap kali.
- ERR trap diwarisi ke subshell, mencetak dua banner merah untuk satu kegagalan.
- Subnet Docker dikira semula setiap run dan hanyut, kerana rangkaian Wings
  sendiri dikira sebagai "sudah diguna".
- `--config` sebagai argumen terakhir menyebabkan `shift 2` gagal dan mencetak
  banner ralat dalaman, bukan mesej yang berguna.
