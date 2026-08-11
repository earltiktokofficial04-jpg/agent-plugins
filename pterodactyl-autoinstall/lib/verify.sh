#!/usr/bin/env bash
#############################################################################
#  verify.sh — pengesahan akhir dengan pembaikan diri yang terbatas
#
#  Setiap semakan boleh mempunyai rantaian pembaikan. Bilangan cubaan terbatas
#  (satu pusingan per strategi) supaya ia tidak boleh berpusing selama-lamanya.
#############################################################################

[[ -n "${_PTERO_VERIFY_LOADED:-}" ]] && return 0
_PTERO_VERIFY_LOADED=1

declare -a CHECK_PASS=()
declare -a CHECK_HEALED=()
declare -a CHECK_FAIL=()

check() {
    local name="$1" test_fn="$2"
    shift 2
    local -a repairs=("$@")
    if "$test_fn" >/dev/null 2>&1; then
        CHECK_PASS+=("$name")
        return 0
    fi
    local r
    for r in "${repairs[@]}"; do
        log_try "$name — tidak lulus, cuba baiki: $(strategy_label "$r")"
        "$r" >>"$LOG_FILE" 2>&1 || true
        if "$test_fn" >/dev/null 2>&1; then
            CHECK_HEALED+=("$name — dibaiki melalui $(strategy_label "$r")")
            return 0
        fi
    done
    CHECK_FAIL+=("$name")
    return 1
}

#---------------------------------------------------------------------------
# Ujian
#---------------------------------------------------------------------------
t_panel_http() {
    local port; port="$(nginx_listen_port)"
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
            "http://127.0.0.1:$port/auth/login" 2>/dev/null || printf '000')"
    [[ "$code" =~ ^(200|301|302)$ ]]
}

t_panel_assets() {
    local port; port="$(nginx_listen_port)"
    local body asset
    body="$(curl -sS --max-time 20 "http://127.0.0.1:$port/auth/login" 2>/dev/null || true)"
    asset="$( { printf '%s' "$body" | grep -oE 'src="/assets/[^"]+"' | head -1 | sed 's/src="//;s/"//'; } 2>/dev/null || true )"
    [[ -z "$asset" ]] && return 1
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
            "http://127.0.0.1:$port$asset" 2>/dev/null || printf '000')"
    [[ "$code" == "200" ]]
}

t_db()    { db_cli -sN -D"$(cfg DB_NAME)" -e "SELECT 1" >/dev/null 2>&1; }
t_redis() { cfg_is _REDIS_FALLBACK yes && return 0; verify_redis; }
t_admin() { any_admin_exists; }

t_eggs() {
    local n; n="$(db_q "SELECT COUNT(*) FROM eggs" 2>/dev/null || printf 0)"
    [[ "$n" != "0" ]]
}

t_queue() { verify_queue_worker; }

t_scheduler() {
    [[ -f /etc/cron.d/pterodactyl ]] && return 0
    # Jangan paip ke `grep -q` di sini: grep keluar sebaik jumpa padanan, crontab
    # dapat SIGPIPE, dan pipefail jadikan hasilnya "gagal" walaupun entri itu
    # memang ADA. Tangkap output dahulu, kemudian padankan.
    local out
    out="$(crontab -u www-data -l 2>/dev/null || true)
$(crontab -l 2>/dev/null || true)"
    [[ "$out" == *"artisan schedule:run"* ]] && return 0
    pgrep -f '[s]chedule:run' >/dev/null 2>&1
}

