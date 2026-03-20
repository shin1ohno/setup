"""Hydra consent app with Google OAuth login."""

import json
import os
import secrets
import urllib.parse
from html import escape

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response

app = FastAPI()

HYDRA_ADMIN_URL = os.environ["HYDRA_ADMIN_URL"]
GOOGLE_CLIENT_ID = os.environ["GOOGLE_CLIENT_ID"]
GOOGLE_CLIENT_SECRET = os.environ["GOOGLE_CLIENT_SECRET"]
GOOGLE_REDIRECT_URI = os.environ["GOOGLE_REDIRECT_URI"]
ALLOWED_EMAILS = set(os.environ.get("ALLOWED_EMAILS", "").split(","))

# In-memory state store for Google OAuth flow (maps state → login_challenge)
_state_store: dict[str, str] = {}

COMMON_STYLE = """
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
       background: #f5f5f5; min-height: 100vh;
       display: flex; align-items: center; justify-content: center; }
.container { background: white; padding: 2rem; border-radius: 8px;
             box-shadow: 0 2px 10px rgba(0,0,0,0.1);
             width: 100%; max-width: 450px; }
h1 { text-align: center; margin-bottom: 1rem; color: #333; font-size: 1.5rem; }
.client-name { text-align: center; font-size: 1.2rem; color: #007bff; margin-bottom: 1.5rem; }
p { margin-bottom: 1rem; color: #666; }
ul { margin: 1rem 0 1.5rem 1.5rem; }
li { margin-bottom: 0.5rem; }
.buttons { display: flex; gap: 1rem; }
button { flex: 1; padding: 0.75rem; border: none; border-radius: 4px;
         font-size: 1rem; cursor: pointer; }
.approve { background: #28a745; color: white; }
.approve:hover { background: #218838; }
.deny { background: #dc3545; color: white; }
.deny:hover { background: #c82333; }
.error { color: #dc3545; text-align: center; }
.google-btn { display: block; width: 100%; padding: 0.75rem; border: none;
              border-radius: 4px; font-size: 1rem; cursor: pointer;
              background: #4285f4; color: white; text-align: center;
              text-decoration: none; }
.google-btn:hover { background: #3367d6; }
"""


def _error_page(message: str) -> HTMLResponse:
    return HTMLResponse(
        f"""<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>エラー</title><style>{COMMON_STYLE}</style></head>
<body><div class="container">
<h1>エラー</h1>
<p class="error">{escape(message)}</p>
</div></body></html>""",
        status_code=400,
    )


@app.get("/consent/login")
async def login(login_challenge: str = ""):
    """Hydra redirects here for login. We redirect to Google OAuth."""
    if not login_challenge:
        return _error_page("login_challenge が必要です")

    # Check if user is already authenticated (skip login)
    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"{HYDRA_ADMIN_URL}/admin/oauth2/auth/requests/login",
            params={"login_challenge": login_challenge},
        )
        if resp.status_code != 200:
            return _error_page("無効な login challenge です")
        login_request = resp.json()

        # If the user has already logged in before, skip login
        if login_request.get("skip"):
            accept_resp = await client.put(
                f"{HYDRA_ADMIN_URL}/admin/oauth2/auth/requests/login/accept",
                params={"login_challenge": login_challenge},
                json={"subject": login_request["subject"]},
            )
            redirect_to = accept_resp.json()["redirect_to"]
            return RedirectResponse(redirect_to)

    # Start Google OAuth flow
    state = secrets.token_urlsafe(32)
    _state_store[state] = login_challenge

    google_auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode(
        {
            "client_id": GOOGLE_CLIENT_ID,
            "redirect_uri": GOOGLE_REDIRECT_URI,
            "response_type": "code",
            "scope": "openid email",
            "state": state,
            "prompt": "select_account",
        }
    )
    return RedirectResponse(google_auth_url)


@app.get("/consent/google/callback")
async def google_callback(code: str = "", state: str = "", error: str = ""):
    """Google OAuth callback → accept Hydra login."""
    if error:
        return _error_page(f"Google 認証エラー: {error}")

    login_challenge = _state_store.pop(state, None)
    if not login_challenge:
        return _error_page("無効な state パラメータです。もう一度やり直してください。")

    # Exchange code for Google tokens
    async with httpx.AsyncClient() as client:
        token_resp = await client.post(
            "https://oauth2.googleapis.com/token",
            data={
                "client_id": GOOGLE_CLIENT_ID,
                "client_secret": GOOGLE_CLIENT_SECRET,
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": GOOGLE_REDIRECT_URI,
            },
        )
        if token_resp.status_code != 200:
            return _error_page("Google トークンの取得に失敗しました")
        tokens = token_resp.json()

        # Get user info
        userinfo_resp = await client.get(
            "https://www.googleapis.com/oauth2/v3/userinfo",
            headers={"Authorization": f"Bearer {tokens['access_token']}"},
        )
        if userinfo_resp.status_code != 200:
            return _error_page("Google ユーザー情報の取得に失敗しました")
        userinfo = userinfo_resp.json()

    email = userinfo.get("email", "")
    if email not in ALLOWED_EMAILS:
        return _error_page(f"このメールアドレス ({escape(email)}) はアクセスが許可されていません")

    # Accept Hydra login
    async with httpx.AsyncClient() as client:
        accept_resp = await client.put(
            f"{HYDRA_ADMIN_URL}/admin/oauth2/auth/requests/login/accept",
            params={"login_challenge": login_challenge},
            json={
                "subject": email,
                "remember": True,
                "remember_for": 86400,
            },
        )
        if accept_resp.status_code != 200:
            return _error_page("Hydra login の受け入れに失敗しました")
        redirect_to = accept_resp.json()["redirect_to"]

    return RedirectResponse(redirect_to)


