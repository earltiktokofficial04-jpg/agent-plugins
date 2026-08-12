# Pterodactyl Auto-Installer

Jawab beberapa soalan. Ia pasang **Panel + Wings + node + allocation + egg**,
serta **Node.js** dan **Python 3**, sampai siap.

```bash
git clone https://github.com/earltiktokofficial04-jpg/agent-plugins.git
cd agent-plugins/pterodactyl-autoinstall
sudo ./install.sh
```

## Yang jujur perlu kau tahu dulu

Tiada script boleh "prediksi segala error". Apa yang script ini buat ialah
memberi **beberapa kaedah untuk setiap langkah rapuh**, dan mencuba kaedah
seterusnya sendiri apabila yang pertama gagal:

```
▸ (2/19) PHP dan sambungannya
   → PHP 8.2/8.3 — kaedah 1/5: repo yang sudah dikonfigurasi
   ! kaedah 1 gagal
   → PHP 8.2/8.3 — kaedah 2/5: PPA ondrej/php
   ✔ berjaya melalui PPA ondrej/php
```

Bila semua kaedah untuk sesuatu matlamat gagal, ia mencetak **sebab setiap satu
gagal**, bukan sekadar "gagal".

Tiga perkara ia **tidak** boleh selesaikan sendiri, dan akan beritahu kau dengan
jelas bila ia berlaku: DNS domain kau belum menunjuk ke server ini; VPS OpenVZ
atau LXC (Docker memang tidak berfungsi di situ, dan ini dikesan **sebelum**
apa-apa dipasang); dan had kadar GitHub yang memerlukan token.

## Soalan yang ditanya

Enam, dan hanya email yang mesti kau taip:

| Soalan | Default |
|---|---|
| Alamat panel — domain atau IP | IP awam server, dikesan automatik |
| Pasang HTTPS Let's Encrypt? | ya (dilangkau terus kalau alamatnya IP) |
| Di belakang Cloudflare/proxy? | tidak — hanya ditanya bila ia relevan |
| Email admin | — |
| Username admin | `admin` |
| Password admin | dijana automatik (tekan Enter) |
| Pasang Wings juga? | ya |
| Pasang Node.js + Python? | ya |

Semua yang lain dikesan: zon waktu, RAM dan disk untuk saiz node, port bebas,
subnet Docker yang tidak bertindih, julat allocation, nama node daripada
hostname, password pangkalan data. Kau nampak semuanya dalam ringkasan
**sebelum** apa-apa disentuh, dan kena tekan `y` untuk teruskan.

## Mod

| Mod | Kegunaan |
|---|---|
| `sudo ./install.sh` | Pasang panel penuh |
| `--wings-only` | Pasang Wings sahaja pada mesin **kedua**, sertai panel sedia ada |
| `--add-node` | Daftar node tambahan pada panel di mesin ini |
| `--upgrade` | Naik taraf panel ke keluaran terkini (backup dahulu, wajib) |
| `--backup` | Simpan pangkalan data + `.env` + config Wings |
| `--restore [FOLDER]` | Pulihkan daripada backup (default: yang terakhir) |
| `--status` | Versi, keadaan service, kiraan pengguna/node/server, tarikh luput sijil |
| `--doctor` | Semak pemasangan dan baiki apa yang boleh |
| `--uninstall` | Buang panel, DB, config Wings, service |

Pilihan: `--config FAIL`, `--non-interactive`, `--reconfigure`, `--github-token`,
`--dry-run`, `--force`, `--skip-preflight`, `-y`.

Selepas pemasangan, `sudo pterodactyl-doctor` menjalankan semakan dan pembaikan
yang sama bila-bila masa.

### Node kedua

Pada mesin panel:

```bash
sudo ./install.sh --add-node
```

Kemudian pada mesin node itu, salin nilai daripada panel
(Admin → Nodes → *node* → Configuration → Auto Deploy) dan jalankan:

```bash
sudo ./install.sh --wings-only
```

Ia meminta URL panel, token, dan ID node, kemudian menyerahkannya kepada
`wings configure` — cara rasmi, jadi `config.yml` termasuk sijilnya betul.

## Keperluan

| Perkara | Nilai |
|---|---|
| OS | Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12 |
| Seni bina | x86_64 atau aarch64 |
| RAM | 1GB minimum, 2GB+ disyorkan (768MB kalau panel sahaja) |
| Disk | 5GB kosong (2.5GB kalau panel sahaja; 1.5GB kosong diperlukan semasa fasa composer) |
| Akses | root (`sudo`) — kecuali Termux, yang memang tidak pernah ada root |
| Wings | KVM atau bare metal. **Bukan** OpenVZ/LXC/Termux. |

## Persekitaran yang dikesan

