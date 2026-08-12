#!/usr/bin/env bash
#############################################################################
#  phases-base.sh — pakej asas, PHP, Composer, Node.js, Python, MariaDB, Redis
#
#  Setiap langkah rapuh dibina sebagai:
#      attempt "matlamat" verify_fn strategi1 strategi2 ...
#  supaya bila cara pertama gagal, cara kedua dicuba sendiri.
#############################################################################

[[ -n "${_PTERO_BASE_LOADED:-}" ]] && return 0
_PTERO_BASE_LOADED=1

#===========================================================================
# Pakej asas
#===========================================================================
BASE_PKGS=(curl wget tar unzip git ca-certificates gnupg lsb-release
           apt-transport-https software-properties-common cron iproute2
           psmisc sudo tzdata jq)

# dpkg yang tertinggal separuh konfigurasi (biasanya kerana pemasangan
# sebelumnya diputuskan) akan menggagalkan setiap apt-get selepas ini, dengan
# mesej yang tidak menyebut puncanya. Baiki sebelum apa-apa lagi.
repair_dpkg_if_broken() {
    local st
    st="$(dpkg --audit 2>/dev/null || true)"
    [[ -z "$st" ]] && return 0
    log_warn "dpkg dalam keadaan separuh terkonfigurasi — cuba baiki dahulu"
    apt_wait
    dpkg --configure -a >>"$LOG_FILE" 2>&1 || true
    apt_q --fix-broken install -y -qq >>"$LOG_FILE" 2>&1 || true
    return 0
}

# Pakej cron boleh dipasang tanpa daemonnya berjalan (biasa dalam imej minimal
# dan container). Scheduler panel bergantung sepenuhnya padanya.
ensure_cron_running() {
    have crontab || return 0
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        systemctl enable cron >>"$LOG_FILE" 2>&1 || systemctl enable crond >>"$LOG_FILE" 2>&1 || true
        systemctl start cron  >>"$LOG_FILE" 2>&1 || systemctl start crond  >>"$LOG_FILE" 2>&1 || true
    fi
    # `a || b && c` di sini akan mengelirukan; tulis secara jelas.
    if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then
        return 0
    fi
    # Tanpa systemd, lancarkan daemon terus.
    if have cron; then
        setsid nohup cron -f >>"$LOG_FILE" 2>&1 </dev/null &
        disown 2>/dev/null || true
    fi
    return 0
}

phase_deps() {
    repair_dpkg_if_broken
    pkg_update || log_warn "apt update tidak bersih — teruskan dan lihat sama ada pakej masih boleh dipasang"

    # Pasang seberapa banyak yang boleh. Kalau kumpulan penuh gagal (satu pakej
    # tiada pada release ini), pasang satu-satu supaya yang lain tetap masuk.
    if ! run pkg_install "${BASE_PKGS[@]}"; then
        log_warn "Pemasangan berkelompok gagal — cuba satu demi satu"
        local p
        for p in "${BASE_PKGS[@]}"; do
            pkg_installed "$p" && continue
            run pkg_install "$p" || log_warn "pakej '$p' tidak dapat dipasang — diteruskan tanpanya"
        done
    fi

    # Yang ini benar-benar wajib untuk langkah seterusnya.
    local missing=()
    for p in curl tar; do have "$p" || missing+=("$p"); done
    (( ${#missing[@]} == 0 )) || die "Pakej wajib masih tiada: ${missing[*]}. Semak sumber apt anda."

    recheck_timezone
    ensure_cron_running
    log_ok "Pakej asas sedia"
    return 0
}

#===========================================================================
# PHP
#===========================================================================
PHP_EXT_NEEDED=(gd mbstring bcmath curl zip intl pdo_mysql dom)

php_pkg_list() {
    local v="$1" suffix
    for suffix in "" -cli -common -fpm -gd -mysql -mbstring -bcmath -xml -curl -zip -intl; do
        printf 'php%s%s\n' "$v" "$suffix"
    done
}

# Versi PHP yang aktif, atau kosong.
php_active_version() {
    have php || return 1
    php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || return 1
}

verify_php() {
    local v mods e
    v="$(php_active_version)" || return 1
    case "$v" in
        8.2|8.3|8.4) : ;;
        # Termux menghantar satu pakej `php` sahaja — tiada pilihan versi untuk
        # dibuat, jadi menolak apa yang ada bermakna menolak Termux sepenuhnya.
        8.*) is_termux || return 1 ;;
        *)   return 1 ;;
    esac
    mods="$(php -m 2>/dev/null || true)"
    for e in "${PHP_EXT_NEEDED[@]}"; do
        [[ "$mods" == *"$e"* ]] || return 1
    done
    # Debian menamakan binari mengikut versi; Termux tidak.
    if is_termux; then
        have php-fpm || return 1
    else
        [[ -x "/usr/sbin/php-fpm$v" ]] || have "php-fpm$v" || return 1
    fi
    PHP_V="$v"
    state_put php-version "$v"
    return 0
}

