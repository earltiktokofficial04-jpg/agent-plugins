#!/usr/bin/env bash
#############################################################################
#  core.sh — asas: log, keadaan sistem, enjin fallback, pengurusan state
#
#  NOTA PENTING TENTANG BASH DI SINI
#  Script berjalan dengan 'set -Eeuo pipefail'. Dua perangkap yang kerap:
#
#  1. `cmd | grep -q X` — grep -q keluar sebaik jumpa padanan, penulis di hulu
#     dapat SIGPIPE, dan pipefail jadikan status keseluruhan GAGAL walaupun
#     padanan itu WUJUD. Jangan guna corak ini. Sama untuk `| head`, `| tail -1`.
#  2. `a && b` sebagai pernyataan TERAKHIR sebuah fungsi menjadikan fungsi itu
#     pulangkan 1 bila `a` palsu. Sentiasa akhiri dengan `return 0` yang jelas.
#############################################################################

[[ -n "${_PTERO_CORE_LOADED:-}" ]] && return 0
_PTERO_CORE_LOADED=1

#---------------------------------------------------------------------------
# Tetapan global
#---------------------------------------------------------------------------
INSTALLER_VERSION="2.0.0"

STATE_DIR="${STATE_DIR:-/var/lib/pterodactyl-installer}"
STATE_FILE="$STATE_DIR/completed-phases"
ANSWERS_FILE="$STATE_DIR/answers.conf"
LOG_FILE="${LOG_FILE:-/var/log/pterodactyl-installer.log}"
PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"
WINGS_ETC="${WINGS_ETC:-/etc/pterodactyl}"

PANEL_TARBALL="https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
WINGS_BASE="https://github.com/pterodactyl/wings/releases/latest/download"

CURRENT_PHASE="init"
PHASE_NUM=0
TOTAL_PHASES=0
DRY_RUN="no"
ASSUME_YES="no"
FORCE_ALL="no"

declare -A CFG=()
declare -A STRATEGY_DESC=()
declare -A STRATEGY_USED=()
declare -a GENERATED_SECRETS=()
declare -a DEFERRED_WARNINGS=()
declare -a ATTEMPT_FAILURES=()

# Diisi oleh detect_system
OS_ID=""; OS_VER=""; OS_CODENAME=""; ARCH=""; ARCH_ALT=""
HAS_SYSTEMD="no"; VIRT="unknown"; HAS_IPV6="no"; PHP_V=""

# Adakah node yang sedang dikonfigurasi berjalan pada mesin INI? --add-node
# menetapkannya kepada "no" kerana node itu berada pada mesin lain.
NODE_IS_LOCAL="yes"

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

# Tulis ke fail log. Tidak sekali-kali gagal supaya tak menjatuhkan script.
# Log mengandungi arahan penuh, termasuk flag --password=. Hadkan keizinan
# sebelum apa-apa ditulis, dan tapis nilai rahsia daripada apa yang dilog.
_log_init_done=""
_log_init() {
    [[ -n "$_log_init_done" ]] && return 0
    _log_init_done=1
    ( umask 077; : >>"$LOG_FILE" ) 2>/dev/null || true
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    return 0
}