Script mengenal pasti di mana ia berjalan **sebelum** apa-apa dipasang, kemudian
menyesuaikan laluan, nama pakej, pemilik fail dan cara service dijalankan. Kau
tidak perlu beritahu ia apa-apa, dan ia tunjukkan apa yang ia dapati dalam
ringkasan sebelum kau tekan `y`.

| Persekitaran | Panel | Wings | Nota |
|---|---|---|---|
| VPS KVM / Xen / VMware / Hyper-V / bare metal | ✅ | ✅ | laluan penuh, ini yang diuji hujung-ke-hujung |
| WSL2 | ✅ | ✅ | service tidak bermula sendiri selepas Windows reboot |
| Container Docker / Podman | ✅ | ⚠️ | Wings tetap dicuba — ia berjaya kalau container itu privileged |
| VPS OpenVZ / LXC | ✅ | ❌ | dikesan awal, Wings dimatikan dengan sebab yang dinyatakan |
| WSL1 | ✅ | ❌ | lapisan terjemahan syscall, tiada kernel sebenar |
| **Termux (Android)** | ⚠️ | ❌ | eksperimen — baca bahagian di bawah |

Perkara yang benar-benar bertukar apabila persekitaran bertukar:

| | Linux biasa | Termux |
|---|---|---|
| Laluan | `/var/www`, `/etc`, `/var/log` | semuanya di bawah `$PREFIX` |
| Nama pakej | `mariadb-server`, `php8.3-fpm` | `mariadb`, `php-fpm` |
| Pemilik fail panel | `www-data` | kau sendiri — tiada `chown` langsung |
| PHP-FPM | socket unix per versi | TCP `127.0.0.1:9000` |
| vhost nginx | `sites-available` + symlink | `conf.d/`, dengan `include` disuntik ke `nginx.conf` |
| Direktori data DB | dicipta oleh postinst pakej | `mariadb-install-db` dijalankan sendiri |
| `mariadbd-safe` | `--user=mysql` | tanpa bendera itu (tiada pengguna `mysql`) |
| Scheduler | `/etc/cron.d` sebagai `www-data` | gelung dalam `pterodactyl-services` |
| Swap sementara | dicipta untuk composer | dilangkau — Android larang `swapon` |
| Firewall | ufw + fail2ban | dilangkau — tiada akses netfilter |
| Semakan root | wajib | dilangkau |

### Termux — apa yang jujur

**Wings mustahil di Termux.** Ia memerlukan Docker, yang memerlukan cgroups dan
namespace, yang Android tidak berikan kepada aplikasi tanpa root. Tiada script
yang boleh mengakalinya. Yang kau dapat ialah **panel sahaja** — berguna untuk
belajar, dan untuk mengurus node yang berjalan pada mesin lain.

Laluan Termux ditulis sepenuhnya dan berkelakuan betul dalam ujian bersimulasi
(pengesanan, penulisan semula laluan, pemetaan nama pakej, pemilihan strategi,
paparan rancangan), tetapi **saya belum menjalankannya pada telefon Android
sebenar**. Ia dilabel eksperimen atas sebab itu.

Satu perkara boleh menghentikannya, dan script akan memberitahu kau dengan jelas
kalau ia berlaku: pakej `php` Termux mesti sudah mengandungi `gd`, `mbstring`,
`bcmath`, `curl`, `zip`, `intl`, `pdo_mysql` dan `dom`. Repo Termux tidak
menyediakan pakej per-sambungan, jadi kalau satu daripadanya tiada, tiada apa
yang boleh dipasang untuk menampalnya. Semak sendiri: `php -m`.

```bash
pkg install git
git clone https://github.com/earltiktokofficial04-jpg/agent-plugins.git
cd agent-plugins/pterodactyl-autoinstall
./install.sh          # tanpa sudo — Termux memang tiada root
```

## Rantaian fallback

| Langkah | Kaedah, mengikut urutan |
|---|---|
| PHP 8.2/8.3 | repo distro → PPA ondrej → sury.org → baiki pakej rosak → apa-apa PHP 8.x |
| PHP (Termux) | `pkg install php php-fpm` → `pkg install php` sahaja |
| Composer | pemasang rasmi (checksum) → phar terus → pakej distro |
| Node.js | NodeSource → pakej distro → tarball rasmi nodejs.org |
| Python 3 | python3 distro → python3-full → PPA deadsnakes |
| Pangkalan data | mariadb-server → cipta semula dir socket → mysql-server |
| Akaun DB | `127.0.0.1` **dan** `localhost` → `mysql_native_password` → hos `%` |
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
| Wings jalan | mula → buang rangkaian tersangkut → cuba 5 subnet lain → tukar port |
| Wings sertai panel | `wings configure` → cuba semula `--allow-insecure` |

