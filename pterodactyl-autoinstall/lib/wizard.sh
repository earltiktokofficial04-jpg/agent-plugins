#!/usr/bin/env bash
#############################################################################
#  wizard.sh — auto-kesan + soalan interaktif
#
#  Falsafah: tanya HANYA perkara yang mesin tak boleh tahu sendiri.
#  Semua yang lain dikesan (IP, zon waktu, RAM, disk, port bebas, subnet)
#  atau diberi default yang munasabah.
#############################################################################

[[ -n "${_PTERO_WIZARD_LOADED:-}" ]] && return 0
_PTERO_WIZARD_LOADED=1

#---------------------------------------------------------------------------
# Auto-kesan
#---------------------------------------------------------------------------
detect_public_ip() {
    local ip="" url
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ip="$( { curl -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]'; } || true )"
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    # Tiada internet keluar atau semua perkhidmatan tersekat — guna IP keluar tempatan.
    ip="$( ip route get 1.1.1.1 2>/dev/null \
           | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i+1); exit } }' || true )"
    [[ -n "$ip" ]] && printf '%s' "$ip"
    return 0
}

detect_timezone() {
    local tz=""
    if have timedatectl; then
        tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    fi
    [[ -z "$tz" && -r /etc/timezone ]] && tz="$(tr -d '[:space:]' </etc/timezone 2>/dev/null || true)"
    if [[ -z "$tz" && -L /etc/localtime ]]; then
        tz="$(readlink -f /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)"
    fi
    [[ -z "$tz" ]] && tz="UTC"
    printf '%s' "$tz"
    return 0
}

detect_node_name() {
    local h
    h="$(hostname -s 2>/dev/null || printf 'node')"
    h="$(printf '%s' "$h" | tr -cd 'A-Za-z0-9._-')"
    [[ -z "$h" ]] && h="node"
    printf '%s' "$h"
    return 0
}

is_ip_literal() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# Subnet /16 dalam 172.x yang tidak bertindih dengan rangkaian Docker sedia ada.
detect_free_subnet() {
    # Pilihan yang pernah dibuat dikekalkan. Kalau tidak, run kedua akan melihat
    # rangkaian Wings SENDIRI sebagai "sudah diguna", memilih julat lain, dan
    # menukar rangkaian Docker node pada setiap run.
    local saved; saved="$(state_get wings-subnet)"
    if [[ -n "$saved" ]]; then
        printf '%s' "$saved"
        return 0
    fi

    local used="" ids o
    if have docker; then
        ids="$(docker network ls -q 2>/dev/null || true)"
        if [[ -n "$ids" ]]; then
            # Kecualikan rangkaian Wings sendiri daripada set "sudah diguna".
            # shellcheck disable=SC2086
            used="$(docker network inspect $ids \
                    --format '{{if ne .Name "pterodactyl_nw"}}{{range .IPAM.Config}}{{.Subnet}} {{end}}{{end}}' \
                    2>/dev/null || true)"
        fi
    fi
    # Juga elak julat yang sudah ada laluan pada hos ini.
    used="$used $(ip -4 route show 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true)"
    for o in 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
        [[ "$used" == *"172.$o."* ]] && continue
        state_put wings-subnet "172.$o.0.0/16"
        printf '172.%s.0.0/16' "$o"
        return 0
    done
    return 0
}

#---------------------------------------------------------------------------
# Primitif soalan
#---------------------------------------------------------------------------
_tty_available() { [[ -e /dev/tty ]] && { : >/dev/tty; } 2>/dev/null; }

ask() {
    local var="$1" prompt="$2" default="$3" vtype="$4" note="${5:-}"
    local val=""
    while :; do
        printf '\n  %s%s%s\n' "$C_BLD" "$prompt" "$C_OFF"
        [[ -n "$note" ]] && printf '  %s%s%s\n' "$C_DIM" "$note" "$C_OFF"
        if [[ -n "$default" ]]; then
            printf '  [%s%s%s] ' "$C_CYN" "$default" "$C_OFF"
        else
            printf '  > '
        fi
        read -r val </dev/tty 2>/dev/null || val=""
        [[ -z "$val" ]] && val="$default"
        if [[ -z "$val" ]]; then
            printf '  %s! Ini wajib diisi.%s\n' "$C_YEL" "$C_OFF"
            continue
        fi
        if check_value "$vtype" "$val"; then
            CFG["$var"]="$val"
            return 0
        fi
        printf '  %s! %s%s\n' "$C_YEL" "$(validator_hint "$vtype")" "$C_OFF"
    done
}