_redact() {
    local t="$1" v
    for v in "${CFG[ADMIN_PASSWORD]:-}" "${CFG[DB_PASSWORD]:-}" \
             "${CFG[REDIS_PASSWORD]:-}" "${CFG[MAIL_PASSWORD]:-}" \
             "${CFG[GITHUB_TOKEN]:-}" "${CFG[RECAPTCHA_SECRET_KEY]:-}"; do
        [[ -n "$v" && ${#v} -ge 6 ]] && t="${t//"$v"/<DIREDAKSI>}"
    done
    printf '%s' "$t"
}

_raw() {
    _log_init
    printf '%s\n' "$(_redact "$*")" >>"$LOG_FILE" 2>/dev/null || true
}

log()      { printf '%s\n' "$*";                             _raw "[$(_ts)] $*"; }
log_info() { printf '   %s\n' "$*";                          _raw "[$(_ts)] INFO  $*"; }
log_ok()   { printf '   %s✔%s %s\n' "$C_GRN" "$C_OFF" "$*";  _raw "[$(_ts)] OK    $*"; }
log_warn() { printf '   %s!%s %s\n' "$C_YEL" "$C_OFF" "$*";  _raw "[$(_ts)] WARN  $*"; }
log_err()  { printf '   %s✘%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; _raw "[$(_ts)] ERROR $*"; }
log_skip() { printf '   %s↷ %s%s\n' "$C_DIM" "$*" "$C_OFF";  _raw "[$(_ts)] SKIP  $*"; }
log_try()  { printf '   %s→%s %s\n' "$C_CYN" "$C_OFF" "$*";  _raw "[$(_ts)] TRY   $*"; }
log_dry()  { printf '   %s[dry-run]%s %s\n' "$C_CYN" "$C_OFF" "$*"; }
log_step() { printf '\n%s▸ %s%s\n' "$C_BLD$C_BLU" "$*" "$C_OFF"; _raw "[$(_ts)] PHASE $*"; }

banner() {
    printf '\n%s%s%s\n' "$C_BLD" "═══════════════════════════════════════════════════════════════" "$C_OFF"
    printf '%s  %s%s\n' "$C_BLD" "$*" "$C_OFF"
    printf '%s%s%s\n\n' "$C_BLD" "═══════════════════════════════════════════════════════════════" "$C_OFF"
}

die() { log_err "$*"; exit 1; }

# Amaran yang dikumpul dan ditunjukkan sekali lagi pada penghujung, supaya
# perkara penting tidak hilang dalam ratusan baris output.
defer_warning() { DEFERRED_WARNINGS+=("$1"); log_warn "$1"; }

#---------------------------------------------------------------------------
# Pengendalian ralat
#---------------------------------------------------------------------------
on_error() {
    local code=$? line="${1:-?}" cmd="${2:-?}"
    # `set -E` mewarisi trap ini ke setiap subshell. Helper seperti
    #     art() { ( cd "$PANEL_DIR" && run php artisan "$@" ); }
    # akan mencetuskannya sekali di dalam subshell dan sekali lagi dalam
    # proses induk — dua banner merah untuk satu kegagalan. Biar subshell
    # keluar senyap; hanya proses utama yang melaporkan.
    if [[ "${BASHPID:-$$}" != "$$" ]]; then
        exit "$code"
    fi
    printf '\n%s%s%s\n' "$C_RED$C_BLD" "═══════════════════════════════════════════════════════════════" "$C_OFF"
    printf '%s  BERHENTI semasa: %s%s\n' "$C_RED$C_BLD" "$CURRENT_PHASE" "$C_OFF"
    printf '%s%s%s\n\n' "$C_RED$C_BLD" "═══════════════════════════════════════════════════════════════" "$C_OFF"
    printf '  Baris     : %s\n' "$line"
    printf '  Arahan    : %s\n' "$cmd"
    printf '  Exit code : %s\n' "$code"
    printf '  Log penuh : %s\n\n' "$LOG_FILE"
    printf '  Semua fasa yang sudah siap dikekalkan. Selepas isu di atas selesai,\n'
    printf '  jalankan arahan yang sama semula — ia akan sambung dari sini:\n\n'
    printf '      %ssudo %s%s\n\n' "$C_BLD" "${INSTALLER_CMDLINE:-./install.sh}" "$C_OFF"
    printf '  20 baris terakhir log:\n'
    tail -n 20 "$LOG_FILE" 2>/dev/null | sed 's/^/      /' || true
    printf '\n'
    _raw "[$(_ts)] FATAL phase=$CURRENT_PHASE line=$line cmd=$cmd code=$code"
    exit "$code"
}

on_signal() {
    local sig="$1"
    printf '\n\n'
    log_warn "Dihentikan oleh isyarat $sig."
    log_info "Fasa yang sudah siap dikekalkan dalam $STATE_FILE."
    log_info "Sambung dengan menjalankan arahan yang sama semula:"
    log_info "    sudo ${INSTALLER_CMDLINE:-./install.sh}"
    cleanup_temp_swap
    # Kalau kita berada di tengah naik taraf, jangan tinggalkan panel offline.
    type panel_restore_maintenance >/dev/null 2>&1 && panel_restore_maintenance
    _raw "[$(_ts)] SIGNAL $sig phase=$CURRENT_PHASE"
    exit 130
}

#---------------------------------------------------------------------------
# Utiliti asas
#---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Hadkan tempoh sesuatu arahan. Tanpa ini, satu operasi rangkaian yang
# tergantung boleh menyekat pemasangan selama-lamanya tanpa sebarang mesej.
with_timeout() {
    local secs="$1"; shift
    if have timeout; then
        timeout --kill-after=30 "$secs" "$@"
    else
        "$@"
    fi
}

#---------------------------------------------------------------------------
# Swap sementara
#
# Composer menyusun graf kebergantungan penuh dalam ingatan. Pada VPS 1GB tanpa
# swap, kernel membunuhnya dengan OOM dan mesejnya ("Killed") tidak menyebut
# ingatan langsung — ini salah satu kegagalan pemasangan Pterodactyl yang paling
# kerap dan paling mengelirukan. Sediakan swap sementara dan tanggalkan semula
# selepas selesai, supaya sistem pengguna tidak diubah secara kekal.
#---------------------------------------------------------------------------
TEMP_SWAP_FILE="/var/pterodactyl-install.swap"

ensure_temp_swap() {
    local want_mb="${1:-2048}" ram swap total
    ram="$(ram_mb)"
    swap="$(awk '/SwapTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null || printf 0)"
    total=$(( ram + swap ))
    (( total >= want_mb )) && return 0
    [[ -f "$TEMP_SWAP_FILE" ]] && return 0

    local need=$(( want_mb - total ))
    (( need < 512 )) && need=512
    # Jangan cipta swap kalau disk sendiri hampir penuh.
    local free; free="$(disk_mb)"
    if (( free < need + 2048 )); then
        log_warn "Ingatan rendah (${total}MB) tetapi ruang disk tidak cukup untuk swap sementara"
        return 1
    fi

    log_info "Ingatan hanya ${total}MB — cipta ${need}MB swap sementara supaya composer tidak dibunuh OOM"
    if have fallocate && fallocate -l "${need}M" "$TEMP_SWAP_FILE" 2>/dev/null; then
        :
    elif ! dd if=/dev/zero of="$TEMP_SWAP_FILE" bs=1M count="$need" >/dev/null 2>&1; then
        rm -f "$TEMP_SWAP_FILE"
        return 1
    fi
    chmod 600 "$TEMP_SWAP_FILE"
    if ! mkswap "$TEMP_SWAP_FILE" >>"$LOG_FILE" 2>&1 || ! swapon "$TEMP_SWAP_FILE" >>"$LOG_FILE" 2>&1; then
        # Sesetengah VPS (OpenVZ, sesetengah container) melarang swapon.
        log_warn "Kernel ini tidak membenarkan swap tambahan — teruskan tanpanya"
        rm -f "$TEMP_SWAP_FILE"
        return 1
    fi
    log_ok "Swap sementara ${need}MB diaktifkan"
    return 0
}

cleanup_temp_swap() {
    [[ -f "$TEMP_SWAP_FILE" ]] || return 0
    swapoff "$TEMP_SWAP_FILE" 2>/dev/null || true
    rm -f "$TEMP_SWAP_FILE" 2>/dev/null || true
    return 0
}

# Ulang arahan dengan backoff. Guna untuk operasi rangkaian.
retry() {
    local max="${RETRY_MAX:-4}" delay="${RETRY_DELAY:-2}" n=0
    until "$@"; do
        n=$((n + 1))
        if (( n >= max )); then
            _raw "[$(_ts)] RETRY gagal selepas $max cubaan: $*"
            return 1
        fi
        log_warn "cubaan $n/$max gagal, ulang dalam ${delay}s"
        sleep "$delay"
        delay=$((delay * 2))
    done
    return 0
}

# Jalankan arahan, log outputnya, dan pada kegagalan tunjuk hujung log.
run() {
    _raw "[$(_ts)] EXEC  $*"
    if ! "$@" >>"$LOG_FILE" 2>&1; then
        _raw "[$(_ts)] EXEC-FAIL $*"
        return 1
    fi
    return 0
}

# Sama seperti run tetapi bising bila gagal — untuk langkah tanpa fallback.
run_loud() {
    if ! run "$@"; then
        log_err "arahan gagal: $*"
        tail -n 25 "$LOG_FILE" 2>/dev/null | sed 's/^/       /' >&2 || true
        return 1
    fi
    return 0
}

# Rahsia rawak. head menutup paip lebih awal, jadi SIGPIPE di hulu memang
# dijangka — sebab itu `|| true`.
gen_secret() {
    { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"; } || true
}

# Password yang memenuhi syarat Pterodactyl: ada huruf besar, kecil dan nombor.
gen_password() {
    local p
    while :; do
        p="$(gen_secret "${1:-20}")"
        if [[ "$p" =~ [A-Z] && "$p" =~ [a-z] && "$p" =~ [0-9] ]]; then
            printf '%s' "$p"
            return 0
        fi
    done
}

# Untuk nilai daripada sumber luar yang dimasukkan ke dalam SQL.
sql_escape() {
    local s="${1//\\/\\\\}"
    printf '%s' "${s//\'/\\\'}"
}

port_busy() {
    local hits
    hits="$(ss -lnt 2>/dev/null | awk -v p="[:.]$1\$" '$4 ~ p { c++ } END { print c + 0 }')"
    [[ "$hits" != "0" ]]
}

# NOTA: jangan guna `awk '... exit'` di sini. awk yang keluar awal menutup paip,
# ss dapat SIGPIPE, dan pipefail jadikan fungsi ini pulangkan 141 — yang pada
# tapak panggilan tertentu mencetuskan ERR trap dan membunuh pemasangan.
port_owner() {
    ss -lntp 2>/dev/null | awk -v p="[:.]$1\$" '$4 ~ p && !seen { print $NF; seen = 1 }'
}

# Port bebas pertama bermula dari $1.
next_free_port() {
    local p="$1" limit=$(( $1 + 200 ))
    while (( p < limit )); do
        port_busy "$p" || { printf '%s' "$p"; return 0; }
        p=$((p + 1))
    done
    return 1
}

#---------------------------------------------------------------------------
# Kesan sistem
#---------------------------------------------------------------------------
detect_system() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
        OS_VER="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
        OS_CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    fi
    [[ -z "$OS_CODENAME" ]] && have lsb_release && OS_CODENAME="$(lsb_release -sc 2>/dev/null || true)"

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  ARCH_ALT="amd64" ;;
        aarch64) ARCH_ALT="arm64" ;;
        *)       ARCH_ALT="" ;;
    esac

    [[ -d /run/systemd/system ]] && HAS_SYSTEMD="yes" || HAS_SYSTEMD="no"
    [[ -f /proc/net/if_inet6 ]] && HAS_IPV6="yes" || HAS_IPV6="no"

    if have systemd-detect-virt; then
        VIRT="$(systemd-detect-virt 2>/dev/null || printf 'none')"
    elif [[ -f /proc/user_beancounters ]]; then
        VIRT="openvz"
    elif grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
        VIRT="lxc"
    else
        VIRT="unknown"
    fi
    return 0
}

ram_mb()  { awk '/MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo; }
disk_mb() { df -Pm / | awk 'NR == 2 { print $4 }'; }

#---------------------------------------------------------------------------
# apt
#---------------------------------------------------------------------------
# Tunggu proses apt/dpkg lain selesai. Pada VPS baharu, cloud-init dan
# unattended-upgrades kerap memegang lock beberapa minit selepas boot —
# ini punca kegagalan "Could not get lock" yang paling biasa.
apt_wait() {
    local i=0 held=""
    while :; do
        held=""
        for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do
            if have fuser && fuser "$f" >/dev/null 2>&1; then held="$f"; break; fi
        done
        [[ -z "$held" ]] && break
        i=$((i + 1))
        if (( i == 1 )); then
            log_info "Menunggu proses apt lain melepaskan lock (biasanya unattended-upgrades)..."
        fi
        if (( i > 60 )); then
            log_warn "Lock apt masih dipegang selepas 5 minit — teruskan dan harap apt sendiri boleh tunggu"
            break
        fi
        sleep 5
    done
    return 0
}

apt_q() {
    apt_wait
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Use-Pty=0 \
        -o DPkg::Lock::Timeout=300 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@"
}

apt_update() { retry apt_q update -qq; }

apt_install() {
    apt_q install -y -qq "$@"
}

# Adakah pakej boleh dipasang daripada sumber yang dikonfigurasi sekarang?
apt_available() {
    local out
    out="$(apt-cache policy "$1" 2>/dev/null || true)"
    [[ "$out" == *"Candidate: "[0-9]* ]]
}

apt_installed() {
    local st
    st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
    [[ "$st" == *"install ok installed"* ]]
}

#---------------------------------------------------------------------------
# Enjin fallback
#
#  attempt "matlamat" verify_fn strategi1 strategi2 ...
#
#  - Kalau verify_fn sudah lulus, tiada apa dilakukan (idempoten).
#  - Setiap strategi dicuba berturut; yang pertama lulus verify_fn menang.
#  - Kalau semua gagal, pulangkan 1 supaya pemanggil boleh putuskan sama ada
#    itu maut atau boleh diteruskan.
#---------------------------------------------------------------------------
strategy_label() {
    printf '%s' "${STRATEGY_DESC[$1]:-$1}"
}

attempt() {
    local goal="$1" verify="$2"
    shift 2
    local -a strategies=("$@")
    local total="${#strategies[@]}" i=0 fn

    if "$verify" >/dev/null 2>&1; then
        log_ok "$goal — sudah dipenuhi"
        return 0
    fi

    for fn in "${strategies[@]}"; do
        i=$((i + 1))
        log_try "$goal — kaedah $i/$total: $(strategy_label "$fn")"
        _raw "[$(_ts)] ATTEMPT goal='$goal' strategy=$fn ($i/$total)"
        local mark
        mark="$(wc -l <"$LOG_FILE" 2>/dev/null || printf 0)"
        if "$fn" >>"$LOG_FILE" 2>&1; then
            if "$verify" >/dev/null 2>&1; then
                log_ok "$goal — berjaya melalui $(strategy_label "$fn")"
                STRATEGY_USED["$goal"]="$fn"
                return 0
            fi
            record_attempt_failure "$goal" "$fn" "$mark" "selesai tetapi pengesahan tidak lulus"
            log_warn "$goal — $(strategy_label "$fn") selesai tetapi pengesahan tidak lulus"
        else
            record_attempt_failure "$goal" "$fn" "$mark" ""
            log_warn "$goal — $(strategy_label "$fn") gagal"
        fi
    done

    log_err "$goal — semua $total kaedah gagal"
    explain_attempt_failures "$goal"
    return 1
}

# Ambil baris ralat yang paling bermakna daripada output strategi itu sendiri,
# supaya ringkasan akhir boleh memberitahu MENGAPA sesuatu gagal.
record_attempt_failure() {
    local goal="$1" fn="$2" mark="$3" note="$4" why=""
    why="$( { tail -n "+$((mark + 1))" "$LOG_FILE" 2>/dev/null \
              | grep -iE 'error|fatal|cannot|unable|failed|denied|not found|no space|killed' \
              | grep -viE '^\[|EXEC|RETRY' \
              | tail -n 1; } 2>/dev/null || true )"
    why="$(printf '%s' "$why" | cut -c1-160)"
    [[ -z "$why" ]] && why="$note"
    [[ -z "$why" ]] && why="tiada mesej ralat yang jelas dalam log"
    ATTEMPT_FAILURES+=("$goal|$(strategy_label "$fn")|$why")
    return 0
}

explain_attempt_failures() {
    local goal="$1" e g s w
    for e in "${ATTEMPT_FAILURES[@]}"; do
        IFS='|' read -r g s w <<<"$e"
        [[ "$g" == "$goal" ]] || continue
        log_err "  · $s: $w"
    done
    return 0
}

# Cari corak dalam log baru-baru ini. Untuk memadankan punca kegagalan.
log_has() {
    local pat="$1" lines="${2:-200}" out
    out="$(tail -n "$lines" "$LOG_FILE" 2>/dev/null || true)"
    [[ "$out" == *"$pat"* ]]
}

#---------------------------------------------------------------------------
# State
#---------------------------------------------------------------------------
state_init() { mkdir -p "$STATE_DIR" 2>/dev/null || true; }

phase_done() { [[ -f "$STATE_FILE" ]] && grep -qxF "$1" "$STATE_FILE"; }

mark_done() {
    state_init
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null || printf '%s\n' "$1" >>"$STATE_FILE"
    return 0
}

unmark_done() {
    [[ -f "$STATE_FILE" ]] || return 0
    grep -vxF "$1" "$STATE_FILE" >"$STATE_FILE.tmp" 2>/dev/null || true
    mv "$STATE_FILE.tmp" "$STATE_FILE"
    return 0
}

# Simpanan kunci-nilai yang kekal antara run (cth. password yang dijana).
state_get() {
    local f="$STATE_DIR/kv-$1"
    [[ -s "$f" ]] && cat "$f"
    return 0
}

state_put() {
    state_init
    ( umask 077; printf '%s' "$2" >"$STATE_DIR/kv-$1" ) 2>/dev/null || true
    return 0
}

run_phase() {
    local name="$1" desc="$2" fn="$3"
    CURRENT_PHASE="$name"
    PHASE_NUM=$((PHASE_NUM + 1))
    if phase_done "$name" && [[ "$FORCE_ALL" != "yes" ]]; then
        log_skip "($PHASE_NUM/$TOTAL_PHASES) $desc — sudah siap"
        return 0
    fi
    log_step "($PHASE_NUM/$TOTAL_PHASES) $desc"
    if [[ "$DRY_RUN" == "yes" ]]; then
        log_dry "akan jalankan fasa '$name'"
        return 0
    fi
    "$fn"
    mark_done "$name"
    return 0
}

#---------------------------------------------------------------------------
# Service: systemd bila ada, fallback proses bila tiada
#---------------------------------------------------------------------------
svc_is_active() {
    if [[ "$HAS_SYSTEMD" == "yes" ]] && systemctl list-unit-files "$1.service" >/dev/null 2>&1; then
        systemctl is-active --quiet "$1" && return 0
    fi
    [[ -n "${2:-}" ]] && pgrep -x "$2" >/dev/null 2>&1 && return 0
    return 1
}

# svc_up <unit> <nama-proses> <arahan-fallback...>
svc_up() {
    local unit="$1" proc="$2"
    shift 2
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        run systemctl enable "$unit" || true
        run systemctl restart "$unit" || run systemctl start "$unit" || true
        systemctl is-active --quiet "$unit" && return 0
        # systemd gagal — cuba lancarkan terus sebagai fallback
        log_warn "systemd tak dapat memulakan $unit — cuba lancarkan terus"
    fi
    pgrep -x "$proc" >/dev/null 2>&1 && return 0
    [[ $# -eq 0 ]] && return 1
    setsid nohup "$@" >>"$LOG_FILE" 2>&1 </dev/null &
    disown 2>/dev/null || true
    return 0
}

# Tunggu sampai syarat dipenuhi. wait_for <detik> <arahan...>
wait_for() {
    local secs="$1"; shift
    local i=0
    while (( i < secs )); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

confirm() {
    [[ "$ASSUME_YES" == "yes" ]] && return 0
    [[ ! -t 0 && ! -e /dev/tty ]] && return 0
    local reply=""
    printf '\n%s%s%s [y/N] ' "$C_YEL" "$1" "$C_OFF"
    read -r reply </dev/tty 2>/dev/null || reply="n"
    [[ "$reply" =~ ^[Yy] ]]
}

cfg() { printf '%s' "${CFG[$1]:-}"; }
cfg_is() { [[ "${CFG[$1]:-}" == "$2" ]]; }