STRATEGY_DESC["php_from_configured_repos"]="repo yang sudah dikonfigurasi"
php_from_configured_repos() {
    local v
    for v in 8.3 8.2; do
        if pkg_available "php$v-cli"; then
            # shellcheck disable=SC2046
            pkg_install $(php_pkg_list "$v") && return 0
        fi
    done
    return 1
}

STRATEGY_DESC["php_via_ondrej"]="PPA ondrej/php"
php_via_ondrej() {
    [[ "$OS_ID" == "ubuntu" ]] || return 1
    if have add-apt-repository; then
        add-apt-repository -y ppa:ondrej/php || return 1
    else
        # Tanpa software-properties-common, tulis sumber secara manual.
        mkdir -p /usr/share/keyrings
        curl -fsSL 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x4f4ea0aae5267a6c' \
            | gpg --dearmor -o /usr/share/keyrings/ondrej-php.gpg || return 1
        printf 'deb [signed-by=/usr/share/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu %s main\n' \
            "$OS_CODENAME" >/etc/apt/sources.list.d/ondrej-php.list
    fi
    pkg_update || return 1
    php_from_configured_repos
}

STRATEGY_DESC["php_via_sury"]="repo packages.sury.org"
php_via_sury() {
    mkdir -p /usr/share/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg || return 1
    local suite="$OS_CODENAME"
    [[ -z "$suite" ]] && return 1
    local base="https://packages.sury.org/php/"
    printf 'deb [signed-by=/usr/share/keyrings/sury-php.gpg] %s %s main\n' "$base" "$suite" \
        >/etc/apt/sources.list.d/sury-php.list
    pkg_update || return 1
    php_from_configured_repos
}

STRATEGY_DESC["php_any_available"]="apa-apa PHP 8.x yang ada"
php_any_available() {
    local v
    for v in 8.4 8.1; do
        if pkg_available "php$v-cli"; then
            log_warn "Guna PHP $v — upstream Pterodactyl menyokong 8.2/8.3, jadi ini di luar julat yang diuji"
            # shellcheck disable=SC2046
            pkg_install $(php_pkg_list "$v") && return 0
        fi
    done
    return 1
}

STRATEGY_DESC["php_repair_broken"]="baiki pakej PHP yang separuh terpasang"
php_repair_broken() {
    apt_q --fix-broken install -y -qq || true
    dpkg --configure -a || true
    pkg_update || true
    php_from_configured_repos
}

STRATEGY_DESC["php_termux"]="pakej php + php-fpm Termux"
php_termux() {
    is_termux || return 1
    pkg_install php php-fpm || pkg_install php || return 1
    hash -r 2>/dev/null || true
    verify_php
}

