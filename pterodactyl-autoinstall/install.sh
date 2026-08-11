#!/usr/bin/env bash
#############################################################################
#  Pterodactyl Auto-Installer
#
#  Jawab beberapa soalan, dan ia akan pasang Panel + Wings + Node + Egg,
#  serta Node.js dan Python, sampai siap.
#
#      sudo ./install.sh                 pasang (tanya soalan)
#      sudo ./install.sh --doctor        semak dan baiki pemasangan sedia ada
#      sudo ./install.sh --uninstall     buang
#
#  Setiap langkah rapuh mempunyai beberapa kaedah. Bila kaedah pertama gagal,
#  kaedah kedua dicuba sendiri. Kemajuan disimpan, jadi jalankan semula arahan
#  yang sama akan menyambung dari tempat ia berhenti.
#############################################################################

set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_CMDLINE="$0 $*"

# shellcheck source=lib/core.sh
. "$SELF_DIR/lib/core.sh"
# shellcheck source=lib/validate.sh
. "$SELF_DIR/lib/validate.sh"
# shellcheck source=lib/wizard.sh
. "$SELF_DIR/lib/wizard.sh"
# shellcheck source=lib/phases-base.sh
. "$SELF_DIR/lib/phases-base.sh"
# shellcheck source=lib/phases-panel.sh
. "$SELF_DIR/lib/phases-panel.sh"
# shellcheck source=lib/phases-wings.sh
. "$SELF_DIR/lib/phases-wings.sh"
# shellcheck source=lib/verify.sh
. "$SELF_DIR/lib/verify.sh"
# shellcheck source=lib/modes.sh
. "$SELF_DIR/lib/modes.sh"

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
# Ctrl-C tidak boleh meninggalkan pengguna tanpa arah, dan tidak boleh
# meninggalkan swap sementara yang tersangkut.
trap 'on_signal INT'  INT
trap 'on_signal TERM' TERM
trap 'cleanup_temp_swap' EXIT

CONFIG_FILE=""
MODE="install"
INTERACTIVE="auto"
RECONFIGURE="no"
SKIP_PREFLIGHT="no"
RESTORE_FROM=""

usage() {
    cat <<USAGE
Pterodactyl Auto-Installer v$INSTALLER_VERSION

  sudo ./install.sh [pilihan]

Mod
  (tiada)               Pasang. Tanya beberapa soalan, kemudian buat sampai siap.
  --wings-only          Pasang Wings sahaja pada mesin ini, sambung ke panel
                        yang sudah wujud di tempat lain.
  --add-node            Daftar node tambahan pada panel di mesin ini.
  --upgrade             Naik taraf panel ke keluaran terkini (backup dahulu).
  --backup              Simpan pangkalan data, .env dan config Wings.
  --restore [FOLDER]    Pulihkan daripada backup (default: yang terakhir).
  --status              Laporkan versi, service, dan kiraan dalam panel.
  --doctor              Semak pemasangan sedia ada dan baiki apa yang boleh.
  --uninstall           Buang panel, pangkalan data, config Wings dan service.

Pilihan
  --config FAIL         Baca jawapan daripada fail, bukan bertanya.
  --non-interactive     Jangan tanya apa-apa (perlu --config atau jawapan tersimpan).
  --reconfigure         Tanya semula walaupun ada jawapan tersimpan.
  --github-token TOKEN  Token GitHub, elak had kadar composer.
  --dry-run             Tunjuk apa yang akan dibuat tanpa mengubah sistem.
  --force               Jalankan semula semua fasa walaupun sudah siap.
  --skip-preflight      Langkau semakan awal.
  -y, --yes             Jawab ya kepada semua pengesahan.
  -h, --help            Papar mesej ini.

Selepas pemasangan, 'sudo pterodactyl-doctor' menyemak dan membaiki bila-bila masa.
USAGE
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --config)          [[ $# -ge 2 ]] || { usage; die "--config perlukan nama fail"; }
                               CONFIG_FILE="$2"; shift 2 ;;
            --config=*)        CONFIG_FILE="${1#*=}"; shift ;;
            --github-token)    [[ $# -ge 2 ]] || { usage; die "--github-token perlukan nilai token"; }
                               CFG[GITHUB_TOKEN]="$2"; shift 2 ;;
            --github-token=*)  CFG[GITHUB_TOKEN]="${1#*=}"; shift ;;
            --non-interactive) INTERACTIVE="no"; ASSUME_YES="yes"; shift ;;
            --reconfigure)     RECONFIGURE="yes"; shift ;;
            --doctor)          MODE="doctor"; shift ;;
            --uninstall)       MODE="uninstall"; shift ;;
            --wings-only)      MODE="wings-only"; shift ;;
            --add-node)        MODE="add-node"; shift ;;
            --upgrade)         MODE="upgrade"; shift ;;
            --backup)          MODE="backup"; shift ;;
            --status)          MODE="status"; shift ;;
            --restore)
                MODE="restore"; shift
                # Argumen folder adalah pilihan; jangan telan bendera lain.
                if [[ $# -ge 1 && "$1" != -* ]]; then RESTORE_FROM="$1"; shift; fi
                ;;
            --restore=*)       MODE="restore"; RESTORE_FROM="${1#*=}"; shift ;;
            --dry-run)         DRY_RUN="yes"; shift ;;
            --force)           FORCE_ALL="yes"; shift ;;
            --skip-preflight)  SKIP_PREFLIGHT="yes"; shift ;;
            -y|--yes)          ASSUME_YES="yes"; shift ;;
            -h|--help)         usage; exit 0 ;;
            *) usage; die "Pilihan tidak dikenali: $1" ;;
        esac
    done
    return 0
}

