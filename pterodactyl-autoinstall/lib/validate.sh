#!/usr/bin/env bash
#############################################################################
#  validate.sh — skema konfigurasi, validator, dan pembaca fail config
#############################################################################

[[ -n "${_PTERO_VALIDATE_LOADED:-}" ]] && return 0
_PTERO_VALIDATE_LOADED=1

#---------------------------------------------------------------------------
#  Skema:  nama | keperluan | validator | default | penerangan
#
#  keperluan: required | optional | req_if:KUNCI=nilai
#  Medan yang boleh diisi oleh wizard ditanda dalam WIZARD_FIELDS (wizard.sh).
#---------------------------------------------------------------------------
SCHEMA=(
"PANEL_FQDN|required|host||Domain atau IP untuk akses panel"
"ADMIN_EMAIL|required|email||Alamat email akaun admin"
"ADMIN_USERNAME|optional|uname|admin|Username admin"
"ADMIN_PASSWORD|optional|pass||Password admin (dijana jika kosong)"
"PANEL_TIMEZONE|optional|tz||Zon waktu (auto-kesan jika kosong)"

"PANEL_SSL|optional|bool|no|Pasang sijil Let's Encrypt"
"SSL_EMAIL|optional|email||Email Let's Encrypt (default: ADMIN_EMAIL)"
"PANEL_HTTP_PORT|optional|port||Port nginx (auto jika kosong)"
"ADMIN_FIRST_NAME|optional|any|Admin|Nama pertama admin"
"ADMIN_LAST_NAME|optional|any|User|Nama akhir admin"
"PANEL_TELEMETRY|optional|bool|no|Hantar telemetri ke upstream"
"RECAPTCHA_ENABLED|optional|bool|no|reCAPTCHA di halaman login"
"RECAPTCHA_SITE_KEY|req_if:RECAPTCHA_ENABLED=yes|any||Site key reCAPTCHA"
"RECAPTCHA_SECRET_KEY|req_if:RECAPTCHA_ENABLED=yes|any||Secret key reCAPTCHA"

"DB_NAME|optional|dbident|panel|Nama pangkalan data"
"DB_USERNAME|optional|dbident|pterodactyl|Username pangkalan data"
"DB_PASSWORD|optional|any||Password pangkalan data (dijana jika kosong)"
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
"MAIL_FROM|optional|email||Alamat pengirim"
"MAIL_FROM_NAME|optional|any|Pterodactyl Panel|Nama pengirim"
"MAIL_ENCRYPTION|optional|enum:tls,ssl,none|tls|Enkripsi SMTP"

"INSTALL_WINGS|optional|bool|yes|Pasang Wings + Docker + node"
"INSTALL_NODEJS|optional|bool|yes|Pasang Node.js LTS"
"INSTALL_PYTHON|optional|bool|yes|Pasang Python 3 + pip + venv"
"NODEJS_MAJOR|optional|int|22|Versi major Node.js"

"WINGS_FQDN|optional|host||Domain/IP node Wings (default: PANEL_FQDN)"
"NODE_NAME|optional|nodename||Nama node (auto jika kosong)"
"NODE_LOCATION|optional|locshort|main|Kod lokasi"
"NODE_LOCATION_DESC|optional|any||Penerangan lokasi"
"NODE_MEMORY|optional|int||RAM node dalam MB (auto jika kosong)"
"NODE_DISK|optional|int||Disk node dalam MB (auto jika kosong)"
"NODE_MEMORY_OVERALLOCATE|optional|overalloc|0|Over-allocate RAM (%)"
"NODE_DISK_OVERALLOCATE|optional|overalloc|0|Over-allocate disk (%)"
"WINGS_PORT|optional|port|8080|Port HTTP Wings"
"WINGS_SFTP_PORT|optional|port|2022|Port SFTP Wings"
"WINGS_DATA_DIR|optional|abspath|/var/lib/pterodactyl/volumes|Folder data Wings"
"WINGS_SSL|optional|bool||Node guna https (default: ikut PANEL_SSL)"
"WINGS_DOCKER_SUBNET|optional|cidr||Subnet Docker Wings (auto jika kosong)"
"NODE_PORT_RANGE|optional|portrange|25565-25585|Julat port allocation"
"NODE_ALLOCATION_IP|optional|host|0.0.0.0|IP allocation"

"EGG_IMPORT_URLS|optional|any||URL egg custom, pisah dengan koma"
"EGG_IMPORT_NEST_ID|optional|int|1|Nest ID untuk egg custom"

"PANEL_URL|optional|url||URL panel penuh (mod --wings-only)"
"NODE_TOKEN|optional|any||Token Auto Deploy daripada panel (mod --wings-only)"
"NODE_ID|optional|int||ID node dalam panel (mod --wings-only)"
"WINGS_ALLOW_INSECURE|optional|bool|no|Terima sijil panel yang tidak dipercayai"
"BEHIND_PROXY|optional|bool|no|Panel di belakang reverse proxy / Cloudflare"
"PROXY_SCHEME|optional|enum:http,https|https|Skema yang dilihat pengguna melalui proxy"
"TRUSTED_PROXIES|optional|any|*|Nilai TRUSTED_PROXIES untuk .env panel"
"GITHUB_TOKEN|optional|any||Token GitHub (elak had kadar composer)"
"HARDEN_FIREWALL|optional|bool|no|Pasang UFW + fail2ban"
"CREDENTIALS_FILE|optional|abspath|/root/pterodactyl-credentials.txt|Fail kredential"
)

