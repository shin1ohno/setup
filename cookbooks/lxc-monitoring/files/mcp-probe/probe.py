#!/usr/bin/env python3
"""MCP fleet health probe.

For each MCP server in the fleet, exercise the full usability path:
  1. Hydra OAuth2 client_credentials grant -> Bearer token
  2. GET /<server>/sse with Authorization: Bearer <token> -> SSE stream open + extract session_id
  3. POST /<server>/messages/?session_id=<sid> with JSON-RPC `initialize`
  4. POST /<server>/messages/?session_id=<sid> with JSON-RPC `tools/list`

Emit Prometheus textfile metrics per phase + an aggregate `e2e_success`.

Stdlib only (no requests / mcp-sdk dependency) — keeps the prober deployable
on a minimal LXC without a Python build chain.

Env vars (set by systemd service unit):
  HYDRA_TOKEN_URL      e.g. http://192.168.1.71:4444/oauth2/token
  PROBER_CLIENT_ID
  PROBER_CLIENT_SECRET
  MCP_BASE_URL         e.g. https://mcp.ohno.be
  TEXTFILE_OUT         e.g. /var/lib/node_exporter/textfile_collector/mcp_probe.prom
  PROBE_TIMEOUT_S      default 8
"""

import json
import os
import socket
import ssl
import sys
import tempfile
import time
import urllib.parse
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

# Servers to probe. Each tuple: (logical name, audience claim, sse path).
# Audience is what the OAuth token's `aud` claim must include for the
# server's JWT validator to accept it.
#
# SSE path notes (verified 2026-05-07):
#   - cognee     → /cognee/sse (auth-proxy strips /cognee/ → backend /sse)
#   - roon-mcp   → /roon/sse (auth-proxy strips /roon/ → backend /sse)
#   - memory     → /memory/mcp/<client>/sse/<user> (openmemory upstream
#                  uses path params for client+user identification;
#                  auth-proxy preserves the path verbatim minus /memory/)
# The actual messages URL is read out of the SSE `endpoint` event's data
# line (NOT derived from sse_path) — each server emits the canonical
# messages path it expects, including any auth-proxy prefix rewrite.
SERVERS = [
    ("cognee",   "cognee",   "/cognee/sse"),
    ("memory",   "memory",   "/memory/mcp/monitoring-prober/sse/monitoring"),
    ("roon-mcp", "roon-mcp", "/roon/sse"),
]

# Default 15s — SSE endpoint event has been observed to arrive 4-12s
# after connect on cognee + roon-mcp. The auth + JSON-RPC phases are
# typically <500ms each.
TIMEOUT = float(os.environ.get("PROBE_TIMEOUT_S", "15"))


def now() -> float:
    return time.monotonic()


def _http(method: str, url: str, *, headers=None, body=None, timeout=TIMEOUT):
    """Return (status, response_headers, body_bytes). Never raises on HTTP status."""
    req = urllib.request.Request(url, method=method, data=body)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    ctx = ssl.create_default_context() if url.startswith("https://") else None
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read() or b""


def get_token(token_url: str, client_id: str, client_secret: str, audience: str):
    """OAuth2 client_credentials grant. Returns (token, latency_seconds, error)."""
    t0 = now()
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "scope": "mcp.read",
        "audience": audience,
    }).encode()
    auth = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    # Use Basic auth header instead of Manager — Hydra token endpoint accepts both.
    import base64
    basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    headers = {
        "Authorization": f"Basic {basic}",
        "Content-Type": "application/x-www-form-urlencoded",
    }
    try:
        status, _, raw = _http("POST", token_url, headers=headers, body=body)
        if status != 200:
            return None, now() - t0, f"http_{status}: {raw[:200].decode(errors='replace')}"
        data = json.loads(raw)
        tok = data.get("access_token")
        if not tok:
            return None, now() - t0, "no_access_token"
        return tok, now() - t0, None
    except Exception as e:
        return None, now() - t0, f"exception: {e}"


