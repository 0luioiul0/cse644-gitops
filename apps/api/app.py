#!/usr/bin/env python3
"""CSE644 Assignment 03 - Python application workload (listens on port 8888).

Carried forward from Assignment 02 and extended for this assignment with a
Prometheus exposition endpoint, plus two endpoints that exist so a load
generator can move the dashboard in a controlled way.

Standard library only. The image needs no package index at build time, which
also means there is no `prometheus_client` here - the exposition format is
written by hand in `render_metrics()`. That is a deliberate trade-off, recorded
in the README: the format is small enough to emit correctly, and a
dependency-free image keeps the build reproducible offline.

What each metric is for
-----------------------
  cse644_api_requests_total          rate() gives request rate; the `status`
                                     label gives the error ratio.
  cse644_api_request_duration_seconds
                                     a histogram, so latency quantiles are
                                     computed at query time from bucket counts
                                     rather than pre-averaged in the app.
  cse644_api_requests_in_flight      concurrency. Rises when work queues up,
                                     which an averaged latency figure hides.
  cse644_api_notes_stored            application state, not infrastructure
                                     state: how many notes are on the
                                     PersistentVolume. It survives a Pod
                                     replacement, and the graph shows that.
  cse644_api_healthy                 what the liveness endpoint would answer.
  cse644_api_build_info              the running version, as a label. Lets a
                                     deployment be located on a graph.

Routes
    GET  /                    HTML status page
    GET  /api/info            JSON: pod, node, config, secret status, storage
    GET  /api/notes           the notes stored on the persistent volume
    POST /api/notes           append a note (form field or raw body "text")
    GET  /api/work?ms=N       sleep N ms - generates latency and concurrency
    GET  /api/cpu?ms=N        busy-loop N ms - generates CPU load
    GET  /api/boom            always 500 - generates a controlled error rate
    GET  /metrics             Prometheus exposition
    GET  /healthz             liveness probe target
    GET  /readyz              readiness probe target
    POST /debug/break         make /healthz fail, to demonstrate liveness
"""

import hashlib
import json
import os
import socket
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8888"))
DATA_DIR = os.environ.get("DATA_DIR", "/data")
NOTES = os.path.join(DATA_DIR, "notes.log")
READY_DELAY = float(os.environ.get("READY_DELAY_SECONDS", "5"))

APP_VERSION = os.environ.get("APP_VERSION", "0.0.0-dev")
GREETING = os.environ.get("APP_GREETING", "(no APP_GREETING configured)")
APP_ENV = os.environ.get("APP_ENV", "unset")
POD_NAME = os.environ.get("POD_NAME", socket.gethostname())
NODE_NAME = os.environ.get("NODE_NAME", "unknown")

STARTED = time.time()
HEALTHY = True

# Ceilings on what a single request may ask for. Without them, one crafted
# query string could wedge the process and take the liveness probe down with
# it - which would look like an application bug rather than a load-generator
# mistake.
MAX_WORK_MS = 5000
MAX_CPU_MS = 1000

# ---------------------------------------------------------------------------
# Metric state
#
# ThreadingHTTPServer serves each connection on its own thread, so every
# counter below is mutated under one lock. Python's GIL makes `x += 1` look
# atomic, but read-modify-write on a dict entry is not, and the histogram
# updates several values that must move together.
# ---------------------------------------------------------------------------
_LOCK = threading.Lock()

# (method, route, status) -> count
_REQUESTS = {}
# route -> [bucket counts..., sum, count]
_LATENCY = {}
_IN_FLIGHT = 0

LATENCY_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0)

# Only these paths become label values. Anything else is folded into "other",
# so a scan for /wp-admin.php cannot create unbounded label cardinality - the
# classic way an instrumented service takes its own monitoring down.
KNOWN_ROUTES = frozenset({
    "/", "/api/info", "/api/notes", "/api/work", "/api/cpu", "/api/boom",
    "/metrics", "/healthz", "/readyz", "/debug/break",
})


def route_label(path):
    return path if path in KNOWN_ROUTES else "other"


def observe(method, route, status, elapsed):
    global _REQUESTS, _LATENCY
    with _LOCK:
        key = (method, route, str(status))
        _REQUESTS[key] = _REQUESTS.get(key, 0) + 1

        entry = _LATENCY.get(route)
        if entry is None:
            entry = {"buckets": [0] * len(LATENCY_BUCKETS), "sum": 0.0, "count": 0}
            _LATENCY[route] = entry
        entry["sum"] += elapsed
        entry["count"] += 1
        # Store *per-bucket* counts, not cumulative ones: increment the
        # smallest bucket this observation fits in and stop. render_metrics()
        # is what turns these into the cumulative counts the exposition format
        # requires. Incrementing every matching bucket here and accumulating
        # there as well would count each observation once per bucket - which is
        # exactly the bug this comment exists to prevent a repeat of.
        # An observation larger than the last edge lands in no bucket at all;
        # +Inf is emitted from `count`, so it is still counted.
        for i, edge in enumerate(LATENCY_BUCKETS):
            if elapsed <= edge:
                entry["buckets"][i] += 1
                break