Setiap kaedah disahkan selepas dijalankan — "berjaya" bermakna semakan lulus,
bukan sekadar arahan keluar dengan kod 0.

## Keadaan dunia sebenar yang dikendalikan

| Keadaan | Apa yang berlaku |
|---|---|
| RAM 1GB, composer dibunuh OOM | Swap sementara dicipta sebelum composer, ditanggalkan selepasnya. Kalau masih OOM, arahan swap kekal dicetak |
| `dpkg` separuh terkonfigurasi | `dpkg --configure -a` + `--fix-broken` sebelum apa-apa apt |
| apt dikunci oleh unattended-upgrades | Tunggu sehingga 5 minit, plus `DPkg::Lock::Timeout` |
| Cloudflare / reverse proxy di hadapan | `TRUSTED_PROXIES` ditetapkan dan `APP_URL` guna skema proxy — tanpanya aset tersekat dan sesi hilang |
| Apache sudah memegang port 80 | Apache dikonfigurasi, bukan dilawan dengan nginx |
| MySQL 8 `caching_sha2_password` | Fallback mencipta akaun dengan `mysql_native_password` |
| Pakej cron ada tetapi daemon mati | Daemon dimulakan; scheduler bergantung padanya |
| Panel sedia ada dalam direktori itu | Backup diambil automatik sebelum ditulis ganti |
| Disk hampir penuh | Dihentikan sebelum muat turun, bukan separuh jalan |
| Kernel tanpa IPv6 | `listen [::]` ditinggalkan; kalau Docker pula gagal, puncanya dinamakan |
| Perakaunan swap cgroup mati | Amaran — had RAM game server tidak akan dikuatkuasakan sepenuhnya |
| Ctrl-C di tengah jalan | Kemajuan dikekalkan, swap sementara ditanggalkan, arahan sambung dicetak |
| Jalankan semula | Tiada pendua node/allocation/user/egg; password DB yang dijana dikekalkan |

## Pengesahan dan pembaikan diri

Pada penghujung, 15–18 semakan dijalankan. Yang gagal dicuba baiki dahulu
(terbatas — satu pusingan per strategi):

panel menjawab HTTP · aset frontend dimuatkan · **log masuk admin sebenar
melalui HTTP** · pangkalan data · Redis · akaun admin · egg · queue worker ·
scheduler · Node.js · Python · Docker · binari Wings · config Wings · node
berdaftar · allocation · proses Wings · Wings mendengar pada portnya

Kalau ada yang masih gagal, script **enggan** melaporkan "siap" — ia senaraikan
apa yang gagal dan keluar dengan kod bukan sifar.

## Keselamatan

Perkara yang script ini buat berbeza daripada panduan pemasangan biasa:

- **Scheduler berjalan sebagai `www-data`, bukan root.** Panduan upstream letak
  `php artisan schedule:run` dalam crontab root, tetapi seluruh direktori panel
  dimiliki `www-data` — jadi sesiapa yang menguasai proses web boleh menulis
  `artisan` dan mendapat root pada minit berikutnya.
- `.env` ditulis 0600 milik `www-data` (`.env.example` datang 0644).
- `storage/` 0750 — log Laravel bukan bacaan awam.
- Log pemasang 0600, dan password diredaksi daripada apa yang dilog.
- Password pangkalan data tidak dihantar pada baris arahan (`ps` menampakkannya)
  — ia melalui fail `defaults-extra-file` 0600, termasuk semasa backup.
- Fail sementara guna `mktemp`, bukan nama tetap dalam `/tmp` yang boleh diteka
  lalu dilaksanakan sebagai root.
- Pemasang Composer disemak terhadap checksum rasmi sebelum dijalankan.
- Nilai daripada sumber luar (nama dalam fail egg) di-escape sebelum masuk SQL.
- Backup disimpan 0700 dan gagal dengan kuat — `--upgrade` menolak untuk
  meneruskan kalau backupnya tidak menjadi.

## Validasi

Konfigurasi disemak sebelum apa-apa disentuh, dan **semua** masalah dilaporkan
sekali gus dengan sebab dan petunjuk. Selain medan satu-satu, kombinasi yang
mustahil juga ditangkap:

- `BEHIND_PROXY="yes"` bersama `PANEL_SSL="yes"` — proxy memegang port 80, jadi
  cabaran Let's Encrypt di sini akan gagal.
- `WINGS_SSL="yes"` dengan `WINGS_FQDN` berbentuk IP — panel menolaknya.
- `NODE_PORT_RANGE` yang merangkumi port Wings atau port SFTP — satu game server
  akan diberi port yang Wings sedang dengar.

## Status ujian

Diuji hujung-ke-hujung dalam container Ubuntu 24.04 yang bersih — tanpa `curl`,
`ss`, `php`, `python3`, `node` atau `sudo` pada mulanya. 16 daripada 18 semakan
lulus.

