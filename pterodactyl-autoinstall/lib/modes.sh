#!/usr/bin/env bash
#############################################################################
#  modes.sh — kitaran hayat selain pemasangan pertama
#
#    --wings-only   pasang Wings sahaja, sambung ke panel yang sudah wujud
#    --upgrade      naik taraf panel sedia ada ke keluaran terkini
#    --backup       simpan pangkalan data + .env + config Wings
#    --restore      pulihkan daripada backup
#    --status       laporkan versi dan keadaan setiap komponen
#    --add-node     daftar node tambahan pada panel ini
#############################################################################

[[ -n "${_PTERO_MODES_LOADED:-}" ]] && return 0
_PTERO_MODES_LOADED=1

BACKUP_DIR="${BACKUP_DIR:-/var/backups/pterodactyl}"

# Ditetapkan semasa panel berada dalam mod penyelenggaraan. Trap EXIT dan
# pengendali isyarat memanggil hook di bawah, supaya Ctrl-C atau ralat maut di
# tengah naik taraf tidak meninggalkan panel offline selama-lamanya.
_PANEL_TAKEN_DOWN="no"

panel_restore_maintenance() {
    [[ "$_PANEL_TAKEN_DOWN" == "yes" ]] || return 0
    _PANEL_TAKEN_DOWN="no"
    ( cd "$PANEL_DIR" && php artisan up >/dev/null 2>&1 ) || true
    return 0
}

#===========================================================================
# Backup
#===========================================================================
# Dipanggil sendiri sebelum apa-apa yang merosakkan (upgrade, restore), dan
# tersedia sebagai mod. Sebuah backup yang gagal mesti menghentikan operasi
# yang memerlukannya — kalau tidak ia bukan backup, cuma harapan.
backup_now() {
    local label="${1:-manual}" stamp dest
    stamp="$(date '+%Y%m%d-%H%M%S')"
    dest="$BACKUP_DIR/$stamp-$label"
    mkdir -p "$dest" 2>/dev/null || { log_err "Tidak dapat mencipta $dest"; return 1; }
    chmod 700 "$BACKUP_DIR" "$dest" 2>/dev/null || true

    # Backup separuh yang ditinggalkan lebih berbahaya daripada tiada backup:
    # ia kelihatan sah dalam senarai, dan --restore daripadanya memusnahkan data.
    # Setiap laluan kegagalan di bawah membuangnya semula.
    _backup_abort() {
        rm -rf "$dest" 2>/dev/null || true
        log_err "$1"
        return 1
    }

    if [[ -f "$PANEL_DIR/.env" ]]; then
        if ! cp -p "$PANEL_DIR/.env" "$dest/panel.env"; then
            _backup_abort "Gagal menyalin .env"
            return 1
        fi
    fi
    [[ -f "$WINGS_ETC/config.yml" ]] && cp -p "$WINGS_ETC/config.yml" "$dest/wings-config.yml" 2>/dev/null || true

    # Dump pangkalan data melalui fail kelayakan 0600, bukan argumen baris
    # arahan yang kelihatan dalam `ps`.
    if have mysqldump || have mariadb-dump; then
        local cnf dumper
        dumper="$(have mariadb-dump && printf 'mariadb-dump' || printf 'mysqldump')"
        cnf="$(mktemp)"; chmod 600 "$cnf"
        {
            printf '[client]\n'
            printf 'user=%s\n' "$(cfg DB_USERNAME)"
            printf 'password=%s\n' "$(cfg DB_PASSWORD)"
            printf 'host=%s\n' "$(cfg DB_HOST)"
            printf 'port=%s\n' "$(cfg DB_PORT)"
        } >"$cnf"
        if "$dumper" --defaults-extra-file="$cnf" --single-transaction --quick \
             --routines --events "$(cfg DB_NAME)" >"$dest/database.sql" 2>>"$LOG_FILE"; then
            gzip -f "$dest/database.sql" 2>/dev/null || true
        else
            rm -f "$cnf"
            _backup_abort "Dump pangkalan data gagal — backup ini tidak lengkap, jadi ia dibuang"
            return 1
        fi
        rm -f "$cnf"
    else
        _backup_abort "Tiada mysqldump/mariadb-dump — tidak boleh backup pangkalan data"
        return 1
    fi

    printf 'panel_dir=%s\ndb_name=%s\ncreated=%s\nlabel=%s\n' \
        "$PANEL_DIR" "$(cfg DB_NAME)" "$(_ts)" "$label" >"$dest/manifest.txt"
    chmod -R go-rwx "$dest" 2>/dev/null || true
    log_ok "Backup disimpan di $dest"
    printf '%s' "$dest" >"$STATE_DIR/last-backup"
    return 0
}