ask_yesno() {
    local var="$1" prompt="$2" default="$3" note="${4:-}"
    local reply="" hint
    [[ "$default" == "yes" ]] && hint="Y/n" || hint="y/N"
    while :; do
        printf '\n  %s%s%s\n' "$C_BLD" "$prompt" "$C_OFF"
        [[ -n "$note" ]] && printf '  %s%s%s\n' "$C_DIM" "$note" "$C_OFF"
        printf '  [%s%s%s] ' "$C_CYN" "$hint" "$C_OFF"
        read -r reply </dev/tty 2>/dev/null || reply=""
        [[ -z "$reply" ]] && reply="$default"
        case "$reply" in
            [Yy]*) CFG["$var"]="yes"; return 0 ;;
            [Nn]*) CFG["$var"]="no";  return 0 ;;
        esac
        printf '  %s! Jawab y atau n.%s\n' "$C_YEL" "$C_OFF"
    done
}

ask_password() {
    local var="$1" prompt="$2"
    local p1="" p2=""
    printf '\n  %s%s%s\n' "$C_BLD" "$prompt" "$C_OFF"
    printf '  %sTekan Enter sahaja untuk biar script jana password kuat.%s\n' "$C_DIM" "$C_OFF"
    while :; do
        printf '  Password: '
        read -rs p1 </dev/tty 2>/dev/null || p1=""
        printf '\n'
        if [[ -z "$p1" ]]; then
            CFG["$var"]="$(gen_password 20)"
            GENERATED_SECRETS+=("$var")
            printf '  %s✔ Password dijana — ia akan dipaparkan pada penghujung dan disimpan dalam fail kredential.%s\n' "$C_GRN" "$C_OFF"
            return 0
        fi
        if ! v_pass "$p1"; then
            printf '  %s! %s%s\n' "$C_YEL" "$(validator_hint pass)" "$C_OFF"
            continue
        fi
        printf '  Ulang    : '
        read -rs p2 </dev/tty 2>/dev/null || p2=""
        printf '\n'
        if [[ "$p1" != "$p2" ]]; then
            printf '  %s! Tidak sama. Cuba lagi.%s\n' "$C_YEL" "$C_OFF"
            continue
        fi
        CFG["$var"]="$p1"
        return 0
    done
}