**Disahkan berfungsi:** wizard interaktif, preflight, PHP 8.3 + semua sambungan,
Composer, Node.js 22 via NodeSource, Python 3.12 + venv, MariaDB dengan akaun
dua-hos dan log masuk diuji, Redis, panel 1.15.0, migrasi + 14 egg rasmi, akaun
admin, nginx + PHP-FPM, queue worker, scheduler, Docker, binari Wings, node +
allocation + `config.yml`, import egg custom, dan log masuk HTTP sebenar.

Empat rantaian fallback dilihat mengambil alih sendiri: composer ke
`--prefer-source` selepas had kadar GitHub; Docker ke `get.docker.com`; queue
worker ke pelancar tanpa systemd; dan gelung subnet mencuba 172.19 hingga
172.23.

**Lapisan pengesanan persekitaran** diuji dengan cara yang berbeza: `bash -n`
dan shellcheck bersih pada semua sembilan fail; dry-run sebenar dijalankan dua
kali, sekali sebagai container Docker dan sekali dengan Termux disimulasikan
(`TERMUX_VERSION` + `PREFIX`), dan disahkan bahawa setiap fail yang ditulis
mendarat di bawah `$PREFIX`; pemetaan nama pakej diuji unit untuk 19 nama.
Yang **tidak** diuji ialah pemasangan Termux sebenar pada telefon Android.

**Tidak diuji secara langsung:** mod `--upgrade`, `--backup`, `--restore`,
`--wings-only`, `--add-node` dan `--status` — hanya `--status` dan laluan
validasi yang dijalankan; selebihnya disemak secara statik sahaja. Sijil Let's
Encrypt perlukan domain awam. Wings tidak dapat hidup sepenuhnya dalam container
ujian kerana kernelnya dibina **tanpa IPv6**, jadi Docker tidak boleh mencipta
bridge langsung — rantaian subnet berjaya melepasi ralat "Pool overlaps",
kemudian terserempak had itu, dan script menamakan puncanya dan tidak berpura-pura
berjaya.

## Dari mana pembetulan datang

Kod ini melalui audit adversarial berbilang lensa, dan setiap penemuan disemak
semula untuk menolak yang palsu. Antara pepijat sebenar yang ditemui dan dibaiki:

- `cmd | grep -q` di bawah `pipefail` melaporkan "tidak jumpa" pada padanan yang
  ADA, kerana penulis di hulu dapat SIGPIPE. Ini merosakkan pengesanan PHP,
  `port_owner`, dan semakan scheduler.
- `pgrep` bukan bukti Wings berjalan: Wings hidup ~1 saat sebelum FATAL, jadi
  fasa itu mengisytiharkan kejayaan dan **seluruh rantaian fallback tidak pernah
  dicuba**.
- `setsid nohup` tidak boleh memanggil fungsi shell, jadi queue worker tidak
  pernah bermula pada sistem tanpa systemd.
- Pembetulan "subnet melekat" (untuk mengelak hanyut antara run) memecahkan
  fallback subnet, yang memerlukan julat *berbeza* dan menerima yang *sama*.
- Pada `--force`, fasa webserver menulis semula vhost dan memusnahkan suntingan
  certbot, sementara semakan SSL masih nampak folder sijil — HTTPS mati senyap.
- `> config.yml` memotong fail sebelum `artisan` jalan, jadi satu kegagalan
  memusnahkan config Wings yang berfungsi.
- `$(tail -c1)` membuang newline, jadi ujian "fail berakhir dengan newline?"
  sentiasa benar dan satu baris kosong ditambah pada `.env` setiap kali.
- ERR trap diwarisi ke subshell, mencetak dua banner merah untuk satu kegagalan.
- `attempt()` dengan pengesahan yang sudah lulus (contohnya `vendor/` semasa
  upgrade) melangkau kerja yang memang perlu dibuat.
- Pengesanan container bergantung pada `/.dockerenv` dan `/proc/1/cgroup`, dan
  kedua-duanya tiada dalam container yang script ini sendiri sedang berjalan —
  ia melaporkan "bare metal" dan akan memasang Wings di tempat yang mungkin
  tidak boleh menjalankannya. `systemd-detect-virt --container` tahu; ia kini
  ditanya sebagai kaedah terakhir.
- Percubaan pertama saya membaiki perkara di atas menetapkan `CAN_DOCKER=no`
  untuk semua container — yang akan **menolak pemasangan yang sudah terbukti
  berjaya** dalam ujian hujung-ke-hujung, kerana Docker-dalam-Docker memang
  berfungsi dalam container privileged. Sebab itu ada keadaan ketiga,
  "tidak pasti": ia mencuba, dan memberitahu kau lebih awal apa yang mungkin
  gagal.