#---------------------------------------------------------------------------
# Validator
#---------------------------------------------------------------------------
v_any()      { return 0; }
v_email()    { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
v_host()     { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; }
v_uname()    { [[ "$1" =~ ^[A-Za-z0-9_.-]{3,}$ ]]; }
v_nodename() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,100}$ ]]; }
v_locshort() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,60}$ ]]; }
v_dbident()  { [[ "$1" =~ ^[A-Za-z0-9_]{1,32}$ ]]; }
v_int()      { [[ "$1" =~ ^[0-9]+$ ]]; }
v_port()     { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
v_bool()     { [[ "$1" =~ ^(yes|no)$ ]]; }
v_abspath()  { [[ "$1" == /* ]]; }
v_cidr()     { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; }
v_url()      { [[ "$1" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/.*)?$ ]]; }
v_overalloc(){ [[ "$1" == "-1" ]] || { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 <= 1000 )); }; }

# Password: syarat Pterodactyl sendiri — 8+ aksara, ada huruf besar, kecil, nombor.
v_pass() {
    (( ${#1} >= 8 )) || return 1
    [[ "$1" =~ [A-Z] ]] || return 1
    [[ "$1" =~ [a-z] ]] || return 1
    [[ "$1" =~ [0-9] ]] || return 1
    return 0
}

# tzdata mungkin belum dipasang semasa validasi awal. Kalau pangkalan data zon
# waktu tiada, sahkan format sahaja — nilai sebenar disemak semula selepas
# tzdata dipasang (lihat recheck_timezone).
v_tz() {
    if [[ -d /usr/share/zoneinfo/posix ]]; then
        [[ -f "/usr/share/zoneinfo/$1" ]]
    else
        [[ "$1" == "UTC" ]] || [[ "$1" =~ ^[A-Za-z_]+/[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)?$ ]]
    fi
}

v_portrange() {
    [[ "$1" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
    v_port "$a" && v_port "$b" && (( b >= a )) && (( b - a <= 5000 ))
}

v_enum() {
    local val="$1" allowed="$2" a
    local -a opts=()
    IFS=',' read -ra opts <<<"$allowed"
    for a in "${opts[@]}"; do
        [[ "$val" == "$a" ]] && return 0
    done
    return 1
}

# Sahkan satu nilai terhadap nama validator (termasuk bentuk enum:a,b,c).
check_value() {
    local vtype="$1" val="$2"
    case "$vtype" in
        enum:*) v_enum "$val" "${vtype#enum:}" ;;
        *)      "v_$vtype" "$val" ;;
    esac
}

validator_hint() {
    case "$1" in
        email)     printf 'mesti alamat email yang sah' ;;
        host)      printf 'domain atau IP sahaja — tanpa http:// dan tanpa / di hujung' ;;
        uname)     printf 'huruf/nombor/._- sahaja, minimum 3 aksara' ;;
        nodename)  printf 'huruf/nombor/._- sahaja, maksimum 100 aksara' ;;
        locshort)  printf 'huruf/nombor/._- sahaja, maksimum 60 aksara' ;;
        dbident)   printf 'huruf/nombor/underscore sahaja, maksimum 32 aksara' ;;
        pass)      printf 'minimum 8 aksara, mesti ada huruf besar, huruf kecil dan nombor' ;;
        int)       printf 'mesti nombor bulat' ;;
        port)      printf 'mesti port 1-65535' ;;
        bool)      printf 'mesti "yes" atau "no"' ;;
        tz)        printf 'zon waktu tak wujud — cth "Asia/Kuala_Lumpur"' ;;
        abspath)   printf 'mesti laluan mutlak bermula dengan /' ;;
        cidr)      printf 'format CIDR, cth "172.20.0.0/16"' ;;
        url)       printf 'mesti URL penuh bermula dengan http:// atau https://' ;;
        overalloc) printf '0-1000, atau -1 untuk tanpa had' ;;
        portrange) printf 'format "mula-tamat", cth "25565-25585"' ;;
        enum:*)    printf 'mesti salah satu daripada: %s' "${1#enum:}" ;;
        *)         printf 'nilai tidak sah' ;;
    esac
}

schema_field() {
    local want="$1" idx="$2" entry name req vtype def desc
    for entry in "${SCHEMA[@]}"; do
        IFS='|' read -r name req vtype def desc <<<"$entry"
        if [[ "$name" == "$want" ]]; then
            case "$idx" in
                req)  printf '%s' "$req" ;;
                type) printf '%s' "$vtype" ;;
                def)  printf '%s' "$def" ;;
                desc) printf '%s' "$desc" ;;
            esac
            return 0
        fi
    done
    return 0
}

#---------------------------------------------------------------------------
# Baca fail konfigurasi. Parser ketat — tiada eval, tiada pelaksanaan kod.
#---------------------------------------------------------------------------
load_config_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local lineno=0 line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val%"${val##*[![:space:]]}"}"
            [[ "$val" == \"*\" ]] && val="${val:1:${#val}-2}"
            [[ "$val" == \'*\' ]] && val="${val:1:${#val}-2}"
            [[ -n "$val" ]] && CFG["$key"]="$val"
        else
            die "Konfigurasi rosak dalam $file pada baris $lineno: $line"
        fi
    done <"$file"
    return 0
}

#---------------------------------------------------------------------------
# Sahkan keseluruhan CFG. Kumpul SEMUA masalah, jangan berhenti pada yang pertama.
#---------------------------------------------------------------------------
validate_config() {
    local -a errors=()
    local entry name req vtype def desc val

    for entry in "${SCHEMA[@]}"; do
        IFS='|' read -r name req vtype def desc <<<"$entry"
        val="${CFG[$name]:-}"

        local is_required="no"
        case "$req" in
            required) is_required="yes" ;;
            req_if:*)
                local cond="${req#req_if:}" ck cv other
                ck="${cond%%=*}"; cv="${cond#*=}"
                other="${CFG[$ck]:-}"
                [[ -z "$other" ]] && other="$(schema_field "$ck" def)"
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

        check_value "$vtype" "$val" \
            || errors+=("$name|nilai \"$val\" tidak sah — $(validator_hint "$vtype")|$desc")
    done

    # Semakan silang
    if cfg_is PANEL_SSL yes && [[ "$(cfg PANEL_FQDN)" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        errors+=("PANEL_FQDN|PANEL_SSL=\"yes\" perlukan domain sebenar, bukan IP|Let's Encrypt tidak mengeluarkan sijil untuk alamat IP")
    fi

    # Kombinasi yang setiap satunya sah, tetapi mustahil bersama.
    if cfg_is PANEL_SSL yes && cfg_is BEHIND_PROXY yes; then
        errors+=("BEHIND_PROXY|tidak boleh 'yes' serentak dengan PANEL_SSL='yes'|Kalau proxy sudah mengendalikan HTTPS, server ini tidak sepatutnya cuba mendapatkan sijilnya sendiri — port 80 dipegang proxy dan cabaran Let's Encrypt akan gagal")
    fi
    if [[ -n "$(cfg WINGS_FQDN)" ]] && cfg_is WINGS_SSL yes \
       && [[ "$(cfg WINGS_FQDN)" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        errors+=("WINGS_SSL|https memerlukan domain untuk node, bukan IP|Panel menolak node https yang fqdn-nya alamat IP, dan sijil tidak boleh dikeluarkan untuk IP")
    fi
    if [[ -n "$(cfg NODE_PORT_RANGE)" && -n "$(cfg WINGS_PORT)" ]]; then
        local _s="${CFG[NODE_PORT_RANGE]%%-*}" _e="${CFG[NODE_PORT_RANGE]##*-}"
        if [[ "$_s" =~ ^[0-9]+$ && "$_e" =~ ^[0-9]+$ ]]; then
            local _wp="$(cfg WINGS_PORT)" _sp="$(cfg WINGS_SFTP_PORT)"
            if (( _wp >= _s && _wp <= _e )); then
                errors+=("NODE_PORT_RANGE|julat ini merangkumi port Wings sendiri ($_wp)|Satu game server akan diberi port yang Wings sedang dengar, dan ia tidak akan dapat bermula")
            fi
            if [[ "$_sp" =~ ^[0-9]+$ ]] && (( _sp >= _s && _sp <= _e )); then
                errors+=("NODE_PORT_RANGE|julat ini merangkumi port SFTP Wings ($_sp)|SFTP akan berlanggar dengan game server")
            fi
        fi
    fi

    if (( ${#errors[@]} == 0 )); then
        return 0
    fi

    printf '\n%s%s%s\n\n' "$C_RED$C_BLD" "KONFIGURASI TIDAK LENGKAP — ${#errors[@]} masalah:" "$C_OFF"
    local i=1 e n m d
    for e in "${errors[@]}"; do
        IFS='|' read -r n m d <<<"$e"
        printf '  %s%2d.%s %s%-24s%s %s\n' "$C_BLD" "$i" "$C_OFF" "$C_YEL" "$n" "$C_OFF" "$m"
        printf '      %s%s%s\n' "$C_DIM" "$d" "$C_OFF"
        i=$((i + 1))
    done
    printf '\n'
    return 1
}

# Dipanggil selepas tzdata dipasang, kerana v_tz tak dapat menyemak dengan
# tepat sebelum pangkalan data zon waktu ada.
recheck_timezone() {
    local tz; tz="$(cfg PANEL_TIMEZONE)"
    [[ -z "$tz" ]] && return 0
    local zi="/usr/share/zoneinfo"
    is_termux && zi="$TERMUX_PREFIX/share/zoneinfo"
    [[ -f "$zi/$tz" ]] && return 0
    log_warn "Zon waktu \"$tz\" tidak wujud dalam pangkalan data — guna UTC"
    CFG[PANEL_TIMEZONE]="UTC"
    return 0
}
