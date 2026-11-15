#!/usr/bin/env python3
"""Forward authenticated Pages requests to the local aria2 RPC socket."""

from contextlib import closing, contextmanager
import hashlib
import json
import re
import secrets
import sqlite3
import time
from http.client import HTTPConnection, HTTPException
from http.server import BaseHTTPRequestHandler
from socketserver import ThreadingUnixStreamServer
from pathlib import Path, PurePosixPath
from urllib.parse import parse_qs, quote, urlsplit

SECRET_FILE = Path("/etc/aria2-download-server/rpc-secret")
RPC_HOST = "127.0.0.1"
RPC_PORT = 16800
GATEWAY_SOCKET = Path("/run/aria2-pages/rpc.sock")
MAX_BODY = 32 * 1024 * 1024
DATABASE = Path("/var/lib/aria2-pages/auth.sqlite")
DOWNLOADS = Path("/srv/aria2-downloads")
SESSION_TTL = 30 * 24 * 60 * 60
DOWNLOAD_TTL = 5 * 60
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_-]{43}")


@contextmanager
def database():
    with closing(sqlite3.connect(DATABASE)) as connection, connection:
        yield connection


def init_database():
    with database() as db:
        db.execute("CREATE TABLE IF NOT EXISTS sessions (digest BLOB PRIMARY KEY, expires INTEGER NOT NULL)")
        db.execute("CREATE TABLE IF NOT EXISTS tickets (digest BLOB PRIMARY KEY, expires INTEGER NOT NULL, path TEXT NOT NULL)")


def token_digest(token):
    if not TOKEN_PATTERN.fullmatch(token):
        return None
    return hashlib.sha256(token.encode("ascii")).digest()


def download_file(value):
    if not isinstance(value, str) or not value or "\x00" in value:
        return None
    relative = PurePosixPath(value)
    if relative.is_absolute() or not relative.parts or relative.name.endswith(".aria2"):
        return None
    full_path = DOWNLOADS
    for part in relative.parts:
        if part.startswith("."):
            return None
        full_path /= part
        if full_path.is_symlink():
            return None
    return relative if full_path.is_file() else None


def authorize_call(call, token):
    method_key = "methodName" if "methodName" in call else "method"
    method = call.get(method_key, "")
    if not isinstance(method, str):
        raise ValueError("Invalid method")

    params = call.get("params", [])
    if not isinstance(params, list):
        raise ValueError("Invalid parameters")
    if method.startswith("aria2."):
        call["params"] = [token, *params]
    elif method == "system.multicall":
        for item in params[0]:
            if not isinstance(item, dict) or not str(item.get("methodName", "")).startswith("aria2."):
                raise ValueError("Invalid multicall")
            authorize_call(item, token)
    elif method not in {"system.listMethods", "system.listNotifications"}:
        raise ValueError("Unknown method")


class Handler(BaseHTTPRequestHandler):
    def respond(self, status, payload=None, headers=()):
        body = json.dumps(payload).encode() if payload is not None else b""
        self.send_response(status)
        if body:
            self.send_header("Content-Type", "application/json")
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def session_digest(self):
        bearer = self.headers.get("Authorization", "")
        return token_digest(bearer.removeprefix("Bearer ")) if bearer.startswith("Bearer ") else None

    def do_GET(self):
        target = urlsplit(self.path)
        if target.path == "/session/check":
            digest = self.session_digest()
            session = None
            if digest:
                with database() as db:
                    session = db.execute("SELECT 1 FROM sessions WHERE digest = ? AND expires > ?",
                                         (digest, int(time.time()))).fetchone()
            self.respond(204 if session else 401)
        elif target.path == "/file":
            self.serve_download(parse_qs(target.query).get("ticket", [""])[0])
        else:
            self.respond(404)

    def do_DELETE(self):
        if self.path != "/session":
            self.respond(404)
            return
        digest = self.session_digest()
        if not digest:
            self.respond(401)
            return
        with database() as db:
            db.execute("DELETE FROM sessions WHERE digest = ?", (digest,))
        self.respond(204)

    def do_POST(self):
        if self.path == "/session":
            token = secrets.token_urlsafe(32)
            now = int(time.time())
            with database() as db:
                db.execute("DELETE FROM sessions WHERE expires <= ?", (now,))
                db.execute("INSERT INTO sessions VALUES (?, ?)", (token_digest(token), now + SESSION_TTL))
            self.respond(201, {"token": token})
            return
        if self.path == "/ticket":
            self.issue_download()
            return
        self.forward_rpc()

    def issue_download(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 16384:
                raise ValueError()
            path = download_file(json.loads(self.rfile.read(length)).get("path"))
        except (ValueError, AttributeError, OSError):
            self.respond(400, {"message": "Invalid file."})
            return
        if path is None:
            self.respond(404, {"message": "This file is no longer available."})
            return
        token = secrets.token_urlsafe(32)
        now = int(time.time())
        with database() as db:
            db.execute("DELETE FROM tickets WHERE expires <= ?", (now,))
            db.execute("INSERT INTO tickets VALUES (?, ?, ?)", (token_digest(token), now + DOWNLOAD_TTL, str(path)))
        self.respond(201, {"ticket": token})

    def serve_download(self, ticket):
        digest = token_digest(ticket)
        row = None
        if digest:
            with database() as db:
                row = db.execute("SELECT path FROM tickets WHERE digest = ? AND expires > ?",
                                 (digest, int(time.time()))).fetchone()
        path = download_file(row[0]) if row else None
        if path is None:
            self.respond(404)
            return
        self.respond(200, headers=(
            ("X-Accel-Redirect", "/_aria2_protected_file/" + quote(str(path))),
            ("Content-Disposition", "attachment; filename*=UTF-8''" + quote(path.name, safe="")),
        ))

    def forward_rpc(self):
        if self.path != "/jsonrpc":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                self.send_error(413)
                return
            body = json.loads(self.rfile.read(length))
            token = "token:" + SECRET_FILE.read_text().strip()
            calls = body if isinstance(body, list) else [body]
            for call in calls:
                if not isinstance(call, dict):
                    raise ValueError("Invalid request")
                authorize_call(call, token)
        except (ValueError, TypeError, IndexError):
            self.send_error(400, "Invalid JSON-RPC request")
            return
        except OSError:
            self.send_error(503, "RPC configuration unavailable")
            return

        connection = HTTPConnection(RPC_HOST, RPC_PORT, timeout=15)
        try:
            connection.request("POST", "/jsonrpc", json.dumps(body), {"Content-Type": "application/json"})
            upstream = connection.getresponse()
            payload = upstream.read()
        except (OSError, HTTPException):
            self.send_error(502, "Downloader unavailable")
            return
        finally:
            connection.close()

        self.send_response(upstream.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    init_database()
    GATEWAY_SOCKET.unlink(missing_ok=True)
    with ThreadingUnixStreamServer(str(GATEWAY_SOCKET), Handler) as server:
        server.serve_forever()
