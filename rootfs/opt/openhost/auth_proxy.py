#!/usr/bin/env python3
"""auth_proxy.py — OpenHost SSO front-door for Mastodon.

Sits at :8080 (the port openhost.toml declares to the OpenHost router)
and reverse-proxies every request to Caddy at 127.0.0.1:8090, which in
turn fans out to Puma (:3000) and the streaming node server (:4000).

The *only* behaviour this proxy adds on top of a transparent reverse
proxy is owner auto-login:

  When the OpenHost router forwards a request from the authenticated
  zone owner it stamps `X-OpenHost-Is-Owner: true`. On the owner's first
  top-level HTML navigation that does not already carry a Mastodon
  session cookie, we ask the Ruby session-minter (over a loopback UNIX
  socket) to mint a real Mastodon session for the bootstrap `operator`
  account, then 302 the owner back to the URL they asked for with the
  minted cookies attached. From then on Mastodon's own session cookies
  carry them and this proxy is a pure passthrough.

Everything else — federation inbox deliveries, WebFinger, public
timelines, the streaming WebSocket, anonymous visitors reading public
posts, non-owner logged-in users — flows straight through untouched.
This is essential: Mastodon federates with the wider fediverse, so
`public_paths = ["/"]` in openhost.toml means the OpenHost owner-auth
gate is disabled and random remote servers reach us directly. We must
never mint a session for, redirect, or otherwise interfere with those
requests. The owner-auto-login path is gated on the `X-OpenHost-Is-Owner`
header, which only the OpenHost router can set, so remote/anonymous
traffic can never trigger it.

Design constraints that shaped this file:

  * No third-party Python deps. Mastodon's base image is Ruby; we add
    only the system `python3`. Stdlib http.server + socket only.
  * Streaming (`/api/v1/streaming`) is long-lived WebSocket/SSE. We
    bypass this proxy's buffering entirely for those paths and hand the
    socket to a raw bidirectional pump so upgrades and long polls work.
  * The proxy must be transparent about the Host header. The OpenHost
    router already sets X-Forwarded-Host; Caddy rewrites Host from it
    downstream. We forward all headers unchanged so Caddy's existing
    logic keeps working.
"""

import http.client
import os
import select
import socket
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = int(os.environ.get("AUTH_PROXY_PORT", "8080"))

# Caddy front-door (the former :8080 listener, moved to :8090 so this
# proxy can take the public port).
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = int(os.environ.get("CADDY_PORT", "8090"))

# UNIX socket the Ruby session-minter listens on.
MINTER_SOCK = os.environ.get("MINTER_SOCK", "/run/mastodon/minter.sock")

# The OpenHost health-check path (must match openhost.toml's
# routing.health_check). The auth-proxy owns the public port and starts
# BEFORE the Mastodon backend is ready (first boot walks ~250 db
# migrations + a Rails cold boot, which can take a few minutes). During
# that window Caddy/puma aren't listening yet, so proxying the health
# check upstream would fail and OpenHost would mark the app "App started
# but not responding to HTTP" even though it's just still booting.
#
# To avoid that false failure, the auth-proxy answers the health path
# itself with a 200 whenever the upstream isn't reachable yet. Once the
# backend is up, the health check is proxied through to Mastodon's real
# /health as normal. Net effect: OpenHost sees a live, healthy HTTP
# server from the very first second, and the slow first boot no longer
# trips a spurious failure.
HEALTH_PATH = os.environ.get("HEALTH_PATH", "/health")

# Header the OpenHost router stamps for the authenticated zone owner.
OWNER_HEADER = "x-openhost-is-owner"

# Mastodon session cookies. If any of these is already present we treat
# the visitor as having a (possibly stale) session and do NOT auto-login
# — that avoids clobbering a real login and avoids a redirect loop.
MASTODON_SESSION_COOKIES = ("_mastodon_session", "_session_id")

# Anti-loop guard. We set this short-lived marker cookie on the
# auto-login redirect. If an owner comes back to us STILL without a
# Mastodon session but WITH this marker, the browser is not storing the
# minted session cookies (private-mode edge cases, cookie policy, clock
# skew rejecting the expiry, etc.). Rather than mint again and loop, we
# pass through to Mastodon's normal login form and clear the marker.
AUTOLOGIN_MARKER_COOKIE = "_oh_sso_attempt"

