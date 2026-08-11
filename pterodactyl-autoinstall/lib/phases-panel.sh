#!/usr/bin/env bash
#############################################################################
#  phases-panel.sh — fail panel, .env, migrasi, admin, nginx, SSL, service
#############################################################################

[[ -n "${_PTERO_PANEL_LOADED:-}" ]] && return 0
_PTERO_PANEL_LOADED=1

#===========================================================================
# Muat turun panel
#===========================================================================
verify_panel_files() {
    [[ -f "$PANEL_DIR/artisan" && -f "$PANEL_DIR/composer.json" ]]
}

# Jangan sekali-kali extract arkib yang tidak lengkap — itu menghasilkan
# pemasangan separuh yang sukar didiagnosis. Uji dulu.
_extract_panel_tarball() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    tar -tzf "$f" >/dev/null 2>&1 || { log_warn "Arkib rosak atau tidak lengkap — tolak"; rm -f "$f"; return 1; }
    mkdir -p "$PANEL_DIR"
    tar -xzf "$f" -C "$PANEL_DIR" || return 1
    rm -f "$f"
    verify_panel_files
}

STRATEGY_DESC["panel_dl_curl"]="muat turun keluaran terkini dengan curl"
panel_dl_curl() {
    local f; f="$(mktemp)"
    curl -fsSL --max-time 300 --retry 3 --retry-delay 2 -o "$f" "$PANEL_TARBALL" || { rm -f "$f"; return 1; }
    _extract_panel_tarball "$f"
}

STRATEGY_DESC["panel_dl_wget"]="muat turun dengan wget"
panel_dl_wget() {
    have wget || return 1
    local f; f="$(mktemp)"
    wget -q --tries=3 --timeout=60 -O "$f" "$PANEL_TARBALL" || { rm -f "$f"; return 1; }
    _extract_panel_tarball "$f"
}

STRATEGY_DESC["panel_dl_pinned"]="muat turun versi tetap yang diketahui baik"
panel_dl_pinned() {
    # Bila "latest" tidak dapat diselesaikan (redirect tersekat, API dihadkan),
    # ambil versi tetap yang memang wujud.
    local v f
    for v in v1.15.0 v1.11.11; do
        f="$(mktemp)"
        if curl -fsSL --max-time 300 -o "$f" \
            "https://github.com/pterodactyl/panel/releases/download/$v/panel.tar.gz"; then
            log_info "Guna versi tetap $v kerana 'latest' tidak dapat diambil"
            _extract_panel_tarball "$f" && return 0
        fi
        rm -f "$f"
    done
    return 1
}

#===========================================================================
# Composer install
#===========================================================================
verify_vendor() {
    [[ -f "$PANEL_DIR/vendor/autoload.php" ]] || return 1
    # autoload yang ada tetapi tidak lengkap tetap memecahkan panel.
    [[ -d "$PANEL_DIR/vendor/laravel/framework" ]] || return 1
    return 0
}

_composer_run() {
    ( cd "$PANEL_DIR" && COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1 \
        composer "$@" --no-interaction >>"$LOG_FILE" 2>&1 )
}

STRATEGY_DESC["composer_install_plain"]="composer install --no-dev"
composer_install_plain() {
    if [[ -n "$(cfg GITHUB_TOKEN)" ]]; then
        COMPOSER_ALLOW_SUPERUSER=1 composer config --global --no-interaction \
            github-oauth.github.com "$(cfg GITHUB_TOKEN)" >>"$LOG_FILE" 2>&1 || true
    fi
    _composer_run install --no-dev --optimize-autoloader
}

STRATEGY_DESC["composer_install_prefer_source"]="composer install --prefer-source (guna git, elak had kadar dist GitHub)"
composer_install_prefer_source() {
    have git || apt_install git || return 1
    _composer_run install --no-dev --optimize-autoloader --prefer-source
}

STRATEGY_DESC["composer_install_ignore_platform"]="composer install --ignore-platform-req=php"
composer_install_ignore_platform() {
    # composer.json Pterodactyl mengunci PHP ^8.2||^8.3. Kalau hos hanya ada
    # 8.4 (atau 8.1), pemasangan ditolak walaupun kod itu sendiri berjalan.
    _composer_run install --no-dev --optimize-autoloader --ignore-platform-req=php
}

STRATEGY_DESC["composer_clear_cache_retry"]="kosongkan cache composer dan cuba semula"
composer_clear_cache_retry() {
    COMPOSER_ALLOW_SUPERUSER=1 composer clear-cache >>"$LOG_FILE" 2>&1 || true
    rm -rf "$PANEL_DIR/vendor" 2>/dev/null || true
    _composer_run install --no-dev --optimize-autoloader
}