t_panel_can_login() {
    # Ujian sebenar: log masuk penuh melalui HTTP, bukan sekadar halaman terbuka.
    local port jar token body
    port="$(nginx_listen_port)"
    jar="$(mktemp)"
    curl -sS -c "$jar" -o /dev/null --max-time 20 "http://127.0.0.1:$port/auth/login" 2>/dev/null || { rm -f "$jar"; return 1; }
    token="$( { awk '$6 == "XSRF-TOKEN" { print $7 }' "$jar" | sed 's/%3D/=/g'; } 2>/dev/null || true )"
    [[ -z "$token" ]] && { rm -f "$jar"; return 1; }
    body="$(curl -sS -b "$jar" -X POST "http://127.0.0.1:$port/auth/login" \
        -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -H 'X-Requested-With: XMLHttpRequest' -H "X-XSRF-TOKEN: $token" \
        -d "{\"user\":\"$(cfg ADMIN_USERNAME)\",\"password\":$(php -r 'echo json_encode($argv[1]);' "$(cfg ADMIN_PASSWORD)" 2>/dev/null || printf '""')}" \
        --max-time 30 2>/dev/null || true)"
    rm -f "$jar"
    [[ "$body" == *'"complete":true'* ]]
}

t_wings_binary()  { cfg_is INSTALL_WINGS yes || return 0; verify_wings_binary; }
t_wings_config()  { cfg_is INSTALL_WINGS yes || return 0; verify_wings_config; }
t_wings_running() { cfg_is INSTALL_WINGS yes || return 0; verify_wings_running; }

t_wings_port() {
    cfg_is INSTALL_WINGS yes || return 0
    # Wings memulangkan 401 tanpa token — itu bukti ia mendengar dan bercakap HTTP.
    local code
    code="$(curl -sS -k -o /dev/null -w '%{http_code}' --max-time 15 \
            "http://127.0.0.1:$(cfg WINGS_PORT)/api/system" 2>/dev/null || printf '000')"
    [[ "$code" =~ ^(200|401|403)$ ]]
}

t_node_registered() { cfg_is INSTALL_WINGS yes || return 0; verify_node_registered; }

t_allocations() {
    cfg_is INSTALL_WINGS yes || return 0
    local n; n="$(db_q "SELECT COUNT(*) FROM allocations" 2>/dev/null || printf 0)"
    [[ "$n" != "0" ]]
}

t_docker() { cfg_is INSTALL_WINGS yes || return 0; verify_docker; }
t_nodejs() { cfg_is INSTALL_NODEJS yes || return 0; verify_nodejs; }
t_python() { cfg_is INSTALL_PYTHON yes || return 0; verify_python; }

#---------------------------------------------------------------------------
# Pembaikan
#---------------------------------------------------------------------------
STRATEGY_DESC["fix_restart_fpm_nginx"]="mula semula PHP-FPM dan nginx"
fix_restart_fpm_nginx() {
    start_php_fpm
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        systemctl restart "php$PHP_V-fpm" 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || systemctl restart apache2 2>/dev/null || true
    else
        # Bukan `pgrep && reload || nginx`: reload yang gagal akan jatuh ke
        # cabang `nginx`, melancarkan instance kedua yang kemudian gagal kerana
        # port sudah diikat.
        if pgrep -x nginx >/dev/null 2>&1; then
            nginx -s reload 2>/dev/null || true
        else
            nginx 2>/dev/null || true
        fi
    fi
    sleep 3
    return 0
}

STRATEGY_DESC["fix_clear_panel_cache"]="kosongkan cache konfigurasi panel"
fix_clear_panel_cache() {
    art config:clear || true
    art cache:clear || true
    art view:clear || true
    return 0
}

STRATEGY_DESC["fix_fix_permissions"]="betulkan pemilikan fail panel"
fix_fix_permissions() {
    chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || true
    chmod -R 750 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
    chmod 600 "$PANEL_DIR/.env" 2>/dev/null || true
    return 0
}

STRATEGY_DESC["fix_start_db"]="mula semula pelayan pangkalan data"
fix_start_db() { db_start_server; }

STRATEGY_DESC["fix_start_redis"]="mula semula Redis"
fix_start_redis() { redis_install_and_start || redis_start_foreground; }

STRATEGY_DESC["fix_restart_queue"]="mula semula queue worker"
fix_restart_queue() {
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        systemctl restart pteroq 2>/dev/null || services_systemd || true
    else
        services_fallback_runner || true
    fi
    sleep 3
    return 0
}