def _escape(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def render_metrics():
    """Prometheus text exposition format, version 0.0.4."""
    out = []
    now_notes = storage_status().get("note_count", 0)

    with _LOCK:
        requests = dict(_REQUESTS)
        latency = {r: {"buckets": list(e["buckets"]), "sum": e["sum"], "count": e["count"]}
                   for r, e in _LATENCY.items()}
        in_flight = _IN_FLIGHT

    out.append("# HELP cse644_api_build_info Version of the running application, as a label.")
    out.append("# TYPE cse644_api_build_info gauge")
    out.append('cse644_api_build_info{version="%s",app_env="%s"} 1'
               % (_escape(APP_VERSION), _escape(APP_ENV)))

    out.append("# HELP cse644_api_requests_total Total HTTP requests handled, by method, route and status.")
    out.append("# TYPE cse644_api_requests_total counter")
    for (method, route, status), count in sorted(requests.items()):
        out.append('cse644_api_requests_total{method="%s",route="%s",status="%s"} %d'
                   % (_escape(method), _escape(route), _escape(status), count))

    out.append("# HELP cse644_api_request_duration_seconds Request latency in seconds.")
    out.append("# TYPE cse644_api_request_duration_seconds histogram")
    for route in sorted(latency):
        entry = latency[route]
        cumulative = 0
        for i, edge in enumerate(LATENCY_BUCKETS):
            cumulative += entry["buckets"][i]
            out.append('cse644_api_request_duration_seconds_bucket{route="%s",le="%s"} %d'
                       % (_escape(route), _fmt(edge), cumulative))
        out.append('cse644_api_request_duration_seconds_bucket{route="%s",le="+Inf"} %d'
                   % (_escape(route), entry["count"]))
        out.append('cse644_api_request_duration_seconds_sum{route="%s"} %s'
                   % (_escape(route), _fmt(entry["sum"])))
        out.append('cse644_api_request_duration_seconds_count{route="%s"} %d'
                   % (_escape(route), entry["count"]))

    out.append("# HELP cse644_api_requests_in_flight Requests currently being served.")
    out.append("# TYPE cse644_api_requests_in_flight gauge")
    out.append("cse644_api_requests_in_flight %d" % in_flight)

    out.append("# HELP cse644_api_notes_stored Notes currently on the persistent volume.")
    out.append("# TYPE cse644_api_notes_stored gauge")
    out.append("cse644_api_notes_stored %d" % now_notes)

    out.append("# HELP cse644_api_healthy 1 if the liveness endpoint reports healthy, 0 otherwise.")
    out.append("# TYPE cse644_api_healthy gauge")
    out.append("cse644_api_healthy %d" % (1 if HEALTHY else 0))

    out.append("# HELP cse644_api_start_time_seconds Unix time at which the process started.")
    out.append("# TYPE cse644_api_start_time_seconds gauge")
    out.append("cse644_api_start_time_seconds %s" % _fmt(STARTED))

    return "\n".join(out) + "\n"


def _fmt(value):
    """Render a float the way the exposition format expects."""
    if value == int(value):
        return str(int(value))
    return repr(float(value))


# ---------------------------------------------------------------------------
# Application state
# ---------------------------------------------------------------------------
def secret_status():
    """Describe the injected Secret without ever revealing it."""
    value = os.environ.get("API_KEY")
    if not value:
        return {"present": False, "fingerprint": None, "length": 0}
    digest = hashlib.sha256(value.encode()).hexdigest()
    return {
        "present": True,
        # A truncated hash proves the app received a specific value and lets it
        # be compared against the same hash taken elsewhere; it does not reveal
        # the value itself.
        "fingerprint": "sha256:" + digest[:16],
        "length": len(value),
    }


def storage_status():
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        lines = []
        if os.path.exists(NOTES):
            with open(NOTES, encoding="utf-8") as fh:
                lines = [l.rstrip("\n") for l in fh if l.strip()]
        st = os.statvfs(DATA_DIR)
        return {
            "dir": DATA_DIR,
            "writable": os.access(DATA_DIR, os.W_OK),
            "notes": lines,
            "note_count": len(lines),
            "capacity_mb": round(st.f_blocks * st.f_frsize / 1e6, 1),
        }
    except OSError as exc:
        return {"dir": DATA_DIR, "error": str(exc), "note_count": 0}


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CSE644 &middot; API workload</title>
<style>
 body{{margin:0;padding:3rem 1.25rem;background:#0f1115;color:#e7e9ee;
      font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}}
 .card{{max-width:46rem;margin:0 auto;background:#171a21;border:1px solid #262b36;
        border-radius:14px;padding:2.5rem}}
 .eyebrow{{margin:0 0 .5rem;font-size:.78rem;letter-spacing:.14em;text-transform:uppercase;color:#4aa3ff}}
 h1{{margin:0 0 .35rem;font-size:1.6rem;line-height:1.3}}
 .env{{display:inline-block;padding:.2rem .6rem;border-radius:999px;font-size:.78rem;
       background:rgba(74,163,255,.16);border:1px solid rgba(74,163,255,.45);color:#9fcbff}}
 .ver{{display:inline-block;margin-left:.4rem;padding:.2rem .6rem;border-radius:999px;font-size:.78rem;
       background:rgba(94,214,154,.14);border:1px solid rgba(94,214,154,.42);color:#8fe3ba}}
 p{{color:#99a1b3}}
 table{{width:100%;border-collapse:collapse;margin-top:1.25rem}}
 td{{padding:.42rem 0;border-bottom:1px dashed #262b36;vertical-align:top}}
 td:first-child{{color:#99a1b3;width:13rem}}
 code{{font-family:ui-monospace,Menlo,Consolas,monospace;background:rgba(127,145,180,.16);
       padding:.12em .38em;border-radius:4px}}
 .ok{{color:#5ed69a}}
</style>
</head>
<body>
<div class="card">
  <p class="eyebrow">Cloud Computing CSE644 &middot; Assignment 03 &middot; GitOps</p>
  <h1>{greeting}</h1>
  <p><span class="env">environment: {app_env}</span><span class="ver">version {version}</span></p>
  <p>Everything on this page is declared in Git and applied to the cluster by
     Argo CD. Nothing here was created with <code>kubectl apply</code>.</p>
  <table>
    <tr><td>Pod</td><td><code>{pod}</code></td></tr>
    <tr><td>Node</td><td><code>{node}</code></td></tr>
    <tr><td>Image version</td><td><code>{version}</code></td></tr>
    <tr><td>Listening on</td><td><code>0.0.0.0:{port}</code></td></tr>
    <tr><td>Secret API_KEY</td><td class="ok">{secret_line}</td></tr>
    <tr><td>Persistent volume</td><td><code>{data_dir}</code> &mdash; {note_count} note(s) stored</td></tr>
    <tr><td>Uptime</td><td><code>{uptime:.1f}s</code></td></tr>
  </table>
  <p style="margin-top:1.5rem">metrics: <code>GET /metrics</code> &nbsp;&middot;&nbsp;
     JSON: <code>GET /api/info</code> &nbsp;&middot;&nbsp;
     notes: <code>GET /api/notes</code></p>
</div>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "CSE644ApiServer/3.0"
    protocol_version = "HTTP/1.1"

    # ---------------------------------------------------------------- helpers
    def _send(self, code, body, ctype):
        self._status = code
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Pod-Name", POD_NAME)
        self.send_header("X-Node-Name", NODE_NAME)
        self.send_header("X-App-Version", APP_VERSION)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, payload):
        self._send(code, (json.dumps(payload, indent=2) + "\n").encode(),
                   "application/json; charset=utf-8")

    def _text(self, code, text):
        self._send(code, text.encode(), "text/plain; charset=utf-8")

    def _path(self):
        return urllib.parse.urlsplit(self.path).path.rstrip("/") or "/"

    def _query(self):
        return urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)

    def _int_arg(self, name, default, ceiling):
        raw = self._query().get(name, [str(default)])[0]
        try:
            return max(0, min(int(float(raw)), ceiling))
        except ValueError:
            return default

    # --------------------------------------------------------- instrumentation
    def handle_one_request(self):
        """Wrap every request so latency and concurrency are measured once,
        here, rather than being sprinkled through each route."""
        global _IN_FLIGHT
        with _LOCK:
            _IN_FLIGHT += 1
        start = time.time()
        self._status = 0
        try:
            BaseHTTPRequestHandler.handle_one_request(self)
        finally:
            elapsed = time.time() - start
            with _LOCK:
                _IN_FLIGHT -= 1
            # command/path are unset if the client dropped before sending a
            # request line; there is nothing meaningful to record then.
            if self._status and getattr(self, "command", None):
                observe(self.command, route_label(self._path()), self._status, elapsed)

    # ------------------------------------------------------------------ verbs
    def do_GET(self):
        path = self._path()

        if path == "/metrics":
            self._send(200, render_metrics().encode(),
                       "text/plain; version=0.0.4; charset=utf-8")
            return

        if path == "/healthz":
            if HEALTHY:
                self._text(200, "ok\n")
            else:
                self._text(500, "liveness deliberately broken via /debug/break\n")
            return

        if path == "/readyz":
            warm = time.time() - STARTED
            if warm < READY_DELAY:
                self._text(503, "warming up: %.1fs of %.1fs\n" % (warm, READY_DELAY))
            else:
                self._text(200, "ready\n")
            return

        # ---- load-generation endpoints -------------------------------------
        if path == "/api/work":
            # Sleeping, not spinning: this simulates waiting on a downstream
            # dependency. It raises latency and in-flight count without
            # competing for the GIL, so the probes keep answering.
            ms = self._int_arg("ms", 100, MAX_WORK_MS)
            time.sleep(ms / 1000.0)
            self._json(200, {"slept_ms": ms, "pod": POD_NAME})
            return

        if path == "/api/cpu":
            # Spinning, on purpose: this is the one that moves the container
            # CPU graph. Capped at 1s so it cannot starve the liveness probe.
            ms = self._int_arg("ms", 50, MAX_CPU_MS)
            deadline = time.time() + ms / 1000.0
            iterations = 0
            while time.time() < deadline:
                iterations += 1
            self._json(200, {"burned_ms": ms, "iterations": iterations, "pod": POD_NAME})
            return

        if path == "/api/boom":
            # A deliberate, labelled failure so the dashboard's error ratio has
            # something real to plot. It is not an exception - the response is
            # a normal 500 - so it never restarts the container.
            self._text(500, "deliberate failure for the error-rate demonstration\n")
            return

        # ---- application endpoints -----------------------------------------
        if path == "/api/info":
            self._json(200, {
                "service": "cse644-api",
                "version": APP_VERSION,
                "pod": POD_NAME,
                "node": NODE_NAME,
                "port": PORT,
                "config": {"APP_GREETING": GREETING, "APP_ENV": APP_ENV},
                "secret": secret_status(),
                "storage": storage_status(),
                "uptime_seconds": round(time.time() - STARTED, 1),
                "healthy": HEALTHY,
            })
            return

        if path == "/api/notes":
            self._json(200, {"notes": storage_status().get("notes", [])})
            return

        if path == "/":
            st = storage_status()
            sec = secret_status()
            secret_line = ("delivered, {} ({} chars) - value never rendered"
                           .format(sec["fingerprint"], sec["length"])
                           if sec["present"] else "NOT present")
            self._send(200, PAGE.format(
                greeting=GREETING, app_env=APP_ENV, pod=POD_NAME, node=NODE_NAME,
                port=PORT, secret_line=secret_line, data_dir=DATA_DIR,
                version=APP_VERSION, note_count=st.get("note_count", "?"),
                uptime=time.time() - STARTED,
            ).encode(), "text/html; charset=utf-8")
            return

        self._text(404, "not found\n")

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        global HEALTHY
        path = self._path()
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""

        if path == "/debug/break":
            HEALTHY = False
            print("[debug] liveness broken on request; kubelet should restart "
                  "this container", flush=True)
            self._text(200, "healthz will now fail\n")
            return

        if path == "/api/notes":
            text = raw.strip()
            if text.startswith("text="):
                text = urllib.parse.unquote_plus(text[5:])
            if not text:
                self._text(400, "empty note\n")
                return
            stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            line = "%s  pod=%s  %s" % (stamp, POD_NAME, text)
            os.makedirs(DATA_DIR, exist_ok=True)
            with open(NOTES, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
            print("[notes] appended to %s by %s" % (NOTES, POD_NAME), flush=True)
            self._json(201, {"stored": line, "file": NOTES})
            return

        self._text(404, "not found\n")

    def log_message(self, fmt, *args):
        # The probes and the Prometheus scrape together generate several
        # requests a second. Logging them would bury the lines that matter.
        # `self.path` is unset when the request line itself was malformed,
        # which is exactly when the log line is worth keeping.
        if getattr(self, "path", None) and self._path() in ("/healthz", "/readyz", "/metrics"):
            return
        print("[%s] %s" % (self.log_date_time_string(), fmt % args), flush=True)


def main():
    sec = secret_status()
    print("cse644-api %s starting on 0.0.0.0:%d" % (APP_VERSION, PORT), flush=True)
    print("  pod=%s node=%s" % (POD_NAME, NODE_NAME), flush=True)
    print("  config: APP_ENV=%s APP_GREETING=%r" % (APP_ENV, GREETING), flush=True)
    # Deliberately logs only presence and fingerprint - never the value itself.
    print("  secret: API_KEY %s" % (
        "present, %s (%d chars)" % (sec["fingerprint"], sec["length"])
        if sec["present"] else "ABSENT"), flush=True)
    print("  storage: %s" % DATA_DIR, flush=True)
    print("  readiness gate: %.1fs warm-up" % READY_DELAY, flush=True)
    print("  metrics: http://0.0.0.0:%d/metrics" % PORT, flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