# Adakah ini pemasangan yang sudah hidup, bukan direktori kosong?
existing_panel_present() {
    [[ -f "$PANEL_DIR/artisan" && -f "$PANEL_DIR/.env" ]] || return 1
    db_cli -sN -D"$(cfg DB_NAME)" -e "SELECT COUNT(*) FROM migrations" >/dev/null 2>&1
}

phase_panel_files() {
    # Menulis fail panel di atas pemasangan yang sedang hidup adalah operasi
    # yang merosakkan. Ambil backup dahulu supaya ada jalan pulang.
    if existing_panel_present; then
        log_warn "Pemasangan panel sedia ada dikesan di $PANEL_DIR"
        if backup_now pre-install; then
            log_ok "Backup diambil sebelum menyentuh apa-apa"
        else
            defer_warning "Backup pemasangan sedia ada GAGAL. Fail panel akan ditulis ganti tanpa jaring — batalkan sekarang kalau data itu penting."
            confirm "Teruskan tanpa backup?" || die "Dibatalkan. Betulkan backup dahulu, atau guna --upgrade."
        fi
    fi

    # Panel ~150MB, vendor ~250MB, cache composer ~300MB, ruang kerja tar.
    local free; free="$(disk_mb)"
    if (( free < 1536 )); then
        die "Ruang kosong pada / hanya ${free}MB. Muat turun dan composer memerlukan sekurang-kurangnya 1.5GB, dan disk yang penuh separuh jalan meninggalkan pemasangan yang rosak. Kosongkan ruang dahulu."
    fi

    attempt "Fail panel" verify_panel_files \
        panel_dl_curl panel_dl_wget panel_dl_pinned \
        || die "Tidak dapat memuat turun panel. Semak sambungan ke github.com."

    # 750, bukan 755: storage/logs mengandungi jejak ralat Laravel yang boleh
    # membocorkan maklumat, dan hanya www-data perlu membacanya.
    chown -R www-data:www-data "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
    chmod -R 750 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true

    # Composer menyusun keseluruhan graf kebergantungan dalam ingatan. Pada VPS
    # 1GB tanpa swap, kernel membunuhnya dan mesejnya hanya "Killed" — tiada
    # petunjuk bahawa ingatan puncanya.
    ensure_temp_swap 2048 || true

    if ! attempt "Kebergantungan PHP panel (composer)" verify_vendor \
        composer_install_plain \
        composer_install_prefer_source \
        composer_install_ignore_platform \
        composer_clear_cache_retry
    then
        # Punca paling biasa, dan satu-satunya yang perlukan tindakan manusia.
        if log_has 'Could not authenticate against github.com' 400 || log_has 'API rate limit' 400; then
            log_err "GitHub menghadkan muat turun tanpa token, dan fallback --prefer-source juga gagal."
            log_err "Jana token di https://github.com/settings/tokens (tiada skop diperlukan),"
            log_err "kemudian jalankan semula dengan: --github-token ghp_xxxxx"
        fi
        if log_has 'Killed' 200 || log_has 'Out of memory' 200 || log_has 'Allowed memory size' 200; then
            log_err "Composer dibunuh kerana kehabisan ingatan."
            log_err "Tambah swap kekal pada server ini, kemudian jalankan semula:"
            log_err "  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
            log_err "  echo '/swapfile none swap sw 0 0' >> /etc/fstab"
        fi
        cleanup_temp_swap
        die "Composer tidak dapat memasang kebergantungan panel. Semak $LOG_FILE"
    fi
    cleanup_temp_swap

    local ver
    ver="$( { grep -oE "'version' => '[^']+'" "$PANEL_DIR/config/app.php" | head -1; } 2>/dev/null || true )"
    log_ok "Panel dipasang di $PANEL_DIR ${ver:+($ver)}"
    return 0
}

#===========================================================================
# .env dan migrasi
#===========================================================================
# Tetapkan kunci dalam .env. Guna awk, bukan sed, supaya nilai yang mengandungi
# / & | tidak merosakkan gantian.
env_set() {
    local key="$1" val="$2" f="$PANEL_DIR/.env"
    touch "$f"
    # Command substitution membuang newline di hujung, jadi `$(tail -c1)` bagi
    # fail yang memang berakhir dengan newline menghasilkan "" — ujian
    # `"" != $'\n'` sentiasa benar dan satu baris kosong ditambah setiap kali.
    # Tangkapan yang TIDAK kosong bermakna bait terakhir bukan newline.
    if [[ -s "$f" && -n "$(tail -c1 "$f")" ]]; then
        printf '\n' >>"$f"
    fi
    if grep -qE "^${key}=" "$f"; then
        awk -v k="$key" -v v="$val" 'BEGIN { FS = "=" } { if ($1 == k) print k "=" v; else print }' \
            "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    else
        printf '%s=%s\n' "$key" "$val" >>"$f"
    fi
    return 0
}

