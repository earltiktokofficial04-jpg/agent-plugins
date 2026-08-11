#!/usr/bin/env bash
#############################################################################
#  phases-wings.sh — Docker, binari Wings, node, allocation, egg
#############################################################################

[[ -n "${_PTERO_WINGS_LOADED:-}" ]] && return 0
_PTERO_WINGS_LOADED=1

db_q() { db_cli -sN -D"$(cfg DB_NAME)" -e "$1"; }

#===========================================================================
# Docker
#===========================================================================
verify_docker() {
    have docker || return 1
    docker info >/dev/null 2>&1
}

docker_start_daemon() {
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        systemctl enable docker >>"$LOG_FILE" 2>&1 || true
        systemctl start docker >>"$LOG_FILE" 2>&1 || true
    fi
    verify_docker && return 0
    pgrep -x dockerd >/dev/null 2>&1 || {
        setsid nohup dockerd >>"$LOG_FILE" 2>&1 </dev/null &
        disown 2>/dev/null || true
    }
    wait_for 45 verify_docker
}

STRATEGY_DESC["docker_via_official_script"]="skrip rasmi get.docker.com"
docker_via_official_script() {
    if ! have docker; then
        # mktemp: /tmp boleh ditulis semua orang dan skrip ini dijalankan root.
        local f; f="$(mktemp)"
        curl -fsSL --max-time 180 -o "$f" https://get.docker.com || { rm -f "$f"; return 1; }
        sh "$f" >>"$LOG_FILE" 2>&1 || { rm -f "$f"; return 1; }
        rm -f "$f"
    fi
    docker_start_daemon
}

STRATEGY_DESC["docker_from_distro"]="pakej docker.io daripada repo distro"
docker_from_distro() {
    apt_available docker.io || return 1
    apt_install docker.io || return 1
    docker_start_daemon
}

STRATEGY_DESC["docker_via_apt_repo"]="repo apt rasmi download.docker.com"
docker_via_apt_repo() {
    [[ -n "$OS_CODENAME" ]] || return 1
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" \
        -o /etc/apt/keyrings/docker.asc || return 1
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
        "$ARCH_ALT" "$OS_ID" "$OS_CODENAME" >/etc/apt/sources.list.d/docker.list
    apt_update || return 1
    apt_install docker-ce docker-ce-cli containerd.io || return 1
    docker_start_daemon
}

STRATEGY_DESC["docker_restart_only"]="mula semula daemon yang sudah dipasang"
docker_restart_only() {
    have docker || return 1
    docker_start_daemon
}

phase_wings_docker() {
    # Semak dulu perkara yang script tidak boleh betulkan, supaya masa tidak
    # dibuang pada tiga cubaan yang pasti gagal.
    case "$VIRT" in
        openvz|lxc|lxc-libvirt)
            log_err "Virtualisasi '$VIRT' dikesan. Docker tidak berfungsi di sini, jadi Wings"
            log_err "tidak akan dapat menjalankan game server. Ini had platform, bukan"
            log_err "sesuatu yang script boleh atasi."
            log_err ""
            log_err "Pilihan kau:"
            log_err "  1. Guna VPS KVM atau bare metal untuk Wings."
            log_err "  2. Pasang panel sahaja di sini, dan Wings pada mesin lain."
            if ! confirm "Teruskan cuba pasang Docker walaupun begitu?"; then
                die "Dibatalkan. Jalankan semula dan jawab 'no' pada soalan Wings untuk pasang panel sahaja."
            fi
            ;;
    esac

    attempt "Docker" verify_docker \
        docker_restart_only \
        docker_via_official_script \
        docker_from_distro \
        docker_via_apt_repo \
        || die "Docker tidak dapat dipasang atau dimulakan selepas 4 kaedah. Semak: dockerd --debug"

    log_ok "Docker aktif: $(docker info --format '{{.ServerVersion}}' 2>/dev/null || true)"
    return 0
}

#===========================================================================
# Binari Wings
#===========================================================================
verify_wings_binary() {
    [[ -x /usr/local/bin/wings ]] || return 1
    /usr/local/bin/wings version >/dev/null 2>&1 || /usr/local/bin/wings --version >/dev/null 2>&1
}

