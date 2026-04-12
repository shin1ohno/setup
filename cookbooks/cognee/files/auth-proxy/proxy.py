#!/usr/bin/env python3
"""Auth proxy for OpenMemory MCP server.

Validates sage OAuth tokens (RS256 via JWKS) and proxies authenticated
requests to the upstream openmemory-api service.
"""

import json
import logging
import os
import re
import time
from urllib.request import urlopen

import jwt
import jwt.algorithms
from aiohttp import web, ClientSession, ClientTimeout

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)
logger = logging.getLogger("auth-proxy")

SAGE_ISSUER = os.environ.get("SAGE_ISSUER", "https://mcp.ohno.be")
SAGE_JWKS_URL = os.environ.get(
    "SAGE_JWKS_URL", "https://mcp.ohno.be/.well-known/jwks.json"
)
UPSTREAM_URL = os.environ.get("UPSTREAM_URL", "http://openmemory-api:8765")
PORT = int(os.environ.get("PORT", "8766"))
# Public path prefix used by the reverse proxy (e.g. "/memory")
PATH_PREFIX = os.environ.get("PATH_PREFIX", "")
# Override the Host header sent upstream (some MCP servers use Starlette
# TrustedHostMiddleware and reject foreign Host values).
HOST_OVERRIDE = os.environ.get("HOST_OVERRIDE", "")


# ── JWKS-based token verifier ──────────────────────────────────────────


class TokenVerifier:
    """Verifies RS256 JWTs using a remote JWKS endpoint."""

    def __init__(self, jwks_url: str, issuer: str, cache_ttl: int = 300):
        self._jwks_url = jwks_url
        self._issuer = issuer
        self._cache_ttl = cache_ttl
        self._keys: dict = {}
        self._fetched_at: float = 0

    def _fetch_keys(self) -> None:
        try:
            with urlopen(self._jwks_url, timeout=10) as resp:
                data = json.loads(resp.read())
            self._keys = {}
            for jwk_data in data.get("keys", []):
                kid = jwk_data.get("kid", "default")
                self._keys[kid] = jwt.algorithms.RSAAlgorithm.from_jwk(
                    json.dumps(jwk_data)
                )
            self._fetched_at = time.monotonic()
            logger.info("Fetched %d key(s) from JWKS", len(self._keys))
        except Exception:
            logger.exception("Failed to fetch JWKS from %s", self._jwks_url)

    def _ensure_keys(self, force: bool = False) -> None:
        expired = time.monotonic() - self._fetched_at > self._cache_ttl
        if force or not self._keys or expired:
            self._fetch_keys()

    def _pick_key(self, token: str):
        """Select the signing key for the token (by kid or first available)."""
        if not self._keys:
            return None
        try:
            header = jwt.get_unverified_header(token)
            kid = header.get("kid")
            if kid and kid in self._keys:
                return self._keys[kid]
        except Exception:
            pass
        return next(iter(self._keys.values()))

    def verify(self, token: str) -> dict | None:
        """Verify a JWT token. Retries with fresh JWKS on signature failure."""
        self._ensure_keys()
        key = self._pick_key(token)
        if key is None:
            return None
        try:
            return jwt.decode(
                token,
                key,
                algorithms=["RS256"],
                issuer=self._issuer,
                options={"verify_aud": False},
            )
        except jwt.InvalidSignatureError:
            self._ensure_keys(force=True)
            key = self._pick_key(token)
            if key is None:
                return None
            try:
                return jwt.decode(
                    token,
                    key,
                    algorithms=["RS256"],
                    issuer=self._issuer,
                    options={"verify_aud": False},
                )
            except Exception as exc:
                logger.warning("Token verify failed after JWKS refresh: %s", exc)
                return None
        except Exception as exc:
            logger.warning("Token verification failed: %s", exc)
            return None


verifier = TokenVerifier(SAGE_JWKS_URL, SAGE_ISSUER)


# ── CORS helpers ─────────────────────────────────────────────────────

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, Accept",
    "Access-Control-Expose-Headers": "WWW-Authenticate",
    "Access-Control-Max-Age": "86400",
}


def add_cors(headers: dict) -> dict:
    """Merge CORS headers into response headers."""
    merged = dict(headers)
    merged.update(CORS_HEADERS)
    return merged


# ── SSE path rewriting ───────────────────────────────────────────────

# Matches SSE endpoint events: "event: endpoint\ndata: /some/path..."
_SSE_ENDPOINT_RE = re.compile(
    rb"(event:\s*endpoint\s*\ndata:\s*)(\/\S+)",
    re.MULTILINE,
)


def rewrite_sse_paths(chunk: bytes, prefix: str) -> bytes:
    """Prepend PATH_PREFIX to SSE endpoint event paths."""
    if not prefix:
        return chunk
    prefix_bytes = prefix.encode()

    def _rewrite(m: re.Match) -> bytes:
        path = m.group(2)
        if path.startswith(prefix_bytes):
            return m.group(0)  # already prefixed
        return m.group(1) + prefix_bytes + path

    return _SSE_ENDPOINT_RE.sub(_rewrite, chunk)


# ── Request handling ───────────────────────────────────────────────────

# Resource identifier — distinct from sage to avoid MCP client confusion
RESOURCE_ID = f"{SAGE_ISSUER}{PATH_PREFIX}" if PATH_PREFIX else SAGE_ISSUER

WWW_AUTH = (
    f'Bearer resource_metadata="{RESOURCE_ID}/.well-known/oauth-protected-resource"'
)