@app.get("/consent/consent")
async def consent_get(consent_challenge: str = ""):
    """Show consent page."""
    if not consent_challenge:
        return _error_page("consent_challenge が必要です")

    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"{HYDRA_ADMIN_URL}/admin/oauth2/auth/requests/consent",
            params={"consent_challenge": consent_challenge},
        )
        if resp.status_code != 200:
            return _error_page("無効な consent challenge です")
        consent_request = resp.json()

        # If previously consented, skip consent screen
        if consent_request.get("skip"):
            accept_resp = await client.put(
                f"{HYDRA_ADMIN_URL}/admin/oauth2/auth/requests/consent/accept",
                params={"consent_challenge": consent_challenge},
                json={
                    "grant_scope": consent_request.get("requested_scope", []),
                    "grant_access_token_audience": consent_request.get(
                        "requested_access_token_audience", []
                    ),
                },
            )
            redirect_to = accept_resp.json()["redirect_to"]
            return RedirectResponse(redirect_to)

    client_name = consent_request.get("client", {}).get("client_name", "不明なアプリ")
    scopes = consent_request.get("requested_scope", [])
    scope_labels = {
        "openid": "OpenID Connect (ID 情報)",
        "offline_access": "オフラインアクセス (リフレッシュトークン)",
        "mcp:read": "読み取り専用アクセス",
        "mcp:write": "読み書きアクセス",
        "mcp:admin": "管理者アクセス",
    }
    scope_list = "".join(
        f"<li>{escape(scope_labels.get(s, s))}</li>" for s in scopes
    )

    return HTMLResponse(f"""<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>認可リクエスト</title>
  <style>{COMMON_STYLE}</style>
</head>
<body>
  <div class="container">
    <h1>認可リクエスト</h1>
    <div class="client-name">{escape(client_name)}</div>
    <p>上記のアプリケーションがあなたのアカウントへのアクセスを要求しています。</p>
    <p><strong>要求されている権限:</strong></p>
    <ul>{scope_list}</ul>
    <form method="POST" action="/consent/consent">
      <input type="hidden" name="consent_challenge" value="{escape(consent_challenge)}">
      <div class="buttons">
        <button type="submit" name="approve" value="true" class="approve">許可</button>
        <button type="submit" name="approve" value="false" class="deny">拒否</button>
      </div>
    </form>
  </div>
</body>
</html>""")


@app.post("/consent/consent")
async def consent_post(request: Request):
    """Handle consent form submission."""
    form = await request.form()
    consent_challenge = form.get("consent_challenge", "")
    approved = form.get("approve") == "true"

    if not consent_challenge:
        return _error_page("consent_challenge が必要です")

    async with httpx.AsyncClient() as client:
        if approved:
            # Get consent request to know what scopes were requested
            resp = await client.get(
                f"{HYDRA_ADMIN_URL}/admin/oauth2/auth/requests/consent",
                params={"consent_challenge": consent_challenge},
            )
            consent_request = resp.json()

            accept_resp = await client.put(
                f"{HYDRA_ADMIN_URL}/admin/oauth2/auth/requests/consent/accept",
                params={"consent_challenge": consent_challenge},
                json={
                    "grant_scope": consent_request.get("requested_scope", []),
                    "grant_access_token_audience": consent_request.get(
                        "requested_access_token_audience", []
                    ),
                    "remember": True,
                    "remember_for": 86400,
                },
            )
            redirect_to = accept_resp.json()["redirect_to"]
        else:
            reject_resp = await client.put(
                f"{HYDRA_ADMIN_URL}/admin/oauth2/auth/requests/consent/reject",
                params={"consent_challenge": consent_challenge},
                json={
                    "error": "access_denied",
                    "error_description": "ユーザーがアクセスを拒否しました",
                },
            )
            redirect_to = reject_resp.json()["redirect_to"]

    return RedirectResponse(redirect_to, status_code=303)


@app.post("/oauth2/register")
async def dcr_proxy(request: Request):
    """Proxy DCR to Hydra and strip null/empty fields from response.

    Claude rejects DCR responses containing null values or empty objects,
    so we filter them out before returning.
    """
    body = await request.body()
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
    }

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{HYDRA_ADMIN_URL.replace(':4445', ':4444')}/oauth2/register",
            content=body,
            headers=headers,
        )

    data = resp.json()

    # Strip null, empty string, empty list, empty dict, and None values
    cleaned = {
        k: v
        for k, v in data.items()
        if v is not None and v != "" and v != [] and v != {}
    }

    return Response(
        content=json.dumps(cleaned),
        status_code=resp.status_code,
        media_type="application/json",
    )


@app.get("/consent/health")
async def health():
    """Health check endpoint."""
    return {"status": "ok"}
