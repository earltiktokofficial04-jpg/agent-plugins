#!/usr/bin/env bash
#############################################################################
#  env.sh — kenal pasti persekitaran, dan sesuaikan diri kepadanya
#
#  Pemasang ini asalnya menganggap satu dunia: Debian/Ubuntu, root, systemd,
#  /etc dan /var boleh ditulis, pengguna www-data wujud. Anggapan itu pecah
#  pada Termux, WSL, container, dan VPS OpenVZ.
#
#  Fail ini mengesan dunia mana kita berada, kemudian menetapkan laluan,
#  pengurus pakej, pengguna web dan cara service dijalankan — supaya baki
#  pemasang tidak perlu bertanya "adakah ini Termux?" pada setiap baris.
#############################################################################

[[ -n "${_PTERO_ENV_LOADED:-}" ]] && return 0
_PTERO_ENV_LOADED=1

# Diisi oleh detect_environment
ENV_KIND="unknown"          # termux|wsl1|wsl2|docker|podman|lxc|openvz|kvm|xen|vmware|metal|unknown
ENV_LABEL="tidak diketahui"
IS_ANDROID="no"
IS_ROOT="no"
PKG_MGR=""                  # apt | pkg
TERMUX_PREFIX=""
WEB_USER=""                 # pemilik fail panel; www-data pada Linux biasa
WEB_GROUP=""
SERVICE_MODE="manual"       # systemd | manual
CAN_DOCKER="yes"
DOCKER_BLOCK_REASON=""
SUPPORT_LEVEL="full"        # full | panel-only | experimental | unsupported
ENV_NOTES=()

# Tempat script bantuan dipasang, dan direktori yang disemak ruang kosongnya.
# Kedua-duanya berpindah di bawah $PREFIX pada Termux.
BIN_DIR="/usr/local/bin"
DISK_CHECK_PATH="/"

is_termux() { [[ "$ENV_KIND" == "termux" ]]; }