#---------------------------------------------------------------------------
# Wizard
#---------------------------------------------------------------------------
wizard() {
    banner "Persiapan"
    printf '  Saya akan tanya beberapa perkara yang tidak boleh dikesan automatik.\n'
    printf '  Semua yang lain (zon waktu, saiz RAM/disk node, port, subnet Docker)\n'
    printf '  saya kesan sendiri dan tunjukkan kepada kau sebelum apa-apa dipasang.\n'
    printf '  Tekan Enter untuk terima nilai dalam [ ].\n'

    local ip_guess; ip_guess="$(detect_public_ip)"

    # 1 — alamat panel
    ask PANEL_FQDN \
        "Alamat untuk akses panel — domain atau IP?" \
        "$ip_guess" host \
        "Kalau kau ada domain yang sudah point ke server ini, guna domain (cth panel.domain.com) supaya HTTPS boleh dipasang."

    # 2 — SSL, hanya bermakna bila alamatnya domain
    if is_ip_literal "$(cfg PANEL_FQDN)"; then
        CFG[PANEL_SSL]="no"
        printf '\n  %s↷ Alamat yang kau beri ialah IP, jadi HTTPS dilangkau.%s\n' "$C_DIM" "$C_OFF"
        printf '  %s  Let'"'"'s Encrypt tidak mengeluarkan sijil untuk alamat IP.%s\n' "$C_DIM" "$C_OFF"
    else
        ask_yesno PANEL_SSL \
            "Pasang sijil HTTPS Let's Encrypt automatik?" yes \
            "Perlu domain di atas sudah point ke server ini dan port 80 terbuka dari internet."
    fi

    # 3 — email admin
    ask ADMIN_EMAIL \
        "Email untuk akaun admin?" \
        "" email \
        "Diguna untuk log masuk dan reset password$( cfg_is PANEL_SSL yes && printf ', dan untuk pendaftaran sijil Let'"'"'s Encrypt' )."
    [[ -z "$(cfg SSL_EMAIL)" ]] && CFG[SSL_EMAIL]="$(cfg ADMIN_EMAIL)"

    # 4 — username admin
    ask ADMIN_USERNAME "Username admin?" "admin" uname

    # 5 — password admin
    ask_password ADMIN_PASSWORD "Password admin?"

    # 6 — wings
    ask_yesno INSTALL_WINGS \
        "Pasang Wings juga (daemon yang benar-benar menjalankan game server)?" yes \
        "Tanpa Wings kau dapat panel sahaja dan tidak boleh cipta game server. Wings perlukan Docker — tidak berfungsi atas VPS OpenVZ/LXC."

    # 7 — runtime tambahan
    ask_yesno INSTALL_NODEJS \
        "Pasang Node.js LTS dan Python 3 sekali?" yes \
        "Banyak egg dan tooling komuniti perlukan kedua-duanya. Selamat dipasang walaupun kau tak pasti."
    CFG[INSTALL_PYTHON]="$(cfg INSTALL_NODEJS)"

    save_answers
    return 0
}