art() { ( cd "$PANEL_DIR" && run php artisan "$@" ); }
art_out() { ( cd "$PANEL_DIR" && php artisan "$@" 2>>"$LOG_FILE" ); }

panel_url() {
    # Di belakang proxy, pengguna melihat skema dan port PROXY, bukan yang
    # didengari nginx di sini. APP_URL mesti sepadan dengan apa yang dilihat
    # pelayar — kalau tidak, aset dimuatkan melalui http pada halaman https
    # (pelayar menyekatnya) dan sesi hilang pada setiap permintaan.
    if cfg_is BEHIND_PROXY yes; then
        printf '%s://%s' "$(cfg PROXY_SCHEME)" "$(cfg PANEL_FQDN)"
        return 0
    fi
    local scheme; cfg_is PANEL_SSL yes && scheme=https || scheme=http
    local url="$scheme://$(cfg PANEL_FQDN)"
    local p; p="$(cfg PANEL_HTTP_PORT)"
    [[ "$p" != "80" && "$p" != "443" ]] && url="$url:$p"
    printf '%s' "$url"
}

verify_migrated() {
    db_cli -sN -D"$(cfg DB_NAME)" -e "SELECT COUNT(*) FROM migrations" >/dev/null 2>&1
}

STRATEGY_DESC["panel_migrate_seed"]="php artisan migrate --seed"
panel_migrate_seed() { art migrate --seed --force; }

STRATEGY_DESC["panel_migrate_then_seed"]="migrate dahulu, seed berasingan"
panel_migrate_then_seed() {
    art migrate --force || return 1
    art db:seed --force
}

phase_panel_env() {
    [[ -f "$PANEL_DIR/.env" ]] || cp "$PANEL_DIR/.env.example" "$PANEL_DIR/.env"
    # .env memegang APP_KEY dan password pangkalan data. .env.example datang
    # dengan 0644, jadi kunci sebelum apa-apa rahsia ditulis ke dalamnya.
    chown www-data:www-data "$PANEL_DIR/.env" 2>/dev/null || true
    chmod 600 "$PANEL_DIR/.env" 2>/dev/null || true
    grep -qE '^APP_KEY=base64:' "$PANEL_DIR/.env" || art key:generate --force

    # Kalau Redis tidak dapat dijalankan, jangan konfigurasi panel untuk
    # menggunakannya — panel akan crash pada setiap permintaan.
    local drv_cache drv_session drv_queue
    if cfg_is _REDIS_FALLBACK yes; then
        drv_cache="file"; drv_session="file"; drv_queue="database"
    else
        drv_cache="redis"; drv_session="redis"; drv_queue="redis"
    fi

    art p:environment:setup \
        --author="$(cfg ADMIN_EMAIL)" \
        --url="$(panel_url)" \
        --timezone="$(cfg PANEL_TIMEZONE)" \
        --cache="$drv_cache" --session="$drv_session" --queue="$drv_queue" \
        --redis-host="$(cfg REDIS_HOST)" \
        --redis-port="$(cfg REDIS_PORT)" \
        --redis-pass="$(cfg REDIS_PASSWORD)" \
        --settings-ui=true --no-interaction || true

    art p:environment:database \
        --host="$(cfg DB_HOST)" --port="$(cfg DB_PORT)" \
        --database="$(cfg DB_NAME)" --username="$(cfg DB_USERNAME)" \
        --password="$(cfg DB_PASSWORD)" --no-interaction \
        || die "Panel menolak kelayakan pangkalan data walaupun log masuk manual berjaya. Semak $LOG_FILE"

    if cfg_is MAIL_DRIVER smtp; then
        art p:environment:mail --driver=smtp \
            --host="$(cfg MAIL_HOST)" --port="$(cfg MAIL_PORT)" \
            --username="$(cfg MAIL_USERNAME)" --password="$(cfg MAIL_PASSWORD)" \
            --email="$(cfg MAIL_FROM)" --from="$(cfg MAIL_FROM_NAME)" \
            --encryption="$(cfg MAIL_ENCRYPTION)" --no-interaction \
            || defer_warning "Konfigurasi SMTP gagal — panel ditetapkan kepada pemacu 'log' supaya pemasangan boleh diteruskan."
    else
        env_set MAIL_MAILER log
    fi

    env_set APP_URL "$(panel_url)"
    if cfg_is BEHIND_PROXY yes; then
        # Tanpa ini Laravel melihat setiap permintaan sebagai http dan datang
        # dari IP proxy: redirect salah skema, dan rate limiting mengira semua
        # pengguna sebagai satu.
        env_set TRUSTED_PROXIES "$(cfg TRUSTED_PROXIES)"
        log_info "Panel dikonfigurasi untuk berada di belakang proxy ($(cfg PROXY_SCHEME)), TRUSTED_PROXIES=$(cfg TRUSTED_PROXIES)"
    fi
    env_set PTERODACTYL_TELEMETRY_ENABLED "$( cfg_is PANEL_TELEMETRY yes && printf true || printf false )"
    if cfg_is RECAPTCHA_ENABLED yes; then
        env_set RECAPTCHA_ENABLED true
        env_set RECAPTCHA_WEBSITE_KEY "$(cfg RECAPTCHA_SITE_KEY)"
        env_set RECAPTCHA_SECRET_KEY "$(cfg RECAPTCHA_SECRET_KEY)"
    else
        # Middleware reCAPTCHA panel crash dengan TypeError bila tiada token
        # dan tiada domain, jadi matikan ia secara jelas.
        env_set RECAPTCHA_ENABLED false
    fi

    art config:clear || true

    log_info "Menjalankan migrasi dan seeder (semua egg rasmi dipasang di sini)..."
    attempt "Skema pangkalan data dan egg rasmi" verify_migrated \
        panel_migrate_seed panel_migrate_then_seed \
        || die "Migrasi pangkalan data gagal. Semak $LOG_FILE"

    local eggs; eggs="$(db_cli -sN -D"$(cfg DB_NAME)" -e 'SELECT COUNT(*) FROM eggs' 2>/dev/null || printf '0')"
    log_ok "Skema sedia — $eggs egg rasmi dipasang"
    return 0
}

