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

It also holds the per-client tool policy (CLIENT_POLICY, bottom of the file):
which tools and datasets a client_credentials caller may use. The gate that
applies it to every tools/call lives in policy_mcp.PolicyFastMCP.
"""

from __future__ import annotations

import hmac
import os
import re
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


# --------------------------------------------------------------------------- #
# Per-client tool policy (CLIENT_POLICY)
# --------------------------------------------------------------------------- #
# The proxy decides WHO may reach this server (ALLOWED_CLIENT_IDS); this decides
# WHAT a machine client may do once here. Without it every client_credentials
# token could call every tool, so a leaked mirror credential would read and
# write the whole store. authorization_code (the claude.ai connector) is not
# subject to it.
#
# Format, set in memory-mcp-v2.service (NOT the SSM-generated .env, whose
# regeneration guard only looks at VOYAGE_API_KEY):
#
#     client=tool,tool@dataset|dataset;client=
#
# `client=` with no tools means "known, may call nothing". Fail-closed
# throughout: a malformed policy, a client that is not listed, and a missing or
# unrecognised grant header all deny every call rather than guessing.
CLIENT_POLICY_ENV = "CLIENT_POLICY"

# Every policy refusal carries exactly this text. The caller learns that it was
# refused, not which constraint refused it; the reason stays server-side.
POLICY_DENIED_MESSAGE = "policy_denied: this client is not permitted to make this call"

# Longest `ingest` document a client_credentials caller may send, in characters.
# Bounds the size — and the Voyage embedding spend — of any single write a leaked
# machine token can make. The file-memory mirror hook skips notes over the same
# limit with a WARN, so the two sides must change together.
RESTRICTED_INGEST_MAX_CHARS = 45000

_CLIENT_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
_TOOL_RE = re.compile(r"[a-z_][a-z0-9_]*")
_DATASET_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")

_DENY = (False, POLICY_DENIED_MESSAGE)
_ACTIVE = object()  # sentinel: "use the policy loaded from the environment"


class PolicyError(ValueError):
    """CLIENT_POLICY is malformed."""


def _split_tokens(part: str, sep: str, pattern, kind: str, client: str) -> tuple:
    tokens = part.split(sep)
    for tok in tokens:
        if not pattern.fullmatch(tok):
            raise PolicyError(f"client {client}: invalid {kind} {tok!r}")
    if len(set(tokens)) != len(tokens):
        raise PolicyError(f"client {client}: duplicate {kind}")
    return tuple(tokens)


def parse_client_policy(spec: str) -> dict:
    """Parse a CLIENT_POLICY value strictly.

    Grammar (no whitespace anywhere; `;` separates entries):

        entry    := client "=" [tools ["@" datasets]]
        tools    := tool ("," tool)*
        datasets := dataset ("|" dataset)*

    A tool list without `@datasets` grants no dataset, so any call that names
    one is refused. The empty string is an empty policy (no machine client may
    do anything). Anything else that does not match — including a duplicate
    client, tool or dataset, and an empty entry from a stray `;` — raises
    PolicyError, so a typo can only ever narrow what a client may do.

    Returns {client_id: {"tools": tuple, "datasets": tuple}}.
    """
    if spec == "":
        return {}
    policy: dict = {}
    for entry in spec.split(";"):
        client, eq, rest = entry.partition("=")
        if not eq:
            raise PolicyError(f"entry {entry!r}: missing '='")
        if not _CLIENT_ID_RE.fullmatch(client):
            raise PolicyError(f"entry {entry!r}: invalid client id")
        if client in policy:
            raise PolicyError(f"client {client}: listed twice")
        tools_part, at, datasets_part = rest.partition("@")
        tools = _split_tokens(tools_part, ",", _TOOL_RE, "tool", client) if tools_part else ()
        datasets: tuple = ()
        if at:
            if not tools:
                raise PolicyError(f"client {client}: datasets without tools")
            datasets = _split_tokens(datasets_part, "|", _DATASET_RE, "dataset", client)
        policy[client] = {"tools": tools, "datasets": datasets}
    return policy


def _load_client_policy(spec: str):
    """(policy, error). policy None = invalid, which denies every
    client_credentials call."""
    try:
        return parse_client_policy(spec), ""
    except PolicyError as exc:
        return None, str(exc)


_CLIENT_POLICY, _CLIENT_POLICY_ERROR = _load_client_policy(
    os.environ.get(CLIENT_POLICY_ENV, ""))


def unknown_policy_tools(policy, registered) -> list:
    """Tool names the policy grants that the server does not register. A name
    that matches nothing is a typo that silently denies what was meant to be
    allowed, so check_client_policy treats it as an invalid policy."""
    if not policy:
        return []
    granted = {t for entry in policy.values() for t in entry["tools"]}
    return sorted(granted - set(registered))


def policy_lines(policy, error: str = "") -> list:
    """The startup lines describing the effective policy (journald)."""
    if policy is None:
        return [f"AUDIT policy_invalid reason={error or 'unknown'} "
                "client_credentials=deny-all"]
    if not policy:
        return ["POLICY (none): every client_credentials call is denied"]
    return [
        f"POLICY {client} -> {','.join(entry['tools']) or '(none)'}"
        f" @ {'|'.join(entry['datasets']) or '(none)'}"
        for client, entry in policy.items()
    ]


def check_client_policy(registered_tools) -> None:
    """Validate the loaded policy against the server's registered tool names and
    log the effective policy. Called once at server startup."""
    global _CLIENT_POLICY, _CLIENT_POLICY_ERROR
    unknown = unknown_policy_tools(_CLIENT_POLICY, registered_tools)
    if unknown:
        _CLIENT_POLICY = None
        _CLIENT_POLICY_ERROR = f"unknown tool(s) {','.join(unknown)}"
    for line in policy_lines(_CLIENT_POLICY, _CLIENT_POLICY_ERROR):
        print(line, file=sys.stderr, flush=True)


def _policy_entry(ident: dict, policy):
    """The policy entry governing a client_credentials identity, or None."""
    pol = _CLIENT_POLICY if policy is _ACTIVE else policy
    if pol is None:
        return None
    return pol.get((ident or {}).get("client_id") or "")


def _dataset_allowed(dataset, allowed) -> bool:
    # Exact str match only: a list, a number or a JSON-encoded string is not a
    # dataset name, whatever pydantic would later coerce it into.
    return isinstance(dataset, str) and dataset in allowed


def authorize_tool(ident: dict, name, arguments, policy=_ACTIVE) -> tuple:
    """Pure policy decision for one tools/call. Returns (ok, reason); reason is
    POLICY_DENIED_MESSAGE on refusal, "" otherwise.

    - authorization_code: always allowed (the interactive connector).
    - client_credentials: the client must be listed, the tool granted, and:
        * no `tags` (a restricted caller may not set or clear routing keys);
        * any `dataset` argument must be one of its datasets;
        * `ingest` must name an allowed dataset and send a str document of at
          most RESTRICTED_INGEST_MAX_CHARS characters.
      forget-by-id is scoped in es_backend.supersede (allowed_datasets), where
      the target document's dataset is known.
    - any other grant value, including a missing header: denied.

    `arguments` is the raw JSON object from the request, before FastMCP's
    pydantic coercion, so the checks see exactly what the client sent.
    """
    grant = (ident or {}).get("grant", "")
    if grant == GRANT_AUTHZ_CODE:
        return True, ""
    if grant != GRANT_CLIENT_CREDS:
        return _DENY
    entry = _policy_entry(ident, policy)
    if entry is None:
        return _DENY
    if not isinstance(name, str) or name not in entry["tools"]:
        return _DENY
    args = {} if arguments is None else arguments
    if not isinstance(args, dict):
        return _DENY
    if args.get("tags") is not None:
        return _DENY
    if args.get("dataset") is not None and not _dataset_allowed(args["dataset"], entry["datasets"]):
        return _DENY
    if name == "ingest":
        if not _dataset_allowed(args.get("dataset"), entry["datasets"]):
            return _DENY
        document = args.get("document")
        if not isinstance(document, str) or len(document) > RESTRICTED_INGEST_MAX_CHARS:
            return _DENY
    return True, ""


def allowed_datasets(ident: dict, policy=_ACTIVE):
    """Datasets a caller may touch: None = unrestricted (authorization_code),
    otherwise a frozenset — empty for anyone the policy does not grant."""
    grant = (ident or {}).get("grant", "")
    if grant == GRANT_AUTHZ_CODE:
        return None
    if grant != GRANT_CLIENT_CREDS:
        return frozenset()
    entry = _policy_entry(ident, policy)
    return frozenset(entry["datasets"]) if entry else frozenset()


_AUDIT_TOKEN_RE = re.compile(r"[^A-Za-z0-9._@:/-]")


def _audit_token(value) -> str:
    """Render a client-controlled value safely on one log line: no whitespace or
    control characters (no forged extra lines), bounded length, and only the
    TYPE of a non-string."""
    if value is None or value == "":
        return "-"
    if not isinstance(value, str):
        return f"<{type(value).__name__}>"
    token = _AUDIT_TOKEN_RE.sub("?", value)
    return token if len(token) <= 64 else token[:64] + "..."


def audit_policy_deny(tool, client, dataset) -> None:
    """One line per policy refusal. Carries the tool, the client and the
    dataset only — never the arguments, which may hold the document itself."""
    print(f"AUDIT deny tool={_audit_token(tool)} client={_audit_token(client)}"
          f" dataset={_audit_token(dataset)}", file=sys.stderr, flush=True)