phase_php() {
    if is_termux; then
        attempt "PHP dengan semua sambungan" verify_php php_termux \
            || die "PHP Termux tidak mempunyai semua sambungan yang panel perlukan ($(printf '%s ' "${PHP_EXT_NEEDED[@]}")). Semak dengan: php -m. Repo Termux tidak menyediakan pakej per-sambungan, jadi ini had platform — panel tidak boleh berjalan tanpanya."
        log_ok "PHP $PHP_V sedia (Termux)"
        return 0
    fi

    attempt "PHP 8.2/8.3 dengan semua sambungan" verify_php \
        php_from_configured_repos \
        php_via_ondrej \
        php_via_sury \
        php_repair_broken \
        php_any_available \
        || die "Tidak dapat memasang PHP yang sesuai selepas mencuba repo distro, ondrej, sury dan pembaikan pakej. Semak $LOG_FILE — biasanya ini bermakna sumber apt anda tersekat oleh firewall."

    log_ok "PHP $PHP_V sedia dengan gd, mysql, mbstring, bcmath, xml, curl, zip, intl"
    return 0
}

#===========================================================================
# Composer
#===========================================================================
verify_composer() {
    have composer || return 1
    composer --version >/dev/null 2>&1
}

STRATEGY_DESC["composer_official_installer"]="pemasang rasmi getcomposer.org (dengan semakan checksum)"
composer_official_installer() {
    local tmp; tmp="$(mktemp -d)"
    curl -fsSL --max-time 120 -o "$tmp/installer" https://getcomposer.org/installer || { rm -rf "$tmp"; return 1; }
    local expected actual
    expected="$(curl -fsSL --max-time 30 https://composer.github.io/installer.sig || true)"
    actual="$(php -r "echo hash_file('sha384', '$tmp/installer');" 2>/dev/null || true)"
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
        log_warn "Checksum pemasang Composer tidak sepadan — tolak fail ini"
        rm -rf "$tmp"
        return 1
    fi
    mkdir -p "$BIN_DIR" 2>/dev/null || true
    php "$tmp/installer" --install-dir="$BIN_DIR" --filename=composer
    local rc=$?
    rm -rf "$tmp"
    hash -r 2>/dev/null || true
    return $rc
}

STRATEGY_DESC["composer_phar_direct"]="composer.phar terus daripada getcomposer.org"
composer_phar_direct() {
    mkdir -p "$BIN_DIR" 2>/dev/null || true
    curl -fsSL --max-time 120 -o "$BIN_DIR/composer" https://getcomposer.org/composer-stable.phar || return 1
    chmod +x "$BIN_DIR/composer"
    hash -r 2>/dev/null || true
    composer --version >/dev/null 2>&1
}

STRATEGY_DESC["composer_from_distro"]="pakej composer daripada repo distro"
composer_from_distro() {
    pkg_available composer || return 1
    pkg_install composer
}

phase_composer() {
    attempt "Composer" verify_composer \
        composer_official_installer \
        composer_phar_direct \
        composer_from_distro \
        || die "Tidak dapat memasang Composer. Semak sambungan ke getcomposer.org."
    log_ok "Composer sedia: $(composer --version 2>/dev/null | head -1 || true)"
    return 0
}

#===========================================================================
# Node.js
#===========================================================================
verify_nodejs() {
    have node || return 1
    have npm || return 1
    local major
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    (( major >= 18 )) || return 1
    npm --version >/dev/null 2>&1
}

STRATEGY_DESC["node_via_nodesource"]="skrip persiapan NodeSource"
node_via_nodesource() {
    local major; major="$(cfg NODEJS_MAJOR)"
    # mktemp, bukan nama tetap: /tmp boleh ditulis semua orang, dan fail ini
    # dilaksanakan sebagai root.
    local f; f="$(mktemp)"
    curl -fsSL --max-time 120 "https://deb.nodesource.com/setup_${major}.x" -o "$f" || { rm -f "$f"; return 1; }
    bash "$f" || { rm -f "$f"; return 1; }
    rm -f "$f"
    pkg_install nodejs
}

STRATEGY_DESC["node_from_distro"]="pakej nodejs daripada repo distro"
node_from_distro() {
    pkg_available nodejs || return 1
    pkg_install nodejs npm || pkg_install nodejs || return 1
    verify_nodejs
}