def open_sse(base_url: str, sse_path: str, token: str):
    """Open SSE stream and read until we see the `endpoint` event.

    Returns (session_id, messages_path, sse_handle, latency_seconds, error).
    `messages_path` is the path portion of the data URL — used directly by
    the caller to POST JSON-RPC messages. Don't derive it from sse_path:
    each server's auth-proxy emits its own canonical messages URL
    (e.g. memory's auth-proxy preserves /memory/mcp/messages/ but cognee's
    emits /cognee/messages/), and reverse-engineering this from sse_path
    breaks for any non-standard server layout.
    """
    t0 = now()
    url = base_url.rstrip("/") + sse_path
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "text/event-stream")
    try:
        ctx = ssl.create_default_context() if url.startswith("https://") else None
        resp = urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx)
    except Exception as e:
        return None, None, None, now() - t0, f"sse_open_exception: {e}"
    if resp.status != 200:
        body = resp.read()[:200]
        return None, None, None, now() - t0, f"sse_http_{resp.status}: {body.decode(errors='replace')}"

    # Read SSE line-by-line via readline() — terminates immediately when
    # a newline arrives, instead of blocking until N bytes accumulate.
    # The MCP `endpoint` event fits in the first ~80 bytes of the stream;
    # without readline the read(256) blocked for the full socket timeout
    # waiting for additional data that never came (servers send sparse
    # SSE).
    deadline = now() + TIMEOUT
    session_id = None
    messages_path = None
    head_buf: list[bytes] = []
    fp = resp.fp if hasattr(resp, "fp") else resp
    while now() < deadline:
        try:
            line = fp.readline(512)
        except (TimeoutError, socket.timeout):
            break
        if not line:
            break
        head_buf.append(line)
        if line.startswith(b"data: ") and b"session_id=" in line:
            payload = line[len(b"data: "):].decode(errors="replace").strip()
            if "?" in payload:
                path_part, qs = payload.split("?", 1)
            else:
                path_part, qs = payload, ""
            messages_path = path_part
            for kv in qs.split("&"):
                if kv.startswith("session_id="):
                    session_id = kv.split("=", 1)[1].strip()
                    break
            if session_id:
                break

    if not session_id:
        try:
            resp.close()
        except Exception:
            pass
        head = b"".join(head_buf)[:300]
        return None, None, None, now() - t0, f"no_session_id: head={head.decode(errors='replace')}"

    return session_id, messages_path, resp, now() - t0, None


def post_jsonrpc(base_url: str, messages_path: str, session_id: str, token: str, payload: dict):
    """POST a JSON-RPC message to the server's canonical messages URL.

    `messages_path` comes verbatim from the SSE `endpoint` event's data
    line (path portion only; query is reconstructed here). Servers using
    the MCP SSE-streamable transport accept the request and answer 202
    Accepted; the actual response is delivered back through the SSE
    channel. For a probe, 202 is success — we don't read the response
    payload for `initialize`/`tools/list` (would require concurrent SSE
    consumption).
    Returns (status_code, latency, error).
    """
    t0 = now()
    url = f"{base_url.rstrip('/')}{messages_path}?session_id={session_id}"
    body = json.dumps(payload).encode()
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    try:
        status, _, raw = _http("POST", url, headers=headers, body=body)
        if status not in (200, 202):
            return status, now() - t0, f"http_{status}: {raw[:200].decode(errors='replace')}"
        return status, now() - t0, None
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


