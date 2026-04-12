"""Watch the Cognee knowledge graph via REST API and export to Obsidian vault on changes.

Polls the cognee API periodically and re-exports when node or edge counts change.
Uses the REST API instead of direct DB access to avoid Kuzu file locking.

Env vars:
  COGNEE_API            Base URL of the Cognee service (default http://cognee:8000)
  COGNEE_USER_EMAIL     Login email (default default_user@example.com)
  COGNEE_USER_PASSWORD  Login password (default default_password)
  EXPORT_POLL_SECONDS   Seconds between polls (default 60)
  VAULT_DIR             Output vault directory (default /vault)
  STARTUP_DELAY_SECONDS Seconds to wait before first poll (default 30)
"""

import asyncio
import logging
import os
import re
import shutil
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any

import httpx

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("cognee-vault-watcher")

COGNEE_API = os.environ.get("COGNEE_API", "http://cognee:8000").rstrip("/")
COGNEE_USER_EMAIL = os.environ.get("COGNEE_USER_EMAIL", "default_user@example.com")
COGNEE_USER_PASSWORD = os.environ.get("COGNEE_USER_PASSWORD", "default_password")
POLL_SECONDS = float(os.environ.get("EXPORT_POLL_SECONDS", "60"))
VAULT_DIR = Path(os.environ.get("VAULT_DIR", "/vault"))
STARTUP_DELAY = float(os.environ.get("STARTUP_DELAY_SECONDS", "30"))


# ---------------------------------------------------------------------------
# Rendering helpers (adapted from export_vault.py to be self-contained)
# ---------------------------------------------------------------------------

_slug_punct = re.compile(r"[^\w\u3040-\u30ff\u4e00-\u9fff\-]+", re.UNICODE)


def slugify(value: str, fallback: str) -> str:
    if not value:
        value = fallback
    value = unicodedata.normalize("NFKC", value)
    value = value.strip().replace(" ", "-")
    value = _slug_punct.sub("", value)
    value = re.sub(r"-{2,}", "-", value).strip("-")
    return value or fallback


def frontmatter(fields: dict[str, Any]) -> str:
    lines = ["---"]
    for key, value in fields.items():
        if value is None:
            continue
        rendered = str(value).replace("\n", " ").strip()
        if not rendered:
            continue
        if any(ch in rendered for ch in [":", "#", "[", "]", "\"", "'"]):
            rendered = '"' + rendered.replace('"', '\\"') + '"'
        lines.append(f"{key}: {rendered}")
    lines.append("---")
    return "\n".join(lines)