STRATEGY_DESC["fix_install_scheduler"]="daftarkan semula scheduler"
fix_install_scheduler() { install_scheduler_cron; }

STRATEGY_DESC["fix_start_docker"]="mula semula daemon Docker"
fix_start_docker() { docker_start_daemon; }

STRATEGY_DESC["fix_restart_wings"]="mula semula Wings"
fix_restart_wings() { wings_launch; }

STRATEGY_DESC["fix_wings_full"]="jana semula config Wings dan mula semula"
fix_wings_full() {
    wings_config_from_panel || return 1
    wings_launch
}

#---------------------------------------------------------------------------
# Jalankan semua semakan
#---------------------------------------------------------------------------
run_verification() {
    CHECK_PASS=(); CHECK_HEALED=(); CHECK_FAIL=()

    check "Pelayan pangkalan data"      t_db          fix_start_db
    check "Redis"                       t_redis       fix_start_redis
    check "Halaman login panel"         t_panel_http  fix_restart_fpm_nginx fix_fix_permissions fix_clear_panel_cache
    check "Aset frontend panel"         t_panel_assets fix_fix_permissions
    check "Log masuk admin berfungsi"   t_panel_can_login fix_clear_panel_cache
    check "Akaun admin"                 t_admin
    check "Egg tersedia"                t_eggs
    check "Queue worker"                t_queue       fix_restart_queue
    check "Scheduler didaftarkan"       t_scheduler   fix_install_scheduler

    if cfg_is INSTALL_NODEJS yes; then check "Node.js" t_nodejs; fi
    if cfg_is INSTALL_PYTHON yes; then check "Python 3" t_python; fi

    if cfg_is INSTALL_WINGS yes; then
        check "Docker"                  t_docker          fix_start_docker
        check "Binari Wings"            t_wings_binary
        check "Konfigurasi Wings"       t_wings_config    fix_wings_full
        check "Node berdaftar"          t_node_registered
        check "Allocation"              t_allocations
        check "Proses Wings"            t_wings_running   fix_restart_wings fix_wings_full
        check "Wings mendengar pada port" t_wings_port    fix_restart_wings
    fi

    printf '\n'
    local x
    for x in "${CHECK_PASS[@]}";   do printf '   %s✔%s %s\n' "$C_GRN" "$C_OFF" "$x"; done
    for x in "${CHECK_HEALED[@]}"; do printf '   %s✔%s %s\n' "$C_YEL" "$C_OFF" "$x"; done
    for x in "${CHECK_FAIL[@]}";   do printf '   %s✘%s %s\n' "$C_RED" "$C_OFF" "$x"; done

    (( ${#CHECK_FAIL[@]} == 0 ))
}

#---------------------------------------------------------------------------
# Alat doctor — boleh dijalankan bila-bila masa selepas ini
#---------------------------------------------------------------------------
install_doctor() {
    local self_dir="$1"
    cat >/usr/local/bin/pterodactyl-doctor <<DOCTOR
#!/usr/bin/env bash
# Semak pemasangan Pterodactyl dan baiki apa yang boleh dibaiki.
# Dijana oleh pterodactyl auto-installer.
exec "$self_dir/install.sh" --doctor "\$@"
DOCTOR
    chmod +x /usr/local/bin/pterodactyl-doctor
    return 0
}

#---------------------------------------------------------------------------
# Kredential dan ringkasan
#---------------------------------------------------------------------------
write_credentials() {
    local f; f="$(cfg CREDENTIALS_FILE)"
    ( umask 077
      cat >"$f" <<CREDS
════════════════════════════════════════════════════════════
 PTERODACTYL — KREDENTIAL
 Dijana: $(_ts)
 JANGAN kongsi fail ini dengan sesiapa.
════════════════════════════════════════════════════════════

PANEL
  URL       : $(panel_url)
  Username  : $(cfg ADMIN_USERNAME)
  Email     : $(cfg ADMIN_EMAIL)
  Password  : $(cfg ADMIN_PASSWORD)

PANGKALAN DATA
  Host      : $(cfg DB_HOST):$(cfg DB_PORT)
  Database  : $(cfg DB_NAME)
  Username  : $(cfg DB_USERNAME)
  Password  : $(cfg DB_PASSWORD)

LOKASI PENTING
  Panel        : $PANEL_DIR
  Env panel    : $PANEL_DIR/.env
  Config Wings : $WINGS_ETC/config.yml
  Log pasang   : $LOG_FILE
  State        : $STATE_DIR

ALAT
  Semak dan baiki : pterodactyl-doctor
$( [[ "$HAS_SYSTEMD" != "yes" ]] && printf '  Mula service    : /usr/local/bin/pterodactyl-services start\n' )
CREDS
    ) 2>/dev/null || { log_warn "Tidak dapat menulis fail kredential"; return 0; }
    chmod 600 "$f" 2>/dev/null || true
    log_ok "Kredential disimpan di $f (chmod 600)"
    return 0
}

print_summary() {
    local ok=$1
    if (( ok == 0 )); then
        banner "SIAP"
    else
        banner "SIAP SEBAHAGIAN"
    fi

    printf '  %sPanel%s\n' "$C_BLD" "$C_OFF"
    printf '    URL       : %s%s%s\n' "$C_BLD" "$(panel_url)" "$C_OFF"
    printf '    Username  : %s\n' "$(cfg ADMIN_USERNAME)"
    if [[ " ${GENERATED_SECRETS[*]:-} " == *ADMIN_PASSWORD* ]]; then
        printf '    Password  : %s%s%s\n' "$C_BLD" "$(cfg ADMIN_PASSWORD)" "$C_OFF"
        printf '                %s(dijana automatik — simpan sekarang)%s\n' "$C_DIM" "$C_OFF"
    else
        printf '    Password  : (yang kau taip semasa persiapan)\n'
    fi
    printf '    Kredential: %s\n' "$(cfg CREDENTIALS_FILE)"

    if (( ${#CHECK_HEALED[@]} > 0 )); then
        printf '\n  %s%d perkara dibaiki automatik semasa pengesahan%s\n' "$C_YEL" "${#CHECK_HEALED[@]}" "$C_OFF"
    fi

    if (( ${#DEFERRED_WARNINGS[@]} > 0 )); then
        printf '\n  %sPerkara yang perlu kau tahu%s\n' "$C_BLD$C_YEL" "$C_OFF"
        local i=1 w
        for w in "${DEFERRED_WARNINGS[@]}"; do
            printf '    %d. %s\n' "$i" "$w"
            i=$((i + 1))
        done
    fi

    if (( ${#CHECK_FAIL[@]} > 0 )); then
        printf '\n  %sSemakan yang masih gagal%s\n' "$C_BLD$C_RED" "$C_OFF"
        local f
        for f in "${CHECK_FAIL[@]}"; do printf '    - %s\n' "$f"; done
        printf '\n  Selepas kau betulkan puncanya, jalankan semakan dan pembaikan semula:\n'
        printf '      %ssudo pterodactyl-doctor%s\n' "$C_BLD" "$C_OFF"
    fi

    printf '\n  %sLangkah seterusnya%s\n' "$C_BLD" "$C_OFF"
    printf '    1. Buka %s dan log masuk.\n' "$(panel_url)"
    if cfg_is INSTALL_WINGS yes; then
        printf '    2. Admin → Nodes → %s: node patut menunjukkan tanda hijau.\n' "$(cfg NODE_NAME)"
        printf '    3. Servers → Create New: cipta game server pertama kau.\n'
    else
        printf '    2. Pasang Wings pada mesin yang akan menjalankan game server.\n'
    fi
    if [[ "$HAS_SYSTEMD" != "yes" ]]; then
        printf '\n  %sSistem ini tiada systemd%s — selepas setiap reboot jalankan:\n' "$C_YEL" "$C_OFF"
        printf '      /usr/local/bin/pterodactyl-services start\n'
    fi
    printf '\n  Log penuh: %s\n\n' "$LOG_FILE"
    return 0
}