# Paths we must never auto-login on even for the owner: the login/logout
# machinery, the streaming endpoint, and anything that isn't a browser
# navigation. Auto-login only makes sense for top-level HTML GETs.
NO_AUTOLOGIN_PREFIXES = (
    "/auth/",           # Devise sign-in/out/registration
    "/api/",            # REST + streaming; never HTML navigations
    "/oauth/",          # OAuth authorize/token
    "/.well-known/",    # WebFinger, nodeinfo, host-meta
    "/inbox",           # ActivityPub shared inbox
    "/users/",          # ActivityPub actor inboxes/outboxes
    "/nodeinfo",
    "/health",
    "/manifest",
    "/packs/",          # asset bundles
    "/system/",         # uploads
    "/sw.js",
    "/assets/",
)

# Hop-by-hop headers we must not forward verbatim (RFC 7230 §6.1).
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


def log(msg):
    sys.stderr.write(f"[auth-proxy] {msg}\n")
    sys.stderr.flush()


# One-way latch: flips True the first time we observe the Caddy upstream
# reachable, and never flips back. It bounds the "serve a fake 200 on the
# health path" behaviour to the INITIAL boot window only. Rationale: the
# placeholder exists so OpenHost doesn't kill a still-booting instance
# whose backend hasn't come up yet. But once the backend HAS been up, a
# later outage is a real failure that OpenHost must see — so after the
# latch is set we always proxy the health check through and let genuine
# 5xx/connection errors surface instead of masking them forever.
_backend_ever_ready = False
_backend_ready_lock = threading.Lock()


def _mark_backend_ready():
    global _backend_ever_ready
    if not _backend_ever_ready:
        with _backend_ready_lock:
            if not _backend_ever_ready:
                _backend_ever_ready = True
                log("backend reachable; health check now proxies through")


def _backend_was_ever_ready():
    return _backend_ever_ready


