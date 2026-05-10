#!/usr/bin/env python3
"""MCP fleet shallow health probe.

For each MCP server in the fleet, GET its `/health` endpoint via auth-proxy.
The path is unauthenticated by design (cookbooks/cognee/files/auth-proxy/proxy.py
short-circuits /health before the bearer check) so the prober needs no OAuth
client credentials.

Emit Prometheus textfile metrics per server: phase=health success/latency plus
the legacy `mcp_probe_e2e_success` aggregate (now equivalent to phase=health
since this is a single-phase probe).

Earlier revisions exercised the full SSE + JSON-RPC initialize + tools/list
chain. That deeper coverage was traded for stability after probe-induced SSE
sessions accumulated as ESTABLISHED conns inside cognee-mcp and exhausted its
accept budget. Shallow `/health` checks plus the auth-proxy SSE close fix in
cookbooks/cognee/files/auth-proxy/proxy.py replace that workload with a
bounded request that closes cleanly every time.

Stdlib only — keeps the prober deployable on a minimal LXC.

Env vars (set by systemd service unit):
  MCP_BASE_URL         e.g. https://mcp.ohno.be
  TEXTFILE_OUT         e.g. /var/lib/node_exporter/textfile/mcp_probe.prom
  PROBE_TIMEOUT_S      default 5
"""

import os
import socket
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any

# Force IPv4 lookups. The PVE LXC's /etc/resolv.conf points at
# 192.168.1.253 (RTX router) which doesn't answer AAAA queries — leaving
# c-ares / glibc's parallel A+AAAA lookup hung for 8s+ before giving up.
# The synchronous getaddrinfo path used by urllib never sees a timeout
# and silently bricks the prober. Forcing AF_INET is the same workaround
# `curl -4` applies and matches what node_exporter / blackbox_exporter do
# at the Go level. The textfile collector path stays AF_UNSPEC fine
# because that's pure local IO.
_orig_getaddrinfo = socket.getaddrinfo

def _ipv4_only_getaddrinfo(host, port, family=0, *args, **kwargs):
    return _orig_getaddrinfo(host, port, socket.AF_INET, *args, **kwargs)

socket.getaddrinfo = _ipv4_only_getaddrinfo

# (server name, /health path under MCP_BASE_URL).
# auth-proxy serves /health unauthenticated and returns 200 with a JSON body;
# any 200 from this endpoint means the auth-proxy → upstream MCP container
# pair is reachable. Path-prefix rewriting differs per server (cognee/roon
# strip the prefix; memory preserves it) but /health on every auth-proxy
# uses the same shape: {prefix}/health.
SERVERS = [
    ("cognee",   "/cognee/health"),
    ("memory",   "/memory/health"),
    ("roon-mcp", "/roon/health"),
]

TIMEOUT = float(os.environ.get("PROBE_TIMEOUT_S", "5"))


def now() -> float:
    return time.monotonic()


def http_get(url: str, *, timeout=TIMEOUT):
    """Return (status, latency_seconds, error). Never raises on HTTP status."""
    t0 = now()
    ctx = ssl.create_default_context() if url.startswith("https://") else None
    try:
        with urllib.request.urlopen(url, timeout=timeout, context=ctx) as resp:
            resp.read()  # drain so the connection closes cleanly
            return resp.status, now() - t0, None
    except urllib.error.HTTPError as e:
        return e.code, now() - t0, f"http_{e.code}"
    except Exception as e:
        return 0, now() - t0, f"exception: {e}"


def write_textfile(metrics: list[str], out_path: str) -> None:
    """Atomic textfile write — required by node_exporter's textfile collector."""
    out_dir = os.path.dirname(out_path)
    os.makedirs(out_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=out_dir, prefix=".mcp_probe.", suffix=".prom.tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write("# HELP mcp_probe_phase_success Per-phase MCP probe outcome (1=ok 0=fail).\n")
            f.write("# TYPE mcp_probe_phase_success gauge\n")
            f.write("# HELP mcp_probe_phase_latency_seconds Phase latency.\n")
            f.write("# TYPE mcp_probe_phase_latency_seconds gauge\n")
            f.write("# HELP mcp_probe_e2e_success End-to-end probe outcome (1=ok 0=fail).\n")
            f.write("# TYPE mcp_probe_e2e_success gauge\n")
            f.write("# HELP mcp_probe_last_run_timestamp_seconds Unix timestamp of last probe attempt.\n")
            f.write("# TYPE mcp_probe_last_run_timestamp_seconds gauge\n")
            f.write("\n".join(metrics) + "\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, out_path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def probe_one(server: tuple[str, str], base_url: str) -> list[str]:
    name, path = server

    def m(metric: str, labels: dict[str, str], value: Any) -> str:
        label_str = ",".join(f'{k}="{v}"' for k, v in labels.items())
        return f"{metric}{{{label_str}}} {value}"

    url = base_url.rstrip("/") + path
    status, latency, _err = http_get(url)
    ok = 1 if status == 200 else 0
    return [
        m("mcp_probe_phase_success", {"server": name, "phase": "health"}, ok),
        m("mcp_probe_phase_latency_seconds", {"server": name, "phase": "health"}, f"{latency:.4f}"),
        m("mcp_probe_e2e_success", {"server": name}, ok),
    ]


def main():
    base_url = os.environ.get("MCP_BASE_URL", "https://mcp.ohno.be")
    out_path = os.environ.get("TEXTFILE_OUT", "/var/lib/node_exporter/textfile/mcp_probe.prom")

    all_metrics: list[str] = []
    for server in SERVERS:
        all_metrics.extend(probe_one(server, base_url))
    all_metrics.append('mcp_probe_credentials_missing 0')
    all_metrics.append(f'mcp_probe_last_run_timestamp_seconds {int(time.time())}')
    write_textfile(all_metrics, out_path)


if __name__ == "__main__":
    main()
