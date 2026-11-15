#!/usr/bin/env python3
"""Forward authenticated Pages requests to the local aria2 RPC socket."""

import json
from http.client import HTTPConnection, HTTPException
from http.server import BaseHTTPRequestHandler
from socketserver import ThreadingUnixStreamServer
from pathlib import Path

SECRET_FILE = Path("/etc/aria2-download-server/rpc-secret")
RPC_HOST = "127.0.0.1"
RPC_PORT = 16800
GATEWAY_SOCKET = Path("/run/aria2-pages/rpc.sock")
MAX_BODY = 32 * 1024 * 1024


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
    def do_POST(self):
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
    GATEWAY_SOCKET.unlink(missing_ok=True)
    with ThreadingUnixStreamServer(str(GATEWAY_SOCKET), Handler) as server:
        server.serve_forever()