def probe_one(server: tuple[str, str, str], token_url: str, client_id: str, client_secret: str, base_url: str) -> list[str]:
    name, audience, sse_path = server
    metrics: list[str] = []

    def m(metric: str, labels: dict[str, str], value: Any) -> str:
        label_str = ",".join(f'{k}="{v}"' for k, v in labels.items())
        return f"{metric}{{{label_str}}} {value}"

    # Phase 1: auth
    token, lat_auth, err = get_token(token_url, client_id, client_secret, audience)
    auth_ok = 1 if token else 0
    metrics.append(m("mcp_probe_phase_success", {"server": name, "phase": "auth"}, auth_ok))
    metrics.append(m("mcp_probe_phase_latency_seconds", {"server": name, "phase": "auth"}, f"{lat_auth:.4f}"))
    if not token:
        metrics.append(m("mcp_probe_e2e_success", {"server": name}, 0))
        return metrics

    # Phase 2: SSE open + session
    sid, messages_path, sse_handle, lat_sse, err = open_sse(base_url, sse_path, token)
    sse_ok = 1 if sid else 0
    metrics.append(m("mcp_probe_phase_success", {"server": name, "phase": "sse_open"}, sse_ok))
    metrics.append(m("mcp_probe_phase_latency_seconds", {"server": name, "phase": "sse_open"}, f"{lat_sse:.4f}"))
    if not sid:
        metrics.append(m("mcp_probe_e2e_success", {"server": name}, 0))
        return metrics

    try:
        # Phase 3: initialize
        init_payload = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "mcp-fleet-prober", "version": "0.1"},
            },
        }
        status, lat_init, err = post_jsonrpc(base_url, messages_path, sid, token, init_payload)
        init_ok = 1 if status in (200, 202) else 0
        metrics.append(m("mcp_probe_phase_success", {"server": name, "phase": "initialize"}, init_ok))
        metrics.append(m("mcp_probe_phase_latency_seconds", {"server": name, "phase": "initialize"}, f"{lat_init:.4f}"))
        if not init_ok:
            metrics.append(m("mcp_probe_e2e_success", {"server": name}, 0))
            return metrics

        # Phase 4: tools/list
        tools_payload = {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
        status, lat_tools, err = post_jsonrpc(base_url, messages_path, sid, token, tools_payload)
        tools_ok = 1 if status in (200, 202) else 0
        metrics.append(m("mcp_probe_phase_success", {"server": name, "phase": "tools_list"}, tools_ok))
        metrics.append(m("mcp_probe_phase_latency_seconds", {"server": name, "phase": "tools_list"}, f"{lat_tools:.4f}"))

        e2e = 1 if (auth_ok and sse_ok and init_ok and tools_ok) else 0
        metrics.append(m("mcp_probe_e2e_success", {"server": name}, e2e))
    finally:
        if sse_handle is not None:
            try:
                sse_handle.close()
            except Exception:
                pass
    return metrics


def main():
    token_url = os.environ.get("HYDRA_TOKEN_URL", "http://192.168.1.71:4444/oauth2/token")
    base_url = os.environ.get("MCP_BASE_URL", "https://mcp.ohno.be")
    out_path = os.environ.get("TEXTFILE_OUT", "/var/lib/node_exporter/textfile_collector/mcp_probe.prom")
    client_id = os.environ.get("PROBER_CLIENT_ID")
    client_secret = os.environ.get("PROBER_CLIENT_SECRET")

    if not client_id or not client_secret:
        sys.stderr.write("PROBER_CLIENT_ID / PROBER_CLIENT_SECRET not set\n")
        # Still emit a textfile so the absence of probe is visible.
        write_textfile([
            f'mcp_probe_credentials_missing 1',
            f'mcp_probe_last_run_timestamp_seconds {int(time.time())}',
        ], out_path)
        sys.exit(1)

    all_metrics: list[str] = []
    for server in SERVERS:
        all_metrics.extend(probe_one(server, token_url, client_id, client_secret, base_url))
    all_metrics.append(f'mcp_probe_credentials_missing 0')
    all_metrics.append(f'mcp_probe_last_run_timestamp_seconds {int(time.time())}')
    write_textfile(all_metrics, out_path)


if __name__ == "__main__":
    main()