do_backup() {
    banner "Backup"
    [[ -f "$PANEL_DIR/artisan" ]] || die "Tiada pemasangan panel di $PANEL_DIR."
    backup_now manual || die "Backup gagal — lihat $LOG_FILE"
    printf '\n  Simpan folder itu di luar server ini juga.\n\n'
    exit 0
}

do_restore() {
    banner "Restore"
    local src="${RESTORE_FROM:-}"
    if [[ -z "$src" ]]; then
        src="$(cat "$STATE_DIR/last-backup" 2>/dev/null || true)"
        [[ -z "$src" ]] && die "Tiada backup dinyatakan. Guna: --restore /var/backups/pterodactyl/<folder>"
        log_info "Guna backup terakhir: $src"
    fi
    [[ -d "$src" ]] || die "Folder backup tidak wujud: $src"
    [[ -f "$src/panel.env" || -f "$src/database.sql.gz" ]] || die "Folder itu tidak nampak seperti backup Pterodactyl."

    printf '  Akan menulis ganti pangkalan data "%s" dan %s/.env\n' "$(cfg DB_NAME)" "$PANEL_DIR"
    printf '  daripada: %s\n' "$src"
    confirm "Teruskan? Data semasa akan hilang." || die "Dibatalkan."

    # Backup keadaan semasa dahulu — restore yang silap tanpa jaring adalah
    # kehilangan data yang kekal.
    backup_now pre-restore || defer_warning "Tidak dapat membuat backup keselamatan sebelum restore."

    if [[ -f "$src/database.sql.gz" || -f "$src/database.sql" ]]; then
        local cnf; cnf="$(mktemp)"; chmod 600 "$cnf"
        {
            printf '[client]\n'
            printf 'user=%s\n' "$(cfg DB_USERNAME)"
            printf 'password=%s\n' "$(cfg DB_PASSWORD)"
            printf 'host=%s\n' "$(cfg DB_HOST)"
            printf 'port=%s\n' "$(cfg DB_PORT)"
        } >"$cnf"
        local rc=0
        if [[ -f "$src/database.sql.gz" ]]; then
            gunzip -c "$src/database.sql.gz" | db_cli --defaults-extra-file="$cnf" "$(cfg DB_NAME)" || rc=1
        else
            db_cli --defaults-extra-file="$cnf" "$(cfg DB_NAME)" <"$src/database.sql" || rc=1
        fi
        rm -f "$cnf"
        (( rc == 0 )) || die "Restore pangkalan data gagal. Data asal masih ada dalam backup pre-restore."
        log_ok "Pangkalan data dipulihkan"
    fi

    if [[ -f "$src/panel.env" ]]; then
        cp -p "$src/panel.env" "$PANEL_DIR/.env"
        chown www-data:www-data "$PANEL_DIR/.env" 2>/dev/null || true
        chmod 600 "$PANEL_DIR/.env"
        log_ok ".env dipulihkan"
    fi
    [[ -f "$src/wings-config.yml" ]] && {
        mkdir -p "$WINGS_ETC"
        cp -p "$src/wings-config.yml" "$WINGS_ETC/config.yml"
        chmod 600 "$WINGS_ETC/config.yml"
        log_ok "config.yml Wings dipulihkan"
    }

    art config:clear || true
    art cache:clear || true
    fix_restart_queue || true
    log_ok "Restore selesai."
    exit 0
}

