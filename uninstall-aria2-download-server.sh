#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

CONFIG_DIR="${CONFIG_DIR:-/etc/aria2-download-server}"
STATE_FILE="$CONFIG_DIR/install-state.env"
DELETE_DOWNLOADS="${DELETE_DOWNLOADS:-false}"
SERVICE="aria2-download-server.service"
WEB_SERVICE="aria2-download-server-web.service"
NGINX_SITE="/etc/nginx/sites-available/aria2-download-server.conf"
NGINX_LINK="/etc/nginx/sites-enabled/aria2-download-server.conf"
HTPASSWD_FILE="/etc/nginx/.htpasswd-aria2-download-server"

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }

# Read only the installer's strict KEY=value state format; never source it.
state() { sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | tail -n1; }
DOMAIN="$(state DOMAIN)"; RPC_PORT="$(state RPC_PORT)"; BT_PORT="$(state BT_PORT)"
TEMP_PORT="$(state TEMP_PORT)"; NGINX_PREEXISTED="$(state NGINX_PREEXISTED)"
USE_NGINX="$(state USE_NGINX)"; FALLBACK_ENABLED="$(state FALLBACK_ENABLED)"
UFW_BT_TCP_ADDED="$(state UFW_BT_TCP_ADDED)"; UFW_BT_UDP_ADDED="$(state UFW_BT_UDP_ADDED)"
ARIA2_USER="$(state ARIA2_USER)"; DOWNLOAD_DIR="$(state DOWNLOAD_DIR)"
ARIANG_DIR="$(state ARIANG_DIR)"; STATE_DIR="$(state STATE_DIR)"
: "${ARIA2_USER:=aria2dl}" "${DOWNLOAD_DIR:=/srv/aria2-downloads}" "${ARIANG_DIR:=/var/www/ariang}" "${STATE_DIR:=/var/lib/aria2-download-server}"

systemctl disable --now "$WEB_SERVICE" 2>/dev/null || true
systemctl disable --now "$SERVICE" 2>/dev/null || true

if [ -L "$NGINX_LINK" ] && [ "$(readlink -f "$NGINX_LINK")" = "$(readlink -f "$NGINX_SITE")" ]; then unlink "$NGINX_LINK"; fi
if [ -e "$NGINX_SITE" ]; then unlink "$NGINX_SITE"; fi
if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    if nginx -t; then systemctl reload nginx; else echo "WARNING: Nginx test failed after project site removal; Nginx was not reloaded." >&2; fi
fi

for f in "/etc/systemd/system/$SERVICE" "/etc/systemd/system/$WEB_SERVICE" "$HTPASSWD_FILE" "/etc/letsencrypt/renewal-hooks/deploy/aria2-download-server-nginx-reload"; do
    [ -e "$f" ] || [ -L "$f" ] && unlink "$f"
done
systemctl daemon-reload

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    [ "$UFW_BT_TCP_ADDED" = true ] && [ -n "$BT_PORT" ] && ufw --force delete allow "$BT_PORT/tcp" || true
    [ "$UFW_BT_UDP_ADDED" = true ] && [ -n "$BT_PORT" ] && ufw --force delete allow "$BT_PORT/udp" || true
fi

# Remove only project-owned UI/state/config trees. Downloads are preserved by default.
for d in "$ARIANG_DIR" "$STATE_DIR" "$CONFIG_DIR"; do
    case "$d" in
      /var/www/ariang|/var/lib/aria2-download-server|/etc/aria2-download-server)
        [ -d "$d" ] && find "$d" -xdev -depth -delete
        ;;
      *) echo "Refusing unexpected project path: $d" >&2;;
    esac
done
# Retain timestamped AriaNg backups for safety; print their paths.
find /var/www -maxdepth 1 -type d -name 'ariang.backup-*' -print 2>/dev/null || true

if [ "$DELETE_DOWNLOADS" = true ]; then
    [ "$DOWNLOAD_DIR" = /srv/aria2-downloads ] || { echo "Refusing unexpected download path: $DOWNLOAD_DIR" >&2; exit 1; }
    [ -d "$DOWNLOAD_DIR" ] && find "$DOWNLOAD_DIR" -xdev -depth -delete
else
    echo "Downloads preserved: $DOWNLOAD_DIR"
fi

if getent passwd "$ARIA2_USER" >/dev/null; then
    if pgrep -u "$ARIA2_USER" >/dev/null 2>&1; then
        echo "User $ARIA2_USER retained because processes are still running." >&2
    else
        userdel "$ARIA2_USER"
    fi
fi

echo "aria2 Download Server removed. Nginx packages, unrelated sites, certificates, firewall rules, and downloads were preserved."
