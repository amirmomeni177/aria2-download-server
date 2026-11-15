#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# ---------------- Project configuration ----------------
DOMAIN="${DOMAIN:-downloads.example.com}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/srv/aria2-downloads}"
ARIA2_USER="${ARIA2_USER:-aria2dl}"
ARIA2_RPC_HOST="127.0.0.1"
ARIA2_RPC_PORT="${ARIA2_RPC_PORT:-16800}"
ARIANG_DIR="${ARIANG_DIR:-/var/www/ariang}"
CONFIG_DIR="${CONFIG_DIR:-/etc/aria2-download-server}"
STATE_DIR="${STATE_DIR:-/var/lib/aria2-download-server}"
BT_PORT="${BT_PORT:-16881}"
TEMP_PORT="${TEMP_PORT:-18080}"
PANEL_USER="${PANEL_USER:-aria2admin}"
OPEN_BT_PORT="${OPEN_BT_PORT:-false}"
ENABLE_HTTPS="${ENABLE_HTTPS:-auto}" # auto, true, false
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="aria2-download-server.service"
NGINX_SITE="/etc/nginx/sites-available/aria2-download-server.conf"
NGINX_LINK="/etc/nginx/sites-enabled/aria2-download-server.conf"
HTPASSWD_FILE="/etc/nginx/.htpasswd-aria2-download-server"
STATE_FILE="$CONFIG_DIR/install-state.env"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
backup_file() { [ ! -e "$1" ] && [ ! -L "$1" ] && return 0; cp -a -- "$1" "$1.backup-$STAMP"; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash install.sh"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid DOMAIN"
[[ "$ARIA2_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid ARIA2_USER"
[[ "$PANEL_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid PANEL_USER"
for p in "$ARIA2_RPC_PORT" "$BT_PORT" "$TEMP_PORT"; do [[ "$p" =~ ^[0-9]+$ ]] && ((p >= 1024 && p <= 65535)) || die "Invalid port: $p"; done
for d in "$DOWNLOAD_DIR" "$ARIANG_DIR" "$CONFIG_DIR" "$STATE_DIR"; do [[ "$d" == /* ]] || die "Path must be absolute: $d"; done

# Refuse to adopt colliding service/config identities from an unrelated install.
if [ ! -r "$STATE_FILE" ]; then
    for p in "/etc/systemd/system/$SERVICE_NAME" "$NGINX_SITE" "$NGINX_LINK" "$HTPASSWD_FILE" "$CONFIG_DIR" "$STATE_DIR" "$ARIANG_DIR"; do
        if [ -e "$p" ] || [ -L "$p" ]; then die "Refusing existing unmanaged path: $p"; fi
    done
    if getent passwd "$ARIA2_USER" >/dev/null; then
        existing_home="$(getent passwd "$ARIA2_USER" | cut -d: -f6)"
        [ "$existing_home" = "$STATE_DIR" ] || die "Existing user $ARIA2_USER has unrelated home: $existing_home"
    fi
fi

port_owner() {
    local port="$1"
    ss -lntupH 2>/dev/null | awk -v p=":$port" '$5 ~ (p "$") {print; found=1} END {if (!found) exit 1}'
}
tcp_port_used() { ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$1$"; }
any_port_used() { ss -lntuH 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$1$"; }
find_free_tcp_port() {
    local preferred="$1" p
    if ! tcp_port_used "$preferred"; then printf '%s\n' "$preferred"; return; fi
    for ((p=preferred+1; p<=65535; p++)); do if ! tcp_port_used "$p"; then printf '%s\n' "$p"; return; fi; done
    die "No free TCP port found"
}
find_free_any_port() {
    local preferred="$1" p
    if ! any_port_used "$preferred"; then printf '%s\n' "$preferred"; return; fi
    for ((p=preferred+1; p<=65535; p++)); do if ! any_port_used "$p"; then printf '%s\n' "$p"; return; fi; done
    die "No free TCP/UDP port found"
}
service_detected() { command_exists "$1" && printf detected || printf 'not detected'; }
port_status() { local o; if o="$(port_owner "$1" 2>/dev/null)"; then printf 'USED BY %s' "$o"; else printf FREE; fi; }

NGINX_PREEXISTED=false; command_exists nginx && NGINX_PREEXISTED=true
APACHE_DETECTED=false; { command_exists apache2 || command_exists httpd; } && APACHE_DETECTED=true
CADDY_DETECTED=false; command_exists caddy && CADDY_DETECTED=true
PORT80_USED=false; tcp_port_used 80 && PORT80_USED=true
PORT443_USED=false; tcp_port_used 443 && PORT443_USED=true

log "======================================="
log "aria2 Download Server Preflight"
log "======================================="
log "Nginx: $(service_detected nginx)"
if $APACHE_DETECTED; then log "Apache: detected"; else log "Apache: not detected"; fi
if $CADDY_DETECTED; then log "Caddy: detected"; else log "Caddy: not detected"; fi
log ""
log "Port 80: $(port_status 80)"
log "Port 443: $(port_status 443)"
log "Preferred RPC port $ARIA2_RPC_PORT: $(port_status "$ARIA2_RPC_PORT")"
log "Preferred BT port $BT_PORT: $(port_status "$BT_PORT")"
log ""
log "Domain:"
log "$DOMAIN"
log ""
log "Download directory:"
log "$DOWNLOAD_DIR"
log ""
log "Existing services will not be modified."
log "======================================="

# Preserve dynamically chosen ports on reruns unless explicitly overridden.
if [ -r "$STATE_FILE" ]; then
    old_rpc="$(sed -n 's/^RPC_PORT=//p' "$STATE_FILE" | tail -n1 || true)"
    old_bt="$(sed -n 's/^BT_PORT=//p' "$STATE_FILE" | tail -n1 || true)"
    old_temp="$(sed -n 's/^TEMP_PORT=//p' "$STATE_FILE" | tail -n1 || true)"
    old_ufw_tcp="$(sed -n 's/^UFW_BT_TCP_ADDED=//p' "$STATE_FILE" | tail -n1 || true)"
    old_ufw_udp="$(sed -n 's/^UFW_BT_UDP_ADDED=//p' "$STATE_FILE" | tail -n1 || true)"
    [ -n "$old_rpc" ] && ARIA2_RPC_PORT="$old_rpc"
    [ -n "$old_bt" ] && BT_PORT="$old_bt"
    [ -n "$old_temp" ] && TEMP_PORT="$old_temp"
fi
# Existing project listeners are allowed on rerun; otherwise choose safe ports.
project_active=false
systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && project_active=true
if ! $project_active && tcp_port_used "$ARIA2_RPC_PORT"; then ARIA2_RPC_PORT="$(find_free_tcp_port "$((ARIA2_RPC_PORT + 1))")"; fi
if ! $project_active && any_port_used "$BT_PORT"; then BT_PORT="$(find_free_any_port "$((BT_PORT + 1))")"; fi
# The localhost temporary listener is Nginx-owned on reruns.
if tcp_port_used "$TEMP_PORT"; then
    if ! ss -lntpH 2>/dev/null | awk -v p=":$TEMP_PORT" '$4 ~ (p "$") && /nginx/ {ok=1} END {exit !ok}'; then
        TEMP_PORT="$(find_free_tcp_port "$((TEMP_PORT + 1))")"
    fi
fi

# If Nginx is absent and another server owns 80/443, do not install or disturb it.
USE_NGINX=true
if ! $NGINX_PREEXISTED && { $PORT80_USED || $PORT443_USED; }; then USE_NGINX=false; fi

packages=(aria2 ca-certificates curl unzip apache2-utils acl)
$USE_NGINX && ! command_exists nginx && packages+=(nginx)
missing=()
for pkg in "${packages[@]}"; do dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed' || missing+=("$pkg"); done
if ((${#missing[@]})); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${missing[@]}"
fi
command_exists aria2c || die "aria2c installation failed"
command_exists curl || die "curl installation failed"
command_exists unzip || die "unzip installation failed"
command_exists htpasswd || die "htpasswd installation failed"

if ! getent passwd "$ARIA2_USER" >/dev/null; then
    useradd --system --home "$STATE_DIR" --shell /usr/sbin/nologin "$ARIA2_USER"
fi
ARIA2_GROUP="$(id -gn "$ARIA2_USER")"
install -d -o "$ARIA2_USER" -g "$ARIA2_GROUP" -m 0750 "$DOWNLOAD_DIR"
install -d -o "$ARIA2_USER" -g "$ARIA2_GROUP" -m 0750 "$STATE_DIR"
install -d -o root -g "$ARIA2_GROUP" -m 0750 "$CONFIG_DIR"
install -d -o root -g root -m 0755 "$(dirname "$ARIANG_DIR")"
install -d -o "$ARIA2_USER" -g "$ARIA2_GROUP" -m 0750 "$STATE_DIR/acme-challenge"
touch "$STATE_DIR/aria2.session"
chown "$ARIA2_USER:$ARIA2_GROUP" "$STATE_DIR/aria2.session"
chmod 0640 "$STATE_DIR/aria2.session"

SECRET_FILE="$CONFIG_DIR/rpc-secret"
if [ ! -s "$SECRET_FILE" ]; then openssl rand -hex 32 > "$SECRET_FILE"; fi
chown root:"$ARIA2_GROUP" "$SECRET_FILE"; chmod 0640 "$SECRET_FILE"
RPC_SECRET="$(tr -d '\r\n' < "$SECRET_FILE")"
[[ "$RPC_SECRET" =~ ^[0-9a-fA-F]{64}$ ]] || die "Invalid RPC secret file: $SECRET_FILE"

CREDENTIAL_FILE="$CONFIG_DIR/panel-credentials"
if [ -s "$CREDENTIAL_FILE" ] && [ -s "$HTPASSWD_FILE" ]; then
    PANEL_PASSWORD="$(sed -n 's/^password=//p' "$CREDENTIAL_FILE" | tail -n1)"
    saved_user="$(sed -n 's/^username=//p' "$CREDENTIAL_FILE" | tail -n1)"
    [ -n "$saved_user" ] && PANEL_USER="$saved_user"
else
    PANEL_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
    htpasswd -bcB "$HTPASSWD_FILE" "$PANEL_USER" "$PANEL_PASSWORD" >/dev/null
    printf 'username=%s\npassword=%s\n' "$PANEL_USER" "$PANEL_PASSWORD" > "$CREDENTIAL_FILE"
fi
if command_exists nginx; then
    NGINX_RUNTIME_USER="$(nginx -T 2>/dev/null | sed -n 's/^[[:space:]]*user[[:space:]]\+\([^;[:space:]]\+\).*/\1/p; /^[[:space:]]*user[[:space:]]/q')"
    [ -n "$NGINX_RUNTIME_USER" ] || NGINX_RUNTIME_USER=www-data
    NGINX_AUTH_GROUP="$(id -gn "$NGINX_RUNTIME_USER" 2>/dev/null || printf '%s' root)"
else
    NGINX_AUTH_GROUP=root
fi
chown root:"$NGINX_AUTH_GROUP" "$HTPASSWD_FILE"
chown root:root "$CREDENTIAL_FILE"
chmod 0640 "$HTPASSWD_FILE"
chmod 0600 "$CREDENTIAL_FILE"
if command_exists nginx && [ "$NGINX_AUTH_GROUP" != root ]; then
    setfacl -R -m "u:$NGINX_RUNTIME_USER:rX" "$DOWNLOAD_DIR"
    find "$DOWNLOAD_DIR" -type d -exec setfacl -m "d:u:$NGINX_RUNTIME_USER:rX" {} +
fi

ARIA_CONF="$CONFIG_DIR/aria2.conf"
backup_file "$ARIA_CONF"
cat > "$ARIA_CONF" <<EOF
dir=$DOWNLOAD_DIR
continue=true
max-concurrent-downloads=5
split=8
min-split-size=10M
max-connection-per-server=8
file-allocation=none
enable-rpc=true
rpc-listen-all=false
rpc-listen-port=$ARIA2_RPC_PORT
rpc-secret=$RPC_SECRET
input-file=$STATE_DIR/aria2.session
save-session=$STATE_DIR/aria2.session
save-session-interval=30
enable-dht=true
enable-dht6=true
bt-enable-lpd=true
enable-peer-exchange=true
bt-tracker=udp://tracker.opentrackr.org:1337/announce,udp://open.stealth.si:80/announce,udp://tracker.torrent.eu.org:451/announce,udp://exodus.desync.com:6969/announce,udp://open.demonii.com:1337/announce,https://tracker.opentrackr.org:443/announce
bt-save-metadata=true
bt-load-saved-metadata=true
listen-port=$BT_PORT
dht-listen-port=$BT_PORT
check-certificate=true
follow-torrent=mem
seed-time=0
max-overall-upload-limit=1M
summary-interval=0
console-log-level=notice
EOF
chown root:"$ARIA2_GROUP" "$ARIA_CONF"; chmod 0640 "$ARIA_CONF"

UNIT_FILE="/etc/systemd/system/$SERVICE_NAME"
backup_file "$UNIT_FILE"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Isolated aria2 Download Server
Documentation=https://aria2.github.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$ARIA2_USER
Group=$ARIA2_GROUP
UMask=0027
ExecStart=/usr/bin/aria2c --conf-path=$ARIA_CONF
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
ReadWritePaths=$DOWNLOAD_DIR $STATE_DIR

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$UNIT_FILE"

# Download and atomically install the latest official AriaNg release.
release_json="$(mktemp)"; release_standard_zip="$(mktemp)"; release_allinone_zip="$(mktemp)"; release_source_tgz="$(mktemp)"; stage="${ARIANG_DIR}.new.$$"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 https://api.github.com/repos/mayswind/AriaNg/releases/latest -o "$release_json"
readarray -t rel < <(python3 - "$release_json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
assets=x.get('assets',[])
standard=next((a for a in assets if a.get('name','').endswith('.zip') and 'AllInOne' not in a.get('name','')),None)
allinone=next((a for a in assets if a.get('name','').endswith('-AllInOne.zip')),None)
if not standard or not allinone: raise SystemExit('Required AriaNg release assets not found')
print(x['tag_name']); print(standard['browser_download_url']); print(allinone['browser_download_url'])
PY
)
ARIANG_VERSION="${rel[0]}"; ARIANG_STANDARD_URL="${rel[1]}"; ARIANG_ALLINONE_URL="${rel[2]}"
curl -fL --retry 3 --connect-timeout 15 --max-time 180 "$ARIANG_STANDARD_URL" -o "$release_standard_zip"
curl -fL --retry 3 --connect-timeout 15 --max-time 180 "$ARIANG_ALLINONE_URL" -o "$release_allinone_zip"
curl -fL --retry 3 --connect-timeout 15 --max-time 180 "https://github.com/mayswind/AriaNg/archive/refs/tags/$ARIANG_VERSION.tar.gz" -o "$release_source_tgz"
python3 - "$release_standard_zip" "$release_allinone_zip" <<'PY'
import sys,zipfile
for archive in sys.argv[1:]:
  with zipfile.ZipFile(archive) as z:
    for n in z.namelist():
      if n.startswith('/') or '..' in n.split('/'):
        raise SystemExit('Unsafe path in release archive: '+n)
    bad=z.testzip()
    if bad: raise SystemExit('Corrupt archive member: '+bad)
PY
install -d -o root -g root -m 0755 "$stage"
unzip -q "$release_standard_zip" -d "$stage"
unzip -p "$release_allinone_zip" index.html > "$stage/index.html"
python3 - "$release_source_tgz" "$stage" <<'PY'
import pathlib,sys,tarfile
archive,dest=sys.argv[1:]
out=pathlib.Path(dest)/'views'; out.mkdir(mode=0o755,exist_ok=True)
count=0
with tarfile.open(archive,'r:gz') as t:
  for m in t.getmembers():
    marker='/src/views/'
    if marker not in m.name or not m.isfile(): continue
    rel=m.name.split(marker,1)[1]
    if not rel or '/' in rel or not rel.endswith('.html'): continue
    data=t.extractfile(m).read()
    (out/rel).write_bytes(data); count+=1
if count < 10: raise SystemExit(f'Incomplete AriaNg views in source archive: {count}')
PY
rm -f -- "$release_json" "$release_standard_zip" "$release_allinone_zip" "$release_source_tgz"
[ -f "$stage/index.html" ] || die "AriaNg archive did not contain index.html"
python3 - "$stage/index.html" "$RPC_SECRET" <<'PY'
import base64,html,json,sys
p,secret=sys.argv[1:]
s=open(p,encoding='utf-8').read()
script="""<style id=\"aria2-download-server-ui\">.aria-files-button{position:fixed;right:22px;bottom:22px;z-index:9999;display:inline-flex;align-items:center;gap:10px;padding:13px 18px;border-radius:14px;color:#fff!important;text-decoration:none!important;font:700 14px/1 Inter,system-ui,sans-serif;background:linear-gradient(135deg,#06b6d4,#2563eb 60%%,#7c3aed);border:1px solid rgba(255,255,255,.22);box-shadow:0 16px 40px rgba(0,0,0,.4),0 0 28px rgba(34,211,238,.16);transition:.18s ease}.aria-files-button:hover{transform:translateY(-3px);filter:brightness(1.1);box-shadow:0 20px 50px rgba(0,0,0,.48),0 0 34px rgba(34,211,238,.24)}@media(max-width:600px){.aria-files-button{right:14px;bottom:14px;padding:12px 14px}}</style>\n<script id=\"aria2-download-server-bootstrap\">\n(function(){try{var k='AriaNg.Options';var o=JSON.parse(localStorage.getItem(k)||'{}');if(!o.language)o.language='en';if(!Array.isArray(o.extendRpcServers))o.extendRpcServers=[];if(o.rpcRequestHeaders===undefined)o.rpcRequestHeaders='';o.rpcAlias='aria2 Download Server';o.rpcHost=location.hostname;o.rpcPort=location.port||(location.protocol==='https:'?'443':'80');o.rpcInterface='jsonrpc';o.protocol=location.protocol==='https:'?'https':'http';o.httpMethod='POST';o.secret=%s;localStorage.setItem(k,JSON.stringify(o));var add=function(){if(document.querySelector('.aria-files-button'))return;var a=document.createElement('a');a.className='aria-files-button';a.href='/files/';a.textContent='📁  Open Downloads';a.setAttribute('aria-label','Open downloaded files');document.body.appendChild(a)};document.readyState==='loading'?document.addEventListener('DOMContentLoaded',add):add();}catch(e){console.error(e);}}());\n</script>\n""" % json.dumps(base64.b64encode(secret.encode()).decode())
if '</head>' not in s: raise SystemExit('Unexpected AriaNg index format')
s=s.replace('</head>',script+'</head>',1)
open(p,'w',encoding='utf-8').write(s)
PY
install -m 0644 "$PROJECT_DIR/files-theme.css" "$stage/files-theme.css"
install -m 0644 "$PROJECT_DIR/files-theme.js" "$stage/files-theme.js"
printf '%s\n' "$ARIANG_VERSION" > "$stage/.aria2-download-server-version"
find "$stage" -type d -exec chmod 0755 {} +
find "$stage" -type f -exec chmod 0644 {} +
chown -R root:root "$stage"
if [ -e "$ARIANG_DIR" ]; then mv -- "$ARIANG_DIR" "$ARIANG_DIR.backup-$STAMP"; fi
mv -- "$stage" "$ARIANG_DIR"

# Resolve DNS without treating DNS failure as fatal.
PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
mapfile -t DOMAIN_IPS < <(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
DOMAIN_MATCH=false
for ip in "${DOMAIN_IPS[@]:-}"; do [ -n "$PUBLIC_IP" ] && [ "$ip" = "$PUBLIC_IP" ] && DOMAIN_MATCH=true; done

write_nginx_site() {
    local tls="$1"
    cat > "$NGINX_SITE" <<EOF
# Managed only by aria2-download-server/install.sh
server {
    listen 80;
    listen [::]:80;
    listen 127.0.0.1:$TEMP_PORT;
    server_name $DOMAIN;
    client_max_body_size 32m;
    access_log /var/log/nginx/aria2-download-server.access.log;
    error_log /var/log/nginx/aria2-download-server.error.log;

    location ^~ /.well-known/acme-challenge/ {
        alias $STATE_DIR/acme-challenge/;
        auth_basic off;
        default_type text/plain;
    }

    location = /jsonrpc {
        auth_basic "aria2 Download Server";
        auth_basic_user_file $HTPASSWD_FILE;
        proxy_pass http://$ARIA2_RPC_HOST:$ARIA2_RPC_PORT/jsonrpc;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_request_buffering off;
        proxy_buffering off;
    }

    location /files/ {
        auth_basic "aria2 Download Server";
        auth_basic_user_file $HTPASSWD_FILE;
        alias $DOWNLOAD_DIR/;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        charset utf-8;
        disable_symlinks on;
        add_header Accept-Ranges bytes always;
        sub_filter_once on;
        sub_filter '</head>' '<link rel="stylesheet" href="/files-theme.css"></head>';
        sub_filter '</body>' '<script src="/files-theme.js" defer></script></body>';
    }

    location / {
        auth_basic "aria2 Download Server";
        auth_basic_user_file $HTPASSWD_FILE;
        root $ARIANG_DIR;
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    if [ "$tls" = true ]; then
        cat >> "$NGINX_SITE" <<EOF

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    client_max_body_size 32m;
    access_log /var/log/nginx/aria2-download-server.access.log;
    error_log /var/log/nginx/aria2-download-server.error.log;

    location = /jsonrpc {
        auth_basic "aria2 Download Server";
        auth_basic_user_file $HTPASSWD_FILE;
        proxy_pass http://$ARIA2_RPC_HOST:$ARIA2_RPC_PORT/jsonrpc;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_request_buffering off;
        proxy_buffering off;
    }

    location /files/ {
        auth_basic "aria2 Download Server";
        auth_basic_user_file $HTPASSWD_FILE;
        alias $DOWNLOAD_DIR/;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        charset utf-8;
        disable_symlinks on;
        add_header Accept-Ranges bytes always;
        sub_filter_once on;
        sub_filter '</head>' '<link rel="stylesheet" href="/files-theme.css"></head>';
        sub_filter '</body>' '<script src="/files-theme.js" defer></script></body>';
    }

    location / {
        auth_basic "aria2 Download Server";
        auth_basic_user_file $HTPASSWD_FILE;
        root $ARIANG_DIR;
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    fi
    chmod 0644 "$NGINX_SITE"
}

TLS_ENABLED=false
FALLBACK_ENABLED=false
NGINX_SITE_CREATED=false
if $USE_NGINX; then
    command_exists nginx || die "Nginx unavailable"
    nginx -t
    backup_file "$NGINX_SITE"
    write_nginx_site false
    if [ -e "$NGINX_LINK" ] && [ ! -L "$NGINX_LINK" ]; then die "Nginx enable path is not a symlink: $NGINX_LINK"; fi
    if [ -L "$NGINX_LINK" ] && [ "$(readlink -f "$NGINX_LINK")" != "$(readlink -f "$NGINX_SITE")" ]; then die "Nginx enable path points elsewhere: $NGINX_LINK"; fi
    if [ ! -L "$NGINX_LINK" ]; then ln -s "$NGINX_SITE" "$NGINX_LINK"; NGINX_SITE_CREATED=true; fi
    if ! nginx -t; then
        $NGINX_SITE_CREATED && unlink "$NGINX_LINK"
        if [ -e "$NGINX_SITE.backup-$STAMP" ]; then cp -a -- "$NGINX_SITE.backup-$STAMP" "$NGINX_SITE"; else unlink "$NGINX_SITE"; fi
        die "New Nginx site failed validation; previous state restored"
    fi
    systemctl reload nginx

    cert_exists=false
    [ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && [ -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ] && cert_exists=true
    want_cert=false
    [ "$ENABLE_HTTPS" = true ] && want_cert=true
    [ "$ENABLE_HTTPS" = auto ] && $DOMAIN_MATCH && want_cert=true
    if $cert_exists; then
        TLS_ENABLED=true
    elif $want_cert; then
        if ! command_exists certbot; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends certbot
        fi
        cert_args=(certonly --webroot -w "$STATE_DIR/acme-challenge" -d "$DOMAIN" --non-interactive --agree-tos --keep-until-expiring)
        if [ -n "$CERTBOT_EMAIL" ]; then cert_args+=(--email "$CERTBOT_EMAIL"); else cert_args+=(--register-unsafely-without-email); fi
        if certbot "${cert_args[@]}"; then TLS_ENABLED=true; else log "WARNING: Certificate request failed; keeping authenticated HTTP and localhost temporary access."; fi
    fi
    if $TLS_ENABLED; then
        write_nginx_site true
        if ! nginx -t; then
            write_nginx_site false
            nginx -t || die "Nginx rollback validation failed"
            TLS_ENABLED=false
            log "WARNING: TLS site validation failed; restored HTTP-only site."
        else
            systemctl reload nginx
            install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
            cat > /etc/letsencrypt/renewal-hooks/deploy/aria2-download-server-nginx-reload <<'EOF'
#!/bin/sh
nginx -t && systemctl reload nginx
EOF
            chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/aria2-download-server-nginx-reload
        fi
    fi
else
    # Safe fallback: localhost-only Python listener. Existing public web server stays untouched.
    FALLBACK_ENABLED=true
    FALLBACK_SCRIPT="$CONFIG_DIR/fallback-server.py"
    cat > "$FALLBACK_SCRIPT" <<'PY'
import base64, http.client, os, pathlib, re
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
ROOT=pathlib.Path(os.environ['ARIANG_DIR']).resolve(); FILES=pathlib.Path(os.environ['DOWNLOAD_DIR']).resolve()
AUTH='Basic '+base64.b64encode((os.environ['username']+':'+os.environ['password']).encode()).decode()
RPC_PORT=int(os.environ['RPC_PORT'])
class H(SimpleHTTPRequestHandler):
 _range=None
 def auth(self):
  if self.headers.get('Authorization')==AUTH:return True
  self.send_response(401);self.send_header('WWW-Authenticate','Basic realm="aria2 Download Server"');self.end_headers();return False
 def translate_path(self,path):
  from urllib.parse import unquote,urlsplit
  p=unquote(urlsplit(path).path)
  base=FILES if p.startswith('/files/') else ROOT
  rel=p[7:] if p.startswith('/files/') else p.lstrip('/')
  out=(base/rel).resolve()
  if out!=base and base not in out.parents:return str(base/'__denied__')
  return str(out)
 def do_POST(self):
  if not self.auth():return
  if self.path!='/jsonrpc':self.send_error(404);return
  n=int(self.headers.get('Content-Length','0'));body=self.rfile.read(n)
  c=http.client.HTTPConnection('127.0.0.1',RPC_PORT,timeout=30);c.request('POST','/jsonrpc',body,{'Content-Type':'application/json'});r=c.getresponse();data=r.read()
  self.send_response(r.status);self.send_header('Content-Type',r.getheader('Content-Type','application/json'));self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_GET(self):
  if not self.auth():return
  if self.path=='/files':self.send_response(301);self.send_header('Location','/files/');self.end_headers();return
  return super().do_GET()
 def do_HEAD(self):
  if not self.auth():return
  return super().do_HEAD()
 def send_head(self):
  if self.path.startswith('/files/') and self.headers.get('Range'):
   path=self.translate_path(self.path)
   try:f=open(path,'rb'); size=os.fstat(f.fileno()).st_size
   except OSError:self.send_error(404);return None
   m=re.fullmatch(r'bytes=(\d*)-(\d*)',self.headers['Range'].strip())
   if not m:f.close();self.send_error(416);return None
   a,b=m.groups()
   if not a:
    count=int(b or 0); start=max(0,size-count); end=size-1
   else:
    start=int(a); end=min(int(b) if b else size-1,size-1)
   if start> end or start>=size:f.close();self.send_response(416);self.send_header('Content-Range',f'bytes */{size}');self.end_headers();return None
   self._range=(start,end);self.send_response(206);self.send_header('Content-Type',self.guess_type(path));self.send_header('Content-Length',str(end-start+1));self.send_header('Content-Range',f'bytes {start}-{end}/{size}');self.send_header('Accept-Ranges','bytes');self.end_headers();return f
  return super().send_head()
 def copyfile(self,source,output):
  if self._range:
   start,end=self._range;source.seek(start);left=end-start+1
   while left:
    chunk=source.read(min(1024*1024,left))
    if not chunk:break
    output.write(chunk);left-=len(chunk)
   self._range=None;return
  return super().copyfile(source,output)
 def end_headers(self):self.send_header('X-Content-Type-Options','nosniff');self.send_header('Accept-Ranges','bytes');super().end_headers()
os.chdir(ROOT)
ThreadingHTTPServer(('127.0.0.1',int(os.environ['TEMP_PORT'])),H).serve_forever()
PY
    chmod 0750 "$FALLBACK_SCRIPT"; chown root:"$ARIA2_GROUP" "$FALLBACK_SCRIPT"
    chown root:"$ARIA2_GROUP" "$CREDENTIAL_FILE"; chmod 0640 "$CREDENTIAL_FILE"
    FALLBACK_ENV="$CONFIG_DIR/fallback.env"
    printf 'ARIANG_DIR=%s\nDOWNLOAD_DIR=%s\nRPC_PORT=%s\nTEMP_PORT=%s\n' "$ARIANG_DIR" "$DOWNLOAD_DIR" "$ARIA2_RPC_PORT" "$TEMP_PORT" > "$FALLBACK_ENV"
    chown root:"$ARIA2_GROUP" "$FALLBACK_ENV"; chmod 0640 "$FALLBACK_ENV"
    FALLBACK_UNIT=/etc/systemd/system/aria2-download-server-web.service
    cat > "$FALLBACK_UNIT" <<EOF
[Unit]
Description=Local fallback web frontend for aria2 Download Server
After=$SERVICE_NAME
Requires=$SERVICE_NAME
[Service]
Type=simple
User=$ARIA2_USER
Group=$ARIA2_GROUP
EnvironmentFile=$FALLBACK_ENV
EnvironmentFile=$CREDENTIAL_FILE
ExecStart=/usr/bin/python3 $FALLBACK_SCRIPT
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=$ARIANG_DIR $DOWNLOAD_DIR
[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$FALLBACK_UNIT"
fi

# Add only explicitly requested, dedicated BT rules. RPC is never opened.
UFW_BT_TCP_ADDED="${old_ufw_tcp:-false}"; UFW_BT_UDP_ADDED="${old_ufw_udp:-false}"
if [ "$OPEN_BT_PORT" = true ] && command_exists ufw && ufw status | grep -q '^Status: active'; then
    if ! ufw status | grep -Eq "^$BT_PORT/tcp[[:space:]]+ALLOW"; then ufw allow "$BT_PORT/tcp" comment 'aria2-download-server BT'; UFW_BT_TCP_ADDED=true; fi
    if ! ufw status | grep -Eq "^$BT_PORT/udp[[:space:]]+ALLOW"; then ufw allow "$BT_PORT/udp" comment 'aria2-download-server DHT'; UFW_BT_UDP_ADDED=true; fi
fi

backup_file "$STATE_FILE"
cat > "$STATE_FILE" <<EOF
DOMAIN=$DOMAIN
RPC_PORT=$ARIA2_RPC_PORT
BT_PORT=$BT_PORT
TEMP_PORT=$TEMP_PORT
NGINX_PREEXISTED=$NGINX_PREEXISTED
USE_NGINX=$USE_NGINX
TLS_ENABLED=$TLS_ENABLED
FALLBACK_ENABLED=$FALLBACK_ENABLED
UFW_BT_TCP_ADDED=$UFW_BT_TCP_ADDED
UFW_BT_UDP_ADDED=$UFW_BT_UDP_ADDED
ARIA2_USER=$ARIA2_USER
ARIA2_GROUP=$ARIA2_GROUP
DOWNLOAD_DIR=$DOWNLOAD_DIR
ARIANG_DIR=$ARIANG_DIR
STATE_DIR=$STATE_DIR
CONFIG_DIR=$CONFIG_DIR
EOF
chown root:root "$STATE_FILE"; chmod 0600 "$STATE_FILE"

systemctl daemon-reload
systemd-analyze verify "$UNIT_FILE"
systemctl enable "$SERVICE_NAME"
if systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl restart "$SERVICE_NAME"
else
    systemctl start "$SERVICE_NAME"
fi
if $FALLBACK_ENABLED; then
    systemctl enable aria2-download-server-web.service
    if systemctl is-active --quiet aria2-download-server-web.service; then systemctl restart aria2-download-server-web.service; else systemctl start aria2-download-server-web.service; fi
fi
systemctl is-active --quiet "$SERVICE_NAME" || die "aria2 service did not become active"

# Validation: localhost-only RPC, authenticated proxy, legal small test download, and file serving.
rpc_ready=false
for _ in $(seq 1 20); do
    if ss -lntH | awk '{print $4}' | grep -Eq "127\.0\.0\.1:$ARIA2_RPC_PORT$|\[::1\]:$ARIA2_RPC_PORT$"; then
        rpc_ready=true
        break
    fi
    sleep 1
done
if ss -lntH | awk '{print $4}' | grep -Eq "(^|:)0\.0\.0\.0:$ARIA2_RPC_PORT$|^\*:$ARIA2_RPC_PORT$|^\[::\]:$ARIA2_RPC_PORT$"; then die "RPC unexpectedly exposed publicly"; fi
$rpc_ready || die "RPC is not listening on loopback"
BASE="http://127.0.0.1:$TEMP_PORT"
download_ok=false
if [ -s "$DOWNLOAD_DIR/aria2-install-test.txt" ]; then
    download_ok=true
fi
for TEST_URL in \
    https://raw.githubusercontent.com/github/gitignore/main/README.md \
    https://www.example.com/ \
    https://example.com/; do
    $download_ok && break
    RPC_PAYLOAD="$(python3 - "$RPC_SECRET" "$DOWNLOAD_DIR" "$TEST_URL" <<'PY'
import json,sys
print(json.dumps({'jsonrpc':'2.0','id':'install-test','method':'aria2.addUri','params':['token:'+sys.argv[1],[sys.argv[3]],{'dir':sys.argv[2],'out':'aria2-install-test.txt','allow-overwrite':'true','auto-file-renaming':'false'}]}))
PY
)"
    RPC_RESULT="$(curl -fsS --max-time 30 -u "$PANEL_USER:$PANEL_PASSWORD" -H 'Content-Type: application/json' --data "$RPC_PAYLOAD" "$BASE/jsonrpc")"
    TEST_GID="$(python3 -c 'import json,sys; x=json.load(sys.stdin); print(x.get("result",""))' <<<"$RPC_RESULT")"
    [ -n "$TEST_GID" ] || continue
    for _ in $(seq 1 20); do
        if [ -s "$DOWNLOAD_DIR/aria2-install-test.txt" ]; then download_ok=true; break; fi
        sleep 1
    done
    $download_ok && break
done
$download_ok || die "Legal test download did not complete after three endpoints"
curl -fsS --max-time 30 -u "$PANEL_USER:$PANEL_PASSWORD" "$BASE/files/aria2-install-test.txt" -o /dev/null
curl -fsSI --max-time 30 -u "$PANEL_USER:$PANEL_PASSWORD" -H 'Range: bytes=0-9' "$BASE/files/aria2-install-test.txt" | grep -Eq '^HTTP/.* (200|206)' || die "File Range request validation failed"

# Remove only installer-test result records, then persist the clean session.
QUERY_PAYLOAD="$(python3 - "$RPC_SECRET" <<'PY'
import json,sys
print(json.dumps({'jsonrpc':'2.0','id':'cleanup-list','method':'aria2.tellStopped','params':['token:'+sys.argv[1],0,1000,['gid','files']]},separators=(',',':')))
PY
)"
QUERY_RESULT="$(curl -fsS --max-time 30 -u "$PANEL_USER:$PANEL_PASSWORD" -H 'Content-Type: application/json' --data "$QUERY_PAYLOAD" "$BASE/jsonrpc")"
mapfile -t TEST_GIDS < <(python3 - "$DOWNLOAD_DIR/aria2-install-test.txt" "$QUERY_RESULT" <<'PY'
import json,sys
target=sys.argv[1]; data=json.loads(sys.argv[2])
for item in data.get('result',[]):
    if any(f.get('path')==target for f in item.get('files',[])): print(item['gid'])
PY
)
for gid in "${TEST_GIDS[@]:-}"; do
    [ -n "$gid" ] || continue
    REMOVE_PAYLOAD="$(python3 - "$RPC_SECRET" "$gid" <<'PY'
import json,sys
print(json.dumps({'jsonrpc':'2.0','id':'cleanup','method':'aria2.removeDownloadResult','params':['token:'+sys.argv[1],sys.argv[2]]},separators=(',',':')))
PY
)"
    curl -fsS --max-time 30 -u "$PANEL_USER:$PANEL_PASSWORD" -H 'Content-Type: application/json' --data "$REMOVE_PAYLOAD" "$BASE/jsonrpc" -o /dev/null
done
SAVE_PAYLOAD="$(python3 - "$RPC_SECRET" <<'PY'
import json,sys
print(json.dumps({'jsonrpc':'2.0','id':'save','method':'aria2.saveSession','params':['token:'+sys.argv[1]]},separators=(',',':')))
PY
)"
curl -fsS --max-time 30 -u "$PANEL_USER:$PANEL_PASSWORD" -H 'Content-Type: application/json' --data "$SAVE_PAYLOAD" "$BASE/jsonrpc" -o /dev/null

if $TLS_ENABLED; then SCHEME=https; else SCHEME=http; fi
log "================================================"
log "aria2 Download Server Ready"
log "================================================"
log ""
log "Panel:"
log "$SCHEME://$DOMAIN/"
log ""
log "Downloads:"
log "$SCHEME://$DOMAIN/files/"
log ""
log "RPC endpoint:"
log "$SCHEME://$DOMAIN/jsonrpc"
log ""
log "Temporary localhost panel (use an SSH tunnel):"
log "http://127.0.0.1:$TEMP_PORT/"
log ""
log "Panel Username:"
log "$PANEL_USER"
log ""
log "Panel Password:"
log "$PANEL_PASSWORD"
log ""
log "RPC backend:"
log "$ARIA2_RPC_HOST:$ARIA2_RPC_PORT"
log ""
log "RPC Secret:"
log "$RPC_SECRET"
log ""
log "BitTorrent Port:"
log "$BT_PORT (public firewall: $OPEN_BT_PORT)"
log ""
log "Download Directory:"
log "$DOWNLOAD_DIR"
log ""
log "Systemd Service:"
log "$SERVICE_NAME"
log ""
log "Nginx Site:"
if $USE_NGINX; then log "aria2-download-server.conf"; else log "Not enabled; existing non-Nginx web server was untouched"; fi
log ""
if $DOMAIN_MATCH; then log "Domain DNS: MATCHES $PUBLIC_IP"; else log "Domain DNS: NOT CONFIGURED for $PUBLIC_IP"; fi
log "Existing VPS services:"
log "UNCHANGED (Nginx received validated reloads only)"
log "================================================"