#===========================================================================
# Upgrade
#===========================================================================
do_upgrade() {
    banner "Naik taraf panel"
    [[ -f "$PANEL_DIR/artisan" ]] || die "Tiada pemasangan panel di $PANEL_DIR."

    local before
    before="$( { grep -oE "'version' => '[^']+'" "$PANEL_DIR/config/app.php" | head -1; } 2>/dev/null || true )"
    log_info "Versi sekarang: ${before:-tidak diketahui}"

    backup_now pre-upgrade \
        || die "Backup gagal, jadi naik taraf dibatalkan. Naik taraf tanpa backup bukan pilihan yang saya akan buat untuk kau."

    # Mod penyelenggaraan supaya pengguna tidak menekan panel separuh dinaik taraf.
    art down --message="Naik taraf sedang dijalankan" --retry=120 || true
    _PANEL_TAKEN_DOWN="yes"

    # Jangan guna attempt() di sini: pengesahannya ialah "fail panel wujud",
    # yang sudah benar sebelum kita mula, jadi ia akan melaporkan "sudah
    # dipenuhi" dan tidak memuat turun apa-apa. Panggil strategi secara terus.
    local ok=1 strat
    for strat in panel_dl_curl panel_dl_wget panel_dl_pinned; do
        log_try "Muat turun keluaran terkini — $(strategy_label "$strat")"
        if "$strat" >>"$LOG_FILE" 2>&1; then
            log_ok "Fail panel dikemas kini"
            ok=0
            break
        fi
        log_warn "$(strategy_label "$strat") gagal"
    done

    if (( ok == 0 )); then
        chmod -R 750 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
        ensure_temp_swap 2048 || true
        # Sama seperti di atas: vendor/ daripada versi lama sudah wujud, jadi
        # verify_vendor lulus sebelum kita mula dan attempt() akan melangkau
        # composer sepenuhnya — meninggalkan kebergantungan lama dengan kod baharu.
        ok=1
        for strat in composer_install_plain composer_install_prefer_source \
                     composer_install_ignore_platform; do
            log_try "Kemas kini kebergantungan PHP — $(strategy_label "$strat")"
            if "$strat" >>"$LOG_FILE" 2>&1 && verify_vendor; then
                log_ok "Kebergantungan PHP dikemas kini"
                ok=0
                break
            fi
            log_warn "$(strategy_label "$strat") gagal"
        done
        cleanup_temp_swap
    fi

    if (( ok == 0 )); then
        art migrate --seed --force || ok=1
    fi

    chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || true
    chmod 600 "$PANEL_DIR/.env" 2>/dev/null || true
    art view:clear || true
    art config:clear || true
    fix_restart_queue || true
    art up || true
    _PANEL_TAKEN_DOWN="no"

    if (( ok != 0 )); then
        log_err "Naik taraf tidak selesai dengan bersih."
        log_err "Backup sebelum naik taraf ada di: $(cat "$STATE_DIR/last-backup" 2>/dev/null || printf "$BACKUP_DIR")"
        log_err "Pulihkan dengan: sudo $0 --restore <folder-backup>"
        exit 1
    fi

    local after
    after="$( { grep -oE "'version' => '[^']+'" "$PANEL_DIR/config/app.php" | head -1; } 2>/dev/null || true )"
    log_ok "Naik taraf selesai: ${before:-?} → ${after:-?}"
    run_verification || true
    exit 0
}

#===========================================================================
# Wings sahaja — pasang node pada mesin kedua
#===========================================================================
# Ini aliran "auto deploy" Pterodactyl. Panel menjana arahan konfigurasi dalam
# Admin → Nodes → <node> → Configuration → Auto Deploy, yang mengandungi URL
# panel, token dan id node. Kita minta tiga nilai itu dan serahkan kepada
# `wings configure`, yang menulis config.yml dengan betul termasuk sijilnya.
do_wings_only() {
    banner "Pasang Wings sahaja"
    printf '  Mesin ini akan menjalankan game server dan bersambung ke panel\n'
    printf '  yang sudah wujud di tempat lain.\n\n'
    printf '  Dalam panel: Admin → Nodes → (node kau) → tab Configuration →\n'
    printf '  butang "Auto Deploy". Salin nilai dari situ.\n'

    if [[ -z "$(cfg PANEL_URL)" ]]; then
        _tty_available || die "Mod ini perlukan terminal, atau berikan --config dengan PANEL_URL, NODE_TOKEN dan NODE_ID."
        ask PANEL_URL "URL penuh panel?" "" url \
            "Termasuk https:// — contoh https://panel.domain.com"
        ask NODE_TOKEN "Token daripada Auto Deploy?" "" any
        ask NODE_ID "ID node (nombor dalam panel)?" "" int
    fi

    # Nilai daripada fail config belum melalui validate_config dalam mod ini.
    local bad=0
    v_url  "$(cfg PANEL_URL)"  || { log_err "PANEL_URL tidak sah: $(validator_hint url)"; bad=1; }
    v_int  "$(cfg NODE_ID)"    || { log_err "NODE_ID mesti nombor"; bad=1; }
    [[ -n "$(cfg NODE_TOKEN)" ]] || { log_err "NODE_TOKEN kosong"; bad=1; }
    (( bad == 0 )) || die "Betulkan nilai di atas dan cuba lagi."

    detect_system
    log_step "Pemeriksaan awal"
    bootstrap_tools
    case "$VIRT" in
        openvz|lxc|lxc-libvirt)
            log_err "Virtualisasi '$VIRT' — Docker tidak berfungsi di sini, jadi Wings tidak akan"
            log_err "dapat menjalankan game server. Ini had platform."
            confirm "Teruskan juga?" || die "Dibatalkan."
            ;;
    esac
    log_ok "OS: $OS_ID $OS_VER ($ARCH)"

    TOTAL_PHASES=4
    run_phase wings_docker  "Docker"        phase_wings_docker
    run_phase wings_binary  "Binari Wings"  phase_wings_binary
    run_phase wings_join    "Sambung ke panel" phase_wings_join
    run_phase wings_service "Service Wings" phase_wings_service

    printf '\n'
    if verify_wings_running; then
        log_ok "Wings berjalan dan bersambung ke $(cfg PANEL_URL)"
        printf '\n  Semak dalam panel: node patut menunjukkan tanda hijau.\n\n'
        exit 0
    fi
    log_err "Wings tidak berjalan. Semak /var/log/wings.log"
    exit 1
}

