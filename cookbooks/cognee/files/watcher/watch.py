"""Cognee drop-folder watcher.

Monitors DROP_DIR for new or updated files, POSTs them to the Cognee REST API
(`/api/v1/add`), and after a period of inactivity triggers `/api/v1/cognify`
to extract entities and relationships. Processed files are moved to
DROP_DIR/.done/ so the folder stays clean.

Env vars:
  COGNEE_API            Base URL of the Cognee service (default http://cognee:8000)
  DROP_DIR              Folder to watch (default /drop)
  COGNIFY_IDLE_SECONDS  Seconds of inactivity before cognify is triggered (default 30)
  DATASET_NAME          Dataset label used for the ingestion (default main_dataset)
  COGNEE_USER_EMAIL     Login email (default default_user@example.com)
  COGNEE_USER_PASSWORD  Login password (default default_password)
"""

import asyncio
import logging
import os
import shutil
import sys
import time
from pathlib import Path

import httpx
from watchfiles import Change, awatch

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("cognee-watcher")

COGNEE_API = os.environ.get("COGNEE_API", "http://cognee:8000").rstrip("/")
DROP_DIR = Path(os.environ.get("DROP_DIR", "/drop"))
COGNIFY_IDLE_SECONDS = float(os.environ.get("COGNIFY_IDLE_SECONDS", "30"))
DATASET_NAME = os.environ.get("DATASET_NAME", "main_dataset")
COGNEE_USER_EMAIL = os.environ.get("COGNEE_USER_EMAIL", "default_user@example.com")
COGNEE_USER_PASSWORD = os.environ.get("COGNEE_USER_PASSWORD", "default_password")

DONE_DIR = DROP_DIR / ".done"
SUPPORTED_EXTS = {".md", ".txt", ".pdf", ".docx", ".csv", ".html", ".htm"}

# Shared state: when cognify should run next.
pending_cognify = asyncio.Event()
last_activity_ts = 0.0


def is_ingestable(path: Path) -> bool:
    if not path.is_file():
        return False
    if DONE_DIR in path.parents:
        return False
    if path.name.startswith("."):
        return False
    if path.suffix.lower() not in SUPPORTED_EXTS:
        return False
    return True


async def _post_with_relogin(
    client: httpx.AsyncClient, url: str, *, files=None, data=None, json=None, timeout: float
) -> httpx.Response:
    """POST, re-logging-in once on 401 so restarts of cognee don't wedge us."""
    if files is not None:
        response = await client.post(url, files=files, data=data, timeout=timeout)
    else:
        response = await client.post(url, json=json, timeout=timeout)
    if response.status_code == 401:
        log.warning("session expired, re-authenticating")
        await login(client)
        if files is not None:
            # httpx consumed the file handle on the first attempt; caller will rebuild
            return response
        response = await client.post(url, json=json, timeout=timeout)
    return response


async def upload_file(client: httpx.AsyncClient, path: Path) -> bool:
    """Upload a single file to Cognee. Returns True on success."""
    url = f"{COGNEE_API}/api/v1/add"
    for attempt in range(2):
        try:
            with path.open("rb") as f:
                files = {"data": (path.name, f, "application/octet-stream")}
                data = {"datasetName": DATASET_NAME}
                response = await client.post(url, files=files, data=data, timeout=120.0)
            if response.status_code == 401 and attempt == 0:
                log.warning("session expired, re-authenticating")
                await login(client)
                continue
            if response.status_code >= 400:
                log.error("add failed for %s: HTTP %s %s", path.name, response.status_code, response.text[:500])
                return False
            log.info("added %s (HTTP %s)", path.name, response.status_code)
            return True
        except httpx.HTTPError as exc:
            log.error("add error for %s: %s", path.name, exc)
            return False
    return False


async def trigger_cognify(client: httpx.AsyncClient) -> None:
    url = f"{COGNEE_API}/api/v1/cognify"
    try:
        response = await _post_with_relogin(
            client, url, json={"datasets": [DATASET_NAME]}, timeout=1800.0
        )
        if response.status_code >= 400:
            log.error("cognify failed: HTTP %s %s", response.status_code, response.text[:500])
            return
        log.info("cognify completed (HTTP %s)", response.status_code)
    except httpx.HTTPError as exc:
        log.error("cognify error: %s", exc)


def mark_activity() -> None:
    global last_activity_ts
    last_activity_ts = time.monotonic()
    pending_cognify.set()


async def process_path(client: httpx.AsyncClient, path: Path) -> None:
    if not is_ingestable(path):
        return
    log.info("picked up %s", path)
    success = await upload_file(client, path)
    if success:
        DONE_DIR.mkdir(parents=True, exist_ok=True)
        target = DONE_DIR / path.name
        counter = 1
        while target.exists():
            target = DONE_DIR / f"{path.stem}.{counter}{path.suffix}"
            counter += 1
        shutil.move(str(path), str(target))
        mark_activity()


async def cognify_loop(client: httpx.AsyncClient) -> None:
    """Wait for pending activity, then after idle period trigger cognify."""
    while True:
        await pending_cognify.wait()
        while True:
            await asyncio.sleep(1)
            idle = time.monotonic() - last_activity_ts
            if idle >= COGNIFY_IDLE_SECONDS:
                break
        pending_cognify.clear()
        log.info("idle for %.0fs — triggering cognify", COGNIFY_IDLE_SECONDS)
        await trigger_cognify(client)


async def initial_sweep(client: httpx.AsyncClient) -> None:
    """Ingest any files that were already present when we started."""
    if not DROP_DIR.exists():
        log.warning("drop dir %s does not exist", DROP_DIR)
        return
    for path in sorted(DROP_DIR.rglob("*")):
        await process_path(client, path)


async def watch_loop(client: httpx.AsyncClient) -> None:
    async for changes in awatch(str(DROP_DIR), recursive=True):
        for change, raw_path in changes:
            if change == Change.deleted:
                continue
            await process_path(client, Path(raw_path))


async def login(client: httpx.AsyncClient) -> None:
    url = f"{COGNEE_API}/api/v1/auth/login"
    response = await client.post(
        url,
        data={"username": COGNEE_USER_EMAIL, "password": COGNEE_USER_PASSWORD},
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=30.0,
    )
    response.raise_for_status()
    log.info("logged in as %s", COGNEE_USER_EMAIL)


async def main() -> None:
    DROP_DIR.mkdir(parents=True, exist_ok=True)
    log.info("watching %s, cognee API at %s", DROP_DIR, COGNEE_API)
    async with httpx.AsyncClient() as client:
        await login(client)
        await initial_sweep(client)
        await asyncio.gather(watch_loop(client), cognify_loop(client))


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("shutting down")