#---------------------------------------------------------------------------
# Pengesanan
#---------------------------------------------------------------------------
_is_termux() {
    [[ -n "${TERMUX_VERSION:-}" ]] && return 0
    [[ -n "${PREFIX:-}" && "${PREFIX}" == */com.termux/* ]] && return 0
    [[ -d /data/data/com.termux/files/usr ]] && return 0
    return 1
}

_is_wsl() {
    local v=""
    [[ -r /proc/version ]] && v="$(tr '[:upper:]' '[:lower:]' </proc/version 2>/dev/null || true)"
    [[ "$v" == *microsoft* || "$v" == *wsl* ]]
}

_detect_container() {
    [[ -f /.dockerenv ]] && { printf 'docker'; return 0; }
    [[ -f /run/.containerenv ]] && { printf 'podman'; return 0; }
    [[ -f /proc/user_beancounters || -d /proc/vz ]] && { printf 'openvz'; return 0; }
    if [[ -r /proc/1/environ ]] && grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
        printf 'lxc'; return 0
    fi
    local cg=""
    [[ -r /proc/1/cgroup ]] && cg="$(cat /proc/1/cgroup 2>/dev/null || true)"
    case "$cg" in
        *docker*) printf 'docker'; return 0 ;;
        *lxc*)    printf 'lxc';    return 0 ;;
    esac
    # Tiada satu pun petunjuk di atas dijamin ada. Docker moden tidak lagi
    # mencipta /.dockerenv pada setiap runtime, dan cgroup v2 dalam namespace
    # sendiri kelihatan seperti hos. systemd-detect-virt masih tahu, jadi
    # tanya ia sebelum menyerah — kalau tidak container akan disalah anggap
    # sebagai bare metal dan Wings dipasang di tempat ia tidak boleh jalan.
    local v=""
    have systemd-detect-virt && v="$(systemd-detect-virt --container 2>/dev/null || true)"
    case "$v" in
        docker|podman|lxc|lxc-libvirt|openvz) printf '%s' "$v"; return 0 ;;
        none|"") ;;
        *) printf '%s' "$v"; return 0 ;;
    esac
    return 1
}

detect_environment() {
    [[ "$(id -u)" -eq 0 ]] && IS_ROOT="yes" || IS_ROOT="no"

    # Android/Termux dahulu: di sana banyak andaian Linux biasa tidak terpakai,
    # termasuk kewujudan /etc yang boleh ditulis dan pengguna sistem.
    if _is_termux; then
        ENV_KIND="termux"
        IS_ANDROID="yes"
        TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
        ENV_LABEL="Termux di Android"
        PKG_MGR="pkg"
        SERVICE_MODE="manual"
        WEB_USER="$(id -un)"
        WEB_GROUP="$(id -gn)"
        CAN_DOCKER="no"
        DOCKER_BLOCK_REASON="Android tanpa root tidak mempunyai Docker, cgroups atau namespace yang Wings perlukan"
        SUPPORT_LEVEL="experimental"
        ENV_NOTES+=("Termux: panel sahaja. Wings tidak mungkin di sini.")
        return 0
    fi

    PKG_MGR="apt"
    WEB_USER="www-data"
    WEB_GROUP="www-data"
    [[ -d /run/systemd/system ]] && SERVICE_MODE="systemd" || SERVICE_MODE="manual"

    local c=""
    c="$(_detect_container || true)"
    if _is_wsl; then
        # WSL2 mempunyai kernel sebenar dan boleh menjalankan Docker; WSL1 ialah
        # lapisan terjemahan syscall dan tidak boleh.
        if [[ -r /proc/sys/kernel/osrelease ]] && grep -qi 'wsl2\|microsoft-standard' /proc/sys/kernel/osrelease 2>/dev/null; then
            ENV_KIND="wsl2"; ENV_LABEL="WSL2 (Windows)"
            SUPPORT_LEVEL="full"
            ENV_NOTES+=("WSL2: Docker berfungsi, tetapi service tidak bermula sendiri selepas Windows dimulakan semula.")
        else
            ENV_KIND="wsl1"; ENV_LABEL="WSL1 (Windows)"
            CAN_DOCKER="no"
            DOCKER_BLOCK_REASON="WSL1 ialah lapisan terjemahan syscall tanpa kernel sebenar, jadi Docker tidak boleh berjalan"
            SUPPORT_LEVEL="panel-only"
        fi
    elif [[ -n "$c" ]]; then
        ENV_KIND="$c"
        case "$c" in
            openvz)
                ENV_LABEL="VPS OpenVZ"
                CAN_DOCKER="no"
                DOCKER_BLOCK_REASON="OpenVZ berkongsi kernel hos dan tidak membenarkan Docker"
                SUPPORT_LEVEL="panel-only"
                ;;
            lxc|lxc-libvirt)
                ENV_LABEL="container LXC"
                CAN_DOCKER="no"
                DOCKER_BLOCK_REASON="Container LXC biasanya tidak dibenarkan menjalankan Docker di dalamnya"
                SUPPORT_LEVEL="panel-only"
                ;;
            docker|podman)
                # "maybe", bukan "no": container privileged BOLEH menjalankan
                # Docker di dalamnya, dan itu bukan persediaan yang jarang.
                # Menolaknya terus akan menghalang pemasangan yang sah.
                ENV_LABEL="container ${c^}"
                SUPPORT_LEVEL="full"
                CAN_DOCKER="maybe"
                DOCKER_BLOCK_REASON="Docker di dalam container hanya berfungsi bila container itu privileged"
                ENV_NOTES+=("Dalam container: tiada systemd, jadi service perlu dilancarkan semula selepas setiap restart.")
                ;;
            *)
                # systemd-nspawn, container-other, dan apa-apa yang muncul
                # selepas ini. Tidak diketahui, bukan mustahil.
                ENV_LABEL="container $c"
                SUPPORT_LEVEL="full"
                CAN_DOCKER="maybe"
                DOCKER_BLOCK_REASON="Docker di dalam container '$c' memerlukan keistimewaan tambahan yang mungkin tiada di sini"
                ;;
        esac
    else
        # Mesin maya biasa atau bare metal.
        local virt="none"
        have systemd-detect-virt && virt="$(systemd-detect-virt 2>/dev/null || printf 'none')"
        case "$virt" in
            kvm|qemu)  ENV_KIND="kvm";    ENV_LABEL="VPS KVM" ;;
            xen)       ENV_KIND="xen";    ENV_LABEL="VPS Xen" ;;
            vmware)    ENV_KIND="vmware"; ENV_LABEL="VMware" ;;
            microsoft) ENV_KIND="hyperv"; ENV_LABEL="Hyper-V" ;;
            none)      ENV_KIND="metal";  ENV_LABEL="bare metal" ;;
            *)         ENV_KIND="${virt}"; ENV_LABEL="virtualisasi $virt" ;;
        esac
        SUPPORT_LEVEL="full"
    fi
    return 0
}

# detect_system (core.sh) berjalan selepas kita, dan ia melihat perkara yang
# kita tidak lihat — systemd-detect-virt yang baru dipasang, /etc/os-release.
# Selaraskan kedua-dua gambaran itu supaya tiada dua sumber kebenaran.
env_adjust_after_detect() {
    if is_termux; then
        # /etc/os-release tidak wujud di Termux, jadi OS_ID kosong dan setiap
        # semakan "OS disokong?" akan menolaknya dengan mesej yang salah.
        OS_ID="android"
        # Tetapkan tanpa syarat: kalau /etc/os-release wujud di sini, ia milik
        # sesuatu yang lain, bukan Android.
        OS_VER="$( { getprop ro.build.version.release; } 2>/dev/null | tr -d '[:space:]' || true )"
        [[ -z "$OS_VER" ]] && OS_VER="unknown"
        HAS_SYSTEMD="no"
        VIRT="termux"
        return 0
    fi

    # systemd-detect-virt tahu perkara yang /.dockerenv dan cgroup tidak
    # tunjukkan, terutamanya pada container yang bersih.
    case "$VIRT" in
        openvz|lxc|lxc-libvirt)
            if [[ "$CAN_DOCKER" != "no" ]]; then
                CAN_DOCKER="no"
                DOCKER_BLOCK_REASON="virtualisasi '$VIRT' berkongsi kernel hos dan tidak membenarkan Docker"
                SUPPORT_LEVEL="panel-only"
                ENV_KIND="$VIRT"
                ENV_LABEL="VPS $VIRT"
            fi
            ;;
    esac
    [[ "$HAS_SYSTEMD" == "yes" ]] && SERVICE_MODE="systemd" || SERVICE_MODE="manual"
    return 0
}

# Jangan biarkan pengguna memilih sesuatu yang persekitaran ini tidak boleh
# lakukan. Lebih baik memberitahunya sekarang, dengan sebabnya, daripada
# membiarkan empat fasa Wings gagal satu demi satu kemudian.
env_enforce_capabilities() {
    cfg_is INSTALL_WINGS yes || return 0
    case "$CAN_DOCKER" in
        yes) return 0 ;;
        maybe)
            # Kita tidak tahu, jadi kita tidak memutuskan. Rantaian fallback
            # Docker akan mencuba, dan kalau ia gagal, mesejnya sudah jelas.
            defer_warning "Wings dicuba walaupun $DOCKER_BLOCK_REASON. Kalau fasa Docker gagal, itu sebabnya — pasang Wings pada hos, bukan di dalam container ini."
            return 0
            ;;
    esac
    CFG[INSTALL_WINGS]="no"
    defer_warning "Wings dimatikan: $DOCKER_BLOCK_REASON. Panel akan dipasang seperti biasa — pasang Wings pada mesin lain (KVM atau bare metal) dan daftarkannya ke panel ini dengan: sudo ./install.sh --wings-only"
    return 0
}

#---------------------------------------------------------------------------
# Laluan
#
# Termux tidak mempunyai /etc, /var atau /var/www yang boleh ditulis. Semuanya
# hidup di bawah $PREFIX, dan pengguna memilikinya — jadi tiada root diperlukan.
#---------------------------------------------------------------------------
env_apply_paths() {
    is_termux || return 0
    local p="$TERMUX_PREFIX"
    STATE_DIR="$p/var/lib/pterodactyl-installer"
    STATE_FILE="$STATE_DIR/completed-phases"
    ANSWERS_FILE="$STATE_DIR/answers.conf"
    LOG_FILE="$p/var/log/pterodactyl-installer.log"
    PANEL_DIR="$p/var/www/pterodactyl"
    WINGS_ETC="$p/etc/pterodactyl"
    BACKUP_DIR="$p/var/backups/pterodactyl"
    BIN_DIR="$p/bin"
    DISK_CHECK_PATH="$p"
    # Swap tidak boleh diaktifkan pada Android tanpa root; jangan cuba menulis
    # fail 2GB ke storan telefon hanya untuk gagal pada swapon.
    TEMP_SWAP_FILE="$p/tmp/pterodactyl-install.swap"

    # Default dalam SCHEMA menunjuk ke /root dan /var, yang tidak wujud di sini.
    # autofill hanya mengisi kunci yang kosong, jadi menetapkannya sekarang
    # bermakna default itu tidak pernah digunakan.
    local home="${HOME:-}"
    [[ -d "$home" && -w "$home" ]] || home="${p%/usr}/home"
    [[ -d "$home" ]] || home="$p/var"
    [[ -z "${CFG[CREDENTIALS_FILE]:-}" ]] && CFG[CREDENTIALS_FILE]="$home/pterodactyl-credentials.txt"
    [[ -z "${CFG[WINGS_DATA_DIR]:-}"   ]] && CFG[WINGS_DATA_DIR]="$p/var/lib/pterodactyl/volumes"

    mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$p/tmp" 2>/dev/null || true
    return 0
}

#---------------------------------------------------------------------------
# Laluan pelayan web dan log
#---------------------------------------------------------------------------
log_root() {
    if is_termux; then printf '%s/var/log' "$TERMUX_PREFIX"; else printf '/var/log'; fi
}

nginx_log_dir() { printf '%s/nginx' "$(log_root)"; }

nginx_site_path() {
    if is_termux; then
        printf '%s/etc/nginx/conf.d/pterodactyl.conf' "$TERMUX_PREFIX"
    else
        printf '/etc/nginx/sites-available/pterodactyl.conf'
    fi
}

# Fail vhost tidak berguna kalau nginx.conf tidak memuatkannya. Pada Debian
# ini diuruskan oleh symlink sites-enabled; pada Termux, `include conf.d/*.conf`
# tidak dijamin ada dalam nginx.conf yang dihantar pakej.
nginx_enable_site() {
    local site; site="$(nginx_site_path)"
    if ! is_termux; then
        mkdir -p /etc/nginx/sites-enabled
        ln -sf "$site" /etc/nginx/sites-enabled/pterodactyl.conf
        rm -f /etc/nginx/sites-enabled/default
        return 0
    fi
    local main="$TERMUX_PREFIX/etc/nginx/nginx.conf"
    [[ -f "$main" ]] || return 0
    local body; body="$(cat "$main" 2>/dev/null || true)"
    [[ "$body" == *"conf.d/*.conf"* ]] && return 0
    # Sisipkan include tepat selepas baris `http {`, bukan di hujung fail —
    # `include` di luar blok http ialah ralat sintaks yang menghalang nginx start.
    awk -v inc="    include conf.d/*.conf;" '
        { print }
        !done && /^[[:space:]]*http[[:space:]]*\{/ { print inc; done = 1 }
    ' "$main" >"$main.ptero" 2>/dev/null && mv "$main.ptero" "$main"
    return 0
}

#---------------------------------------------------------------------------
# PHP-FPM
#
# Debian memberi satu binari per versi (php-fpm8.3) yang mendengar pada socket
# unix. Termux memberi satu `php-fpm` tanpa versi, dan konfigurasi lalainya
# mendengar pada TCP 127.0.0.1:9000.
#---------------------------------------------------------------------------
php_fpm_bin() {
    if is_termux; then printf 'php-fpm'; else printf 'php-fpm%s' "$PHP_V"; fi
}

# Nilai untuk fastcgi_pass.
php_fpm_pass() {
    if is_termux; then
        printf '127.0.0.1:9000'
    else
        printf 'unix:%s' "$(php_fpm_socket)"
    fi
}

# Apache menulis handler fcgi dengan sintaks yang berbeza untuk socket unix
# dan untuk TCP — bukan sekadar menukar alamat di tempat yang sama.
apache_fcgi_handler() {
    if is_termux; then
        printf 'proxy:fcgi://127.0.0.1:9000/'
    else
        printf 'proxy:unix:%s|fcgi://localhost/' "$(php_fpm_socket)"
    fi
}

# mariadbd-safe sebagai root MESTI diberi --user, kerana MariaDB enggan
# berjalan sebagai root tanpa diminta secara jelas. Pada Termux tiada pengguna
# `mysql` langsung, dan kita sudah bukan root — bendera itu akan menggagalkannya.
db_safe_args() {
    if is_termux; then printf ''; else printf -- '--user=mysql'; fi
}

php_fpm_listening() {
    if is_termux; then
        port_busy 9000
    else
        [[ -S "$(php_fpm_socket)" ]]
    fi
}

#---------------------------------------------------------------------------
# Pengurus pakej
#
# Nama pakej berbeza antara apt dan pkg Termux, jadi peta di bawah menterjemah
# nama "logik" kepada nama sebenar bagi setiap sistem.
#---------------------------------------------------------------------------
termux_pkg_name() {
    case "$1" in
        mariadb-server|mariadb-client) printf 'mariadb' ;;
        redis-server|redis-tools)      printf 'redis' ;;
        nodejs|npm)                    printf 'nodejs-lts' ;;
        python3|python3-pip|python3-venv|python3-dev|python3-full) printf 'python' ;;
        # Termux mempunyai satu pakej `php` (dengan sambungan terbina dalam)
        # dan satu subpakej `php-fpm`. Tiada pakej per-sambungan.
        # Urutan penting: `php8.3-gd` mesti sampai ke arm "buang", bukan
        # ditangkap oleh corak `php8.*` yang lebih longgar.
        php-fpm|php*-fpm)                printf 'php-fpm' ;;
        php|php[0-9]|php[0-9].[0-9])     printf 'php' ;;
        php*-cli|php*-common)            printf 'php' ;;
        php*-*)                          printf '' ;;
        # Tiada dalam repo Termux, atau tidak bermakna pada Android:
        # cron/sudo/systemd tiada; Docker dan sekutunya mustahil; certbot dan
        # firewall memerlukan akses yang tidak dimiliki aplikasi tanpa root.
        cron|sudo|tzdata|software-properties-common|apt-transport-https) printf '' ;;
        lsb-release|psmisc|pipx)       printf '' ;;
        docker*|containerd*)           printf '' ;;
        certbot|python3-certbot-*)     printf '' ;;
        ufw|fail2ban)                  printf '' ;;
        mysql-server)                  printf '' ;;
        *)                             printf '%s' "$1" ;;
    esac
}

# Terjemah senarai nama logik kepada nama sebenar bagi sistem ini, membuang
# yang tiada padanan. Mencetak satu nama per baris supaya nama yang mengandungi
# ruang tidak pernah berlaku (dan tidak boleh, kerana nama pakej tiada ruang).
pkg_names() {
    local n out
    for n in "$@"; do
        if is_termux; then out="$(termux_pkg_name "$n")"; else out="$n"; fi
        [[ -n "$out" ]] && printf '%s\n' "$out"
    done
    return 0
}

# Termux menghantar apt sebenar, jadi apt_q berfungsi di sana juga — dan ia
# lebih boleh diramal daripada `pkg`, yang boleh bertanya soalan mirror di
# tengah-tengah pemasangan tanpa pengawasan.
pkg_update() {
    if have apt-get; then
        retry apt_q update -qq
    elif have pkg; then
        retry pkg update -y
    else
        return 1
    fi
}

pkg_install() {
    local -a want=()
    local n
    while IFS= read -r n; do [[ -n "$n" ]] && want+=("$n"); done < <(pkg_names "$@")
    # Semua yang diminta tiada padanan di sini (cth. `cron` pada Termux) —
    # itu bukan kegagalan, cuma tiada apa yang perlu dipasang.
    (( ${#want[@]} == 0 )) && return 0
    if have apt-get; then
        apt_q install -y -qq "${want[@]}"
    elif have pkg; then
        pkg install -y "${want[@]}"
    else
        return 1
    fi
}

pkg_available() {
    local n; n="$(pkg_names "$1")"
    [[ -z "$n" ]] && return 1
    local out; out="$(apt-cache policy "$n" 2>/dev/null || true)"
    [[ "$out" == *"Candidate: "[0-9]* ]]
}

pkg_installed() {
    local n; n="$(pkg_names "$1")"
    # Tiada padanan bermakna tiada apa yang perlu dipasang — anggap sudah ada,
    # supaya gelung "pasang satu demi satu" tidak cuba memasang nama kosong.
    [[ -z "$n" ]] && return 0
    local st; st="$(dpkg-query -W -f='${Status}' "$n" 2>/dev/null || true)"
    [[ "$st" == *"install ok installed"* ]]
}

#---------------------------------------------------------------------------
# Pemilikan fail
#---------------------------------------------------------------------------
# chown_web [-R ...] LALUAN...
#
# Tidak melakukan apa-apa bila kita sendiri sudah menjadi pemilik (Termux), dan
# tidak pernah gagal — pemilikan yang tidak dapat ditukar bukan sebab untuk
# membatalkan pemasangan.
chown_web() {
    [[ "$WEB_USER" == "$(id -un)" ]] && return 0
    local -a opts=()
    while [[ $# -gt 0 && "$1" == -* ]]; do
        opts+=("$1"); shift
    done
    (( $# == 0 )) && return 0
    chown ${opts[@]+"${opts[@]}"} "$WEB_USER:$WEB_GROUP" "$@" 2>/dev/null || true
    return 0
}

#---------------------------------------------------------------------------
# Ringkasan untuk pengguna
#---------------------------------------------------------------------------
env_summary() {
    printf '    Persekitaran        : %s\n' "$ENV_LABEL"
    printf '    Pengurus pakej      : %s\n' "$PKG_MGR"
    printf '    Root                : %s\n' "$IS_ROOT"
    printf '    Service             : %s\n' \
        "$( [[ "$SERVICE_MODE" == "systemd" ]] && printf 'systemd' || printf 'manual (script pelancar)' )"
    printf '    Pengguna web        : %s\n' "$WEB_USER"
    printf '    Tahap sokongan      : %s\n' \
        "$( case "$SUPPORT_LEVEL" in
              full)         printf 'penuh (panel + Wings)' ;;
              panel-only)   printf 'panel sahaja — Wings tidak boleh di sini' ;;
              experimental) printf 'eksperimen — panel sahaja, belum diuji' ;;
              *)            printf '%s' "$SUPPORT_LEVEL" ;;
            esac )"
    case "$CAN_DOCKER" in
        no)    printf '    Docker              : tidak tersedia — %s\n' "$DOCKER_BLOCK_REASON" ;;
        maybe) printf '    Docker              : tidak pasti — %s\n'    "$DOCKER_BLOCK_REASON" ;;
    esac
    local n
    for n in ${ENV_NOTES[@]+"${ENV_NOTES[@]}"}; do
        printf '    Nota                : %s\n' "$n"
    done
    return 0
}
