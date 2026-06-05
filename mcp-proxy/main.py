"""
MCP OAuth 2.1 / Virtual-Key Auth Proxy for Bifrost
- Connections from Claude.ai web (remote MCP) use OAuth Bearer (JWT) → validated against Authentik
- Other connections (Claude Code, API clients) use virtual key Bearer → passed through to Bifrost
- /.well-known/ discovery handled here for OAuth clients
- All other traffic (web UI, /v1) routes directly to Bifrost via Traefik
Place at /opt/mcp-proxy/main.py on the Docker LXC host.
"""

import os
import base64
import logging
from typing import Any

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from jwt import PyJWKClient, decode as jwt_decode, ExpiredSignatureError, InvalidTokenError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
logger = logging.getLogger("mcp-proxy")

BIFROST_URL        = os.environ["BIFROST_URL"]
MCP_BASE_URL       = os.environ["MCP_BASE_URL"]
AUTHENTIK_ISSUER   = os.environ["AUTHENTIK_ISSUER"]
AUTHENTIK_JWKS_URL = os.environ["AUTHENTIK_JWKS_URL"]
OAUTH_CLIENT_ID    = os.environ["OAUTH_CLIENT_ID"]

_raw = f"{os.environ['BIFROST_BASIC_AUTH_USER']}:{os.environ['BIFROST_BASIC_AUTH_PASS']}"
_BIFROST_BASIC_AUTH = "Basic " + base64.b64encode(_raw.encode()).decode()

app = FastAPI(title="MCP Auth Proxy", docs_url=None, redoc_url=None)
_jwks_client = PyJWKClient(AUTHENTIK_JWKS_URL, cache_keys=True)
_HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "host",
}


def _is_jwt(token: str) -> bool:
    """JWTs have exactly two dots and three non-empty base64url segments."""
    parts = token.split(".")
    return len(parts) == 3 and all(parts)


# ── OAuth discovery ────────────────────────────────────────────────────────────

@app.get("/.well-known/oauth-protected-resource")
async def protected_resource_metadata() -> JSONResponse:
    return JSONResponse({
        "resource": MCP_BASE_URL,
        "authorization_servers": [AUTHENTIK_ISSUER],
        "bearer_methods_supported": ["header"],
        "resource_documentation": MCP_BASE_URL,
    })


@app.get("/.well-known/oauth-authorization-server")
async def auth_server_metadata() -> JSONResponse:
    url = AUTHENTIK_ISSUER.rstrip("/") + "/.well-known/openid-configuration"
    async with httpx.AsyncClient(follow_redirects=True, timeout=10.0) as client:
        r = await client.get(url)
    return JSONResponse(r.json(), status_code=r.status_code)


# ── JWT validation ─────────────────────────────────────────────────────────────

def _www_authenticate(error: str | None = None) -> str:
    prm = f"{MCP_BASE_URL}/.well-known/oauth-protected-resource"
    h = f'Bearer realm="{MCP_BASE_URL}", resource_metadata="{prm}"'
    return h + (f', error="{error}"' if error else "")


def validate_jwt(token: str) -> dict[str, Any]:
    try:
        key = _jwks_client.get_signing_key_from_jwt(token)
        return jwt_decode(
            token, key.key,
            algorithms=["RS256", "ES256"],
            issuer=AUTHENTIK_ISSUER,
            audience=OAUTH_CLIENT_ID,
            options={"require": ["exp", "iss", "aud"]},
        )
    except ExpiredSignatureError:
        raise ValueError("token_expired")
    except InvalidTokenError as exc:
        raise ValueError(f"invalid_token: {exc}")


# ── MCP proxy ──────────────────────────────────────────────────────────────────
# /mcp paths only — Traefik routes everything else directly to Bifrost

@app.api_route(
    "/{path:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"],
)
async def proxy(request: Request, path: str) -> Response:
    authorization = request.headers.get("Authorization", "")

    if not authorization:
        logger.info("No token — 401  path=/%s", path)
        return Response(
            status_code=401,
            headers={"WWW-Authenticate": _www_authenticate()},
        )

    if not authorization.startswith("Bearer "):
        logger.warning("Non-Bearer auth — 401  path=/%s", path)
        return Response(
            status_code=401,
            headers={"WWW-Authenticate": _www_authenticate("invalid_token")},
        )

    token = authorization[7:].strip()

    # ── Path A: JWT → validate OAuth, swap to Bifrost Basic auth upstream ─────
    if _is_jwt(token):
        try:
            claims = validate_jwt(token)
            logger.info("OAuth OK  sub=%s  path=/%s", claims.get("sub"), path)
        except ValueError as exc:
            code = str(exc).split(":")[0]
            logger.warning("OAuth rejected: %s  path=/%s", exc, path)
            return Response(
                status_code=401,
                headers={"WWW-Authenticate": _www_authenticate(code)},
            )
        upstream_headers = {
            k: v for k, v in request.headers.items()
            if k.lower() not in _HOP_BY_HOP and k.lower() != "authorization"
        }
        upstream_headers["Authorization"] = _BIFROST_BASIC_AUTH

    # ── Path B: Opaque virtual key → pass Bearer straight through to Bifrost ──
    else:
        logger.info("Virtual-key passthrough  path=/%s", path)
        upstream_headers = {
            k: v for k, v in request.headers.items()
            if k.lower() not in _HOP_BY_HOP
        }
        # Authorization header preserved as-is; Bifrost validates virtual keys

    # ── Forward to Bifrost ─────────────────────────────────────────────────────
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.request(
                method=request.method,
                url=f"{BIFROST_URL.rstrip('/')}/{path}",
                headers=upstream_headers,
                content=await request.body(),
                params=request.query_params,
                follow_redirects=False,
            )
        return Response(
            content=resp.content,
            status_code=resp.status_code,
            headers={k: v for k, v in resp.headers.items() if k.lower() not in _HOP_BY_HOP},
            media_type=resp.headers.get("content-type"),
        )
    except httpx.RequestError as exc:
        logger.error("Upstream error: %s", exc)
        return Response(status_code=502, content=b"Bad Gateway")
