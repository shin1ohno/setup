"""Identity + server-side destructive-op authorization for memory-mcp v2.

The auth-proxy (contract §3) validates the OIDC-JWT, strips any inbound
`x-verified-*` spoofs, and injects three verified headers:

    X-Verified-Sub        the token `sub` (email for authorization_code)
    X-Verified-Client-Id  the token `client_id`
    X-Verified-Grant      "authorization_code" | "client_credentials"

Provenance is stamped server-side FROM these headers (never from tool args), so
a caller cannot forge which agent wrote a memory. This module holds the pure
authz matrix + a stderr/journald audit line. It intentionally imports no
Starlette so it stays importable anywhere (es_backend imports authorize_supersede).
"""

from __future__ import annotations

import hmac
import os
import sys
import time

HEADER_SUB = "x-verified-sub"
HEADER_CLIENT_ID = "x-verified-client-id"
HEADER_GRANT = "x-verified-grant"

GRANT_AUTHZ_CODE = "authorization_code"
GRANT_CLIENT_CREDS = "client_credentials"


HEADER_PROXY_SECRET = "x-proxy-secret"

# Env-gated shared secret between the auth proxy and this server. UNSET = inert,
# so existing deployments are unaffected.
#
# WHY THIS EXISTS. Everything below trusts the x-verified-* headers completely:
# they decide write provenance, and they decide who may forget or revise a
# document. The only thing stopping a caller from writing them itself is that the
# server listens on loopback and the proxy is the sole reachable listener. On a
# single-purpose host that is enough. On a host that also runs autonomous coding
# agents it is not: any local process can reach loopback, and forging
# `x-verified-grant: authorization_code` there buys the ability to fabricate a
# `user-stated` fact -- which the recall tool explicitly tells the model it may
# treat as instruction rather than data. That turns a local write into prompt
# injection with elevated trust.
#
# With this set, forging an identity additionally requires reading the server's
# environment file, which is the same bar as reading its ES credential.
_PROXY_SHARED_SECRET = os.environ.get("PROXY_SHARED_SECRET", "")


class AuthzError(Exception):
    """Raised when a caller is not permitted to supersede/revise a target doc."""


class ProxyAuthError(Exception):
    """Raised when PROXY_SHARED_SECRET is configured and the request did not come
    through the proxy that holds it."""


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _get_header(headers, name: str) -> str:
    """Case-insensitive header lookup tolerant of Starlette Headers or a plain
    dict. Returns "" when absent (or when headers is None)."""
    if headers is None:
        return ""
    # Starlette Headers.get is already case-insensitive; try common casings for
    # a plain dict, then fall back to a full scan.
    try:
        val = headers.get(name)
        if val is None:
            val = headers.get(name.title())
        if val is None:
            for k, v in headers.items():
                if str(k).lower() == name:
                    return v or ""
        return val or ""
    except AttributeError:
        return ""


def require_proxy_secret(headers) -> None:
    """Reject anything that did not come through the trusted proxy.

    No-op unless PROXY_SHARED_SECRET is set, so this is opt-in per deployment.
    Constant-time compare: the value is a fixed secret checked on every request,
    which is exactly the shape a timing oracle needs."""
    if not _PROXY_SHARED_SECRET:
        return
    got = _get_header(headers, HEADER_PROXY_SECRET)
    # Compared as bytes: compare_digest raises TypeError on a non-ASCII str, which
    # would surface as a 500 instead of a clean rejection for a hostile header.
    if not got or not hmac.compare_digest(
        got.encode("utf-8", "surrogateescape"),
        _PROXY_SHARED_SECRET.encode("utf-8", "surrogateescape"),
    ):
        print("AUDIT proxy_secret_rejected", file=sys.stderr, flush=True)
        raise ProxyAuthError("request did not come through the auth proxy")


def parse_identity(headers) -> dict:
    """Read the three verified headers and derive the provenance agent.

    provenance.agent = client_id (client_credentials) or sub (authorization_code),
    per contract §3. Never sourced from tool arguments.

    Gated on require_proxy_secret: this is the single chokepoint every request
    passes through before an identity exists, so enforcing here means no code path
    can derive provenance from headers that bypassed the proxy.
    """
    require_proxy_secret(headers)
    sub = _get_header(headers, HEADER_SUB)
    client_id = _get_header(headers, HEADER_CLIENT_ID)
    grant = _get_header(headers, HEADER_GRANT)
    if grant == GRANT_CLIENT_CREDS:
        agent = client_id or "unknown-client"
    else:
        agent = sub or "unknown-user"
    return {"sub": sub, "client_id": client_id, "grant": grant, "agent": agent}


def build_provenance(ident: dict, session_id: str = "", source_class: str = "tool-output") -> dict:
    """Build the provenance sub-document stamped server-side from `parse_identity`
    output. source_class ∈ {user-stated, tool-output, reflection, auto-capture,
    migration, promoted}."""
    return {
        "agent": ident.get("agent", "unknown"),
        "session_id": session_id or "",
        "source_class": source_class,
        "written_at": _now_iso(),
    }


def authorize_supersede(grant: str, agent: str, target_source_class, target_agent) -> bool:
    """Destructive-op authorization matrix (contract §3).

    - target source_class == "user-stated": only interactive (authorization_code)
      tokens may forget/revise it.
    - authorization_code: may forget/revise anything.
    - client_credentials: may forget/revise ONLY docs whose provenance.agent
      matches its own verified client id.
    - anything else: deny.
    """
    if target_source_class == "user-stated":
        return grant == GRANT_AUTHZ_CODE
    if grant == GRANT_AUTHZ_CODE:
        return True
    if grant == GRANT_CLIENT_CREDS:
        return bool(agent) and agent == target_agent
    return False


def audit_supersede(target_id, agent: str, grant: str) -> None:
    """Emit an audit line for every supersede/revise (contract §3). Goes to
    stderr, which the systemd unit routes to journald."""
    print(f"AUDIT supersede id={target_id} by={agent} grant={grant}",
          file=sys.stderr, flush=True)