def build_slug_map(nodes: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    slug_map: dict[str, dict[str, Any]] = {}
    used_slugs: set[str] = set()
    for node in nodes:
        label = node.get("name") or node.get("label") or node.get("title") or node.get("id", "node")
        base = slugify(str(label), fallback=node.get("id", "node"))
        slug = base
        counter = 2
        while slug in used_slugs:
            slug = f"{base}-{counter}"
            counter += 1
        used_slugs.add(slug)
        slug_map[node["id"]] = {"slug": slug, "label": str(label), "node": node}
    return slug_map


def render_node(
    info: dict[str, Any],
    outgoing: list[dict[str, Any]],
    slug_map: dict[str, dict[str, Any]],
) -> str:
    node = info["node"]
    label = info["label"]
    node_type = node.get("type") or node.get("entity_type") or "unknown"
    description = node.get("description") or node.get("text") or node.get("summary") or ""

    fm = frontmatter({"id": node.get("id"), "type": node_type, "label": label})
    body = [fm, "", f"# {label}", ""]
    if description:
        body.extend([description.strip(), ""])
    if outgoing:
        body.append("## Relations")
        for edge in outgoing:
            target_info = slug_map.get(edge["target"])
            if not target_info:
                continue
            body.append(
                f"- [[{target_info['slug']}|{target_info['label']}]] — {edge['relation']}"
            )
        body.append("")
    return "\n".join(body)


def render_index(slug_map: dict[str, dict[str, Any]]) -> str:
    buckets: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for info in slug_map.values():
        node_type = info["node"].get("type") or "unknown"
        buckets[node_type].append(info)

    lines = ["# Cognee Knowledge Graph", "", f"Total nodes: {len(slug_map)}", ""]
    for node_type in sorted(buckets):
        entries = sorted(buckets[node_type], key=lambda e: e["label"])
        lines.append(f"## {node_type} ({len(entries)})")
        for info in entries:
            lines.append(f"- [[{info['slug']}|{info['label']}]]")
        lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Cognee API helpers
# ---------------------------------------------------------------------------

async def login(client: httpx.AsyncClient) -> None:
    url = f"{COGNEE_API}/api/v1/auth/login"
    response = await client.post(
        url,
        data={"username": COGNEE_USER_EMAIL, "password": COGNEE_USER_PASSWORD},
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=30.0,
    )
    response.raise_for_status()
    token = response.json().get("access_token")
    client.headers["Authorization"] = f"Bearer {token}"
    log.info("logged in as %s", COGNEE_USER_EMAIL)


async def api_get(client: httpx.AsyncClient, path: str, timeout: float = 30.0) -> Any:
    url = f"{COGNEE_API}{path}"
    response = await client.get(url, timeout=timeout)
    if response.status_code == 401:
        await login(client)
        response = await client.get(url, timeout=timeout)
    response.raise_for_status()
    return response.json()


# ---------------------------------------------------------------------------
# Export logic
# ---------------------------------------------------------------------------

def api_nodes_to_internal(api_nodes: list[dict]) -> list[dict]:
    nodes = []
    for n in api_nodes:
        props = dict(n.get("properties", {}))
        props["id"] = str(n["id"])
        props["type"] = n.get("type", "unknown")
        if "name" not in props and "label" not in props:
            props["label"] = n.get("label", "")
        nodes.append(props)
    return nodes


def api_edges_to_internal(api_edges: list[dict]) -> list[dict]:
    return [
        {
            "source": str(e["source"]),
            "target": str(e["target"]),
            "relation": e.get("label", "related"),
            "props": e,
        }
        for e in api_edges
    ]


def write_vault(nodes: list[dict], edges: list[dict]) -> None:
    nodes_dir = VAULT_DIR / "nodes"
    if nodes_dir.exists():
        shutil.rmtree(nodes_dir)

    VAULT_DIR.mkdir(parents=True, exist_ok=True)
    nodes_dir.mkdir(parents=True, exist_ok=True)

    slug_map = build_slug_map(nodes)

    outgoing_by_source: dict[str, list[dict]] = defaultdict(list)
    for edge in edges:
        outgoing_by_source[edge["source"]].append(edge)

    for node_id, info in slug_map.items():
        content = render_node(info, outgoing_by_source.get(node_id, []), slug_map)
        (nodes_dir / f"{info['slug']}.md").write_text(content + "\n", encoding="utf-8")

    (VAULT_DIR / "index.md").write_text(render_index(slug_map) + "\n", encoding="utf-8")
    log.info("wrote %d node files to %s", len(slug_map), nodes_dir)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

async def main() -> None:
    log.info(
        "starting vault watcher: poll=%ss, vault=%s, startup_delay=%ss",
        POLL_SECONDS,
        VAULT_DIR,
        STARTUP_DELAY,
    )

    log.info("waiting %ss for cognee to initialize", STARTUP_DELAY)
    await asyncio.sleep(STARTUP_DELAY)

    prev_counts: dict[str, tuple[int, int]] = {}

    async with httpx.AsyncClient() as client:
        await login(client)

        while True:
            try:
                datasets = await api_get(client, "/api/v1/datasets")
                all_nodes: list[dict] = []
                all_edges: list[dict] = []
                current_counts: dict[str, tuple[int, int]] = {}

                for ds in datasets:
                    ds_id = ds["id"]
                    graph = await api_get(
                        client, f"/api/v1/datasets/{ds_id}/graph", timeout=120.0
                    )
                    api_nodes = graph.get("nodes", [])
                    api_edges = graph.get("edges", [])
                    current_counts[ds_id] = (len(api_nodes), len(api_edges))
                    all_nodes.extend(api_nodes)
                    all_edges.extend(api_edges)

                total_nodes = sum(c[0] for c in current_counts.values())
                total_edges = sum(c[1] for c in current_counts.values())
                log.info(
                    "poll: %d datasets, nodes=%d edges=%d",
                    len(datasets),
                    total_nodes,
                    total_edges,
                )

                if current_counts != prev_counts:
                    if not prev_counts:
                        log.info("initial export")
                    else:
                        log.info("change detected, re-exporting")
                    try:
                        nodes = api_nodes_to_internal(all_nodes)
                        edges = api_edges_to_internal(all_edges)
                        write_vault(nodes, edges)
                        log.info("export completed successfully")
                    except Exception:
                        log.exception("export failed")
                    else:
                        prev_counts = current_counts

            except Exception:
                log.exception("poll failed (will retry next cycle)")

            await asyncio.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("shutting down")