#===========================================================================
# Akaun admin
#===========================================================================
verify_admin_exists() {
    local n
    n="$(db_cli -sN -D"$(cfg DB_NAME)" -e \
        "SELECT COUNT(*) FROM users WHERE root_admin = 1" 2>/dev/null || printf '0')"
    [[ "$n" != "0" ]]
}

STRATEGY_DESC["admin_make"]="p:user:make"
admin_make() {
    local exists
    exists="$(db_cli -sN -D"$(cfg DB_NAME)" -e \
        "SELECT COUNT(*) FROM users WHERE email='$(sql_escape "$(cfg ADMIN_EMAIL)")' OR username='$(sql_escape "$(cfg ADMIN_USERNAME)")'" 2>/dev/null || printf '0')"
    if [[ "$exists" != "0" ]]; then
        # Sudah ada daripada run sebelumnya — naikkan ke admin kalau perlu.
        db_cli -D"$(cfg DB_NAME)" -e \
            "UPDATE users SET root_admin = 1 WHERE email='$(sql_escape "$(cfg ADMIN_EMAIL)")'" 2>/dev/null || true
        return 0
    fi
    art p:user:make \
        --email="$(cfg ADMIN_EMAIL)" --username="$(cfg ADMIN_USERNAME)" \
        --name-first="$(cfg ADMIN_FIRST_NAME)" --name-last="$(cfg ADMIN_LAST_NAME)" \
        --password="$(cfg ADMIN_PASSWORD)" --admin=1 --no-interaction
}

phase_panel_admin() {
    attempt "Akaun admin" verify_admin_exists admin_make \
        || die "Tidak dapat mencipta akaun admin. Semak $LOG_FILE"
    log_ok "Admin '$(cfg ADMIN_USERNAME)' sedia"
    return 0
}

#===========================================================================
# Pelayan web
#===========================================================================
php_fpm_socket() {
    local s
    for s in "/run/php/php$PHP_V-fpm.sock" "/var/run/php/php$PHP_V-fpm.sock" \
             "/run/php-fpm/www.sock" "/run/php/php-fpm.sock"; do
        [[ -S "$s" ]] && { printf '%s' "$s"; return 0; }
    done
    # Belum wujud kerana php-fpm belum start — guna laluan yang dijangka.
    printf '/run/php/php%s-fpm.sock' "$PHP_V"
    return 0
}

