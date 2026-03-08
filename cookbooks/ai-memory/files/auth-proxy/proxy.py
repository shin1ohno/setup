#!/usr/bin/env python3
"""Auth proxy for OpenMemory MCP server.

Validates sage OAuth tokens (RS256 via JWKS) and proxies authenticated
requests to the upstream openmemory-api service.
"""

import json
import logging
import os
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


# ── Request handling ───────────────────────────────────────────────────

WWW_AUTH = (
    f'Bearer resource_metadata="{SAGE_ISSUER}/.well-known/oauth-protected-resource"'
)

HOP_BY_HOP = frozenset(
    ("host", "authorization", "transfer-encoding", "connection", "keep-alive")
)


async def handle(request: web.Request) -> web.StreamResponse:
    # Health endpoint — no auth required
    if request.path == "/health":
        return web.json_response({"status": "ok"})

    # ── Authenticate ──
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return web.json_response(
            {"error": "unauthorized"},
            status=401,
            headers={"WWW-Authenticate": WWW_AUTH},
        )

    if verifier.verify(auth[7:]) is None:
        return web.json_response(
            {"error": "invalid_token"},
            status=401,
            headers={
                "WWW-Authenticate": (
                    f'Bearer error="invalid_token",'
                    f' resource_metadata="{SAGE_ISSUER}'
                    f'/.well-known/oauth-protected-resource"'
                )
            },
        )

    # ── Proxy to upstream ──
    url = f"{UPSTREAM_URL}{request.path_qs}"
    fwd_headers = {
        k: v for k, v in request.headers.items() if k.lower() not in HOP_BY_HOP
    }

    session: ClientSession = request.app["http_client"]
    body = await request.read() if request.can_read_body else None

    upstream = await session.request(
        request.method,
        url,
        headers=fwd_headers,
        data=body,
        timeout=ClientTimeout(total=300, connect=10),
    )

    ct = upstream.headers.get("Content-Type", "")
    resp_headers = {
        k: v for k, v in upstream.headers.items() if k.lower() not in HOP_BY_HOP
    }

    # Stream SSE responses
    if "text/event-stream" in ct:
        response = web.StreamResponse(status=upstream.status, headers=resp_headers)
        await response.prepare(request)
        async for chunk in upstream.content.iter_any():
            await response.write(chunk)
        await upstream.release()
        return response

    # Regular responses
    content = await upstream.read()
    await upstream.release()
    return web.Response(body=content, status=upstream.status, headers=resp_headers)


# ── App lifecycle ──────────────────────────────────────────────────────


async def on_startup(app: web.Application) -> None:
    app["http_client"] = ClientSession()


async def on_cleanup(app: web.Application) -> None:
    await app["http_client"].close()


app = web.Application()
app.on_startup.append(on_startup)
app.on_cleanup.append(on_cleanup)
app.router.add_route("*", "/{path_info:.*}", handle)

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=PORT)