STRATEGY_DESC["node_official_tarball"]="tarball rasmi nodejs.org ke /usr/local"
node_official_tarball() {
    [[ -n "$ARCH_ALT" ]] || return 1
    local major; major="$(cfg NODEJS_MAJOR)"
    # Cari versi terkini dalam baris major itu.
    local ver
    ver="$( { curl -fsSL --max-time 60 https://nodejs.org/dist/index.json \
              | jq -r --arg m "v$major." '[.[] | select(.version | startswith($m))][0].version'; } 2>/dev/null || true )"
    [[ -z "$ver" || "$ver" == "null" ]] && ver="$( { curl -fsSL --max-time 30 https://nodejs.org/dist/latest-v"$major".x/ \
              | grep -oE "node-v$major\.[0-9]+\.[0-9]+-linux" | head -1 | sed 's/node-//;s/-linux//'; } 2>/dev/null || true )"
    [[ -z "$ver" ]] && return 1
    local tgz="node-$ver-linux-$ARCH_ALT.tar.xz"
    curl -fsSL --max-time 300 -o "/tmp/$tgz" "https://nodejs.org/dist/$ver/$tgz" || return 1
    tar -xJf "/tmp/$tgz" -C /usr/local --strip-components=1 \
        --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md || { rm -f "/tmp/$tgz"; return 1; }
    rm -f "/tmp/$tgz"
    hash -r 2>/dev/null || true
    verify_nodejs
}

phase_nodejs() {
    if ! cfg_is INSTALL_NODEJS yes; then
        log_skip "INSTALL_NODEJS=\"no\" — Node.js dilangkau"
        return 0
    fi
    if attempt "Node.js LTS" verify_nodejs \
        node_via_nodesource \
        node_from_distro \
        node_official_tarball
    then
        log_ok "Node.js $(node -v 2>/dev/null || true) dengan npm $(npm -v 2>/dev/null || true)"
    else
        # Node.js tidak diperlukan oleh panel itu sendiri — jangan gagalkan
        # keseluruhan pemasangan keranaya.
        defer_warning "Node.js tidak dapat dipasang selepas mencuba NodeSource, repo distro dan tarball rasmi. Panel tetap berfungsi; pasang manual kemudian jika egg anda memerlukannya."
    fi
    return 0
}

#===========================================================================
# Python
#===========================================================================
verify_python() {
    have python3 || return 1
    local ver
    ver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
    [[ "$ver" =~ ^3\.[0-9]+$ ]] || return 1
    local minor="${ver#3.}"
    (( minor >= 9 )) || return 1
    # venv mesti benar-benar berfungsi — pada Debian/Ubuntu ia pakej berasingan.
    python3 -c 'import venv, ensurepip' >/dev/null 2>&1 || return 1
    return 0
}

STRATEGY_DESC["python_from_distro"]="python3 daripada repo distro"
python_from_distro() {
    pkg_install python3 python3-pip python3-venv python3-dev || \
        pkg_install python3 python3-venv || return 1
    verify_python
}

STRATEGY_DESC["python_full_meta"]="pakej python3-full"
python_full_meta() {
    pkg_available python3-full || return 1
    pkg_install python3-full
}

STRATEGY_DESC["python_via_deadsnakes"]="PPA deadsnakes (Ubuntu)"
python_via_deadsnakes() {
    [[ "$OS_ID" == "ubuntu" ]] || return 1
    have add-apt-repository || return 1
    add-apt-repository -y ppa:deadsnakes/ppa || return 1
    pkg_update || return 1
    local v
    for v in 3.12 3.11 3.10; do
        if pkg_available "python$v"; then
            pkg_install "python$v" "python$v-venv" "python$v-dev" || continue
            return 0
        fi
    done
    return 1
}