start_php_fpm() {
    mkdir -p /run/php 2>/dev/null || true
    svc_up "php$PHP_V-fpm" "php-fpm$PHP_V" "php-fpm$PHP_V" --nodaemonize
    wait_for 20 test -S "$(php_fpm_socket)"
    return 0
}

write_nginx_conf() {
    local port="$1" sock listen6=""
    sock="$(php_fpm_socket)"
    # Banyak VPS mematikan IPv6 sepenuhnya; "listen [::]" akan menyebabkan
    # nginx gagal start terus pada sistem begitu.
    [[ "$HAS_IPV6" == "yes" ]] && listen6="    listen [::]:$port;"

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
        fastcgi_pass unix:$sock;
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
    mkdir -p /etc/nginx/sites-enabled
    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
    rm -f /etc/nginx/sites-enabled/default
    return 0
}

# Port yang nginx patut dengar sekarang. Certbot akan menambah 443 sendiri,
# jadi semasa pemasangan awal SSL kita mula pada port 80.
nginx_listen_port() {
    if cfg_is PANEL_SSL yes; then printf '80'; else printf '%s' "$(cfg PANEL_HTTP_PORT)"; fi
}

verify_webserver() {
    local port; port="$(nginx_listen_port)"
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
            "http://127.0.0.1:$port/auth/login" 2>/dev/null || printf '000')"
    [[ "$code" =~ ^(200|301|302)$ ]]
}

STRATEGY_DESC["web_nginx"]="nginx + PHP-FPM"
web_nginx() {
    have nginx || apt_install nginx || return 1
    chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || true
    start_php_fpm
    write_nginx_conf "$(nginx_listen_port)"
    nginx -t >>"$LOG_FILE" 2>&1 || return 1
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        systemctl enable nginx >>"$LOG_FILE" 2>&1 || true
        systemctl restart nginx >>"$LOG_FILE" 2>&1 || return 1
    else
        if pgrep -x nginx >/dev/null 2>&1; then nginx -s reload; else nginx; fi
    fi
    wait_for 15 verify_webserver
}

STRATEGY_DESC["web_nginx_no_ipv6"]="nginx tanpa listener IPv6"
web_nginx_no_ipv6() {
    HAS_IPV6="no"
    web_nginx
}

STRATEGY_DESC["web_nginx_alt_port"]="nginx pada port ganti"
web_nginx_alt_port() {
    local alt; alt="$(next_free_port 8080 || printf '')"
    [[ -z "$alt" ]] && return 1
    log_warn "Port $(nginx_listen_port) tidak dapat diikat — tukar panel ke port $alt"
    CFG[PANEL_HTTP_PORT]="$alt"
    CFG[PANEL_SSL]="no"
    defer_warning "Panel dipindahkan ke port $alt kerana port asal tidak dapat diikat. URL panel: $(panel_url)"
    env_set APP_URL "$(panel_url)" 2>/dev/null || true
    web_nginx
}

STRATEGY_DESC["web_apache"]="Apache + mod_proxy_fcgi"
web_apache() {
    apt_available apache2 || return 1
    apt_install apache2 || return 1
    a2enmod proxy_fcgi setenvif rewrite >>"$LOG_FILE" 2>&1 || true
    a2enconf "php$PHP_V-fpm" >>"$LOG_FILE" 2>&1 || true
    start_php_fpm
    local port; port="$(nginx_listen_port)"
    cat >/etc/apache2/sites-available/pterodactyl.conf <<APACHE
<VirtualHost *:$port>
    ServerName $(cfg PANEL_FQDN)
    DocumentRoot "$PANEL_DIR/public"
    AllowEncodedSlashes On
    <Directory "$PANEL_DIR/public">
        Require all granted
        AllowOverride all
    </Directory>
    <FilesMatch \\.php\$>
        SetHandler "proxy:unix:$(php_fpm_socket)|fcgi://localhost/"
    </FilesMatch>
</VirtualHost>
APACHE
    grep -qE "^Listen $port\$" /etc/apache2/ports.conf || printf 'Listen %s\n' "$port" >>/etc/apache2/ports.conf
    a2dissite 000-default >>"$LOG_FILE" 2>&1 || true
    a2ensite pterodactyl >>"$LOG_FILE" 2>&1 || return 1
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then
        systemctl restart apache2 >>"$LOG_FILE" 2>&1 || return 1
    else
        apachectl -k restart >>"$LOG_FILE" 2>&1 || apachectl start >>"$LOG_FILE" 2>&1 || return 1
    fi
    wait_for 15 verify_webserver
}

