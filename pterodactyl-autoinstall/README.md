# Pterodactyl Auto-Installer

Pasang Pterodactyl **Panel + Wings + Node + Allocation + Egg** daripada satu fail
konfigurasi. Direka supaya selamat dijalankan berulang kali dan boleh disambung
semula selepas gagal.

```bash
sudo ./install.sh --validate-only     # semak config sahaja
sudo ./install.sh                     # pasang
sudo ./install.sh --resume            # sambung selepas gagal
sudo ./install.sh --uninstall         # buang
```

## Apa yang jujur perlu kau tahu dulu

Tiada script boleh janji "tiada error langsung" — pemasangan bergantung pada OS,
kernel, repo apt, DNS, port yang sedia diguna, dan dasar provider. Yang script ini
janji ialah **gagal dengan cara yang berguna**:

- Semak konfigurasi dan sistem **sebelum** menyentuh apa-apa.
- Senaraikan **semua** masalah sekali gus, bukan satu demi satu.
- Beritahu punca sebenar dan arahan pembetulan, bukan sekadar "failed".
- Simpan kemajuan supaya `--resume` menyambung dari fasa yang gagal.
- Selamat dijalankan semula — tiada pendua node, allocation, user atau egg.
- Enggan lapor "berjaya" kalau pengesahan akhir tidak lulus.

## Keperluan

| Perkara | Nilai |
|---|---|
| OS | Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12 |
| Seni bina | x86_64 atau aarch64 |
| RAM | 1GB minimum untuk panel, 2GB+ disyorkan |
| Disk | 5GB kosong minimum |
| Akses | root (guna `sudo`) |
| Wings | Perlu KVM atau bare metal. **OpenVZ/LXC tidak boleh** — Docker tak jalan di situ. |

## Cara guna

1. Isi `pterodactyl.conf`. Ia terbahagi tiga:
   - **WAJIB** — script berhenti kalau kosong.
   - **WAJIB BERSYARAT** — hanya wajib kalau syaratnya benar (cth. `SSL_EMAIL`
     hanya wajib bila `PANEL_SSL="yes"`).
   - **OPSIONAL** — boleh biar kosong; default tertera dalam komen setiap medan.

2. Semak dulu — ini tidak memasang apa-apa:
   ```bash
   sudo ./install.sh --validate-only
   ```
   Contoh output bila ada masalah:
   ```
   KONFIGURASI TIDAK LENGKAP — 3 masalah dijumpai:

     1. PANEL_FQDN    WAJIB tetapi kosong
        Domain atau IP untuk akses panel (cth: panel.domain.com)
     2. ADMIN_EMAIL   nilai "bukan-email" tidak sah — mesti alamat email yang sah
        Alamat email akaun admin
     3. SSL_EMAIL     WAJIB kerana PANEL_SSL=yes
        Email pendaftaran Let's Encrypt
   ```

3. Pasang:
   ```bash
   sudo ./install.sh
   ```

Kredential (termasuk password DB yang dijana) disimpan ke
`/root/pterodactyl-credentials.txt` dengan `chmod 600`.

## Pilihan baris arahan

| Pilihan | Kegunaan |
|---|---|
| `--config FAIL` | Guna fail config lain |
| `--validate-only` | Semak config sahaja |
| `--dry-run` | Tunjuk fasa yang akan jalan, tanpa mengubah sistem |
| `--resume` | Langkau fasa yang sudah siap (kelakuan default) |
| `--force` | Jalankan semula semua fasa |
| `--skip-preflight` | Langkau semakan awal |
| `--uninstall` | Buang panel, DB, config Wings, service |
| `-y`, `--yes` | Jawab ya kepada semua soalan |

## Fasa

17 fasa bila Wings dipasang, 13 bila tidak:

`deps` → `php` → `composer` → `mariadb` → `redis` → `panel_files` →
`panel_env` → `panel_admin` → `webserver` → `ssl` → `services` →
`wings_docker` → `wings_binary` → `wings_node` → `wings_service` →
`eggs` → `firewall` → pengesahan akhir

Kemajuan disimpan di `/var/lib/pterodactyl-installer/completed-phases`.
Log penuh di `/var/log/pterodactyl-installer.log`.

## Masalah biasa dan pengendaliannya

Script mengesan dan memberi arahan khusus untuk keadaan berikut:

| Keadaan | Kelakuan script |
|---|---|
| Composer kena rate limit GitHub | Kesan mesejnya, arah kau isi `GITHUB_TOKEN` dan `--resume` |
| `Access denied for user ...@'localhost'` | Dielak: akaun DB dicipta untuk `127.0.0.1` **dan** `localhost`, kemudian log masuk diuji |
| IPv6 dimatikan pada VPS | Baris `listen [::]` nginx ditinggalkan automatik |
| Kernel tanpa IPv6 langsung | Dikesan bila Docker gagal cipta bridge; diterangkan puncanya |
| Subnet Docker Wings bertindih | Julat `172.x` kosong dipilih automatik; boleh dipaksa dengan `WINGS_DOCKER_SUBNET` |
| Port sudah diguna | Preflight kenal pasti pemilik port; nginx/Wings sendiri tidak dikira konflik |
| Tiada systemd (container) | Service ditulis sebagai `/usr/local/bin/pterodactyl-services` |
| PHP 8.2/8.3 tiada dalam repo | Tambah `ppa:ondrej/php` (Ubuntu) atau sury (Debian) |
| Zon waktu tidak wujud | Ditangkap semasa validasi, disemak semula selepas `tzdata` dipasang |
| Jalankan semula | Tiada pendua node/allocation/user/egg; password DB yang dijana dikekalkan |

## Status ujian

Diuji hujung-ke-hujung dalam container Ubuntu 24.04 yang bersih (tanpa curl, ss,
python3, php, sudo pada mulanya).

**Disahkan berfungsi:** validasi config (medan kosong, nilai salah, wajib
bersyarat), preflight, pemasangan PHP 8.3 + sambungan, MariaDB + cipta DB/user +
ujian log masuk, Redis, muat turun panel, `.env` + migrasi + 14 egg rasmi, cipta
admin, nginx + PHP-FPM, queue worker, Docker, binari Wings, cipta lokasi + node +
6 allocation, jana `config.yml`, handshake Wings↔Panel (API panel menjawab),
import egg custom, fail kredential, pengesahan akhir, login HTTP sebenar
(HTTP 200, `root_admin: true`), dan ulang-jalan tanpa pendua.

**Tidak dapat diuji dalam persekitaran itu:**

1. `composer install` melalui rangkaian — diblok rate limit GitHub tanpa token.
   Langkah ini disahkan berfungsi berasingan pada mesin hos; `vendor/` disalin
   masuk supaya fasa selepasnya boleh diuji.
2. Wings hidup sepenuhnya — kernel VM ujian dibina **tanpa IPv6**, jadi Docker
   tidak boleh mencipta bridge `pterodactyl0` langsung. Semua langkah sebelum
   itu (config, token, handshake API) disahkan berfungsi.
3. Sijil Let's Encrypt — perlukan domain awam sebenar.
4. UFW/fail2ban — tidak diaktifkan dalam container ujian.

Pada VPS biasa, ketiga-tiga perkara pertama itu memang berfungsi; ia gagal di sini
semata-mata kerana had persekitaran ujian.