HOP_BY_HOP = frozenset(
    ("host", "authorization", "transfer-encoding", "connection", "keep-alive")
)

# MCP uses JSON-RPC 2.0, whose error objects require a numeric `code`. Returning
# a plain {"error": "..."} body on 401 makes MCP clients reject the response
# with "code: Field required" before they can act on the WWW-Authenticate
# header, so 401s must ship a JSON-RPC 2.0 envelope.
JSONRPC_UNAUTHORIZED = -32001


def jsonrpc_error(code: int, message: str, status: int, headers: dict) -> web.Response:
    return web.json_response(
        {"jsonrpc": "2.0", "id": None, "error": {"code": code, "message": message}},
        status=status,
        headers=headers,
    )


async def handle(request: web.Request) -> web.StreamResponse:
    logger.info("%s %s", request.method, request.path)

    # ── CORS preflight — no auth required ──
    if request.method == "OPTIONS":
        return web.Response(status=204, headers=CORS_HEADERS)

    # ── Health endpoint — no auth required ──
    if request.path == "/health":
        return web.json_response({"status": "ok"}, headers=CORS_HEADERS)

    # ── .well-known — no auth required (MCP/OAuth discovery) ──
    if request.path.startswith("/.well-known/"):
        if request.path == "/.well-known/oauth-protected-resource":
            return web.json_response(
                {
                    "resource": RESOURCE_ID,
                    "authorization_servers": [SAGE_ISSUER],
                    "scopes_supported": ["mcp:read", "mcp:write", "mcp:admin"],
                    "bearer_methods_supported": ["header"],
                },
                headers=add_cors({"Cache-Control": "public, max-age=3600"}),
            )
        # Proxy other .well-known paths to upstream without auth
        session: ClientSession = request.app["http_client"]
        url = f"{UPSTREAM_URL}{request.path_qs}"
        upstream = await session.request("GET", url, timeout=ClientTimeout(total=10))
        content = await upstream.read()
        await upstream.release()
        return web.Response(
            body=content,
            status=upstream.status,
            content_type=upstream.headers.get("Content-Type", "application/json"),
            headers=CORS_HEADERS,
        )

    # ── Authenticate ──
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        logger.info("No Bearer token for %s %s", request.method, request.path)
        return jsonrpc_error(
            JSONRPC_UNAUTHORIZED,
            "unauthorized",
            401,
            add_cors({"WWW-Authenticate": WWW_AUTH}),
        )

    claims = verifier.verify(auth[7:])
    if claims is None:
        logger.warning("Invalid token for %s %s", request.method, request.path)
        return jsonrpc_error(
            JSONRPC_UNAUTHORIZED,
            "invalid_token",
            401,
            add_cors({
                "WWW-Authenticate": (
                    f'Bearer error="invalid_token",'
                    f' resource_metadata="{RESOURCE_ID}'
                    f'/.well-known/oauth-protected-resource"'
                )
            }),
        )

    logger.info("Authenticated %s %s (sub=%s)", request.method, request.path, claims.get("sub", "?"))

    # ── Proxy to upstream ──
    url = f"{UPSTREAM_URL}{request.path_qs}"
    fwd_headers = {
        k: v for k, v in request.headers.items() if k.lower() not in HOP_BY_HOP
    }
    if HOST_OVERRIDE:
        fwd_headers["Host"] = HOST_OVERRIDE

    session = request.app["http_client"]
    body = await request.read() if request.can_read_body else None

    try:
        upstream = await session.request(
            request.method,
            url,
            headers=fwd_headers,
            data=body,
            timeout=ClientTimeout(total=300, connect=10),
        )
    except Exception as exc:
        logger.error("Upstream request failed: %s", exc)
        return jsonrpc_error(
            -32000,
            "upstream_error",
            502,
            CORS_HEADERS,
        )

    ct = upstream.headers.get("Content-Type", "")
    resp_headers = {
        k: v for k, v in upstream.headers.items() if k.lower() not in HOP_BY_HOP
    }
    resp_headers = add_cors(resp_headers)

    logger.info("Upstream responded %d (%s) for %s %s", upstream.status, ct, request.method, request.path)

    # Stream SSE responses
    if "text/event-stream" in ct:
        response = web.StreamResponse(status=upstream.status, headers=resp_headers)
        await response.prepare(request)
        try:
            async for chunk in upstream.content.iter_any():
                logger.info("SSE chunk: %s", chunk[:300])
                chunk = rewrite_sse_paths(chunk, PATH_PREFIX)
                await response.write(chunk)
        except ConnectionResetError:
            logger.info("SSE client disconnected for %s", request.path)
        except Exception as exc:
            logger.warning("SSE streaming error: %s", exc)
        finally:
            await upstream.release()
        return response

    # Regular responses
    content = await upstream.read()
    await upstream.release()
    logger.info("Response body (%d bytes): %s", len(content), content[:500])
    return web.Response(body=content, status=upstream.status, headers=resp_headers)


# ── App lifecycle ──────────────────────────────────────────────────────


async def on_startup(app: web.Application) -> None:
    app["http_client"] = ClientSession()
    logger.info("Auth proxy started (prefix=%s, upstream=%s)", PATH_PREFIX, UPSTREAM_URL)


async def on_cleanup(app: web.Application) -> None:
    await app["http_client"].close()


app = web.Application()
app.on_startup.append(on_startup)
app.on_cleanup.append(on_cleanup)
app.router.add_route("*", "/{path_info:.*}", handle)

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=PORT)