verify_wings_joined() {
    [[ -s "$WINGS_ETC/config.yml" ]] || return 1
    grep -qE '^(uuid|token_id|token):' "$WINGS_ETC/config.yml"
}

STRATEGY_DESC["wings_configure_cmd"]="wings configure daripada token panel"
wings_configure_cmd() {
    mkdir -p "$WINGS_ETC"
    local extra=()
    # Panel yang menggunakan sijil yang tidak dipercayai (self-signed, atau rantai
    # yang tidak lengkap) akan menolak handshake tanpa bendera ini.
    [[ "$(cfg WINGS_ALLOW_INSECURE)" == "yes" ]] && extra+=(--allow-insecure)
    ( cd "$WINGS_ETC" && /usr/local/bin/wings configure \
        --panel-url "$(cfg PANEL_URL)" \
        --token "$(cfg NODE_TOKEN)" \
        --node "$(cfg NODE_ID)" \
        "${extra[@]}" >>"$LOG_FILE" 2>&1 )
}

STRATEGY_DESC["wings_configure_insecure"]="wings configure dengan --allow-insecure"
wings_configure_insecure() {
    # Punca paling biasa kegagalan di sini ialah sijil panel yang tidak
    # dipercayai oleh mesin ini.
    log_warn "Cuba semula tanpa pengesahan sijil — hanya sesuai kalau panel guna sijil sendiri"
    CFG[WINGS_ALLOW_INSECURE]="yes"
    wings_configure_cmd
}

phase_wings_join() {
    attempt "Konfigurasi Wings daripada panel" verify_wings_joined \
        wings_configure_cmd wings_configure_insecure \
        || die "Wings tidak dapat mendaftar dengan panel. Semak URL, token dan id node, dan pastikan mesin ini boleh capai panel: curl -I $(cfg PANEL_URL)"
    chmod 600 "$WINGS_ETC/config.yml" 2>/dev/null || true
    # Nota: fungsi ini pernah dinamakan configure_wings_network dan dinamakan
    # semula semasa logik pemilihan subnet dipindahkan ke dalamnya. Panggilan di
    # sini terlepas, jadi mod ini mati dengan "command not found".
    write_wings_network_section "$(cfg WINGS_DOCKER_SUBNET)"
    log_ok "Wings berdaftar dengan panel"
    return 0
}

#===========================================================================
# Node tambahan pada panel ini
#===========================================================================
do_add_node() {
    banner "Tambah node"
    [[ -f "$PANEL_DIR/artisan" ]] || die "Tiada panel di $PANEL_DIR. Mod ini dijalankan pada mesin panel."

    if _tty_available && [[ -z "$(cfg NODE_NAME)" || "$(cfg NODE_NAME)" == "$(detect_node_name)" ]]; then
        ask NODE_NAME "Nama node baharu?" "" nodename
        ask WINGS_FQDN "Domain atau IP mesin node itu?" "" host
        ask NODE_LOCATION "Kod lokasi?" "$(cfg NODE_LOCATION)" locshort
        ask NODE_PORT_RANGE "Julat port allocation?" "$(cfg NODE_PORT_RANGE)" portrange
    fi
    [[ -n "$(cfg NODE_NAME)" ]] || die "NODE_NAME diperlukan."

    if verify_node_registered; then
        die "Node '$(cfg NODE_NAME)' sudah wujud dalam panel."
    fi

    # Node ini akan berjalan pada mesin LAIN. Tanpa ini, phase_wings_node akan
    # menulis /etc/pterodactyl/config.yml di sini dengan identiti node baharu,
    # menindih config Wings mesin panel sendiri.
    NODE_IS_LOCAL="no"
    phase_wings_node
    printf '\n  Node dicipta. Pada mesin node itu, jalankan:\n\n'
    printf '      sudo ./install.sh --wings-only\n\n'
    printf '  dan masukkan nilai daripada Admin → Nodes → %s → Configuration → Auto Deploy.\n\n' "$(cfg NODE_NAME)"
    exit 0
}