phase_python() {
    if ! cfg_is INSTALL_PYTHON yes; then
        log_skip "INSTALL_PYTHON=\"no\" — Python dilangkau"
        return 0
    fi
    if attempt "Python 3 dengan pip dan venv" verify_python \
        python_from_distro \
        python_full_meta \
        python_via_deadsnakes
    then
        log_ok "Python $(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || true) dengan venv"
        # PEP 668: pada Ubuntu 23.04+/Debian 12+, pip system-wide ditolak.
        # Jangan lawan dasar itu — sediakan pipx supaya alat boleh dipasang
        # tanpa merosakkan pakej sistem.
        local marker="" d
        for d in /usr/lib/python3*/EXTERNALLY-MANAGED; do
            [[ -f "$d" ]] && { marker="$d"; break; }
        done
        if [[ -n "$marker" ]]; then
            pkg_available pipx && run pkg_install pipx || true
            log_info "Python ini externally-managed (PEP 668) — guna venv atau pipx untuk pasang pakej, jangan pip system-wide"
        fi
    else
        defer_warning "Python 3 tidak dapat dipasang sepenuhnya. Panel tetap berfungsi tanpanya."
    fi
    return 0
}

#===========================================================================
# MariaDB
#===========================================================================
verify_db_server() {
    mariadb -e "SELECT 1" >/dev/null 2>&1 || mysql -e "SELECT 1" >/dev/null 2>&1
}

db_cli() {
    if have mariadb; then mariadb "$@"; else mysql "$@"; fi
}

STRATEGY_DESC["db_install_mariadb"]="mariadb-server daripada repo distro"
db_install_mariadb() {
    if ! have mariadbd && ! have mysqld; then
        pkg_install mariadb-server mariadb-client || return 1
    fi
    db_start_server
}

STRATEGY_DESC["db_install_mysql"]="mysql-server sebagai ganti"
db_install_mysql() {
    pkg_available mysql-server || return 1
    pkg_install mysql-server || return 1
    db_start_server
}

# Pada Debian, postinst pakej mencipta jadual sistem. Termux tidak mempunyai
# postinst yang berbuat demikian, jadi mariadbd bermula, tidak menjumpai
# direktori data, dan mati serta-merta dengan ralat yang tidak menyebut sebabnya.
db_init_datadir_if_needed() {
    is_termux || return 0
    local datadir="$TERMUX_PREFIX/var/lib/mysql"
    [[ -d "$datadir/mysql" ]] && return 0
    if have mariadb-install-db; then
        run mariadb-install-db --auth-root-authentication-method=normal || \
            run mariadb-install-db || return 1
    elif have mysql_install_db; then
        run mysql_install_db || return 1
    else
        return 1
    fi
    return 0
}

db_start_server() {
    mkdir -p /run/mysqld /var/run/mysqld 2>/dev/null || true
    chown mysql:mysql /run/mysqld 2>/dev/null || true
    db_init_datadir_if_needed || log_warn "Direktori data MariaDB tidak dapat dimulakan"

    local unit="mariadb"
    [[ -f /lib/systemd/system/mysql.service || -f /usr/lib/systemd/system/mysql.service ]] && unit="mysql"
    # `--user=mysql` betul apabila kita root dan pengguna itu wujud. Pada Termux
    # tiada pengguna `mysql` dan kita bukan root — bendera itu menghalang start.
    local -a safe_args=()
    [[ -n "$(db_safe_args)" ]] && safe_args=(--user=mysql)
    if have mariadbd-safe; then
        svc_up "$unit" mariadbd mariadbd-safe ${safe_args[@]+"${safe_args[@]}"}
    elif have mysqld_safe; then
        svc_up "$unit" mysqld mysqld_safe ${safe_args[@]+"${safe_args[@]}"}
    else
        svc_up "$unit" mysqld
    fi
    wait_for 60 verify_db_server
}

STRATEGY_DESC["db_reset_socket_dir"]="cipta semula direktori socket dan mula semula"
db_reset_socket_dir() {
    mkdir -p /run/mysqld 2>/dev/null && chown mysql:mysql /run/mysqld 2>/dev/null || true
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true
    fi
    db_start_server
}

