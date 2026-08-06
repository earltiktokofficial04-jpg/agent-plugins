#!/usr/bin/env bash
#############################################################################
#  Pterodactyl Auto-Installer
#
#  Pasang Panel + Wings + Node + Egg secara automatik daripada satu fail
#  konfigurasi. Direka supaya boleh dijalankan berulang kali dengan selamat
#  (idempotent) dan boleh disambung semula selepas gagal.
#
#  Guna:
#    ./install.sh --validate-only        semak konfigurasi sahaja
#    ./install.sh --dry-run              tunjuk apa yang akan dibuat
#    ./install.sh                        pasang
#    ./install.sh --resume               sambung selepas gagal
#    ./install.sh --uninstall            buang semuanya
#############################################################################

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

readonly STATE_DIR="/var/lib/pterodactyl-installer"
readonly STATE_FILE="$STATE_DIR/completed-phases"
readonly LOG_FILE="/var/log/pterodactyl-installer.log"
readonly PANEL_DIR="/var/www/pterodactyl"
readonly WINGS_ETC="/etc/pterodactyl"
readonly PANEL_TARBALL="https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
readonly WINGS_BASE="https://github.com/pterodactyl/wings/releases/latest/download"

# Diisi oleh parse_args / load_config
CONFIG_FILE="$SCRIPT_DIR/pterodactyl.conf"
DRY_RUN="no"
VALIDATE_ONLY="no"
FORCE_ALL="no"
ASSUME_YES="no"
SKIP_PREFLIGHT="no"
DO_UNINSTALL="no"

CURRENT_PHASE="init"
PHASE_NUM=0
TOTAL_PHASES=0
HAS_SYSTEMD="no"
PHP_V=""
declare -A CFG=()
declare -a GENERATED_SECRETS=()