#---------------------------------------------------------------------------
# Isi semua yang boleh dikesan atau diterbitkan
#---------------------------------------------------------------------------
autofill() {
    local entry name req vtype def desc

    # Default statik daripada skema
    for entry in "${SCHEMA[@]}"; do
        IFS='|' read -r name req vtype def desc <<<"$entry"
        [[ -z "${CFG[$name]:-}" && -n "$def" ]] && CFG["$name"]="$def"
    done

    [[ -z "$(cfg PANEL_TIMEZONE)" ]] && CFG[PANEL_TIMEZONE]="$(detect_timezone)"
    [[ -z "$(cfg SSL_EMAIL)"      ]] && CFG[SSL_EMAIL]="$(cfg ADMIN_EMAIL)"
    # "no-reply@<fqdn>" bukan email yang sah bila fqdn ialah alamat IP atau nama
    # satu label seperti "localhost" — jangan jadikan itu punca kegagalan validasi.
    if [[ -z "$(cfg MAIL_FROM)" ]]; then
        if v_email "no-reply@$(cfg PANEL_FQDN)"; then
            CFG[MAIL_FROM]="no-reply@$(cfg PANEL_FQDN)"
        else
            CFG[MAIL_FROM]="$(cfg ADMIN_EMAIL)"
        fi
    fi
    [[ -z "$(cfg WINGS_FQDN)"     ]] && CFG[WINGS_FQDN]="$(cfg PANEL_FQDN)"
    [[ -z "$(cfg WINGS_SSL)"      ]] && CFG[WINGS_SSL]="$(cfg PANEL_SSL)"
    [[ -z "$(cfg NODE_NAME)"      ]] && CFG[NODE_NAME]="$(detect_node_name)"
    [[ -z "$(cfg NODE_LOCATION_DESC)" ]] && CFG[NODE_LOCATION_DESC]="$(cfg NODE_LOCATION)"
    [[ -z "$(cfg ADMIN_PASSWORD)" ]] && {
        CFG[ADMIN_PASSWORD]="$(gen_password 20)"
        GENERATED_SECRETS+=("ADMIN_PASSWORD")
    }

    # Port panel: 443 bila SSL, jika tidak 80 — tetapi elak port yang sudah
    # diguna proses lain supaya nginx tidak gagal start.
    if [[ -z "$(cfg PANEL_HTTP_PORT)" ]]; then
        local want
        cfg_is PANEL_SSL yes && want=443 || want=80
        if port_busy "$want" && [[ "$(port_owner "$want")" != *nginx* ]]; then
            local alt; alt="$(next_free_port 8080 || printf '')"
            if [[ -n "$alt" ]]; then
                CFG[PANEL_HTTP_PORT]="$alt"
                defer_warning "Port $want sudah diguna $(port_owner "$want") — panel diletak pada port $alt."
            else
                CFG[PANEL_HTTP_PORT]="$want"
            fi
        else
            CFG[PANEL_HTTP_PORT]="$want"
        fi
    fi

    # Port Wings: sama, elak konflik.
    if cfg_is INSTALL_WINGS yes; then
        local wp; wp="$(cfg WINGS_PORT)"
        if port_busy "$wp" && [[ "$(port_owner "$wp")" != *wings* ]]; then
            local altw; altw="$(next_free_port $((wp + 1)) || printf '')"
            [[ -n "$altw" ]] && {
                CFG[WINGS_PORT]="$altw"
                defer_warning "Port $wp sudah diguna — Wings diletak pada port $altw."
            }
        fi
        local sp; sp="$(cfg WINGS_SFTP_PORT)"
        if port_busy "$sp"; then
            local alts; alts="$(next_free_port $((sp + 1)) || printf '')"
            [[ -n "$alts" ]] && {
                CFG[WINGS_SFTP_PORT]="$alts"
                defer_warning "Port SFTP $sp sudah diguna — Wings SFTP diletak pada port $alts."
            }
        fi
    fi

    # Password DB: dijana sekali, kemudian DIKEKALKAN. Kalau ia berubah pada run
    # kedua, ALTER USER akan tukar password dalam MariaDB sedangkan .env panel
    # masih simpan yang lama, dan panel terus putus daripada pangkalan data.
    if [[ -z "$(cfg DB_PASSWORD)" ]]; then
        # .env panel yang sudah ada ialah sumber kebenaran: kalau kita menjana
        # nilai baharu dan ALTER USER, panel yang berjalan akan terus terputus
        # daripada pangkalan datanya sendiri.
        local from_env=""
        if [[ -f "$PANEL_DIR/.env" ]]; then
            from_env="$( { awk -F= '$1 == "DB_PASSWORD" { sub(/^DB_PASSWORD=/, "", $0); print }' \
                          "$PANEL_DIR/.env" | tr -d '"'"'"'"' ; } 2>/dev/null || true )"
        fi
        local saved; saved="$(state_get db-password)"
        [[ -n "$from_env" ]] && saved="$from_env"
        if [[ -n "$saved" ]]; then
            CFG[DB_PASSWORD]="$saved"
        else
            CFG[DB_PASSWORD]="$(gen_secret 32)"
            GENERATED_SECRETS+=("DB_PASSWORD")
            state_put db-password "${CFG[DB_PASSWORD]}"
        fi
    fi

    # Saiz node daripada perkakasan sebenar.
    if [[ -z "$(cfg NODE_MEMORY)" ]]; then
        local t; t="$(ram_mb)"
        CFG[NODE_MEMORY]="$(( t > 2048 ? t - 1024 : t ))"
    fi
    if [[ -z "$(cfg NODE_DISK)" ]]; then
        local d; d="$(disk_mb)"
        CFG[NODE_DISK]="$(( d > 10240 ? d - 5120 : d ))"
    fi

    [[ -z "$(cfg WINGS_DOCKER_SUBNET)" ]] && CFG[WINGS_DOCKER_SUBNET]="$(detect_free_subnet)"
    return 0
}

#---------------------------------------------------------------------------
# Simpan/muat jawapan supaya run kedua tidak bertanya semula
#---------------------------------------------------------------------------
save_answers() {
    state_init
    local keys="PANEL_FQDN PANEL_SSL SSL_EMAIL ADMIN_EMAIL ADMIN_USERNAME ADMIN_PASSWORD
                INSTALL_WINGS INSTALL_NODEJS INSTALL_PYTHON PANEL_TIMEZONE"
    local k
    # Nota: `[[ -n x ]] && printf` sebagai pernyataan terakhir dalam loop akan
    # menjadikan status keluar subshell 1 apabila kunci terakhir kosong, yang
    # menghasilkan amaran palsu. Sebab itu ada `true` di hujung.
    (
        umask 077
        printf '# Jawapan yang disimpan oleh wizard pada %s\n' "$(_ts)" >"$ANSWERS_FILE"
        printf '# Padam fail ini (atau guna --reconfigure) untuk ditanya semula.\n' >>"$ANSWERS_FILE"
        for k in $keys; do
            if [[ -n "${CFG[$k]:-}" ]]; then
                printf '%s=%q\n' "$k" "${CFG[$k]}" >>"$ANSWERS_FILE"
            fi
        done
        true
    ) 2>/dev/null || log_warn "Tidak dapat menyimpan jawapan ke $ANSWERS_FILE"
    return 0
}

