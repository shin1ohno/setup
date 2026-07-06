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

import sys
import time

HEADER_SUB = "x-verified-sub"
HEADER_CLIENT_ID = "x-verified-client-id"
HEADER_GRANT = "x-verified-grant"

GRANT_AUTHZ_CODE = "authorization_code"
GRANT_CLIENT_CREDS = "client_credentials"


class AuthzError(Exception):
    """Raised when a caller is not permitted to supersede/revise a target doc."""


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


def parse_identity(headers) -> dict:
    """Read the three verified headers and derive the provenance agent.

    provenance.agent = client_id (client_credentials) or sub (authorization_code),
    per contract §3. Never sourced from tool arguments.
    """
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