phase_webserver() {
    # Kalau Apache sudah memegang port itu dan sedang berjalan, melawannya
    # dengan nginx bermakna salah satu daripadanya tidak akan bermula. Lebih
    # baik guna yang sudah ada di situ.
    local owner; owner="$(port_owner "$(nginx_listen_port)")"
    if [[ "$owner" == *apache* ]] || { [[ "$owner" == *httpd* ]] && ! have nginx; }; then
        log_info "Apache sedang memegang port $(nginx_listen_port) — konfigurasikan Apache dan bukannya nginx"
        attempt "Panel disajikan melalui HTTP" verify_webserver \
            web_apache \
            web_nginx \
            web_nginx_alt_port \
            || die "Tiada pelayan web yang dapat menyajikan panel. Semak $LOG_FILE"
        log_ok "Panel disajikan pada port $(nginx_listen_port)"
        return 0
    fi

    attempt "Panel disajikan melalui HTTP" verify_webserver \
        web_nginx \
        web_nginx_no_ipv6 \
        web_nginx_alt_port \
        web_apache \
        || die "Tiada pelayan web yang dapat menyajikan panel. Semak /var/log/nginx/pterodactyl.error.log dan $LOG_FILE"
    log_ok "Panel disajikan pada port $(nginx_listen_port)"
    return 0
}

#===========================================================================
# SSL — kegagalan di sini TIDAK menggagalkan pemasangan
#===========================================================================
# Sijil yang wujud TIDAK cukup. phase_webserver menulis semula vhost daripada
# templat HTTP, jadi pada run --force suntingan certbot (listen 443 ssl, laluan
# sijil, redirect) hilang sedangkan folder sijil masih ada. Kalau kita hanya
# semak folder itu, fasa ini akan dilangkau dan HTTPS mati tanpa sesiapa sedar.
# Sebab itu vhost sendiri mesti disemak juga.
verify_ssl_cert() {
    [[ -d "/etc/letsencrypt/live/$(cfg PANEL_FQDN)" ]] || return 1
    local vhost
    for vhost in /etc/nginx/sites-available/pterodactyl.conf \
                 /etc/apache2/sites-available/pterodactyl.conf; do
        [[ -f "$vhost" ]] || continue
        grep -qE 'ssl_certificate|SSLCertificateFile' "$vhost" && return 0
    done
    return 1
}

STRATEGY_DESC["ssl_reinstall_existing"]="pasang semula sijil yang sudah ada ke dalam vhost"
ssl_reinstall_existing() {
    [[ -d "/etc/letsencrypt/live/$(cfg PANEL_FQDN)" ]] || return 1
    have certbot || return 1
    # Sijil masih sah — cuma vhost yang perlu disuntik semula. 'certbot install'
    # melakukan itu tanpa cuba memperbaharui sijil (yang akan gagal dalam mod
    # non-interactive bila sijil belum tiba masa renew).
    certbot install --cert-name "$(cfg PANEL_FQDN)" --nginx --non-interactive >>"$LOG_FILE" 2>&1
}

STRATEGY_DESC["ssl_certbot_nginx"]="certbot dengan plugin nginx"
ssl_certbot_nginx() {
    have certbot || apt_install certbot python3-certbot-nginx || return 1
    certbot --nginx -d "$(cfg PANEL_FQDN)" --non-interactive --agree-tos \
        --redirect -m "$(cfg SSL_EMAIL)" >>"$LOG_FILE" 2>&1
}

STRATEGY_DESC["ssl_certbot_webroot"]="certbot mod webroot"
ssl_certbot_webroot() {
    have certbot || return 1
    certbot certonly --webroot -w "$PANEL_DIR/public" -d "$(cfg PANEL_FQDN)" \
        --non-interactive --agree-tos -m "$(cfg SSL_EMAIL)" >>"$LOG_FILE" 2>&1
}

STRATEGY_DESC["ssl_certbot_standalone"]="certbot mod standalone (hentikan nginx sebentar)"
ssl_certbot_standalone() {
    have certbot || return 1
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then systemctl stop nginx || true; else nginx -s stop || true; fi
    certbot certonly --standalone -d "$(cfg PANEL_FQDN)" \
        --non-interactive --agree-tos -m "$(cfg SSL_EMAIL)" >>"$LOG_FILE" 2>&1
    local rc=$?
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then systemctl start nginx || true; else nginx || true; fi
    return $rc
}

