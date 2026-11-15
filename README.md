# Isolated aria2 Download Server

Production-safe, non-Docker installation of aria2c + AriaNg + Nginx/systemd.

## Install

Edit variables at the top of `install.sh`, especially `DOMAIN`, or pass them as environment variables:

```bash
sudo DOMAIN=downloads.example.com CERTBOT_EMAIL=admin@example.com bash install.sh
```

Defaults:

- Downloads: `/srv/aria2-downloads`
- State: `/var/lib/aria2-download-server`
- Configuration: `/etc/aria2-download-server`
- AriaNg: `/var/www/ariang`
- Service: `aria2-download-server.service`
- Nginx site: `/etc/nginx/sites-available/aria2-download-server.conf`
- RPC: preferred `127.0.0.1:16800`, automatically changed on conflict
- BT: preferred `16881`, automatically changed on conflict
- Local temporary panel: preferred `127.0.0.1:18080`, automatically changed on conflict

The installer preserves its generated RPC secret and Basic Auth credentials across reruns. It updates AriaNg atomically and leaves timestamped UI/config backups.

## DNS and HTTPS

`ENABLE_HTTPS=auto` requests a certificate only when the domain resolves to the VPS public IPv4. It uses Certbot `certonly --webroot` for only the new domain and never invokes the Nginx plugin. Existing certificates and virtual hosts are not changed.

If DNS is not ready, use the localhost listener over SSH:

```bash
ssh -L 18080:127.0.0.1:18080 root@VPS_IP
```

Then open `http://127.0.0.1:18080/`. Use the final port printed by the installer.

After DNS points to the VPS, rerun the same installer. The RPC secret, credentials, downloads, and selected ports are preserved.

## BitTorrent ingress

By default no public BT firewall rule is added. Downloads still work with reduced inbound peer connectivity. To add only the selected TCP/UDP BT port:

```bash
sudo OPEN_BT_PORT=true bash install.sh
```

The RPC port is always loopback-only and is never added to UFW.

## Credentials

Root-readable copies are stored at:

- `/etc/aria2-download-server/panel-credentials`
- `/etc/aria2-download-server/rpc-secret`

AriaNg is bootstrapped for same-origin `/jsonrpc` with the generated RPC secret.

## Verification

```bash
bash -n install.sh
sudo nginx -t
sudo systemd-analyze verify /etc/systemd/system/aria2-download-server.service
systemctl is-active aria2-download-server
ss -lntp | grep aria2
```

The installer itself also performs an authenticated JSON-RPC call, downloads the legal GitHub `.gitignore` README test file, serves it under `/files/`, and checks a Range request.

## Uninstall

Preserve downloads (default):

```bash
sudo bash uninstall-aria2-download-server.sh
```

Explicitly delete downloads too:

```bash
sudo DELETE_DOWNLOADS=true bash uninstall-aria2-download-server.sh
```

The rollback does not uninstall Nginx, remove unrelated firewall rules/sites/certificates, or delete downloads unless explicitly requested.

## GitHub Pages panel

The public panel is under `docs/`. It uses the AriaNg 1.3.14 All-in-One release with an added sign-in screen. The VPS runs aria2 and keeps the downloads.

For a separate Pages deployment, set your HTTPS JSON-RPC URL in `docs/connect.js` and your Pages origin in `gateway/aria2-pages.nginx.conf`. Publish the `docs/` directory from the default branch. On the VPS, install the Python bridge at the path in its service file, enable the service, and include the Nginx location in the matching HTTPS server block. The bridge uses the existing aria2 account, local RPC port, RPC secret file, and Nginx password file. Adjust those paths and ports if your installation differs.

Sign in to the panel with the existing downloader username and password. Reload the page to sign out. The VPS's Files library is available from its original panel.