# `mariadb -pRAHSIA` menampakkan password dalam `ps` kepada setiap pengguna pada
# mesin ini. Tulis ia ke fail 0600 sementara dan biar klien membacanya dari situ.
verify_db_credentials() {
    local cnf rc
    cnf="$(mktemp)"
    chmod 600 "$cnf"
    {
        printf '[client]\n'
        printf 'user=%s\n' "$(cfg DB_USERNAME)"
        printf 'password=%s\n' "$(cfg DB_PASSWORD)"
        printf 'host=%s\n' "$(cfg DB_HOST)"
        printf 'port=%s\n' "$(cfg DB_PORT)"
    } >"$cnf"
    db_cli --defaults-extra-file="$cnf" -D"$(cfg DB_NAME)" -e "SELECT 1" >/dev/null 2>&1
    rc=$?
    rm -f "$cnf"
    return $rc
}

STRATEGY_DESC["db_grant_both_hosts"]="cipta akaun untuk 127.0.0.1 dan localhost"
db_grant_both_hosts() {
    local db user pass host h
    db="$(cfg DB_NAME)"; user="$(cfg DB_USERNAME)"
    pass="$(cfg DB_PASSWORD)"; host="$(cfg DB_HOST)"

    # Password yang dijana hanya alnum, tetapi password daripada fail config
    # boleh mengandungi petik — escape sebelum ia masuk ke dalam SQL.
    local epass; epass="$(sql_escape "$pass")"
    db_cli -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || return 1

    # MariaDB memadankan akaun ikut hos yang DISELESAIKAN, bukan yang ditaip.
    # Sambungan TCP ke 127.0.0.1 kerap reverse-resolve menjadi "localhost", jadi
    # akaun '...'@'127.0.0.1' sahaja akan menolaknya dengan "Access denied".
    local -a hosts=("$host")
    case "$host" in
        127.0.0.1|localhost|::1) hosts=(127.0.0.1 localhost) ;;
    esac
    for h in "${hosts[@]}"; do
        db_cli <<SQL || return 1
CREATE USER IF NOT EXISTS '$user'@'$h' IDENTIFIED BY '$epass';
ALTER USER '$user'@'$h' IDENTIFIED BY '$epass';
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$user'@'$h' WITH GRANT OPTION;
SQL
    done
    db_cli -e "FLUSH PRIVILEGES;" || return 1
    return 0
}

STRATEGY_DESC["db_grant_native_password"]="cipta akaun dengan mysql_native_password"
db_grant_native_password() {
    # Hanya bermakna pada MySQL; MariaDB tidak menggunakan caching_sha2_password.
    local ver; ver="$(db_cli -sN -e 'SELECT VERSION()' 2>/dev/null || true)"
    [[ "$ver" == *MariaDB* ]] && return 1
    # MySQL 8.4 membuang plugin ini sepenuhnya — jangan cuba di situ.
    case "$ver" in
        8.4*|9.*) return 1 ;;
    esac
    local db user pass h
    db="$(cfg DB_NAME)"; user="$(cfg DB_USERNAME)"; pass="$(sql_escape "$(cfg DB_PASSWORD)")"
    for h in 127.0.0.1 localhost; do
        db_cli <<SQL || return 1
CREATE USER IF NOT EXISTS '$user'@'$h' IDENTIFIED WITH mysql_native_password BY '$pass';
ALTER USER '$user'@'$h' IDENTIFIED WITH mysql_native_password BY '$pass';
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$user'@'$h' WITH GRANT OPTION;
SQL
    done
    db_cli -e "FLUSH PRIVILEGES;" || return 1
    return 0
}