_install_wings_from() {
    local url="$1" tmp
    tmp="$(mktemp)"
    curl -fsSL --max-time 300 --retry 3 -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    # Binari yang terpotong akan "berjaya" dimuat turun tetapi gagal dijalankan.
    [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
    install -m 0755 "$tmp" /usr/local/bin/wings || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    ln -sf /usr/local/bin/wings /usr/bin/wings 2>/dev/null || true
    verify_wings_binary
}

STRATEGY_DESC["wings_dl_latest"]="binari keluaran terkini"
wings_dl_latest() {
    [[ -n "$ARCH_ALT" ]] || return 1
    _install_wings_from "$WINGS_BASE/wings_linux_$ARCH_ALT"
}

STRATEGY_DESC["wings_dl_wget"]="binari keluaran terkini dengan wget"
wings_dl_wget() {
    have wget || return 1
    [[ -n "$ARCH_ALT" ]] || return 1
    local tmp; tmp="$(mktemp)"
    wget -q --tries=3 --timeout=60 -O "$tmp" "$WINGS_BASE/wings_linux_$ARCH_ALT" || { rm -f "$tmp"; return 1; }
    install -m 0755 "$tmp" /usr/local/bin/wings || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    ln -sf /usr/local/bin/wings /usr/bin/wings 2>/dev/null || true
    verify_wings_binary
}

STRATEGY_DESC["wings_dl_pinned"]="binari versi tetap"
wings_dl_pinned() {
    [[ -n "$ARCH_ALT" ]] || return 1
    local v
    for v in v1.11.13 v1.11.12; do
        _install_wings_from "https://github.com/pterodactyl/wings/releases/download/$v/wings_linux_$ARCH_ALT" \
            && return 0
    done
    return 1
}

# Had ingatan Wings bergantung pada perakaunan memori+swap cgroup. Pada
# Debian/Ubuntu ia dimatikan secara lalai, dan tanpanya game server boleh
# melebihi had yang ditetapkan dalam panel. Pembetulannya perlukan reboot,
# jadi ini amaran, bukan sesuatu yang script boleh selesaikan sendiri.
check_swap_accounting() {
    [[ -r /proc/cmdline ]] || return 0
    local cmdline; cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
    [[ "$cmdline" == *"swapaccount=1"* ]] && return 0
    # cgroup v2 mengendalikan ini tanpa parameter kernel.
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        return 0
    fi
    defer_warning "Perakaunan swap cgroup tidak aktif, jadi had RAM game server tidak akan dikuatkuasakan sepenuhnya. Untuk membetulkannya: tambah 'swapaccount=1' pada GRUB_CMDLINE_LINUX_DEFAULT dalam /etc/default/grub, jalankan update-grub, dan reboot."
    return 0
}

phase_wings_binary() {
    check_swap_accounting
    mkdir -p "$WINGS_ETC" "$(cfg WINGS_DATA_DIR)"
    attempt "Binari Wings" verify_wings_binary \
        wings_dl_latest wings_dl_wget wings_dl_pinned \
        || die "Tidak dapat memuat turun binari Wings untuk $ARCH."
    log_ok "Wings dipasang: $(/usr/local/bin/wings version 2>/dev/null | head -1 || printf 'sedia')"
    return 0
}

#===========================================================================
# Node, allocation, config.yml
#===========================================================================
node_id_of() {
    db_q "SELECT id FROM nodes WHERE name='$(sql_escape "$(cfg NODE_NAME)")' LIMIT 1"
}

verify_node_registered() {
    local id; id="$(node_id_of)"
    [[ -n "$id" ]]
}

STRATEGY_DESC["node_create_via_artisan"]="p:location:make + p:node:make"
node_create_via_artisan() {
    local loc_id
    loc_id="$(db_q "SELECT id FROM locations WHERE short='$(sql_escape "$(cfg NODE_LOCATION)")' LIMIT 1")"
    if [[ -z "$loc_id" ]]; then
        art p:location:make --short="$(cfg NODE_LOCATION)" --long="$(cfg NODE_LOCATION_DESC)" || return 1
        loc_id="$(db_q "SELECT id FROM locations WHERE short='$(sql_escape "$(cfg NODE_LOCATION)")' LIMIT 1")"
    fi
    [[ -n "$loc_id" ]] || return 1

    art p:node:make \
        --name="$(cfg NODE_NAME)" \
        --description="Dicipta oleh pterodactyl auto-installer" \
        --locationId="$loc_id" \
        --fqdn="$(cfg WINGS_FQDN)" \
        --public=1 \
        --scheme="$( cfg_is WINGS_SSL yes && printf https || printf http )" \
        --proxy=0 --maintenance=0 \
        --maxMemory="$(cfg NODE_MEMORY)" \
        --overallocateMemory="$(cfg NODE_MEMORY_OVERALLOCATE)" \
        --maxDisk="$(cfg NODE_DISK)" \
        --overallocateDisk="$(cfg NODE_DISK_OVERALLOCATE)" \
        --uploadSize=100 \
        --daemonListeningPort="$(cfg WINGS_PORT)" \
        --daemonSFTPPort="$(cfg WINGS_SFTP_PORT)" \
        --daemonBase="$(cfg WINGS_DATA_DIR)"
}

STRATEGY_DESC["node_create_http_scheme"]="cuba semula dengan skema http"
node_create_http_scheme() {
    # p:node:make menolak fqdn berbentuk IP bila skema https dipilih.
    CFG[WINGS_SSL]="no"
    defer_warning "Node ditetapkan kepada http kerana panel menolak https untuk '$(cfg WINGS_FQDN)' (biasanya kerana ia alamat IP, bukan domain)."
    node_create_via_artisan
}

register_allocations() {
    local node_id="$1" range ip start end p sql=""
    range="$(cfg NODE_PORT_RANGE)"; ip="$(cfg NODE_ALLOCATION_IP)"
    start="${range%-*}"; end="${range#*-}"
    for (( p = start; p <= end; p++ )); do
        sql+="INSERT IGNORE INTO allocations (node_id, ip, port, created_at, updated_at) VALUES ($node_id, '$ip', $p, NOW(), NOW());"
    done
    db_cli -D"$(cfg DB_NAME)" -e "$sql" || return 1
    return 0
}

# Tulis seksyen docker.network ke config.yml supaya Wings tidak bertindih
# dengan rangkaian Docker yang sudah ada.
#
# Subnet dipilih semula di sini kalau pilihan tersimpan ternyata sudah diguna.
# Ini penting kerana pilihan asal dibuat semasa autofill — SEBELUM Docker
# dipasang — jadi julat yang nampak bebas ketika itu boleh menjadi docker0
# sendiri beberapa fasa kemudian.
write_wings_network_section() {
    local subnet="$1" gw
    if subnet_in_use "$subnet"; then
        local o cand
        for o in 19 20 21 22 23 24 25 26 27 28 29 30 31 18; do
            cand="172.$o.0.0/16"
            subnet_in_use "$cand" && continue
            log_info "Subnet $subnet kini diguna — tukar ke $cand"
            subnet="$cand"
            CFG[WINGS_DOCKER_SUBNET]="$cand"
            state_put wings-subnet "$cand"
            break
        done
    fi
    gw="$(awk -F'[./]' '{ print $1 "." $2 ".0.1" }' <<<"$subnet")"
    # Buang seksyen docker lama kalau ada, supaya fungsi ini idempoten.
    if grep -q '^docker:' "$WINGS_ETC/config.yml" 2>/dev/null; then
        awk '/^docker:/ { skip = 1; next } /^[a-z_]+:/ { skip = 0 } !skip' \
            "$WINGS_ETC/config.yml" >"$WINGS_ETC/config.yml.tmp" \
            && mv "$WINGS_ETC/config.yml.tmp" "$WINGS_ETC/config.yml"
    fi
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
    return 0
}

verify_wings_config() {
    [[ -s "$WINGS_ETC/config.yml" ]] || return 1
    grep -qE '^(uuid|token_id|token|api):' "$WINGS_ETC/config.yml" || return 1
    # Token yang sah tidak cukup: kalau subnet yang tertulis kini diguna oleh
    # rangkaian lain, Wings akan mati dengan "Pool overlaps" dan config ini
    # memang perlu ditulis semula. Tanpa semakan ini, fasa config melaporkan
    # "sudah dipenuhi" dan pembetulan subnet tidak pernah berlaku.
    local sub
    sub="$(awk '/^ *subnet:/ { print $2; exit }' "$WINGS_ETC/config.yml" 2>/dev/null || true)"
    [[ -n "$sub" ]] && subnet_in_use "$sub" && return 1
    return 0
}

STRATEGY_DESC["wings_config_from_panel"]="jana config.yml melalui p:node:configuration"
wings_config_from_panel() {
    local id; id="$(node_id_of)"
    [[ -n "$id" ]] || return 1
    # Redirect shell memotong fail sasaran SEBELUM arahan dijalankan. Menulis
    # terus ke config.yml bermakna satu artisan yang gagal memusnahkan config
    # yang sedang berfungsi dan menggantikannya dengan fail kosong. Tulis ke
    # fail sementara dan pindahkan hanya selepas ia disahkan.
    local tmp; tmp="$(mktemp)"
    chmod 600 "$tmp"
    if ! ( cd "$PANEL_DIR" && php artisan p:node:configuration "$id" >"$tmp" 2>>"$LOG_FILE" ); then
        rm -f "$tmp"; return 1
    fi
    if ! grep -qE '^(uuid|token_id|token|api):' "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    mv "$tmp" "$WINGS_ETC/config.yml"
    chmod 600 "$WINGS_ETC/config.yml"
    write_wings_network_section "$(cfg WINGS_DOCKER_SUBNET)"
    return 0
}

phase_wings_node() {
    attempt "Node berdaftar dalam panel" verify_node_registered \
        node_create_via_artisan node_create_http_scheme \
        || die "Tidak dapat mencipta node '$(cfg NODE_NAME)' dalam panel. Semak $LOG_FILE"

    local node_id; node_id="$(node_id_of)"
    log_ok "Node '$(cfg NODE_NAME)' (id=$node_id)"
    state_put node-id "$node_id"

    register_allocations "$node_id" \
        || defer_warning "Allocation tidak dapat didaftarkan. Tambah manual di Admin → Nodes → $(cfg NODE_NAME) → Allocation."
    local total; total="$(db_q "SELECT COUNT(*) FROM allocations WHERE node_id=$node_id" 2>/dev/null || printf '0')"
    log_ok "$total allocation sedia ($(cfg NODE_ALLOCATION_IP):$(cfg NODE_PORT_RANGE))"

    attempt "Konfigurasi Wings" verify_wings_config wings_config_from_panel \
        || die "config.yml Wings tidak dapat dijana. Semak: cd $PANEL_DIR && php artisan p:node:configuration $node_id"
    log_ok "Konfigurasi Wings ditulis ke $WINGS_ETC/config.yml"
    return 0
}

#===========================================================================
# Service Wings — dengan pembaikan diri untuk punca yang diketahui
#===========================================================================
# Kehadiran proses SAHAJA bukan bukti. Bila persekitaran Docker tidak sah,
# Wings hidup kira-kira satu saat, mencetak FATAL, kemudian mati — cukup lama
# untuk pgrep melihatnya. Kalau kita percaya pgrep, fasa ini akan mengisytiharkan
# kejayaan dan seluruh rantaian fallback tidak akan pernah dicuba. Jadi: biar ia
# reda dahulu, semak semula, dan pastikan ia benar-benar menjawab pada portnya.
verify_wings_running() {
    pgrep -x wings >/dev/null 2>&1 || return 1
    sleep 2
    pgrep -x wings >/dev/null 2>&1 || return 1
    # Tanpa token, Wings memulangkan 401 — itu bukti ia mendengar dan sihat.
    local code
    code="$(curl -sS -k -o /dev/null -w '%{http_code}' --max-time 8 \
            "http://127.0.0.1:$(cfg WINGS_PORT)/api/system" 2>/dev/null || printf '000')"
    [[ "$code" =~ ^(200|401|403)$ ]]
}

wings_recent_log() {
    local out=""
    [[ -f /var/log/wings.log ]] && out="$(tail -n 80 /var/log/wings.log 2>/dev/null || true)"
    [[ -f /var/log/pterodactyl/wings.log ]] && out="$out
$(tail -n 80 /var/log/pterodactyl/wings.log 2>/dev/null || true)"
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        out="$out
$(journalctl -u wings -n 80 --no-pager 2>/dev/null || true)"
    fi
    printf '%s' "$out"
}

wings_launch() {
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
        systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
        systemctl enable wings >>"$LOG_FILE" 2>&1 || true
        systemctl restart wings >>"$LOG_FILE" 2>&1 || true
    else
        pkill -x wings 2>/dev/null || true
        sleep 1
        setsid nohup /usr/local/bin/wings --config "$WINGS_ETC/config.yml" \
            >/var/log/wings.log 2>&1 </dev/null &
        disown 2>/dev/null || true
    fi
    wait_for 6 verify_wings_running
}

STRATEGY_DESC["wings_start_plain"]="mulakan Wings"
wings_start_plain() { wings_launch; }

# Adakah julat /16 ini bertindih dengan rangkaian Docker atau laluan yang ada?
subnet_in_use() {
    local prefix="${1%.0.0/16}." used="" ids
    ids="$(docker network ls -q 2>/dev/null || true)"
    if [[ -n "$ids" ]]; then
        # shellcheck disable=SC2086
        used="$(docker network inspect $ids \
                --format '{{if ne .Name "pterodactyl_nw"}}{{range .IPAM.Config}}{{.Subnet}} {{end}}{{end}}' \
                2>/dev/null || true)"
    fi
    # Kecualikan laluan milik pterodactyl0 itu sendiri — kalau tidak, subnet
    # yang Wings sedang guna dengan jayanya akan dikira "diguna" dan config
    # ditulis semula pada setiap run.
    used="$used $(ip -4 route show 2>/dev/null \
                  | awk '$0 !~ /pterodactyl0/ { print $1 }' | tr '\n' ' ' || true)"
    [[ "$used" == *"$prefix"* ]]
}

STRATEGY_DESC["wings_fix_subnet"]="cuba beberapa subnet Docker lain"
wings_fix_subnet() {
    local out; out="$(wings_recent_log)"
    [[ "$out" == *"Pool overlaps"* || "$out" == *"pool overlaps"* ]] || return 1

    # PENTING: jangan guna detect_free_subnet di sini. Ia sengaja mengekalkan
    # pilihan yang tersimpan supaya subnet node tidak hanyut antara run — jadi
    # ia akan memulangkan julat yang SAMA yang baru gagal, dan fallback ini
    # menyerah tanpa mencuba apa-apa. Pilih calon sendiri, dan cuba beberapa:
    # Docker mengira pertindihan terhadap keadaan yang mungkin berubah selepas
    # setiap percubaan.
    local o cand tries=0
    for o in 19 20 21 22 23 24 25 26 27 28 29 30 31 18; do
        (( tries >= 5 )) && break
        cand="172.$o.0.0/16"
        [[ "$cand" == "$(cfg WINGS_DOCKER_SUBNET)" ]] && continue
        subnet_in_use "$cand" && continue
        tries=$((tries + 1))
        log_info "Subnet $(cfg WINGS_DOCKER_SUBNET) bertindih — cuba $cand"
        docker network rm pterodactyl_nw >>"$LOG_FILE" 2>&1 || true
        CFG[WINGS_DOCKER_SUBNET]="$cand"
        state_put wings-subnet "$cand"
        write_wings_network_section "$cand"
        if wings_launch; then
            log_ok "Subnet $cand berfungsi"
            return 0
        fi
        # Kalau puncanya bukan lagi pertindihan, mencuba subnet lain tidak akan
        # membantu — serahkan kepada strategi seterusnya.
        out="$(wings_recent_log)"
        [[ "$out" == *"Pool overlaps"* || "$out" == *"pool overlaps"* ]] || return 1
    done
    return 1
}

STRATEGY_DESC["wings_fix_stale_network"]="buang rangkaian pterodactyl_nw yang tersangkut"
wings_fix_stale_network() {
    docker network rm pterodactyl_nw >>"$LOG_FILE" 2>&1 || return 1
    wings_launch
}

STRATEGY_DESC["wings_fix_port"]="tukar ke port yang bebas"
wings_fix_port() {
    local out; out="$(wings_recent_log)"
    [[ "$out" == *"address already in use"* ]] || return 1
    local alt; alt="$(next_free_port $(( $(cfg WINGS_PORT) + 1 )) || printf '')"
    [[ -z "$alt" ]] && return 1
    log_info "Port $(cfg WINGS_PORT) diguna — tukar Wings ke $alt"
    CFG[WINGS_PORT]="$alt"
    local id; id="$(node_id_of)"
    db_cli -D"$(cfg DB_NAME)" -e "UPDATE nodes SET daemonListen=$alt WHERE id=$id" || return 1
    wings_config_from_panel || return 1
    wings_launch
}

phase_wings_service() {
    if attempt "Wings berjalan" verify_wings_running \
        wings_start_plain \
        wings_fix_stale_network \
        wings_fix_subnet \
        wings_fix_port
    then
        log_ok "Wings berjalan"
        return 0
    fi

    # Semua pembaikan automatik gagal — terangkan puncanya dengan tepat.
    local out; out="$(wings_recent_log)"
    log_err "Wings tidak mahu terus berjalan."
    case "$out" in
        *"Cannot read IPv6 setup"*|*"disable_ipv6: no such file"*)
            log_err "Punca: kernel sistem ini dibina tanpa sokongan IPv6."
            log_err "Docker perlukan /proc/sys/net/ipv6 wujud untuk mencipta bridge, walaupun"
            log_err "IPv6 tidak digunakan. Cuba 'modprobe ipv6', atau guna hos KVM biasa."
            ;;
        *"permission denied"*|*"Operation not permitted"*)
            log_err "Punca: Wings tiada keizinan yang cukup — biasanya VPS OpenVZ/LXC."
            ;;
        *"401"*|*"403"*|*"invalid credentials"*|*"token"*)
            log_err "Punca: Wings ditolak oleh panel. Jana semula config dengan:"
            log_err "  cd $PANEL_DIR && php artisan p:node:configuration $(node_id_of) > $WINGS_ETC/config.yml"
            ;;
        *)
            log_err "20 baris terakhir log Wings:"
            printf '%s\n' "$out" | tail -n 20 | sed 's/^/       /' >&2 || true
            ;;
    esac
    defer_warning "Wings tidak berjalan — panel berfungsi tetapi kau belum boleh cipta game server. Punca dicetak di atas."
    return 0
}