phase_ssl() {
    if cfg_is BEHIND_PROXY yes; then
        log_skip "Panel di belakang proxy — HTTPS dikendalikan di sana, bukan di sini"
        return 0
    fi
    if ! cfg_is PANEL_SSL yes; then
        log_skip "HTTPS tidak diminta — dilangkau"
        return 0
    fi

    # Semakan awal yang menjimatkan masa: kalau DNS tidak menunjuk ke sini,
    # Let's Encrypt PASTI gagal. Beritahu sebabnya, jangan buang 3 cubaan.
    if have dig; then
        local resolved myip
        resolved="$( { dig +short "$(cfg PANEL_FQDN)" A | head -1; } 2>/dev/null || true )"
        myip="$(detect_public_ip)"
        if [[ -z "$resolved" ]]; then
            defer_warning "$(cfg PANEL_FQDN) tidak resolve ke mana-mana IP, jadi HTTPS dilangkau. Point DNS domain itu ke $myip, kemudian jalankan: certbot --nginx -d $(cfg PANEL_FQDN)"
            CFG[PANEL_SSL]="no"
            return 0
        elif [[ -n "$myip" && "$resolved" != "$myip" ]]; then
            defer_warning "$(cfg PANEL_FQDN) resolve ke $resolved tetapi server ini $myip. HSTS/proxy mungkin sebabnya; cubaan HTTPS diteruskan tetapi mungkin gagal."
        fi
    fi

    if attempt "Sijil HTTPS Let's Encrypt" verify_ssl_cert \
        ssl_reinstall_existing ssl_certbot_nginx ssl_certbot_webroot ssl_certbot_standalone
    then
        log_ok "HTTPS aktif dan auto-renew didaftarkan"
        return 0
    fi

    # Turunkan ke HTTP dan teruskan — panel yang berfungsi tanpa HTTPS jauh
    # lebih berguna daripada pemasangan yang terhenti.
    CFG[PANEL_SSL]="no"
    CFG[WINGS_SSL]="no"
    CFG[PANEL_HTTP_PORT]="80"
    env_set APP_URL "$(panel_url)" || true
    write_nginx_conf 80 || true
    if [[ "$HAS_SYSTEMD" == "yes" ]]; then systemctl reload nginx || true; else nginx -s reload || true; fi
    defer_warning "Sijil HTTPS tidak dapat diperoleh selepas 3 kaedah. Panel diteruskan atas HTTP di $(panel_url). Punca biasa: port 80 tersekat dari internet, atau DNS belum betul. Selepas dibetulkan jalankan: certbot --nginx -d $(cfg PANEL_FQDN)"
    return 0
}

#===========================================================================
# Queue worker dan scheduler
#===========================================================================
verify_queue_worker() { pgrep -f 'artisan [q]ueue:work' >/dev/null 2>&1; }

STRATEGY_DESC["services_systemd"]="unit systemd pteroq + cron"
services_systemd() {
    [[ "$HAS_SYSTEMD" == "yes" ]] || return 1
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
    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || return 1
    systemctl enable pteroq.service >>"$LOG_FILE" 2>&1 || return 1
    # `enable --now` TIDAK memulakan semula unit yang sudah berjalan, jadi fail
    # unit yang baru ditulis tidak akan berkuat kuasa. restart memaksa itu.
    systemctl restart pteroq.service >>"$LOG_FILE" 2>&1 || return 1
    install_scheduler_cron
    wait_for 15 verify_queue_worker
}

STRATEGY_DESC["services_fallback_runner"]="script pelancar tanpa systemd"
services_fallback_runner() {
    write_fallback_runner
    /usr/local/bin/pterodactyl-services start >>"$LOG_FILE" 2>&1 || true
    wait_for 15 verify_queue_worker
}