#===========================================================================
# Status
#===========================================================================
_svc_state() {
    local unit="$1" proc="$2"
    if svc_is_active "$unit" "$proc"; then printf 'berjalan'; else printf 'mati'; fi
}

do_status() {
    banner "Status Pterodactyl"

    local ver="tiada"
    [[ -f "$PANEL_DIR/config/app.php" ]] && \
        ver="$( { grep -oE "'version' => '[^']+'" "$PANEL_DIR/config/app.php" | head -1 | grep -oE '[0-9.]+'; } 2>/dev/null || printf '?' )"

    printf '  %sPanel%s\n' "$C_BLD" "$C_OFF"
    printf '    Versi        : %s\n' "$ver"
    printf '    Direktori    : %s\n' "$PANEL_DIR"
    [[ -f "$PANEL_DIR/.env" ]] && \
        printf '    URL          : %s\n' "$( { grep -E '^APP_URL=' "$PANEL_DIR/.env" | head -1 | cut -d= -f2-; } 2>/dev/null || printf '?' )"

    printf '\n  %sService%s\n' "$C_BLD" "$C_OFF"
    printf '    pangkalan data : %s\n' "$(_svc_state mariadb mariadbd)"
    printf '    redis          : %s\n' "$(_svc_state redis-server redis-server)"
    printf '    nginx          : %s\n' "$(_svc_state nginx nginx)"
    printf '    queue worker   : %s\n' "$( verify_queue_worker && printf 'berjalan' || printf 'mati' )"
    printf '    docker         : %s\n' "$( verify_docker 2>/dev/null && printf 'berjalan' || printf 'mati' )"
    printf '    wings          : %s\n' "$( pgrep -x wings >/dev/null 2>&1 && printf 'berjalan' || printf 'mati' )"

    if db_cli -sN -D"$(cfg DB_NAME)" -e "SELECT 1" >/dev/null 2>&1; then
        printf '\n  %sPangkalan data%s\n' "$C_BLD" "$C_OFF"
        printf '    pengguna     : %s\n' "$(db_q 'SELECT COUNT(*) FROM users' 2>/dev/null || printf '?')"
        printf '    node         : %s\n' "$(db_q 'SELECT COUNT(*) FROM nodes' 2>/dev/null || printf '?')"
        printf '    server       : %s\n' "$(db_q 'SELECT COUNT(*) FROM servers' 2>/dev/null || printf '?')"
        printf '    egg          : %s\n' "$(db_q 'SELECT COUNT(*) FROM eggs' 2>/dev/null || printf '?')"
        printf '    allocation   : %s\n' "$(db_q 'SELECT COUNT(*) FROM allocations' 2>/dev/null || printf '?')"
    fi

    # Sijil yang hampir tamat tempoh ialah kegagalan yang menunggu masa.
    local live="/etc/letsencrypt/live/$(cfg PANEL_FQDN)/cert.pem"
    if [[ -f "$live" ]] && have openssl; then
        local exp days
        exp="$(openssl x509 -enddate -noout -in "$live" 2>/dev/null | cut -d= -f2 || true)"
        if [[ -n "$exp" ]]; then
            days="$(( ( $(date -d "$exp" +%s 2>/dev/null || printf 0) - $(date +%s) ) / 86400 ))"
            printf '\n  %sHTTPS%s\n' "$C_BLD" "$C_OFF"
            printf '    sijil tamat  : %s (%s hari lagi)\n' "$exp" "$days"
            (( days < 14 )) && printf '    %s! Perbaharui segera: certbot renew%s\n' "$C_YEL" "$C_OFF"
        fi
    fi

    printf '\n  Backup terakhir : %s\n' "$(cat "$STATE_DIR/last-backup" 2>/dev/null || printf 'tiada')"
    printf '  Log             : %s\n\n' "$LOG_FILE"
    exit 0
}