#---------------------------------------------------------------------------
# Preflight
#---------------------------------------------------------------------------
bootstrap_tools() {
    local -a need=()
    have curl || need+=(curl ca-certificates)
    have ss   || need+=(iproute2)
    (( ${#need[@]} == 0 )) && return 0
    log_info "Memasang alat asas dahulu: ${need[*]}"
    apt_update || true
    apt_install "${need[@]}" >>"$LOG_FILE" 2>&1 \
        || die "Tidak dapat memasang ${need[*]}. Semak sumber apt: apt-get update"
    return 0
}

preflight() {
    log_step "Pemeriksaan awal"
    local -a fatal=()

    bootstrap_tools

    case "$OS_ID:$OS_VER" in
        ubuntu:20.04|ubuntu:22.04|ubuntu:24.04|debian:11|debian:12)
            log_ok "OS disokong: $OS_ID $OS_VER" ;;
        ubuntu:*|debian:*)
            defer_warning "OS $OS_ID $OS_VER belum diuji dengan script ini — ia mungkin berjaya, tetapi kau memandu tanpa jaring." ;;
        *)
            fatal+=("OS '$OS_ID $OS_VER' tidak disokong. Perlu Ubuntu 20.04/22.04/24.04 atau Debian 11/12.") ;;
    esac

    if [[ -n "$ARCH_ALT" ]]; then
        log_ok "Seni bina: $ARCH"
    else
        fatal+=("Seni bina '$ARCH' tidak disokong. Perlu x86_64 atau aarch64.")
    fi

    local ram; ram="$(ram_mb)"
    if (( ram < 1024 )); then
        fatal+=("RAM hanya ${ram}MB. Minimum 1GB untuk panel.")
    elif (( ram < 2048 )); then
        defer_warning "RAM ${ram}MB agak rendah — panel akan jalan tetapi tidak banyak ruang untuk game server."
    else
        log_ok "RAM: ${ram}MB"
    fi

    local disk; disk="$(disk_mb)"
    if (( disk < 5120 )); then
        fatal+=("Ruang kosong pada / hanya ${disk}MB. Minimum 5GB.")
    else
        log_ok "Disk kosong: $(( disk / 1024 ))GB"
    fi

    [[ "$HAS_SYSTEMD" == "yes" ]] && log_ok "systemd aktif" \
        || defer_warning "systemd tiada (biasanya container LXC/Docker). Service akan dipasang sebagai /usr/local/bin/pterodactyl-services dan perlu dijalankan selepas setiap reboot."

    # Rangkaian: uji fail yang benar-benar akan dimuat turun. Range 0-0 supaya
    # tiada muat turun penuh. Laman utama hos bukan ujian yang berguna — ada
    # proxy yang menolak GET / tetapi membenarkan URL sebenar.
    local -a urls=("arkib Panel|$PANEL_TARBALL" "pemasang Composer|https://getcomposer.org/installer")
    cfg_is INSTALL_WINGS yes && urls+=("binari Wings|$WINGS_BASE/wings_linux_$ARCH_ALT")
    local u label url
    for u in "${urls[@]}"; do
        label="${u%%|*}"; url="${u#*|}"
        if retry curl -fsSL --max-time 25 --range 0-0 -o /dev/null "$url" 2>/dev/null; then
            log_ok "Boleh muat turun $label"
        else
            fatal+=("Tidak boleh capai $label ($url). Semak internet, DNS dan firewall keluar.")
        fi
    done

    if (( ${#fatal[@]} > 0 )); then
        printf '\n%s%s%s\n\n' "$C_RED$C_BLD" "TIDAK BOLEH TERUSKAN — ${#fatal[@]} masalah:" "$C_OFF"
        local i=1 f
        for f in "${fatal[@]}"; do
            printf '  %s%2d.%s %s\n' "$C_BLD" "$i" "$C_OFF" "$f"
            i=$((i + 1))
        done
        printf '\n  Tiada komponen Pterodactyl dipasang. Betulkan di atas dan cuba lagi.\n'
        printf '  Untuk langkau semakan ini atas risiko sendiri: --skip-preflight\n\n'
        exit 1
    fi
    return 0
}

#---------------------------------------------------------------------------
# Uninstall
#---------------------------------------------------------------------------
do_uninstall() {
    banner "UNINSTALL"
    printf '  Akan DIBUANG:\n'
    printf '    - %s (semua fail panel)\n' "$PANEL_DIR"
    printf '    - pangkalan data "%s" dan pengguna "%s"\n' "$(cfg DB_NAME)" "$(cfg DB_USERNAME)"
    printf '    - %s (config Wings)\n' "$WINGS_ETC"
    printf '    - service pteroq/wings, config nginx, state pemasang\n'
    printf '\n  TIDAK dibuang: MariaDB/Redis/PHP/Docker/Node.js/Python itu sendiri,\n'
    printf '  dan data game server dalam %s\n' "$(cfg WINGS_DATA_DIR)"
    confirm "Betul-betul teruskan?" || die "Dibatalkan."

    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        systemctl disable --now pteroq wings 2>/dev/null || true
        rm -f /etc/systemd/system/pteroq.service /etc/systemd/system/wings.service
        systemctl daemon-reload 2>/dev/null || true
    fi
    pkill -x wings 2>/dev/null || true
    pkill -f 'artisan [q]ueue:work' 2>/dev/null || true
    { crontab -l 2>/dev/null | grep -v 'artisan schedule:run' || true; } | crontab - 2>/dev/null || true
    rm -f /etc/cron.d/pterodactyl

    db_cli -e "DROP DATABASE IF EXISTS \`$(cfg DB_NAME)\`;" 2>/dev/null || true
    local uh
    for uh in "$(cfg DB_HOST)" 127.0.0.1 localhost '%'; do
        db_cli -e "DROP USER IF EXISTS '$(cfg DB_USERNAME)'@'$uh';" 2>/dev/null || true
    done

    rm -rf "$PANEL_DIR" "$WINGS_ETC" "$STATE_DIR"
    rm -f /etc/nginx/sites-enabled/pterodactyl.conf /etc/nginx/sites-available/pterodactyl.conf
    rm -f /etc/apache2/sites-enabled/pterodactyl.conf /etc/apache2/sites-available/pterodactyl.conf
    rm -f /usr/local/bin/wings /usr/bin/wings /usr/local/bin/pterodactyl-services /usr/local/bin/pterodactyl-doctor
    docker network rm pterodactyl_nw 2>/dev/null || true
    if have nginx && nginx -t >/dev/null 2>&1; then
        [[ "$HAS_SYSTEMD" == "yes" ]] && systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
    fi
    log_ok "Uninstall selesai."
    exit 0
}

#---------------------------------------------------------------------------
# Kumpul jawapan
#---------------------------------------------------------------------------
gather_answers() {
    [[ -n "$CONFIG_FILE" ]] && { load_config_file "$CONFIG_FILE" || die "Fail config tidak dijumpai: $CONFIG_FILE"; }

    [[ "$RECONFIGURE" == "yes" ]] && rm -f "$ANSWERS_FILE"
    have_saved_answers && [[ "$RECONFIGURE" != "yes" ]] && {
        load_saved_answers
        log_ok "Jawapan daripada run sebelumnya dimuatkan — guna --reconfigure untuk tukar"
    }

    # Perlukah kita bertanya? Hanya kalau ada medan wajib yang masih kosong.
    local need_ask="no"
    [[ -z "$(cfg PANEL_FQDN)" || -z "$(cfg ADMIN_EMAIL)" ]] && need_ask="yes"

    if [[ "$need_ask" == "yes" ]]; then
        if [[ "$INTERACTIVE" == "no" ]] || ! _tty_available; then
            log_err "Tiada terminal interaktif dan medan wajib masih kosong."
            log_err "Sediakan fail config (--config) atau jalankan dari terminal."
            log_err "Contoh fail config ada di: $SELF_DIR/pterodactyl.conf.example"
            exit 1
        fi
        wizard
    fi
    return 0
}

#---------------------------------------------------------------------------
# Doctor
#---------------------------------------------------------------------------
do_doctor() {
    banner "Pterodactyl Doctor"
    [[ -d "$PANEL_DIR" ]] || die "Tiada pemasangan panel dijumpai di $PANEL_DIR."
    PHP_V="$(state_get php-version)"
    [[ -z "$PHP_V" ]] && PHP_V="$(php_active_version || printf '8.3')"
    log_info "Menyemak pemasangan dan membaiki apa yang boleh dibaiki..."
    if run_verification; then
        printf '\n  %sSemua semakan lulus.%s\n\n' "$C_GRN" "$C_OFF"
        exit 0
    fi
    printf '\n  %s%d semakan masih gagal:%s\n' "$C_RED" "${#CHECK_FAIL[@]}" "$C_OFF"
    local f
    for f in "${CHECK_FAIL[@]}"; do printf '    - %s\n' "$f"; done
    printf '\n  Log penuh: %s\n\n' "$LOG_FILE"
    exit 1
}

#---------------------------------------------------------------------------
# Main
#---------------------------------------------------------------------------
main() {
    parse_args "$@"
    state_init
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    _raw ""
    _raw "===== run bermula $(_ts) : $INSTALLER_CMDLINE ====="

    [[ "$(id -u)" -eq 0 ]] || die "Script mesti dijalankan sebagai root. Guna: sudo $0"
    detect_system
    PHP_V="$(state_get php-version)"

    # Mod yang beroperasi ke atas pemasangan sedia ada berkongsi persediaan yang
    # sama: muatkan jawapan yang disimpan, isi default, kemudian jalankan.
    case "$MODE" in
        doctor|uninstall|upgrade|backup|restore|status|add-node)
            [[ -n "$CONFIG_FILE" ]] && { load_config_file "$CONFIG_FILE" || die "Fail config tidak dijumpai: $CONFIG_FILE"; }
            load_saved_answers || true
            autofill
            case "$MODE" in
                doctor)    do_doctor ;;
                uninstall) do_uninstall ;;
                upgrade)   do_upgrade ;;
                backup)    do_backup ;;
                restore)   do_restore ;;
                status)    do_status ;;
                add-node)  do_add_node ;;
            esac
            ;;
        wings-only)
            [[ -n "$CONFIG_FILE" ]] && { load_config_file "$CONFIG_FILE" || die "Fail config tidak dijumpai: $CONFIG_FILE"; }
            load_saved_answers || true
            # autofill mesti dijalankan: tanpanya WINGS_DATA_DIR, WINGS_PORT dan
            # rakan-rakannya kosong, dan fasa Wings gagal pada mkdir kosong.
            autofill
            do_wings_only
            ;;
    esac

    banner "Pterodactyl Auto-Installer v$INSTALLER_VERSION"
    printf '  Log penuh ditulis ke %s\n' "$LOG_FILE"

    gather_answers
    autofill

    validate_config || {
        printf '  Betulkan nilai di atas'
        [[ -n "$CONFIG_FILE" ]] && printf ' dalam %s' "$CONFIG_FILE"
        printf ', kemudian jalankan semula.\n'
        printf '  Atau jalankan dengan --reconfigure untuk menjawab semula soalan.\n\n'
        exit 1
    }

    show_plan
    if [[ "$DRY_RUN" != "yes" ]]; then
        confirm "Teruskan pemasangan dengan tetapan di atas?" \
            || die "Dibatalkan. Jalankan semula dengan --reconfigure untuk tukar jawapan."
    fi

    [[ "$SKIP_PREFLIGHT" == "yes" ]] && log_warn "Preflight dilangkau atas permintaan" || preflight

    # Senarai fasa dibina dahulu supaya jumlahnya dikira, bukan ditulis tangan.
    # Nombor yang ditulis tangan hanyut setiap kali satu fasa ditambah, dan
    # pengguna melihat "(19/17)".
    local -a PHASES=(
        "deps|Pakej asas sistem|phase_deps"
        "php|PHP dan sambungannya|phase_php"
        "composer|Composer|phase_composer"
        "nodejs|Node.js|phase_nodejs"
        "python|Python 3|phase_python"
        "mariadb|Pangkalan data|phase_mariadb"
        "redis|Redis|phase_redis"
        "panel_files|Muat turun dan pasang Panel|phase_panel_files"
        "panel_env|Konfigurasi panel, migrasi, egg rasmi|phase_panel_env"
        "panel_admin|Akaun admin|phase_panel_admin"
        "webserver|Pelayan web|phase_webserver"
        "ssl|HTTPS|phase_ssl"
        "services|Queue worker dan scheduler|phase_services"
    )
    if cfg_is INSTALL_WINGS yes; then
        PHASES+=(
            "wings_docker|Docker|phase_wings_docker"
            "wings_binary|Binari Wings|phase_wings_binary"
            "wings_node|Node, allocation, config Wings|phase_wings_node"
            "wings_service|Service Wings|phase_wings_service"
        )
    fi
    PHASES+=(
        "eggs|Egg custom|phase_eggs"
        "firewall|Firewall|phase_firewall"
    )

    TOTAL_PHASES="${#PHASES[@]}"
    local entry pname pdesc pfn
    for entry in "${PHASES[@]}"; do
        IFS='|' read -r pname pdesc pfn <<<"$entry"
        run_phase "$pname" "$pdesc" "$pfn"
    done

    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '\n  %sDry-run selesai — tiada apa-apa diubah.%s\n\n' "$C_CYN" "$C_OFF"
        exit 0
    fi

    CURRENT_PHASE="verify"
    log_step "Pengesahan akhir"
    local ok=0
    run_verification || ok=1

    install_doctor "$SELF_DIR"
    write_credentials
    save_answers
    print_summary "$ok"
    exit "$ok"
}

main "$@"