STRATEGY_DESC["db_grant_wildcard"]="cipta akaun dengan hos '%'"
db_grant_wildcard() {
    local db user pass
    db="$(cfg DB_NAME)"; user="$(cfg DB_USERNAME)"; pass="$(sql_escape "$(cfg DB_PASSWORD)")"
    db_cli <<SQL
CREATE USER IF NOT EXISTS '$user'@'%' IDENTIFIED BY '$pass';
ALTER USER '$user'@'%' IDENTIFIED BY '$pass';
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$user'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

phase_mariadb() {
    attempt "Pelayan pangkalan data berjalan" verify_db_server \
        db_install_mariadb \
        db_reset_socket_dir \
        db_install_mysql \
        || die "Pelayan pangkalan data tidak mahu start. Semak: journalctl -u mariadb -n 50 (atau -u mysql)"

    log_ok "Pangkalan data: $(db_cli -sN -e 'SELECT VERSION()' 2>/dev/null || true)"

    attempt "Akaun pangkalan data panel boleh log masuk" verify_db_credentials \
        db_grant_both_hosts \
        db_grant_native_password \
        db_grant_wildcard \
        || die "Akaun '$(cfg DB_USERNAME)' dicipta tetapi tidak boleh log masuk ke '$(cfg DB_NAME)'. Semak: $(have mariadb && printf mariadb || printf mysql) -u$(cfg DB_USERNAME) -p -h$(cfg DB_HOST) $(cfg DB_NAME)"

    log_ok "Pangkalan data '$(cfg DB_NAME)' dan pengguna '$(cfg DB_USERNAME)' sedia (log masuk diuji)"
    return 0
}

#===========================================================================
# Redis
#===========================================================================
verify_redis() {
    local port pass out
    port="$(cfg REDIS_PORT)"; pass="$(cfg REDIS_PASSWORD)"
    if [[ -n "$pass" ]]; then
        out="$(REDISCLI_AUTH="$pass" redis-cli -p "$port" ping 2>/dev/null || true)"
    else
        out="$(redis-cli -p "$port" ping 2>/dev/null || true)"
    fi
    [[ "$out" == "PONG" ]]
}

# Bila pengguna menetapkan REDIS_PASSWORD, ia mesti dikuatkuasakan pada pelayan
# juga — jika tidak panel menghantar AUTH ke pelayan tanpa password dan setiap
# permintaan gagal.
redis_server_args() {
    printf -- '--port %s' "$(cfg REDIS_PORT)"
    [[ -n "$(cfg REDIS_PASSWORD)" ]] && printf -- ' --requirepass %s' "$(cfg REDIS_PASSWORD)"
    return 0
}

STRATEGY_DESC["redis_install_and_start"]="redis-server daripada repo distro"
redis_install_and_start() {
    have redis-server || pkg_install redis-server redis-tools || pkg_install redis-server || return 1
    if [[ -n "$(cfg REDIS_PASSWORD)" ]]; then
        # svc_up mungkin menyerahkan kepada systemd, yang membaca fail config —
        # jadi tuliskan password ke situ juga, bukan hanya ke argumen.
        printf 'requirepass %s\n' "$(cfg REDIS_PASSWORD)" >/etc/redis/redis.conf.d-ptero.conf 2>/dev/null || true
        if [[ -d /etc/redis ]]; then
            grep -q '^requirepass' /etc/redis/redis.conf 2>/dev/null \
                || printf 'requirepass %s\n' "$(cfg REDIS_PASSWORD)" >>/etc/redis/redis.conf 2>/dev/null || true
            chmod 640 /etc/redis/redis.conf 2>/dev/null || true
        fi
    fi
    # shellcheck disable=SC2046
    svc_up redis-server redis-server redis-server $(redis_server_args)
    wait_for 30 verify_redis
}

STRATEGY_DESC["redis_start_foreground"]="lancarkan redis-server terus"
redis_start_foreground() {
    pkill -x redis-server 2>/dev/null || true
    sleep 1
    # shellcheck disable=SC2046
    setsid nohup redis-server $(redis_server_args) --daemonize no \
        >>"$LOG_FILE" 2>&1 </dev/null &
    disown 2>/dev/null || true
    wait_for 30 verify_redis
}

phase_redis() {
    if attempt "Redis" verify_redis redis_install_and_start redis_start_foreground; then
        log_ok "Redis menjawab pada port $(cfg REDIS_PORT)"
        return 0
    fi
    # Redis boleh digantikan — panel berfungsi dengan cache/session berasaskan fail.
    defer_warning "Redis tidak dapat dijalankan. Panel akan dikonfigurasi menggunakan cache/session/queue berasaskan fail dan pangkalan data — lebih perlahan tetapi berfungsi."
    CFG[_REDIS_FALLBACK]="yes"
    return 0
}