# Scheduler dijalankan sebagai www-data, BUKAN root. Seluruh $PANEL_DIR dimiliki
# www-data, jadi cron root yang melaksanakan artisan dari situ bermakna sesiapa
# yang menguasai proses web boleh menulis artisan dan mendapat root pada minit
# berikutnya. Upstream mendokumenkan versi root; ini versi yang lebih selamat.
install_scheduler_cron() {
    local line="* * * * * php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1"
    # cron.d membenarkan medan pengguna secara jelas — itu pilihan pertama.
    if [[ -d /etc/cron.d ]]; then
        if printf '* * * * * www-data php %s/artisan schedule:run >> /dev/null 2>&1\n' "$PANEL_DIR" \
            >/etc/cron.d/pterodactyl 2>/dev/null; then
            chmod 644 /etc/cron.d/pterodactyl 2>/dev/null || true
            return 0
        fi
    fi
    # Fallback: crontab www-data sendiri.
    if have crontab; then
        if { crontab -u www-data -l 2>/dev/null | grep -v 'artisan schedule:run' || true
             printf '%s\n' "$line"; } | crontab -u www-data - 2>/dev/null; then
            return 0
        fi
        # Fallback terakhir: crontab root, tetapi tetap turun ke www-data.
        if { crontab -l 2>/dev/null | grep -v 'artisan schedule:run' || true
             printf '* * * * * sudo -u www-data php %s/artisan schedule:run >> /dev/null 2>&1\n' "$PANEL_DIR"; } \
             | crontab - 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

write_fallback_runner() {
    cat >/usr/local/bin/pterodactyl-services <<RUNNER
#!/usr/bin/env bash
# Pelancar service Pterodactyl untuk sistem tanpa systemd.
# Jalankan selepas setiap reboot: /usr/local/bin/pterodactyl-services start
PANEL_DIR="$PANEL_DIR"
PHP_V="$PHP_V"
REDIS_PORT="$(cfg REDIS_PORT)"

# MESTI prefix arahan, BUKAN fungsi shell. setsid dan nohup ialah binari luar
# dan tidak dapat memanggil fungsi shell — cubaan itu gagal dengan
# "nohup: failed to run command 'as_web'" dan queue worker tidak pernah bermula.
if command -v sudo >/dev/null 2>&1; then
    RUNAS="sudo -u www-data"
elif command -v runuser >/dev/null 2>&1; then
    RUNAS="runuser -u www-data --"
else
    RUNAS=""
fi

start() {
    mkdir -p /run/mysqld /run/php && chown mysql:mysql /run/mysqld 2>/dev/null || true
    pgrep -x mariadbd    >/dev/null || pgrep -x mysqld >/dev/null || \\
        { setsid nohup mariadbd-safe --user=mysql >/var/log/mariadb-boot.log 2>&1 & }
    pgrep -x redis-server >/dev/null || \\
        { setsid nohup redis-server --port "\$REDIS_PORT" >/var/log/redis-boot.log 2>&1 & }
    pgrep -f "php-fpm: master" >/dev/null || \\
        { setsid nohup "php-fpm\$PHP_V" --nodaemonize >/var/log/php-fpm-boot.log 2>&1 & }
    sleep 5
    pgrep -x nginx >/dev/null || nginx 2>/dev/null || true
    pgrep -f 'artisan [q]ueue:work' >/dev/null || \\
        { setsid nohup \$RUNAS php "\$PANEL_DIR/artisan" queue:work \\
            --queue=high,standard,low --sleep=3 --tries=3 >/var/log/pterodactyl-queue.log 2>&1 & }
    pgrep -f '[s]chedule:run' >/dev/null || \\
        { setsid nohup bash -c "while true; do \$RUNAS php \$PANEL_DIR/artisan schedule:run >/dev/null 2>&1; sleep 60; done" >/dev/null 2>&1 & }
    if [ -x /usr/local/bin/wings ]; then
        pgrep -x wings >/dev/null || \\
            { setsid nohup /usr/local/bin/wings --config /etc/pterodactyl/config.yml >/var/log/wings.log 2>&1 & }
    fi
    sleep 2
    echo "Service dimulakan."
}

status() {
    for p in mariadbd redis-server nginx wings; do
        printf '%-14s %s\n' "\$p" "\$(pgrep -x "\$p" >/dev/null && echo BERJALAN || echo MATI)"
    done
    printf '%-14s %s\n' "php-fpm"      "\$(pgrep -f 'php-fpm: master' >/dev/null && echo BERJALAN || echo MATI)"
    printf '%-14s %s\n' "queue-worker" "\$(pgrep -f 'artisan [q]ueue:work' >/dev/null && echo BERJALAN || echo MATI)"
}

case "\${1:-start}" in
    start)  start ;;
    status) status ;;
    *) echo "Guna: \$0 {start|status}"; exit 1 ;;
esac
RUNNER
    chmod +x /usr/local/bin/pterodactyl-services
    return 0
}

phase_services() {
    if attempt "Queue worker dan scheduler" verify_queue_worker \
        services_systemd services_fallback_runner
    then
        log_ok "Queue worker berjalan dan scheduler didaftarkan"
    else
        defer_warning "Queue worker tidak dapat dimulakan. Panel masih boleh diguna, tetapi kerja latar belakang (email, backup, jadual) tidak akan jalan. Semak: journalctl -u pteroq -n 50"
    fi
    # Tanpa systemd, service perlu dilancarkan semula selepas reboot.
    [[ "$HAS_SYSTEMD" == "yes" ]] || write_fallback_runner
    return 0
}