#===========================================================================
# Egg
#===========================================================================
phase_eggs() {
    local urls; urls="$(cfg EGG_IMPORT_URLS)"
    if [[ -z "$urls" ]]; then
        log_skip "Tiada egg custom diminta (semua egg rasmi sudah dipasang semasa seeding)"
        return 0
    fi

    local nest; nest="$(cfg EGG_IMPORT_NEST_ID)"
    if [[ "$(db_q "SELECT COUNT(*) FROM nests WHERE id=$nest" 2>/dev/null || printf 0)" == "0" ]]; then
        defer_warning "EGG_IMPORT_NEST_ID=$nest tidak wujud — egg custom dilangkau. Nest yang ada: $(db_q "SELECT GROUP_CONCAT(CONCAT(id,'=',name)) FROM nests" 2>/dev/null || true)"
        return 0
    fi

    local -a list=()
    IFS=',' read -ra list <<<"$urls"
    local url n=0 skipped=0 failed=0 tmp egg_name existing
    for url in "${list[@]}"; do
        url="$(printf '%s' "$url" | tr -d '[:space:]')"
        [[ -z "$url" ]] && continue
        tmp="$(mktemp /tmp/egg-XXXXXX.json)"
        if ! curl -fsSL --max-time 60 --retry 2 -o "$tmp" "$url"; then
            defer_warning "Egg dilangkau (tidak dapat dimuat turun): $url"
            failed=$((failed + 1)); rm -f "$tmp"; continue
        fi
        if ! php -r 'exit(json_decode(file_get_contents($argv[1])) === null ? 1 : 0);' "$tmp" 2>/dev/null; then
            defer_warning "Egg dilangkau (JSON tidak sah): $url"
            failed=$((failed + 1)); rm -f "$tmp"; continue
        fi

        # Pengimport panel menjana UUID baharu setiap kali, jadi import semula
        # akan menghasilkan pendua. Padan ikut nama dalam nest yang sama.
        egg_name="$(php -r 'echo json_decode(file_get_contents($argv[1]))->name ?? "";' "$tmp" 2>/dev/null || true)"
        if [[ -n "$egg_name" ]]; then
            existing="$(db_q "SELECT COUNT(*) FROM eggs WHERE nest_id=$nest AND name='$(sql_escape "$egg_name")'" 2>/dev/null || printf 0)"
            if [[ "$existing" != "0" ]]; then
                log_skip "Egg '$egg_name' sudah wujud — dilangkau"
                skipped=$((skipped + 1))
                rm -f "$tmp"; continue
            fi
        fi

        if ( cd "$PANEL_DIR" && php artisan tinker --execute="
\$f = new Illuminate\\Http\\UploadedFile('$tmp', basename('$tmp'), 'application/json', null, true);
\$e = app(Pterodactyl\\Services\\Eggs\\Sharing\\EggImporterService::class)->handle(\$f, $nest);
echo 'IMPORTED:' . \$e->name;
" >>"$LOG_FILE" 2>&1 ); then
            n=$((n + 1))
            log_ok "Egg diimport: ${egg_name:-$url}"
        else
            failed=$((failed + 1))
            defer_warning "Egg gagal diimport: $url (lihat $LOG_FILE)"
        fi
        rm -f "$tmp"
    done
    log_ok "$n egg custom diimport${skipped:+, $skipped dilangkau kerana sudah ada}"
    # Kalau ada import yang gagal, jangan tanda fasa ini siap — kalau tidak
    # run seterusnya akan melangkaunya dan egg itu hilang selama-lamanya.
    if (( failed > 0 )); then
        unmark_done eggs
        defer_warning "$failed egg gagal diimport. Fasa egg dibiarkan belum siap, jadi jalankan semula pemasang untuk mencubanya lagi."
    fi
    return 0
}

#===========================================================================
# Firewall
#===========================================================================
phase_firewall() {
    if ! cfg_is HARDEN_FIREWALL yes; then
        log_skip "Firewall tidak diminta — tiada perubahan"
        return 0
    fi
    apt_install ufw fail2ban || { defer_warning "ufw/fail2ban tidak dapat dipasang."; return 0; }

    # Benarkan SSH DAHULU. Mengaktifkan ufw sebelum ini akan memutuskan
    # sambungan kau sendiri.
    local ssh_port
    ssh_port="$( { grep -oE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config \
                   | grep -oE '[0-9]+' | head -1; } 2>/dev/null || true )"
    [[ -z "$ssh_port" ]] && ssh_port=22
    run ufw allow "$ssh_port/tcp" || true
    run ufw allow 80/tcp  || true
    run ufw allow 443/tcp || true
    [[ "$(cfg PANEL_HTTP_PORT)" =~ ^(80|443)$ ]] || run ufw allow "$(cfg PANEL_HTTP_PORT)/tcp" || true
    if cfg_is INSTALL_WINGS yes; then
        run ufw allow "$(cfg WINGS_PORT)/tcp" || true
        run ufw allow "$(cfg WINGS_SFTP_PORT)/tcp" || true
        local r; r="$(cfg NODE_PORT_RANGE)"
        run ufw allow "${r//-/:}/tcp" || true
        run ufw allow "${r//-/:}/udp" || true
    fi
    run bash -c 'ufw --force enable' || defer_warning "ufw tidak dapat diaktifkan."
    [[ "$HAS_SYSTEMD" == "yes" ]] && { systemctl enable --now fail2ban >>"$LOG_FILE" 2>&1 || true; }
    log_ok "UFW aktif (SSH port $ssh_port dibenarkan) + fail2ban dipasang"
    return 0
}