def mint_session(remote_ip, user_agent, timeout=15.0):
    """Ask the Ruby minter for a fresh owner session.

    Returns a list of (name, value, max_age) cookie tuples on success,
    or None on any failure (in which case we just proxy through and the
    owner sees Mastodon's normal login form — a safe degradation).
    """
    import json

    req = "MINT {ip} {ua}\n".format(
        ip=remote_ip or "127.0.0.1",
        ua=urllib.parse.quote(user_agent or ""),
    )
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(MINTER_SOCK)
            s.sendall(req.encode("utf-8"))
            buf = b""
            while b"\n" not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
        line = buf.split(b"\n", 1)[0].decode("utf-8", "replace")
        data = json.loads(line)
    except (OSError, ValueError) as e:
        log(f"minter call failed: {e}")
        return None

    if not data.get("ok"):
        log(f"minter refused: {data.get('error')}")
        return None

    cookies = []
    for c in data.get("cookies", []):
        cookies.append((c["name"], c["value"], int(c.get("max_age", 0))))
    return cookies


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # Quieter default logging; we log what we care about ourselves.
    def log_message(self, *args):
        pass

    # ---- helpers ------------------------------------------------------

    def _client_ip(self):
        xff = self.headers.get("X-Forwarded-For", "")
        if xff:
            return xff.split(",")[0].strip()
        return self.client_address[0] if self.client_address else "127.0.0.1"

    def _cookie_present(self, name):
        raw = self.headers.get("Cookie", "")
        return bool(raw) and f"{name}=" in raw

    def _has_mastodon_session(self):
        # Cheap substring check is enough — cookie names are distinctive.
        return any(self._cookie_present(name) for name in MASTODON_SESSION_COOKIES)

    def _autologin_already_attempted(self):
        return self._cookie_present(AUTOLOGIN_MARKER_COOKIE)

    def _is_owner(self):
        return self.headers.get(OWNER_HEADER, "").strip().lower() == "true"

    def _is_html_navigation(self):
        if self.command != "GET":
            return False
        accept = self.headers.get("Accept", "")
        return "text/html" in accept.lower()

    def _path_blocks_autologin(self):
        path = urllib.parse.urlparse(self.path).path
        return any(path.startswith(p) for p in NO_AUTOLOGIN_PREFIXES)

    def _should_autologin(self):
        return (
            self._is_owner()
            and not self._has_mastodon_session()
            and not self._autologin_already_attempted()
            and self._is_html_navigation()
            and not self._path_blocks_autologin()
        )

    # ---- request entrypoints -----------------------------------------

    def do_GET(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_PUT(self):
        self._dispatch()

    def do_DELETE(self):
        self._dispatch()

    def do_PATCH(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

    def do_OPTIONS(self):
        self._dispatch()

    # ---- core ---------------------------------------------------------

    def _dispatch(self):
        path = urllib.parse.urlparse(self.path).path

        # Health check: keep the public port answering 200 during the slow
        # first boot even before the Mastodon backend is up, so OpenHost
        # doesn't flag a still-booting instance as "not responding to
        # HTTP".
        #
        # We only serve the fake "starting" 200 UNTIL the backend has been
        # seen reachable at least once. After that, we always proxy the
        # health check through to Mastodon's real /health so a genuine
        # backend crash (which must be reported to OpenHost) is never
        # masked by a permanent placeholder 200.
        if path == HEALTH_PATH:
            if self._upstream_ready():
                _mark_backend_ready()
                self._proxy()
            elif _backend_was_ever_ready():
                # Backend was up and is now unreachable — a real failure.
                # Let it surface as a 502 rather than a fake 200.
                self._send_bad_gateway()
            else:
                # Still in the initial boot window; keep OpenHost happy.
                self._send_starting_health()
            return

        # Streaming / WebSocket upgrade → raw tunnel, no buffering.
        upgrade = self.headers.get("Upgrade", "").lower()
        if upgrade == "websocket" or path.startswith("/api/v1/streaming"):
            self._tunnel()
            return

        if self._should_autologin():
            cookies = mint_session(
                self._client_ip(), self.headers.get("User-Agent", "")
            )
            if cookies:
                self._send_autologin_redirect(cookies)
                return
            # Minter unavailable → fall through and proxy normally; the
            # owner will just see the login form. Never block the app on
            # SSO being down.

        self._proxy()

    def _send_autologin_redirect(self, cookies):
        """302 back to the same URL, attaching the minted session cookies.

        We redirect to the exact URL the owner requested so that after
        the browser stores the cookies and re-requests, this proxy sees
        _mastodon_session present, skips auto-login, and proxies through
        to a now-authenticated Mastodon.
        """
        location = self.path  # same path+query, relative redirect
        body = b"Signing you in..."
        try:
            self.send_response(302)
            self.send_header("Location", location)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for name, value, max_age in cookies:
                # Secure + HttpOnly + SameSite=Lax + path=/. Secure is
                # safe: the OpenHost router always fronts us over TLS.
                cookie = (
                    f"{name}={value}; Path=/; Max-Age={max_age}; "
                    f"HttpOnly; Secure; SameSite=Lax"
                )
                self.send_header("Set-Cookie", cookie)
            # Anti-loop marker: if the browser bounces back to us still
            # without a Mastodon session but carrying this, we'll stop
            # minting and let the login form through. 5-minute lifetime so
            # a normal (successful) login clears it well within the window
            # and a genuinely fresh login attempt later isn't blocked.
            self.send_header(
                "Set-Cookie",
                f"{AUTOLOGIN_MARKER_COOKIE}=1; Path=/; Max-Age=300; "
                f"HttpOnly; Secure; SameSite=Lax",
            )
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _proxy(self):
        # Read request body if present. If the client declared a
        # Content-Length we must deliver exactly that many bytes upstream
        # or not forward the request at all: forwarding the original
        # Content-Length header with a short/empty body would leave the
        # upstream (Caddy/puma) blocking on bytes that never arrive. On a
        # read failure we bail out with a 502 rather than send a
        # malformed, length-mismatched request.
        body = b""
        cl = self.headers.get("Content-Length")
        if cl:
            try:
                body = self.rfile.read(int(cl))
            except ValueError:
                self._send_bad_gateway()
                return
            except OSError as e:
                log(f"request body read failed: {e}")
                self._send_bad_gateway()
                return
            if len(body) != int(cl):
                log("request body shorter than Content-Length; aborting")
                self._send_bad_gateway()
                return

        # Build upstream headers: copy everything except hop-by-hop.
        # Iterate items() (one tuple per header occurrence) rather than
        # keys()+get_all(): keys() yields duplicate names for repeated
        # headers and get_all() returns every value for that name, so the
        # keys()+get_all() combination would forward a header that appears
        # N times as N*N copies. items() yields each occurrence exactly
        # once.
        out_headers = []
        for key, value in self.headers.items():
            if key.lower() in HOP_BY_HOP:
                continue
            out_headers.append((key, value))

        try:
            conn = http.client.HTTPConnection(
                UPSTREAM_HOST, UPSTREAM_PORT, timeout=310
            )
            conn.putrequest(
                self.command, self.path, skip_host=True, skip_accept_encoding=True
            )
            for key, value in out_headers:
                conn.putheader(key, value)
            if cl:
                # Content-Length already among headers; body follows.
                pass
            conn.endheaders()
            if body:
                conn.send(body)

            resp = conn.getresponse()
        except OSError as e:
            log(f"upstream connect failed: {e}")
            self._send_bad_gateway()
            return

        # We got a response from the upstream, so the backend is up. Flip
        # the readiness latch so the health path stops serving the boot
        # placeholder and starts reporting real backend status.
        _mark_backend_ready()

        try:
            # Relay response headers, dropping hop-by-hop. Crucially,
            # http.client has already de-chunked the body for us (we read
            # it below via resp.read), and `transfer-encoding` is in
            # HOP_BY_HOP so it's stripped — but that means the client is
            # left without body framing when the upstream used chunked
            # encoding and sent no Content-Length. Detect that case and
            # frame the body by connection-close (a valid HTTP/1.1
            # length-delimiter) rather than leaving the client to hang or
            # misparse a phantom chunked stream.
            relay_headers = []
            has_content_length = False
            for key, value in resp.getheaders():
                lk = key.lower()
                if lk in HOP_BY_HOP:
                    continue
                if lk == "content-length":
                    has_content_length = True
                relay_headers.append((key, value))

            close_delimited = not has_content_length
            if close_delimited:
                # We must not keep this connection alive: without a
                # Content-Length or Transfer-Encoding the only way the
                # client knows the body is complete is EOF.
                self.close_connection = True

            self.send_response_only(resp.status, resp.reason)
            for key, value in relay_headers:
                self.send_header(key, value)
            if close_delimited and self.request_version != "HTTP/1.0":
                self.send_header("Connection", "close")
            self.end_headers()

            if self.command != "HEAD":
                # Stream the body through in chunks.
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    try:
                        self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        break
        finally:
            conn.close()

    def _send_bad_gateway(self):
        body = b"502 Bad Gateway (Mastodon starting up)"
        try:
            self.send_response(502)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Retry-After", "5")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _upstream_ready(self):
        """Cheap TCP connect probe to the Caddy upstream.

        Used only on the health path to decide whether to proxy the real
        Mastodon health check or answer a local "starting" 200. A short
        timeout keeps the health probe fast during boot.
        """
        try:
            with socket.create_connection(
                (UPSTREAM_HOST, UPSTREAM_PORT), timeout=2
            ):
                return True
        except OSError:
            return False

    def _send_starting_health(self):
        """Answer the health path with 200 while the backend is still
        booting, so OpenHost's health check passes during the slow first
        boot instead of flagging a spurious failure."""
        body = b"OK (Mastodon starting up)\n"
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _tunnel(self):
        """Raw bidirectional byte pump to Caddy for WebSocket/streaming.

        We reconstruct the request line + headers verbatim, open a plain
        TCP socket to Caddy, replay them, then shuttle bytes both ways
        until either side closes. This preserves the WebSocket upgrade
        handshake and SSE long-polls that http.client would mangle.
        """
        try:
            upstream = socket.create_connection(
                (UPSTREAM_HOST, UPSTREAM_PORT), timeout=10
            )
        except OSError as e:
            log(f"tunnel connect failed: {e}")
            self._send_bad_gateway()
            return

        # Rebuild and send the original request head. Use items() (one
        # tuple per header occurrence) — keys()+get_all() would duplicate
        # repeated headers N*N times (see _proxy for the same fix).
        head = [f"{self.command} {self.path} {self.request_version}"]
        for key, value in self.headers.items():
            head.append(f"{key}: {value}")
        head.append("")
        head.append("")
        try:
            upstream.sendall("\r\n".join(head).encode("latin-1"))
        except OSError as e:
            log(f"tunnel head send failed: {e}")
            upstream.close()
            return

        client = self.connection
        client.setblocking(False)
        upstream.setblocking(False)
        sockets = [client, upstream]
        try:
            while True:
                readable, _, exceptional = select.select(sockets, [], sockets, 300)
                if exceptional:
                    break
                if not readable:
                    # Idle timeout window elapsed with no data; keep
                    # looping — WebSockets can idle. select's timeout is
                    # just to avoid a truly infinite block if both peers
                    # vanish without FIN.
                    continue
                for s in readable:
                    try:
                        data = s.recv(65536)
                    except (BlockingIOError, InterruptedError):
                        continue
                    except OSError:
                        return
                    if not data:
                        return
                    dst = upstream if s is client else client
                    try:
                        dst.sendall(data)
                    except OSError:
                        return
        finally:
            upstream.close()


def main():
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.daemon_threads = True
    log(f"listening on {LISTEN_HOST}:{LISTEN_PORT} -> "
        f"{UPSTREAM_HOST}:{UPSTREAM_PORT}; minter={MINTER_SOCK}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