#---------------------------------------------------------------------------
# Output
#---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
    C_BLU=$'\033[0;34m'; C_CYN=$'\033[0;36m'; C_DIM=$'\033[2m'
    C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""; C_DIM=""; C_BLD=""; C_OFF=""
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_raw() { printf '%s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; }

log()      { printf '%s\n' "$*";                    _raw "[$(_ts)] $*"; }
log_info() { printf '   %s\n' "$*";                 _raw "[$(_ts)] INFO  $*"; }
log_ok()   { printf '   %s✔%s %s\n' "$C_GRN" "$C_OFF" "$*";  _raw "[$(_ts)] OK    $*"; }
log_warn() { printf '   %s!%s %s\n' "$C_YEL" "$C_OFF" "$*";  _raw "[$(_ts)] WARN  $*"; }
log_err()  { printf '   %s✘%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; _raw "[$(_ts)] ERROR $*"; }
log_skip() { printf '   %s↷ %s%s\n' "$C_DIM" "$*" "$C_OFF";  _raw "[$(_ts)] SKIP  $*"; }
log_dry()  { printf '   %s[dry-run]%s %s\n' "$C_CYN" "$C_OFF" "$*"; }
log_step() { printf '\n%s▸ %s%s\n' "$C_BLD$C_BLU" "$*" "$C_OFF";     _raw "[$(_ts)] PHASE $*"; }

die() { log_err "$*"; exit 1; }

banner() {
    printf '\n%s%s%s\n' "$C_BLD" "═══════════════════════════════════════════════════════════════" "$C_OFF"
    printf '%s  %s%s\n' "$C_BLD" "$*" "$C_OFF"
    printf '%s%s%s\n\n' "$C_BLD" "═══════════════════════════════════════════════════════════════" "$C_OFF"
}

on_error() {
    local code=$? line="$1" cmd="$2"
    printf '\n%s%s%s\n' "$C_RED$C_BLD" "═══════════════════════════════════════════════════════════════" "$C_OFF"
    printf '%s  GAGAL semasa fasa: %s%s\n' "$C_RED$C_BLD" "$CURRENT_PHASE" "$C_OFF"
    printf '%s%s%s\n\n' "$C_RED$C_BLD" "═══════════════════════════════════════════════════════════════" "$C_OFF"
    printf '  Baris     : %s\n' "$line"
    printf '  Arahan    : %s\n' "$cmd"
    printf '  Exit code : %s\n' "$code"
    printf '  Log penuh : %s\n\n' "$LOG_FILE"
    printf '  Fasa yang dah siap dikekalkan. Selepas betulkan masalah di atas,\n'
    printf '  sambung semula dengan:\n\n'
    printf '      %s%s --config %s --resume%s\n\n' "$C_BLD" "$0" "$CONFIG_FILE" "$C_OFF"
    printf '  Untuk lihat 40 baris terakhir log:\n'
    printf '      tail -n 40 %s\n\n' "$LOG_FILE"
    _raw "[$(_ts)] FATAL phase=$CURRENT_PHASE line=$line cmd=$cmd code=$code"
    exit "$code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

#---------------------------------------------------------------------------
# Utiliti
#---------------------------------------------------------------------------
retry() {
    local max="${RETRY_MAX:-4}" delay=2 n=0
    until "$@"; do
        n=$((n + 1))
        if (( n >= max )); then
            log_err "gagal selepas $max cubaan: $*"
            return 1
        fi
        log_warn "cubaan $n/$max gagal, ulang dalam ${delay}s: $1 ..."
        sleep "$delay"
        delay=$((delay * 2))
    done
}

run() {
    _raw "[$(_ts)] EXEC  $*"
    if ! "$@" >>"$LOG_FILE" 2>&1; then
        log_err "arahan gagal: $*"
        log_err "40 baris terakhir log:"
        tail -n 40 "$LOG_FILE" | sed 's/^/       /' >&2 || true
        return 1
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# NOTA: `set -o pipefail` aktif. Elakkan corak `cmd | grep -q` — grep -q keluar
# sebaik jumpa padanan, penulis di hulu dapat SIGPIPE, dan pipefail jadikan
# status keseluruhan gagal walaupun padanan sebenarnya WUJUD. Semua fungsi di
# bawah sengaja mengelak corak itu.

gen_secret() {
    { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"; } || true
}

port_busy() {
    local hits
    hits="$(ss -lnt 2>/dev/null | awk -v p="[:.]$1\$" '$4 ~ p { c++ } END { print c + 0 }')"
    [[ "$hits" != "0" ]]
}

# Nama proses yang sedang mendengar pada port, atau kosong.
port_owner() {
    ss -lntp 2>/dev/null | awk -v p="[:.]$1\$" '$4 ~ p { print $NF; exit }'
}

phase_done() { [[ -f "$STATE_FILE" ]] && grep -qxF "$1" "$STATE_FILE"; }
mark_done()  { mkdir -p "$STATE_DIR"; grep -qxF "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >>"$STATE_FILE"; }

run_phase() {
    local name="$1" desc="$2" fn="$3"
    CURRENT_PHASE="$name"
    PHASE_NUM=$((PHASE_NUM + 1))
    if phase_done "$name" && [[ "$FORCE_ALL" != "yes" ]]; then
        log_skip "($PHASE_NUM/$TOTAL_PHASES) $desc — sudah siap sebelum ini"
        return 0
    fi
    log_step "($PHASE_NUM/$TOTAL_PHASES) $desc"
    if [[ "$DRY_RUN" == "yes" ]]; then
        log_dry "akan jalankan fasa '$name'"
        return 0
    fi
    "$fn"
    mark_done "$name"
}

confirm() {
    [[ "$ASSUME_YES" == "yes" ]] && return 0
    local reply
    printf '\n%s%s%s [y/N] ' "$C_YEL" "$1" "$C_OFF"
    read -r reply </dev/tty || reply="n"
    [[ "$reply" =~ ^[Yy]$ ]]
}

#---------------------------------------------------------------------------
# Skema konfigurasi
#   nama | keperluan | validator | default | penerangan
#   keperluan: required | optional | req_if:KEY=nilai
#---------------------------------------------------------------------------
readonly SCHEMA=(
"PANEL_FQDN|required|host||Domain atau IP untuk akses panel (cth: panel.domain.com)"
"ADMIN_EMAIL|required|email||Alamat email akaun admin"
"ADMIN_USERNAME|required|uname||Username admin (min 3 aksara)"
"ADMIN_PASSWORD|required|pass||Password admin (min 8 aksara)"
"PANEL_TIMEZONE|required|tz||Zon waktu (cth: Asia/Kuala_Lumpur)"

"SSL_EMAIL|req_if:PANEL_SSL=yes|email||Email pendaftaran Let's Encrypt"
"WINGS_FQDN|req_if:INSTALL_WINGS=yes|host||Domain atau IP node Wings"
"NODE_NAME|req_if:INSTALL_WINGS=yes|nodename||Nama node dalam panel"
"NODE_LOCATION|req_if:INSTALL_WINGS=yes|locshort||Kod lokasi pendek (cth: my)"

"PANEL_SSL|optional|bool|yes|Pasang sijil Let's Encrypt"
"PANEL_HTTP_PORT|optional|port||Port nginx untuk panel"
"ADMIN_FIRST_NAME|optional|any|Admin|Nama pertama admin"
"ADMIN_LAST_NAME|optional|any|User|Nama akhir admin"
"PANEL_TELEMETRY|optional|bool|no|Hantar telemetri ke upstream"
"RECAPTCHA_ENABLED|optional|bool|no|Hidupkan reCAPTCHA di login"
"RECAPTCHA_SITE_KEY|req_if:RECAPTCHA_ENABLED=yes|any||Site key reCAPTCHA"
"RECAPTCHA_SECRET_KEY|req_if:RECAPTCHA_ENABLED=yes|any||Secret key reCAPTCHA"

"DB_NAME|optional|dbident|panel|Nama pangkalan data"
"DB_USERNAME|optional|dbident|pterodactyl|Username pangkalan data"
"DB_PASSWORD|optional|any||Password pangkalan data (auto-jana jika kosong)"
"DB_HOST|optional|host|127.0.0.1|Host pangkalan data"
"DB_PORT|optional|port|3306|Port pangkalan data"

"REDIS_HOST|optional|host|127.0.0.1|Host Redis"
"REDIS_PORT|optional|port|6379|Port Redis"
"REDIS_PASSWORD|optional|any||Password Redis"

"MAIL_DRIVER|optional|enum:log,smtp|log|Pemacu email keluar"
"MAIL_HOST|req_if:MAIL_DRIVER=smtp|host||Host SMTP"
"MAIL_PORT|req_if:MAIL_DRIVER=smtp|port||Port SMTP"
"MAIL_USERNAME|optional|any||Username SMTP"
"MAIL_PASSWORD|optional|any||Password SMTP"
"MAIL_FROM|optional|email||Alamat pengirim (default: no-reply@PANEL_FQDN)"
"MAIL_FROM_NAME|optional|any|Pterodactyl Panel|Nama pengirim"
"MAIL_ENCRYPTION|optional|enum:tls,ssl,none|tls|Enkripsi SMTP"

"INSTALL_WINGS|optional|bool|yes|Pasang Wings + Docker + node"
"NODE_LOCATION_DESC|optional|any||Penerangan lokasi"
"NODE_MEMORY|optional|int||RAM node dalam MB (auto jika kosong)"
"NODE_DISK|optional|int||Disk node dalam MB (auto jika kosong)"
"NODE_MEMORY_OVERALLOCATE|optional|overalloc|0|Peratus over-allocate RAM"
"NODE_DISK_OVERALLOCATE|optional|overalloc|0|Peratus over-allocate disk"
"WINGS_PORT|optional|port|8080|Port HTTP Wings"
"WINGS_SFTP_PORT|optional|port|2022|Port SFTP Wings"
"WINGS_DATA_DIR|optional|abspath|/var/lib/pterodactyl/volumes|Folder data Wings"
"WINGS_SSL|optional|bool||Node guna https (default ikut PANEL_SSL)"
"NODE_PORT_RANGE|optional|portrange|25565-25585|Julat port allocation"
"NODE_ALLOCATION_IP|optional|host|0.0.0.0|IP untuk allocation"

"WINGS_DOCKER_SUBNET|optional|cidr||Subnet Docker untuk Wings (auto jika kosong)"
"EGG_IMPORT_URLS|optional|any||URL egg custom, pisah dengan koma"
"EGG_IMPORT_NEST_ID|optional|int|1|Nest ID untuk egg custom"

"GITHUB_TOKEN|optional|any||Token GitHub untuk elak had kadar composer"
"HARDEN_FIREWALL|optional|bool|no|Pasang UFW + fail2ban"
"CREDENTIALS_FILE|optional|abspath|/root/pterodactyl-credentials.txt|Fail simpanan kredential"
)

#--- validator ------------------------------------------------------------
v_any()      { return 0; }
v_email()    { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
v_host()     { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; }
v_uname()    { [[ "$1" =~ ^[A-Za-z0-9_.-]{3,}$ ]]; }
v_nodename() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,100}$ ]]; }
v_locshort() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,60}$ ]]; }
v_dbident()  { [[ "$1" =~ ^[A-Za-z0-9_]{1,32}$ ]]; }
v_pass()     { (( ${#1} >= 8 )); }
v_int()      { [[ "$1" =~ ^[0-9]+$ ]]; }
v_port()     { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
v_bool()     { [[ "$1" =~ ^(yes|no)$ ]]; }
v_tz() {
    # Pada imej minimal, tzdata belum tentu dipasang semasa validasi. Kalau
    # pangkalan data zon waktu tiada, sahkan format sahaja — nilai sebenar
    # disemak semula dalam phase_deps selepas tzdata dipasang.
    if [[ -d /usr/share/zoneinfo/posix ]]; then
        [[ -f "/usr/share/zoneinfo/$1" ]]
    else
        [[ "$1" == "UTC" ]] || [[ "$1" =~ ^[A-Za-z_]+/[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)?$ ]]
    fi
}
v_abspath()  { [[ "$1" == /* ]]; }
v_overalloc(){ [[ "$1" == "-1" ]] || { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 <= 1000 )); }; }
v_cidr() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]
}
v_portrange(){
    [[ "$1" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
    v_port "$a" && v_port "$b" && (( b >= a )) && (( b - a <= 5000 ))
}
v_enum() {
    local val="$1" allowed="$2" x
    IFS=',' read -ra x <<<"$allowed"
    local a; for a in "${x[@]}"; do [[ "$val" == "$a" ]] && return 0; done
    return 1
}

validator_hint() {
    case "$1" in
        email)     echo "mesti alamat email yang sah" ;;
        host)      echo "mesti domain atau IP yang sah, tanpa http:// dan tanpa / di hujung" ;;
        uname)     echo "huruf/nombor/._- sahaja, minimum 3 aksara" ;;
        nodename)  echo "huruf/nombor/._- sahaja, maksimum 100 aksara" ;;
        locshort)  echo "huruf/nombor/._- sahaja, maksimum 60 aksara" ;;
        dbident)   echo "huruf/nombor/underscore sahaja, maksimum 32 aksara" ;;
        pass)      echo "minimum 8 aksara" ;;
        int)       echo "mesti nombor bulat" ;;
        port)      echo "mesti port 1-65535" ;;
        bool)      echo 'mesti "yes" atau "no"' ;;
        tz)        echo "zon waktu tak wujud — semak \`timedatectl list-timezones\`" ;;
        abspath)   echo "mesti laluan mutlak bermula dengan /" ;;
        overalloc) echo "mesti 0-1000, atau -1 untuk tanpa had" ;;
        portrange) echo 'format "mula-tamat", cth "25565-25585", maksimum 5000 port' ;;
        cidr)      echo 'format CIDR, cth "172.20.0.0/16"' ;;
        enum:*)    echo "mesti salah satu daripada: ${1#enum:}" ;;
        *)         echo "nilai tidak sah" ;;
    esac
}

#---------------------------------------------------------------------------
# Muat & sahkan konfigurasi
#---------------------------------------------------------------------------
load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Fail konfigurasi tidak dijumpai: $CONFIG_FILE"
    local lineno=0 line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val%"${val##*[![:space:]]}"}"          # buang ruang di hujung
            [[ "$val" == \"*\" ]] && val="${val:1:${#val}-2}"
            [[ "$val" == \'*\' ]] && val="${val:1:${#val}-2}"
            CFG["$key"]="$val"
        else
            die "Konfigurasi rosak pada baris $lineno: $line"
        fi
    done <"$CONFIG_FILE"
}

cfg() { printf '%s' "${CFG[$1]:-}"; }

validate_config() {
    local -a errors=()
    local entry name req vtype def desc val

    for entry in "${SCHEMA[@]}"; do
        IFS='|' read -r name req vtype def desc <<<"$entry"
        val="${CFG[$name]:-}"

        # tentukan sama ada wajib
        local is_required="no"
        case "$req" in
            required) is_required="yes" ;;
            req_if:*)
                local cond="${req#req_if:}" ck cv
                ck="${cond%%=*}"; cv="${cond#*=}"
                local other="${CFG[$ck]:-}"
                [[ -z "$other" ]] && other="$(schema_default "$ck")"
                [[ "$other" == "$cv" ]] && is_required="yes"
                ;;
        esac

        if [[ -z "$val" ]]; then
            if [[ "$is_required" == "yes" ]]; then
                if [[ "$req" == req_if:* ]]; then
                    errors+=("$name|WAJIB kerana ${req#req_if:}|$desc")
                else
                    errors+=("$name|WAJIB tetapi kosong|$desc")
                fi
            fi
            continue
        fi

        # sahkan nilai yang diisi
        local ok=0
        case "$vtype" in
            enum:*) v_enum "$val" "${vtype#enum:}" || ok=1 ;;
            *)      "v_$vtype" "$val" || ok=1 ;;
        esac
        (( ok == 0 )) || errors+=("$name|nilai \"$val\" tidak sah — $(validator_hint "$vtype")|$desc")
    done

    # semakan silang
    local ssl; ssl="$(cfg PANEL_SSL)"; [[ -z "$ssl" ]] && ssl="yes"
    local fqdn; fqdn="$(cfg PANEL_FQDN)"
    if [[ "$ssl" == "yes" && "$fqdn" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        errors+=("PANEL_FQDN|PANEL_SSL=\"yes\" perlukan domain sebenar, bukan alamat IP|Let's Encrypt tak boleh keluarkan sijil untuk IP")
    fi
    if [[ -n "$(cfg ADMIN_PASSWORD)" ]]; then
        local p; p="$(cfg ADMIN_PASSWORD)"
        if ! [[ "$p" =~ [A-Z] && "$p" =~ [a-z] && "$p" =~ [0-9] ]]; then
            errors+=("ADMIN_PASSWORD|perlu sekurang-kurangnya satu huruf besar, satu huruf kecil dan satu nombor|Syarat Pterodactyl sendiri, bukan syarat script ini")
        fi
    fi

    if (( ${#errors[@]} == 0 )); then
        log_ok "Konfigurasi sah — ${#SCHEMA[@]} medan diperiksa, tiada masalah"
        return 0
    fi

    printf '\n%s%s%s\n' "$C_RED$C_BLD" "KONFIGURASI TIDAK LENGKAP — ${#errors[@]} masalah dijumpai:" "$C_OFF"
    printf '\n'
    local i=1 e n m d
    for e in "${errors[@]}"; do
        IFS='|' read -r n m d <<<"$e"
        printf '  %s%2d.%s %s%-24s%s %s\n' "$C_BLD" "$i" "$C_OFF" "$C_YEL" "$n" "$C_OFF" "$m"
        printf '      %s%s%s\n' "$C_DIM" "$d" "$C_OFF"
        i=$((i + 1))
    done
    printf '\n  Edit %s%s%s dan jalankan semula.\n\n' "$C_BLD" "$CONFIG_FILE" "$C_OFF"
    return 1
}

schema_default() {
    local entry name req vtype def desc
    for entry in "${SCHEMA[@]}"; do
        IFS='|' read -r name req vtype def desc <<<"$entry"
        [[ "$name" == "$1" ]] && { printf '%s' "$def"; return 0; }
    done
}

apply_defaults() {
    local entry name req vtype def desc
    for entry in "${SCHEMA[@]}"; do
        IFS='|' read -r name req vtype def desc <<<"$entry"
        [[ -z "${CFG[$name]:-}" && -n "$def" ]] && CFG["$name"]="$def"
    done

    # default dinamik
    [[ -z "$(cfg PANEL_HTTP_PORT)" ]] && \
        CFG[PANEL_HTTP_PORT]="$([[ "$(cfg PANEL_SSL)" == "yes" ]] && echo 443 || echo 80)"
    [[ -z "$(cfg WINGS_SSL)" ]] && CFG[WINGS_SSL]="$(cfg PANEL_SSL)"
    [[ -z "$(cfg MAIL_FROM)" ]] && CFG[MAIL_FROM]="no-reply@$(cfg PANEL_FQDN)"
    [[ -z "$(cfg NODE_LOCATION_DESC)" ]] && CFG[NODE_LOCATION_DESC]="$(cfg NODE_LOCATION)"

    # Password yang dijana MESTI kekal antara run. Kalau tidak, run kedua akan
    # menjana password baharu, ALTER USER dalam MariaDB, dan memutuskan panel
    # yang .env-nya masih simpan password lama.
    if [[ -z "$(cfg DB_PASSWORD)" ]]; then
        local pwfile="$STATE_DIR/db-password"
        if [[ -s "$pwfile" ]]; then
            CFG[DB_PASSWORD]="$(cat "$pwfile")"
        else
            CFG[DB_PASSWORD]="$(gen_secret 32)"
            GENERATED_SECRETS+=("DB_PASSWORD")
            if mkdir -p "$STATE_DIR" 2>/dev/null; then
                ( umask 077; printf '%s' "${CFG[DB_PASSWORD]}" >"$pwfile" ) 2>/dev/null || true
            fi
        fi
    fi

    if [[ -z "$(cfg NODE_MEMORY)" ]]; then
        local total_mb; total_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
        CFG[NODE_MEMORY]="$(( total_mb > 2048 ? total_mb - 1024 : total_mb ))"
    fi
    if [[ -z "$(cfg NODE_DISK)" ]]; then
        local free_mb; free_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
        CFG[NODE_DISK]="$(( free_mb > 10240 ? free_mb - 5120 : free_mb ))"
    fi
}

#---------------------------------------------------------------------------
# Preflight
#---------------------------------------------------------------------------
# Preflight sendiri perlukan curl dan ss. Pada imej minimal kedua-duanya
# mungkin tiada, jadi pasang dulu sebelum apa-apa semakan dibuat.
bootstrap_tools() {
    local -a need=()
    have curl || need+=(curl ca-certificates)
    have ss   || need+=(iproute2)
    (( ${#need[@]} == 0 )) && return 0
    log_info "Memasang alat asas untuk preflight: ${need[*]}"
    retry apt_q update -qq >>"$LOG_FILE" 2>&1 || true
    apt_q install -y -qq "${need[@]}" >>"$LOG_FILE" 2>&1 \
        || die "Tak boleh pasang ${need[*]}. Semak sambungan apt anda: apt-get update"
}

preflight() {
    log_step "Pemeriksaan awal (preflight)"
    local -a fatal=() warn=()

    [[ "$(id -u)" -eq 0 ]] || fatal+=("Script mesti dijalankan sebagai root (guna sudo).")
    bootstrap_tools

    local os_id="" os_ver=""
    if [[ -f /etc/os-release ]]; then
        os_id="$(. /etc/os-release && echo "${ID:-}")"
        os_ver="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    fi
    case "$os_id:$os_ver" in
        ubuntu:20.04|ubuntu:22.04|ubuntu:24.04|debian:11|debian:12)
            log_ok "OS disokong: $os_id $os_ver" ;;
        ubuntu:*|debian:*)
            warn+=("OS $os_id $os_ver belum diuji dengan script ini — mungkin berjaya, mungkin tidak.") ;;
        *)
            fatal+=("OS '$os_id $os_ver' tidak disokong. Perlu Ubuntu 20.04/22.04/24.04 atau Debian 11/12.") ;;
    esac

    local arch; arch="$(uname -m)"
    case "$arch" in
        x86_64|aarch64) log_ok "Seni bina: $arch" ;;
        *) fatal+=("Seni bina '$arch' tidak disokong (perlu x86_64 atau aarch64).") ;;
    esac

    local ram_mb; ram_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    if (( ram_mb < 1024 )); then
        fatal+=("RAM hanya ${ram_mb}MB. Minimum 1GB untuk panel sahaja, 2GB disyorkan.")
    elif (( ram_mb < 2048 )); then
        warn+=("RAM ${ram_mb}MB agak rendah. Panel akan jalan tapi game server tak banyak ruang.")
    else
        log_ok "RAM: ${ram_mb}MB"
    fi

    local disk_mb; disk_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
    if (( disk_mb < 5120 )); then
        fatal+=("Ruang kosong pada / hanya ${disk_mb}MB. Minimum 5GB diperlukan.")
    else
        log_ok "Ruang disk kosong: $(( disk_mb / 1024 ))GB"
    fi

    if [[ -d /run/systemd/system ]]; then
        HAS_SYSTEMD="yes"
        log_ok "systemd dikesan — service akan didaftarkan secara normal"
    else
        HAS_SYSTEMD="no"
        warn+=("systemd tiada (biasanya dalam container LXC/Docker). Service akan dipasang sebagai script /usr/local/bin/pterodactyl-services dan perlu dijalankan manual selepas reboot.")
    fi

    # port
    local -a check_ports=("$(cfg PANEL_HTTP_PORT)")
    [[ "$(cfg PANEL_SSL)" == "yes" ]] && check_ports+=(80)
    if [[ "$(cfg INSTALL_WINGS)" == "yes" ]]; then
        check_ports+=("$(cfg WINGS_PORT)" "$(cfg WINGS_SFTP_PORT)")
    fi
    local p seen=""
    for p in "${check_ports[@]}"; do
        [[ " $seen " == *" $p "* ]] && continue
        seen="$seen $p"
        if port_busy "$p"; then
            # Port yang dipegang oleh pemasangan Pterodactyl ini sendiri (dari
            # run sebelumnya) bukan konflik — kenal pasti pemiliknya, jangan
            # hanya bergantung pada rekod fasa yang mungkin dah direset.
            local owner ours="no"
            owner="$(port_owner "$p")"
            case "$owner" in
                *nginx*)   [[ -f /etc/nginx/sites-enabled/pterodactyl.conf ]] && ours="yes" ;;
                *wings*)   [[ -f "$WINGS_ETC/config.yml" ]] && ours="yes" ;;
                *php-fpm*) [[ -d "$PANEL_DIR" ]] && ours="yes" ;;
            esac
            phase_done "webserver" && [[ "$owner" == *nginx* ]] && ours="yes"
            if [[ "$ours" == "yes" ]]; then
                log_ok "Port $p diguna oleh pemasangan Pterodactyl ini sendiri"
            else
                fatal+=("Port $p sudah diguna oleh proses lain${owner:+ ($owner)}. Hentikan proses itu atau tukar port dalam config. Semak: ss -lntp | grep :$p")
            fi
        else
            log_ok "Port $p bebas"
        fi
    done

    # Rangkaian: uji fail sebenar yang akan dimuat turun, bukan sekadar laman
    # utama hos. Range request 0-0 supaya tak muat turun keseluruhan fail.
    local -a net_checks=(
        "arkib Panel|$PANEL_TARBALL"
        "pemasang Composer|https://getcomposer.org/installer"
    )
    if [[ "$(cfg INSTALL_WINGS)" == "yes" ]]; then
        local warch; warch="$([[ "$arch" == "aarch64" ]] && echo arm64 || echo amd64)"
        net_checks+=("binari Wings|$WINGS_BASE/wings_linux_$warch")
    fi
    local check label url
    for check in "${net_checks[@]}"; do
        label="${check%%|*}"; url="${check#*|}"
        if retry curl -fsSL --max-time 25 --range 0-0 -o /dev/null "$url" 2>/dev/null; then
            log_ok "Boleh muat turun $label"
        else
            fatal+=("Tidak boleh capai $label ($url) — semak sambungan internet, DNS, atau firewall keluar.")
        fi
    done

    # virtualisasi untuk Docker
    if [[ "$(cfg INSTALL_WINGS)" == "yes" ]]; then
        local virt="none"
        have systemd-detect-virt && virt="$(systemd-detect-virt 2>/dev/null || echo none)"
        case "$virt" in
            openvz|lxc|lxc-libvirt)
                warn+=("Virtualisasi '$virt' dikesan. Docker selalunya TIDAK berfungsi di sini, jadi Wings tak akan boleh start game server. KVM atau bare metal diperlukan.") ;;
            *) log_ok "Virtualisasi: $virt — sesuai untuk Docker" ;;
        esac
    fi

    # DNS untuk SSL
    if [[ "$(cfg PANEL_SSL)" == "yes" ]] && have dig; then
        local resolved
        resolved="$( { dig +short "$(cfg PANEL_FQDN)" A | head -1; } || true )"
        if [[ -z "$resolved" ]]; then
            warn+=("$(cfg PANEL_FQDN) tak resolve ke mana-mana IP. Let's Encrypt akan gagal sehingga DNS betul.")
        else
            log_ok "DNS $(cfg PANEL_FQDN) → $resolved"
        fi
    fi

    local w
    for w in "${warn[@]}"; do log_warn "$w"; done

    if (( ${#fatal[@]} > 0 )); then
        printf '\n%s%s%s\n\n' "$C_RED$C_BLD" "PREFLIGHT GAGAL — ${#fatal[@]} masalah yang menghalang pemasangan:" "$C_OFF"
        local i=1 f
        for f in "${fatal[@]}"; do
            printf '  %s%2d.%s %s\n' "$C_BLD" "$i" "$C_OFF" "$f"
            i=$((i + 1))
        done
        printf '\n  Tiada apa-apa berkaitan Pterodactyl dipasang. Betulkan di atas dan cuba lagi.\n'
        printf '  Untuk langkau semakan ini atas risiko sendiri: --skip-preflight\n\n'
        exit 1
    fi

    if (( ${#warn[@]} > 0 )) && [[ "$DRY_RUN" != "yes" ]]; then
        confirm "Ada ${#warn[@]} amaran di atas. Teruskan?" || die "Dibatalkan oleh pengguna."
    fi
}

#---------------------------------------------------------------------------
# Fasa pemasangan
#---------------------------------------------------------------------------
apt_q() { DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 "$@"; }

phase_deps() {
    log_info "Kemas kini senarai pakej..."
    retry apt_q update -qq >>"$LOG_FILE" 2>&1
    log_info "Pasang keperluan asas..."
    run apt_q install -y -qq curl wget tar unzip git ca-certificates gnupg \
        lsb-release apt-transport-https software-properties-common cron \
        iproute2 dnsutils sudo tzdata
    # tzdata kini dipasang — sahkan zon waktu betul-betul wujud
    [[ -f "/usr/share/zoneinfo/$(cfg PANEL_TIMEZONE)" ]] \
        || die "PANEL_TIMEZONE=\"$(cfg PANEL_TIMEZONE)\" tidak wujud dalam pangkalan data zon waktu. Lihat senarai penuh: ls /usr/share/zoneinfo"
    log_ok "Pakej asas siap"
}

detect_php() {
    local v out
    for v in 8.3 8.2; do
        out="$(apt-cache policy "php$v-cli" 2>/dev/null || true)"
        if [[ "$out" == *"Candidate: "[0-9]* ]]; then
            PHP_V="$v"; return 0
        fi
    done
    return 1
}

phase_php() {
    if ! detect_php; then
        log_info "PHP 8.2/8.3 tiada dalam repo lalai — tambah repo pihak ketiga..."
        local os_id; os_id="$(. /etc/os-release && echo "$ID")"
        if [[ "$os_id" == "ubuntu" ]]; then
            run add-apt-repository -y ppa:ondrej/php
        else
            run bash -c 'curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg'
            run bash -c 'echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list'
        fi
        retry apt_q update -qq >>"$LOG_FILE" 2>&1
        detect_php || die "Masih tak jumpa PHP 8.2/8.3 selepas tambah repo. Semak $LOG_FILE"
    fi
    log_info "Guna PHP $PHP_V"
    run apt_q install -y -qq \
        "php$PHP_V" "php$PHP_V-cli" "php$PHP_V-common" "php$PHP_V-fpm" \
        "php$PHP_V-gd" "php$PHP_V-mysql" "php$PHP_V-mbstring" "php$PHP_V-bcmath" \
        "php$PHP_V-xml" "php$PHP_V-curl" "php$PHP_V-zip" "php$PHP_V-intl" \
        "php$PHP_V-sqlite3" "php$PHP_V-redis"
    echo "$PHP_V" >"$STATE_DIR/php-version"
    log_ok "PHP $PHP_V + sambungan yang diperlukan siap"
}

phase_composer() {
    if have composer; then
        log_ok "Composer sudah ada: $(composer --version 2>/dev/null | head -1)"
        return 0
    fi
    local tmp; tmp="$(mktemp -d)"
    retry curl -fsSL --max-time 60 -o "$tmp/installer" https://getcomposer.org/installer
    local expected actual
    expected="$(curl -fsSL --max-time 30 https://composer.github.io/installer.sig)"
    actual="$(php -r "echo hash_file('sha384', '$tmp/installer');")"
    [[ "$expected" == "$actual" ]] || die "Checksum pemasang Composer tak sepadan — dibatalkan atas sebab keselamatan."
    run php "$tmp/installer" --install-dir=/usr/local/bin --filename=composer
    rm -rf "$tmp"
    log_ok "Composer dipasang"
}

svc_start() {
    local unit="$1" proc="$2"; shift 2
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        run systemctl enable --now "$unit"
    else
        pgrep -x "$proc" >/dev/null 2>&1 && return 0
        setsid nohup "$@" >>"$LOG_FILE" 2>&1 </dev/null &
        disown || true
    fi
}

phase_mariadb() {
    if ! have mariadbd && ! have mysqld; then
        log_info "Pasang MariaDB..."
        run apt_q install -y -qq mariadb-server mariadb-client
    fi
    mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld
    svc_start mariadb mariadbd mariadbd-safe --user=mysql
    local i
    for i in $(seq 1 45); do mariadb -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
    mariadb -e "SELECT 1" >/dev/null 2>&1 || die "MariaDB tak mahu start. Semak: journalctl -u mariadb -n 50"
    log_ok "MariaDB berjalan: $(mariadb -sN -e 'SELECT VERSION()')"

    local db user pass host
    db="$(cfg DB_NAME)"; user="$(cfg DB_USERNAME)"; pass="$(cfg DB_PASSWORD)"; host="$(cfg DB_HOST)"

    # MariaDB memadankan akaun ikut hos yang DISELESAIKAN, bukan yang ditaip.
    # Sambungan TCP ke 127.0.0.1 selalunya reverse-resolve menjadi "localhost",
    # jadi akaun '...'@'127.0.0.1' sahaja akan menolaknya dengan "Access denied".
    # Cipta kedua-dua bentuk untuk sambungan tempatan.
    local -a hosts=("$host")
    case "$host" in
        127.0.0.1|localhost|::1) hosts=(127.0.0.1 localhost) ;;
    esac

    mariadb -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    local h
    for h in "${hosts[@]}"; do
        mariadb <<SQL
CREATE USER IF NOT EXISTS '$user'@'$h' IDENTIFIED BY '$pass';
ALTER USER '$user'@'$h' IDENTIFIED BY '$pass';
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$user'@'$h' WITH GRANT OPTION;
SQL
    done
    mariadb -e "FLUSH PRIVILEGES;"

    # Sahkan kelayakan benar-benar boleh log masuk sebelum panel bergantung padanya.
    if ! mariadb -u"$user" -p"$pass" -h"$host" -P"$(cfg DB_PORT)" -D"$db" -e "SELECT 1" >/dev/null 2>&1; then
        die "Pengguna '$user' dicipta tetapi tak boleh log masuk ke '$db' melalui $host. Semak: mariadb -u$user -p -h$host $db"
    fi
    log_ok "Pangkalan data '$db' dan pengguna '$user' sedia (log masuk diuji)"
}

phase_redis() {
    have redis-server || run apt_q install -y -qq redis-server
    svc_start redis-server redis-server redis-server --port "$(cfg REDIS_PORT)" --daemonize no
    local i
    for i in $(seq 1 20); do redis-cli -p "$(cfg REDIS_PORT)" ping >/dev/null 2>&1 && break; sleep 1; done
    [[ "$(redis-cli -p "$(cfg REDIS_PORT)" ping 2>/dev/null)" == "PONG" ]] \
        || die "Redis tak mahu respond pada port $(cfg REDIS_PORT)"
    log_ok "Redis berjalan"
}

phase_panel_files() {
    mkdir -p "$PANEL_DIR"
    if [[ ! -f "$PANEL_DIR/artisan" ]]; then
        log_info "Muat turun Panel..."
        retry curl -fsSL --max-time 300 -o /tmp/panel.tar.gz "$PANEL_TARBALL"
        run tar -xzf /tmp/panel.tar.gz -C "$PANEL_DIR"
        rm -f /tmp/panel.tar.gz
    else
        log_ok "Fail panel sudah ada"
    fi
    chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"

    # GitHub mengehadkan muat turun tanpa token. Ini punca kegagalan composer
    # yang paling kerap pada VPS baharu, jadi guna token kalau ada.
    if [[ -n "$(cfg GITHUB_TOKEN)" ]]; then
        COMPOSER_ALLOW_SUPERUSER=1 composer config --global --no-interaction \
            github-oauth.github.com "$(cfg GITHUB_TOKEN)" >>"$LOG_FILE" 2>&1
        log_info "Token GitHub didaftarkan pada composer"
    fi

    log_info "Pasang kebergantungan PHP (ini ambil masa 1-3 minit)..."
    if ! ( cd "$PANEL_DIR" && COMPOSER_ALLOW_SUPERUSER=1 run composer install \
            --no-dev --optimize-autoloader --no-interaction ); then
        if grep -qE 'Could not authenticate against github.com|API limit|rate limit' "$LOG_FILE"; then
            log_err "Composer kena had kadar (rate limit) GitHub."
            log_err "Ini bukan masalah pemasangan — GitHub hadkan muat turun tanpa token."
            log_err "Penyelesaian: jana token di https://github.com/settings/tokens"
            log_err "(tiada skop diperlukan), letak dalam config sebagai GITHUB_TOKEN=\"ghp_...\","
            log_err "kemudian jalankan semula: $0 --config $CONFIG_FILE --resume"
        fi
        return 1
    fi
    log_ok "Panel $(grep -oE "'version' => '[^']+'" "$PANEL_DIR/config/app.php" | head -1 | grep -oE "[0-9.]+") dipasang di $PANEL_DIR"
}

env_set() {
    local key="$1" val="$2" f="$PANEL_DIR/.env"
    touch "$f"
    [[ -s "$f" && "$(tail -c1 "$f")" != $'\n' ]] && echo >>"$f"
    if grep -qE "^${key}=" "$f"; then
        awk -v k="$key" -v v="$val" \
            'BEGIN { FS = "=" } { if ($1 == k) print k "=" v; else print }' \
            "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    else
        printf '%s=%s\n' "$key" "$val" >>"$f"
    fi
}

art() { ( cd "$PANEL_DIR" && run php artisan "$@" ); }

phase_panel_env() {
    [[ -f "$PANEL_DIR/.env" ]] || cp "$PANEL_DIR/.env.example" "$PANEL_DIR/.env"
    grep -qE '^APP_KEY=base64:' "$PANEL_DIR/.env" || art key:generate --force

    local scheme; scheme="$([[ "$(cfg PANEL_SSL)" == "yes" ]] && echo https || echo http)"
    local url="$scheme://$(cfg PANEL_FQDN)"
    [[ "$(cfg PANEL_HTTP_PORT)" != "80" && "$(cfg PANEL_HTTP_PORT)" != "443" ]] \
        && url="$url:$(cfg PANEL_HTTP_PORT)"

    art p:environment:setup \
        --author="$(cfg ADMIN_EMAIL)" \
        --url="$url" \
        --timezone="$(cfg PANEL_TIMEZONE)" \
        --cache=redis --session=redis --queue=redis \
        --redis-host="$(cfg REDIS_HOST)" \
        --redis-port="$(cfg REDIS_PORT)" \
        --redis-pass="$(cfg REDIS_PASSWORD)" \
        --settings-ui=true --no-interaction

    art p:environment:database \
        --host="$(cfg DB_HOST)" --port="$(cfg DB_PORT)" \
        --database="$(cfg DB_NAME)" --username="$(cfg DB_USERNAME)" \
        --password="$(cfg DB_PASSWORD)" --no-interaction

    if [[ "$(cfg MAIL_DRIVER)" == "smtp" ]]; then
        art p:environment:mail --driver=smtp \
            --host="$(cfg MAIL_HOST)" --port="$(cfg MAIL_PORT)" \
            --username="$(cfg MAIL_USERNAME)" --password="$(cfg MAIL_PASSWORD)" \
            --email="$(cfg MAIL_FROM)" --from="$(cfg MAIL_FROM_NAME)" \
            --encryption="$(cfg MAIL_ENCRYPTION)" --no-interaction
    else
        env_set MAIL_MAILER log
    fi

    env_set PTERODACTYL_TELEMETRY_ENABLED "$([[ "$(cfg PANEL_TELEMETRY)" == "yes" ]] && echo true || echo false)"
    if [[ "$(cfg RECAPTCHA_ENABLED)" == "yes" ]]; then
        env_set RECAPTCHA_ENABLED true
        env_set RECAPTCHA_WEBSITE_KEY "$(cfg RECAPTCHA_SITE_KEY)"
        env_set RECAPTCHA_SECRET_KEY "$(cfg RECAPTCHA_SECRET_KEY)"
    else
        env_set RECAPTCHA_ENABLED false
    fi
    env_set APP_URL "$url"

    art config:clear
    log_info "Jalankan migrasi dan seeder (semua egg rasmi dipasang di sini)..."
    art migrate --seed --force
    log_ok "Skema dan data asas siap — $(mariadb -sN -D"$(cfg DB_NAME)" -e 'SELECT COUNT(*) FROM eggs') egg rasmi dipasang"
}

phase_panel_admin() {
    local exists
    exists="$(mariadb -sN -D"$(cfg DB_NAME)" -e \
        "SELECT COUNT(*) FROM users WHERE email='$(cfg ADMIN_EMAIL)' OR username='$(cfg ADMIN_USERNAME)'")"
    if [[ "$exists" != "0" ]]; then
        log_ok "Pengguna admin sudah wujud — dilangkau"
        return 0
    fi
    art p:user:make \
        --email="$(cfg ADMIN_EMAIL)" --username="$(cfg ADMIN_USERNAME)" \
        --name-first="$(cfg ADMIN_FIRST_NAME)" --name-last="$(cfg ADMIN_LAST_NAME)" \
        --password="$(cfg ADMIN_PASSWORD)" --admin=1 --no-interaction
    log_ok "Admin '$(cfg ADMIN_USERNAME)' dicipta"
}

phase_webserver() {
    have nginx || run apt_q install -y -qq nginx
    chown -R www-data:www-data "$PANEL_DIR"
    rm -f /etc/nginx/sites-enabled/default

    local port; port="$(cfg PANEL_HTTP_PORT)"
    # SSL dipasang selepas ini oleh certbot; mula dengan HTTP pada port 80
    [[ "$(cfg PANEL_SSL)" == "yes" ]] && port=80

    # Banyak VPS mematikan IPv6 sepenuhnya. Pada sistem begitu "listen [::]"
    # menyebabkan nginx gagal terus, jadi tulis baris itu hanya bila kernel
    # memang menyokong IPv6.
    local listen6=""
    if [[ -f /proc/net/if_inet6 ]]; then
        listen6="    listen [::]:$port;"
    else
        log_info "IPv6 tiada pada sistem ini — nginx akan dengar IPv4 sahaja"
    fi

    cat >/etc/nginx/sites-available/pterodactyl.conf <<NGINX
server {
    listen $port;
$listen6
    server_name $(cfg PANEL_FQDN);

    root $PANEL_DIR/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log  /var/log/nginx/pterodactyl.error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php$PHP_V-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht { deny all; }
}
NGINX
    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
    mkdir -p /run/php
    svc_start "php$PHP_V-fpm" "php-fpm$PHP_V" "php-fpm$PHP_V" --nodaemonize
    sleep 2
    run nginx -t
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        run systemctl enable nginx
        run systemctl restart nginx
    else
        pgrep -x nginx >/dev/null 2>&1 && run nginx -s reload || run nginx
    fi
    log_ok "nginx menyajikan panel pada port $port"
}

phase_ssl() {
    if [[ "$(cfg PANEL_SSL)" != "yes" ]]; then
        log_skip "PANEL_SSL=\"no\" — sijil dilangkau"
        return 0
    fi
    have certbot || run apt_q install -y -qq certbot python3-certbot-nginx
    if [[ -d "/etc/letsencrypt/live/$(cfg PANEL_FQDN)" ]]; then
        log_ok "Sijil untuk $(cfg PANEL_FQDN) sudah ada"
        return 0
    fi
    run certbot --nginx -d "$(cfg PANEL_FQDN)" \
        --non-interactive --agree-tos --redirect -m "$(cfg SSL_EMAIL)"
    log_ok "Sijil Let's Encrypt dipasang dan auto-renew diaktifkan"
}

phase_services() {
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        cat >/etc/systemd/system/pteroq.service <<UNIT
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php $PANEL_DIR/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
        run systemctl daemon-reload
        run systemctl enable --now pteroq.service
        ( crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan schedule:run' || true;
          echo "* * * * * php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1" ) | crontab -
        log_ok "pteroq.service aktif + cron scheduler didaftarkan"
    else
        write_fallback_runner
        run /usr/local/bin/pterodactyl-services start
        log_ok "Service dimulakan melalui /usr/local/bin/pterodactyl-services"
    fi
}

write_fallback_runner() {
    cat >/usr/local/bin/pterodactyl-services <<RUNNER
#!/usr/bin/env bash
# Pemula service Pterodactyl untuk sistem tanpa systemd.
# Jalankan selepas setiap reboot: /usr/local/bin/pterodactyl-services start
set -e
PANEL_DIR="$PANEL_DIR"
PHP_V="$PHP_V"
REDIS_PORT="$(cfg REDIS_PORT)"

start() {
    mkdir -p /run/mysqld /run/php && chown mysql:mysql /run/mysqld
    pgrep -x mariadbd >/dev/null    || { setsid nohup mariadbd-safe --user=mysql >/var/log/mariadb-boot.log 2>&1 & }
    pgrep -x redis-server >/dev/null || { setsid nohup redis-server --port "\$REDIS_PORT" >/var/log/redis-boot.log 2>&1 & }
    pgrep -f "php-fpm: master" >/dev/null || { setsid nohup "php-fpm\$PHP_V" --nodaemonize >/var/log/php-fpm-boot.log 2>&1 & }
    sleep 5
    pgrep -x nginx >/dev/null || nginx
    pgrep -f 'artisan [q]ueue:work' >/dev/null || {
        setsid nohup sudo -u www-data php "\$PANEL_DIR/artisan" queue:work \\
            --queue=high,standard,low --sleep=3 --tries=3 >/var/log/pterodactyl-queue.log 2>&1 & }
    pgrep -f '[s]chedule:run' >/dev/null || {
        setsid nohup bash -c "while true; do sudo -u www-data php \$PANEL_DIR/artisan schedule:run >/dev/null 2>&1; sleep 60; done" >/dev/null 2>&1 & }
    [ -x /usr/bin/wings ] && { pgrep -x wings >/dev/null || { setsid nohup /usr/bin/wings --config /etc/pterodactyl/config.yml >/var/log/wings.log 2>&1 & }; }
    sleep 2
    echo "Semua service dimulakan."
}

status() {
    for p in mariadbd redis-server nginx wings; do
        printf '%-14s %s\n' "\$p" "\$(pgrep -x "\$p" >/dev/null && echo BERJALAN || echo MATI)"
    done
    printf '%-14s %s\n' "php-fpm" "\$(pgrep -f 'php-fpm: master' >/dev/null && echo BERJALAN || echo MATI)"
    printf '%-14s %s\n' "queue-worker" "\$(pgrep -f 'artisan [q]ueue:work' >/dev/null && echo BERJALAN || echo MATI)"
}

case "\${1:-start}" in
    start)  start ;;
    status) status ;;
    *) echo "Guna: \$0 {start|status}"; exit 1 ;;
esac
RUNNER
    chmod +x /usr/local/bin/pterodactyl-services
}

phase_wings_docker() {
    if have docker && docker info >/dev/null 2>&1; then
        log_ok "Docker sudah berjalan: $(docker info --format '{{.ServerVersion}}' 2>/dev/null)"
        return 0
    fi
    if ! have docker; then
        log_info "Pasang Docker melalui skrip rasmi..."
        retry curl -fsSL --max-time 120 -o /tmp/get-docker.sh https://get.docker.com
        run sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
    fi
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        run systemctl enable --now docker
    else
        pgrep -x dockerd >/dev/null || { setsid nohup dockerd >>"$LOG_FILE" 2>&1 </dev/null & disown || true; }
    fi
    local i
    for i in $(seq 1 40); do docker info >/dev/null 2>&1 && break; sleep 1; done
    docker info >/dev/null 2>&1 || die "Docker daemon tak mahu start. Ini biasanya berlaku pada VPS OpenVZ/LXC. Semak: dockerd --debug"
    log_ok "Docker aktif: $(docker info --format '{{.ServerVersion}}')"
}

phase_wings_binary() {
    local arch bin
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) die "Wings tiada binari untuk $(uname -m)" ;;
    esac
    bin="$WINGS_BASE/wings_linux_$arch"
    mkdir -p "$WINGS_ETC" "$(cfg WINGS_DATA_DIR)"
    if [[ ! -x /usr/local/bin/wings ]]; then
        log_info "Muat turun Wings ($arch)..."
        retry curl -fsSL --max-time 300 -o /usr/local/bin/wings "$bin"
        chmod u+x /usr/local/bin/wings
    fi
    ln -sf /usr/local/bin/wings /usr/bin/wings
    log_ok "Wings dipasang: $(/usr/local/bin/wings version 2>/dev/null | head -1 || echo 'binari sedia')"
}

db_q() { mariadb -sN -D"$(cfg DB_NAME)" -e "$1"; }

# Untuk nilai yang datang dari sumber luar (cth. nama dalam fail egg).
# Nilai daripada config sudah disekat kepada aksara selamat oleh validator.
sql_escape() {
    local s="${1//\\/\\\\}"
    printf '%s' "${s//\'/\\\'}"
}

phase_wings_node() {
    local loc_id node_id
    loc_id="$(db_q "SELECT id FROM locations WHERE short='$(cfg NODE_LOCATION)' LIMIT 1")"
    if [[ -z "$loc_id" ]]; then
        art p:location:make --short="$(cfg NODE_LOCATION)" --long="$(cfg NODE_LOCATION_DESC)"
        loc_id="$(db_q "SELECT id FROM locations WHERE short='$(cfg NODE_LOCATION)' LIMIT 1")"
    fi
    [[ -n "$loc_id" ]] || die "Gagal cipta lokasi '$(cfg NODE_LOCATION)'"
    log_ok "Lokasi '$(cfg NODE_LOCATION)' (id=$loc_id)"

    node_id="$(db_q "SELECT id FROM nodes WHERE name='$(cfg NODE_NAME)' LIMIT 1")"
    if [[ -z "$node_id" ]]; then
        art p:node:make \
            --name="$(cfg NODE_NAME)" \
            --description="Dicipta oleh pterodactyl auto-installer" \
            --locationId="$loc_id" \
            --fqdn="$(cfg WINGS_FQDN)" \
            --public=1 \
            --scheme="$([[ "$(cfg WINGS_SSL)" == "yes" ]] && echo https || echo http)" \
            --proxy=0 --maintenance=0 \
            --maxMemory="$(cfg NODE_MEMORY)" \
            --overallocateMemory="$(cfg NODE_MEMORY_OVERALLOCATE)" \
            --maxDisk="$(cfg NODE_DISK)" \
            --overallocateDisk="$(cfg NODE_DISK_OVERALLOCATE)" \
            --uploadSize=100 \
            --daemonListeningPort="$(cfg WINGS_PORT)" \
            --daemonSFTPPort="$(cfg WINGS_SFTP_PORT)" \
            --daemonBase="$(cfg WINGS_DATA_DIR)"
        node_id="$(db_q "SELECT id FROM nodes WHERE name='$(cfg NODE_NAME)' LIMIT 1")"
    fi
    [[ -n "$node_id" ]] || die "Gagal cipta node '$(cfg NODE_NAME)'"
    log_ok "Node '$(cfg NODE_NAME)' (id=$node_id)"
    echo "$node_id" >"$STATE_DIR/node-id"

    # allocation
    local range ip start end sql=""
    range="$(cfg NODE_PORT_RANGE)"; ip="$(cfg NODE_ALLOCATION_IP)"
    start="${range%-*}"; end="${range#*-}"
    local p
    for (( p = start; p <= end; p++ )); do
        sql+="INSERT IGNORE INTO allocations (node_id, ip, port, created_at, updated_at) VALUES ($node_id, '$ip', $p, NOW(), NOW());"
    done
    mariadb -D"$(cfg DB_NAME)" -e "$sql"
    local total; total="$(db_q "SELECT COUNT(*) FROM allocations WHERE node_id=$node_id")"
    log_ok "$total allocation didaftarkan ($ip:$range)"

    # config wings
    ( cd "$PANEL_DIR" && php artisan p:node:configuration "$node_id" >"$WINGS_ETC/config.yml" 2>>"$LOG_FILE" )
    grep -qE '^(uuid|token_id|debug|api):' "$WINGS_ETC/config.yml" \
        || die "config.yml Wings nampak tak betul. Semak: cat $WINGS_ETC/config.yml"
    chmod 600 "$WINGS_ETC/config.yml"
    configure_wings_network
    log_ok "Konfigurasi Wings ditulis ke $WINGS_ETC/config.yml"
}

# Wings mencipta rangkaian Docker sendiri pada 172.18.0.0/16. Kalau julat itu
# sudah dipakai rangkaian Docker lain, Wings mati dengan "Pool overlaps with
# other one on this address space". Pilih julat kosong lebih awal.
pick_free_subnet() {
    local used="" ids o
    ids="$(docker network ls -q 2>/dev/null || true)"
    if [[ -n "$ids" ]]; then
        # shellcheck disable=SC2086
        used="$(docker network inspect $ids --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)"
    fi
    for o in 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
        [[ "$used" == *"172.$o."* ]] && continue
        printf '172.%s.0.0/16' "$o"
        return 0
    done
    return 1
}

configure_wings_network() {
    local subnet gw
    subnet="$(cfg WINGS_DOCKER_SUBNET)"
    if [[ -z "$subnet" ]]; then
        subnet="$(pick_free_subnet || true)"
        if [[ -z "$subnet" ]]; then
            log_warn "Tiada julat 172.x kosong dijumpai — Wings akan guna defaultnya"
            return 0
        fi
        # 172.18.0.0/16 ialah default Wings; tak perlu tulis apa-apa
        [[ "$subnet" == "172.18.0.0/16" ]] && return 0
        log_info "172.18.0.0/16 sudah diguna — Wings ditetapkan ke $subnet"
    fi
    grep -q '^docker:' "$WINGS_ETC/config.yml" && return 0
    gw="$(awk -F'[./]' '{ print $1 "." $2 ".0.1" }' <<<"$subnet")"
    cat >>"$WINGS_ETC/config.yml" <<YAML
docker:
  network:
    interface: $gw
    name: pterodactyl_nw
    driver: bridge
    network_mode: pterodactyl_nw
    is_internal: false
    enable_icc: true
    network_mtu: 1500
    dns:
      - 1.1.1.1
      - 8.8.8.8
    interfaces:
      v4:
        subnet: $subnet
        gateway: $gw
YAML
}

phase_wings_service() {
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        cat >/etc/systemd/system/wings.service <<UNIT
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=$WINGS_ETC
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
        run systemctl daemon-reload
        run systemctl enable --now wings
    else
        write_fallback_runner
        pgrep -x wings >/dev/null || {
            setsid nohup /usr/local/bin/wings --config "$WINGS_ETC/config.yml" >/var/log/wings.log 2>&1 </dev/null &
            disown || true
        }
    fi
    sleep 6
    if pgrep -x wings >/dev/null; then
        log_ok "Wings berjalan"
        return 0
    fi

    # Wings tidak hidup — kumpul sebabnya dan beri arahan khusus, jangan
    # sekadar lapor "siap".
    local out=""
    [[ -f /var/log/wings.log ]] && out="$(tail -n 60 /var/log/wings.log 2>/dev/null || true)"
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        out="$out
$(journalctl -u wings -n 60 --no-pager 2>/dev/null || true)"
    fi

    log_err "Wings tidak berjalan selepas dimulakan."
    case "$out" in
        *"Pool overlaps"*)
            log_err "Sebab: julat rangkaian Docker Wings bertindih dengan rangkaian Docker sedia ada."
            log_err "Betulkan: tetapkan WINGS_DOCKER_SUBNET ke julat kosong dalam config,"
            log_err "contohnya WINGS_DOCKER_SUBNET=\"172.25.0.0/16\", padam $WINGS_ETC/config.yml,"
            log_err "kemudian: $0 --config $CONFIG_FILE --force --resume"
            ;;
        *"Cannot read IPv6 setup"*|*"disable_ipv6: no such file"*)
            log_err "Sebab: kernel sistem ini dibina tanpa sokongan IPv6 langsung."
            log_err "Docker memerlukan /proc/sys/net/ipv6 wujud untuk mencipta bridge,"
            log_err "walaupun IPv6 tidak digunakan. Ini biasa pada container/VM yang"
            log_err "sangat dipangkas. Penyelesaian: guna kernel dengan modul ipv6"
            log_err "(muat dengan 'modprobe ipv6'), atau pindah Wings ke hos KVM biasa."
            ;;
        *"permission denied"*|*"Operation not permitted"*)
            log_err "Sebab: Wings tiada keizinan yang cukup — biasanya VPS OpenVZ/LXC."
            log_err "Wings perlukan KVM atau bare metal untuk mengurus container."
            ;;
        *"address already in use"*)
            log_err "Sebab: port $(cfg WINGS_PORT) atau $(cfg WINGS_SFTP_PORT) sudah diguna proses lain."
            ;;
        *)
            log_err "60 baris terakhir log Wings:"
            printf '%s\n' "$out" | tail -n 20 | sed 's/^/       /' >&2 || true
            ;;
    esac
    return 1
}

phase_eggs() {
    local urls; urls="$(cfg EGG_IMPORT_URLS)"
    if [[ -z "$urls" ]]; then
        log_skip "Tiada egg custom untuk diimport (egg rasmi sudah dipasang semasa seeding)"
        return 0
    fi
    local nest; nest="$(cfg EGG_IMPORT_NEST_ID)"
    if [[ "$(db_q "SELECT COUNT(*) FROM nests WHERE id=$nest")" == "0" ]]; then
        die "EGG_IMPORT_NEST_ID=$nest tidak wujud. Nest yang ada: $(db_q "SELECT GROUP_CONCAT(CONCAT(id,'=',name)) FROM nests")"
    fi
    local url n=0
    IFS=',' read -ra _urls <<<"$urls"
    for url in "${_urls[@]}"; do
        url="$(echo "$url" | xargs)"
        [[ -z "$url" ]] && continue
        local tmp="/tmp/egg-$RANDOM.json"
        if ! retry curl -fsSL --max-time 60 -o "$tmp" "$url"; then
            log_warn "Langkau egg (tak boleh dimuat turun): $url"
            continue
        fi
        if ! php -r 'exit(json_decode(file_get_contents($argv[1])) === null ? 1 : 0);' "$tmp" 2>/dev/null; then
            log_warn "Langkau egg (JSON tidak sah): $url"
            rm -f "$tmp"; continue
        fi

        # Pengimport panel menjana UUID baharu setiap kali, jadi import semula
        # akan hasilkan pendua. Padan ikut nama dalam nest yang sama.
        local egg_name existing
        egg_name="$(php -r 'echo json_decode(file_get_contents($argv[1]))->name ?? "";' "$tmp" 2>/dev/null || true)"
        if [[ -n "$egg_name" ]]; then
            existing="$(db_q "SELECT COUNT(*) FROM eggs WHERE nest_id=$nest AND name='$(sql_escape "$egg_name")'")"
            if [[ "$existing" != "0" ]]; then
                log_skip "Egg '$egg_name' sudah wujud dalam nest $nest — dilangkau"
                rm -f "$tmp"; continue
            fi
        fi
        if ( cd "$PANEL_DIR" && php artisan tinker --execute="
\$f = new Illuminate\\Http\\UploadedFile('$tmp', basename('$tmp'), 'application/json', null, true);
\$e = app(Pterodactyl\\Services\\Eggs\\Sharing\\EggImporterService::class)->handle(\$f, $nest);
echo 'IMPORTED:' . \$e->name;
" >>"$LOG_FILE" 2>&1 ); then
            n=$((n + 1)); log_ok "Egg diimport: $url"
        else
            log_warn "Gagal import egg: $url (lihat $LOG_FILE)"
        fi
        rm -f "$tmp"
    done
    log_ok "$n egg custom diimport"
}

phase_firewall() {
    if [[ "$(cfg HARDEN_FIREWALL)" != "yes" ]]; then
        log_skip "HARDEN_FIREWALL=\"no\" — firewall tidak diubah"
        return 0
    fi
    run apt_q install -y -qq ufw fail2ban
    run ufw allow 22/tcp
    run ufw allow 80/tcp
    run ufw allow 443/tcp
    if [[ "$(cfg INSTALL_WINGS)" == "yes" ]]; then
        run ufw allow "$(cfg WINGS_PORT)/tcp"
        run ufw allow "$(cfg WINGS_SFTP_PORT)/tcp"
        run ufw allow "$(cfg NODE_PORT_RANGE//-/:)/tcp"
        run ufw allow "$(cfg NODE_PORT_RANGE//-/:)/udp"
    fi
    run bash -c 'ufw --force enable'
    [[ "$HAS_SYSTEMD" == "yes" ]] && run systemctl enable --now fail2ban || true
    log_ok "UFW aktif + fail2ban dipasang"
}

phase_credentials() {
    local f; f="$(cfg CREDENTIALS_FILE)"
    local scheme; scheme="$([[ "$(cfg PANEL_SSL)" == "yes" ]] && echo https || echo http)"
    umask 077
    cat >"$f" <<CREDS
════════════════════════════════════════════════════════════
 PTERODACTYL — KREDENTIAL
 Dijana: $(_ts)
 JANGAN kongsi fail ini.
════════════════════════════════════════════════════════════

PANEL
  URL       : $scheme://$(cfg PANEL_FQDN)
  Username  : $(cfg ADMIN_USERNAME)
  Email     : $(cfg ADMIN_EMAIL)
  Password  : $(cfg ADMIN_PASSWORD)

PANGKALAN DATA
  Host      : $(cfg DB_HOST):$(cfg DB_PORT)
  Database  : $(cfg DB_NAME)
  Username  : $(cfg DB_USERNAME)
  Password  : $(cfg DB_PASSWORD)$( (( ${#GENERATED_SECRETS[@]} )) && echo "   (dijana automatik)" )

LOKASI PENTING
  Panel     : $PANEL_DIR
  Env panel : $PANEL_DIR/.env
  Wings cfg : $WINGS_ETC/config.yml
  Log pasang: $LOG_FILE
  State     : $STATE_FILE
CREDS
    chmod 600 "$f"
    log_ok "Kredential disimpan di $f (chmod 600)"
}

#---------------------------------------------------------------------------
# Pengesahan akhir
#---------------------------------------------------------------------------
phase_verify() {
    local -a pass=() fail=()
    local scheme; scheme="$([[ "$(cfg PANEL_SSL)" == "yes" ]] && echo https || echo http)"

    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' -k --max-time 30 \
            "http://127.0.0.1:$( [[ "$(cfg PANEL_SSL)" == "yes" ]] && echo 80 || cfg PANEL_HTTP_PORT )/auth/login" 2>/dev/null || echo 000)"
    [[ "$code" =~ ^(200|301|302)$ ]] && pass+=("Halaman login panel bertindak balas (HTTP $code)") \
                                     || fail+=("Halaman login panel pulangkan HTTP $code")

    mariadb -sN -D"$(cfg DB_NAME)" -e "SELECT 1" >/dev/null 2>&1 \
        && pass+=("Sambungan pangkalan data OK") || fail+=("Tak boleh sambung ke pangkalan data")

    [[ "$(redis-cli -p "$(cfg REDIS_PORT)" ping 2>/dev/null)" == "PONG" ]] \
        && pass+=("Redis bertindak balas") || fail+=("Redis tidak bertindak balas")

    local users eggs
    users="$(db_q "SELECT COUNT(*) FROM users WHERE root_admin=1")"
    (( users > 0 )) && pass+=("$users akaun admin wujud") || fail+=("Tiada akaun admin dalam pangkalan data")
    eggs="$(db_q "SELECT COUNT(*) FROM eggs")"
    (( eggs > 0 )) && pass+=("$eggs egg tersedia") || fail+=("Tiada egg dalam pangkalan data")

    if pgrep -f 'artisan [q]ueue:work' >/dev/null; then
        pass+=("Queue worker berjalan")
    else
        fail+=("Queue worker tidak berjalan")
    fi

    if [[ "$(cfg INSTALL_WINGS)" == "yes" ]]; then
        docker info >/dev/null 2>&1 && pass+=("Docker daemon aktif") || fail+=("Docker daemon tidak aktif")
        [[ -s "$WINGS_ETC/config.yml" ]] && pass+=("config.yml Wings wujud") || fail+=("config.yml Wings tiada")
        pgrep -x wings >/dev/null && pass+=("Proses Wings berjalan") || fail+=("Proses Wings tidak berjalan")
        local nodes; nodes="$(db_q "SELECT COUNT(*) FROM nodes")"
        (( nodes > 0 )) && pass+=("$nodes node berdaftar") || fail+=("Tiada node berdaftar")
        local allocs; allocs="$(db_q "SELECT COUNT(*) FROM allocations")"
        (( allocs > 0 )) && pass+=("$allocs allocation sedia") || fail+=("Tiada allocation")
    fi

    printf '\n'
    local x
    for x in "${pass[@]}"; do printf '   %s✔%s %s\n' "$C_GRN" "$C_OFF" "$x"; done
    for x in "${fail[@]}"; do printf '   %s✘%s %s\n' "$C_RED" "$C_OFF" "$x"; done

    if (( ${#fail[@]} > 0 )); then
        printf '\n%s%d semakan gagal.%s Pemasangan mungkin separa berfungsi.\n' "$C_YEL" "${#fail[@]}" "$C_OFF"
        printf 'Log penuh: %s\n' "$LOG_FILE"
        return 1
    fi
    return 0
}

print_summary() {
    local scheme; scheme="$([[ "$(cfg PANEL_SSL)" == "yes" ]] && echo https || echo http)"
    banner "SIAP"
    printf '  Panel      : %s%s://%s%s\n' "$C_BLD" "$scheme" "$(cfg PANEL_FQDN)" "$C_OFF"
    printf '  Username   : %s\n' "$(cfg ADMIN_USERNAME)"
    printf '  Kredential : %s\n' "$(cfg CREDENTIALS_FILE)"
    printf '  Log        : %s\n' "$LOG_FILE"
    if [[ "$HAS_SYSTEMD" != "yes" ]]; then
        printf '\n  %sSistem ini tiada systemd.%s Selepas setiap reboot, jalankan:\n' "$C_YEL" "$C_OFF"
        printf '      /usr/local/bin/pterodactyl-services start\n'
    fi
    if [[ "$(cfg INSTALL_WINGS)" == "yes" ]]; then
        printf '\n  Langkah seterusnya: buka panel → Admin → Nodes → %s → tab "Configuration"\n' "$(cfg NODE_NAME)"
        printf '  dan sahkan node menunjukkan tanda hijau. Kemudian cipta server pertama.\n'
    fi
    printf '\n'
}

#---------------------------------------------------------------------------
# Uninstall
#---------------------------------------------------------------------------
do_uninstall() {
    banner "UNINSTALL"
    printf '  Ini akan BUANG:\n'
    printf '    - %s (semua fail panel)\n' "$PANEL_DIR"
    printf '    - pangkalan data "%s" dan pengguna "%s"\n' "$(cfg DB_NAME)" "$(cfg DB_USERNAME)"
    printf '    - %s (config Wings)\n' "$WINGS_ETC"
    printf '    - service pteroq/wings, config nginx, state pemasang\n'
    printf '    - %s%sTIDAK%s dibuang: MariaDB/Redis/PHP/Docker, dan data game server dalam %s\n' \
           "$C_BLD" "$C_YEL" "$C_OFF" "$(cfg WINGS_DATA_DIR)"
    confirm "Betul-betul nak teruskan?" || die "Dibatalkan."

    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        systemctl disable --now pteroq wings 2>/dev/null || true
        rm -f /etc/systemd/system/pteroq.service /etc/systemd/system/wings.service
        systemctl daemon-reload || true
    else
        pkill -x wings 2>/dev/null || true
        pkill -f 'artisan [q]ueue:work' 2>/dev/null || true
    fi
    crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan schedule:run' | crontab - 2>/dev/null || true
    mariadb -e "DROP DATABASE IF EXISTS \`$(cfg DB_NAME)\`;" 2>/dev/null || true
    local uh
    for uh in "$(cfg DB_HOST)" 127.0.0.1 localhost; do
        mariadb -e "DROP USER IF EXISTS '$(cfg DB_USERNAME)'@'$uh';" 2>/dev/null || true
    done
    rm -rf "$PANEL_DIR" "$WINGS_ETC" "$STATE_DIR"
    rm -f /etc/nginx/sites-enabled/pterodactyl.conf /etc/nginx/sites-available/pterodactyl.conf
    rm -f /usr/local/bin/wings /usr/bin/wings /usr/local/bin/pterodactyl-services
    have nginx && { nginx -t >/dev/null 2>&1 && { [[ "$HAS_SYSTEMD" == "yes" ]] && systemctl reload nginx || nginx -s reload; } || true; }
    log_ok "Uninstall selesai."
    exit 0
}

#---------------------------------------------------------------------------
# Main
#---------------------------------------------------------------------------
usage() {
    cat <<USAGE
Pterodactyl Auto-Installer v$SCRIPT_VERSION

  $0 [pilihan]

  --config FAIL       Guna fail konfigurasi lain (default: ./pterodactyl.conf)
  --validate-only     Semak konfigurasi sahaja, jangan pasang apa-apa
  --dry-run           Tunjuk fasa yang akan dijalankan tanpa mengubah sistem
  --resume            Sambung semula, langkau fasa yang sudah siap (default)
  --force             Jalankan semula SEMUA fasa walaupun sudah siap
  --skip-preflight    Langkau semakan awal (atas risiko sendiri)
  --uninstall         Buang pemasangan
  -y, --yes           Jawab "ya" kepada semua soalan
  -h, --help          Papar mesej ini

Urutan biasa:
  1. cp pterodactyl.conf.example pterodactyl.conf && nano pterodactyl.conf
  2. sudo ./install.sh --validate-only
  3. sudo ./install.sh
USAGE
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --config)         CONFIG_FILE="$2"; shift 2 ;;
            --config=*)       CONFIG_FILE="${1#*=}"; shift ;;
            --validate-only)  VALIDATE_ONLY="yes"; shift ;;
            --dry-run)        DRY_RUN="yes"; shift ;;
            --resume)         shift ;;
            --force)          FORCE_ALL="yes"; shift ;;
            --skip-preflight) SKIP_PREFLIGHT="yes"; shift ;;
            --uninstall)      DO_UNINSTALL="yes"; shift ;;
            -y|--yes)         ASSUME_YES="yes"; shift ;;
            -h|--help)        usage; exit 0 ;;
            *) usage; die "Pilihan tidak dikenali: $1" ;;
        esac
    done
}

main() {
    parse_args "$@"
    mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || true
    _raw ""
    _raw "===== run bermula $(_ts) : $0 $* ====="

    banner "Pterodactyl Auto-Installer v$SCRIPT_VERSION"
    log_info "Konfigurasi : $CONFIG_FILE"
    log_info "Log         : $LOG_FILE"

    load_config
    validate_config || exit 1
    apply_defaults

    if [[ "$VALIDATE_ONLY" == "yes" ]]; then
        printf '\n  Ringkasan yang akan dipasang:\n'
        printf '    Panel di    : %s://%s\n' "$([[ "$(cfg PANEL_SSL)" == "yes" ]] && echo https || echo http)" "$(cfg PANEL_FQDN)"
        printf '    Admin       : %s <%s>\n' "$(cfg ADMIN_USERNAME)" "$(cfg ADMIN_EMAIL)"
        printf '    Wings       : %s\n' "$(cfg INSTALL_WINGS)"
        [[ "$(cfg INSTALL_WINGS)" == "yes" ]] && {
            printf '    Node        : %s @ %s (%s MB RAM, %s MB disk)\n' \
                "$(cfg NODE_NAME)" "$(cfg WINGS_FQDN)" "$(cfg NODE_MEMORY)" "$(cfg NODE_DISK)"
            printf '    Allocation  : %s:%s\n' "$(cfg NODE_ALLOCATION_IP)" "$(cfg NODE_PORT_RANGE)"
        }
        printf '\n  Konfigurasi sah. Jalankan tanpa --validate-only untuk pasang.\n\n'
        exit 0
    fi

    [[ "$(id -u)" -eq 0 ]] || die "Script mesti dijalankan sebagai root (guna sudo)."
    [[ -d /run/systemd/system ]] && HAS_SYSTEMD="yes" || HAS_SYSTEMD="no"
    [[ -f "$STATE_DIR/php-version" ]] && PHP_V="$(cat "$STATE_DIR/php-version")"

    [[ "$DO_UNINSTALL" == "yes" ]] && do_uninstall

    if [[ "$SKIP_PREFLIGHT" != "yes" ]]; then
        preflight
    else
        log_warn "Preflight dilangkau atas permintaan"
    fi

    local wings; wings="$(cfg INSTALL_WINGS)"
    TOTAL_PHASES=13
    [[ "$wings" == "yes" ]] && TOTAL_PHASES=17

    run_phase deps          "Pakej asas sistem"                phase_deps
    run_phase php           "PHP dan sambungannya"             phase_php
    [[ -z "$PHP_V" ]] && detect_php
    run_phase composer      "Composer"                         phase_composer
    run_phase mariadb       "MariaDB dan pangkalan data panel" phase_mariadb
    run_phase redis         "Redis"                            phase_redis
    run_phase panel_files   "Muat turun dan pasang Panel"      phase_panel_files
    run_phase panel_env     "Konfigurasi panel, migrasi, egg rasmi" phase_panel_env
    run_phase panel_admin   "Akaun admin"                      phase_panel_admin
    run_phase webserver     "nginx dan PHP-FPM"                phase_webserver
    run_phase ssl           "Sijil SSL"                        phase_ssl
    run_phase services      "Queue worker dan scheduler"       phase_services

    if [[ "$wings" == "yes" ]]; then
        run_phase wings_docker  "Docker"                       phase_wings_docker
        run_phase wings_binary  "Binari Wings"                 phase_wings_binary
        run_phase wings_node    "Node, allocation, config.yml" phase_wings_node
        run_phase wings_service "Service Wings"                phase_wings_service
    fi

    run_phase eggs      "Egg custom"  phase_eggs
    run_phase firewall  "Firewall"    phase_firewall

    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '\n  %sDry-run selesai — tiada apa-apa diubah.%s\n\n' "$C_CYN" "$C_OFF"
        exit 0
    fi

    phase_credentials

    CURRENT_PHASE="verify"
    log_step "Pengesahan akhir"
    if phase_verify; then
        print_summary
    else
        printf '\n  Jalankan semula selepas membaiki: %s --config %s --resume\n\n' "$0" "$CONFIG_FILE"
        exit 1
    fi
}

main "$@"