have_saved_answers() { [[ -s "$ANSWERS_FILE" ]]; }

load_saved_answers() {
    [[ -s "$ANSWERS_FILE" ]] || return 1
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            # Nilai ditulis dengan %q; buang petik ringkas tanpa eval.
            val="${val#\'}"; val="${val%\'}"
            val="${val#\$\'}"
            [[ -z "${CFG[$key]:-}" ]] && CFG["$key"]="$val"
        fi
    done <"$ANSWERS_FILE"
    return 0
}

#---------------------------------------------------------------------------
# Tunjuk rancangan sebelum menyentuh apa-apa
#---------------------------------------------------------------------------
show_plan() {
    local scheme; cfg_is PANEL_SSL yes && scheme=https || scheme=http
    local url="$scheme://$(cfg PANEL_FQDN)"
    [[ "$(cfg PANEL_HTTP_PORT)" != "80" && "$(cfg PANEL_HTTP_PORT)" != "443" ]] \
        && url="$url:$(cfg PANEL_HTTP_PORT)"

    banner "Rancangan"
    printf '  %sJawapan kau%s\n' "$C_BLD" "$C_OFF"
    printf '    Panel               : %s\n' "$url"
    printf '    Admin               : %s <%s>\n' "$(cfg ADMIN_USERNAME)" "$(cfg ADMIN_EMAIL)"
    printf '    Password admin      : %s\n' \
        "$( [[ " ${GENERATED_SECRETS[*]:-} " == *ADMIN_PASSWORD* ]] && printf 'dijana automatik' || printf 'yang kau taip' )"
    printf '    HTTPS               : %s\n' "$(cfg PANEL_SSL)"
    printf '    Wings               : %s\n' "$(cfg INSTALL_WINGS)"
    printf '    Node.js + Python    : %s\n' "$(cfg INSTALL_NODEJS)"

    printf '\n  %sDikesan automatik%s\n' "$C_BLD" "$C_OFF"
    printf '    OS                  : %s %s (%s)\n' "$OS_ID" "$OS_VER" "$ARCH"
    printf '    systemd             : %s\n' "$HAS_SYSTEMD"
    printf '    Virtualisasi        : %s\n' "$VIRT"
    printf '    Zon waktu           : %s\n' "$(cfg PANEL_TIMEZONE)"
    printf '    RAM / disk          : %s MB / %s MB kosong\n' "$(ram_mb)" "$(disk_mb)"
    printf '    Port panel          : %s\n' "$(cfg PANEL_HTTP_PORT)"
    if cfg_is INSTALL_WINGS yes; then
        printf '    Node                : %s @ %s\n' "$(cfg NODE_NAME)" "$(cfg WINGS_FQDN)"
        printf '    Sumber node         : %s MB RAM, %s MB disk\n' "$(cfg NODE_MEMORY)" "$(cfg NODE_DISK)"
        printf '    Port Wings / SFTP   : %s / %s\n' "$(cfg WINGS_PORT)" "$(cfg WINGS_SFTP_PORT)"
        printf '    Allocation          : %s:%s\n' "$(cfg NODE_ALLOCATION_IP)" "$(cfg NODE_PORT_RANGE)"
        printf '    Subnet Docker       : %s\n' "$(cfg WINGS_DOCKER_SUBNET)"
    fi
    printf '    Pangkalan data      : %s / %s (password dijana)\n' "$(cfg DB_NAME)" "$(cfg DB_USERNAME)"
    printf '    Kredential disimpan : %s\n' "$(cfg CREDENTIALS_FILE)"
    printf '\n'
    return 0
}
