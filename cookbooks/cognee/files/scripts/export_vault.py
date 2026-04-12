"""Export the Cognee knowledge graph as an Obsidian-compatible vault.

Usage (inside the cognee container):
    python /app/scripts/export_vault.py --vault /vault
    python /app/scripts/export_vault.py --vault /vault --clean

Each graph node becomes one Markdown file under <vault>/nodes/ with YAML
frontmatter and a "Relations" section linking to other nodes via [[wikilinks]].
An index.md at the vault root groups nodes by type.
"""

import argparse
import asyncio
import logging
import re
import shutil
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any

from cognee.infrastructure.databases.graph import get_graph_engine

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("cognee-export-vault")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export Cognee graph as Obsidian vault")
    parser.add_argument("--vault", type=Path, default=Path("/vault"), help="Output vault directory")
    parser.add_argument("--clean", action="store_true", help="Remove <vault>/nodes before writing")
    return parser.parse_args()


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


async def load_graph() -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    engine = await get_graph_engine()
    raw_nodes, raw_edges = await engine.get_graph_data()

    nodes: list[dict[str, Any]] = []
    for entry in raw_nodes:
        node_id, properties = entry if isinstance(entry, tuple) else (entry.get("id"), entry)
        props = dict(properties or {})
        props["id"] = str(node_id)
        nodes.append(props)

    edges: list[dict[str, Any]] = []
    for entry in raw_edges:
        if isinstance(entry, tuple) and len(entry) >= 3:
            source, target, relation, *rest = entry
            props = rest[0] if rest else {}
        else:
            source = entry.get("source_node_id") or entry.get("source")
            target = entry.get("destination_node_id") or entry.get("target")
            relation = entry.get("relationship_name") or entry.get("label")
            props = entry
        edges.append(
            {
                "source": str(source),
                "target": str(target),
                "relation": relation or "related",
                "props": props,
            }
        )

    return nodes, edges


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

    fm = frontmatter(
        {
            "id": node.get("id"),
            "type": node_type,
            "label": label,
        }
    )

    body = [fm, "", f"# {label}", ""]
    if description:
        body.extend([description.strip(), ""])

    if outgoing:
        body.append("## Relations")
        for edge in outgoing:
            target_info = slug_map.get(edge["target"])
            if not target_info:
                continue
            target_slug = target_info["slug"]
            target_label = target_info["label"]
            relation = edge["relation"]
            body.append(f"- [[{target_slug}|{target_label}]] — {relation}")
        body.append("")

    return "\n".join(body)


def render_index(slug_map: dict[str, dict[str, Any]]) -> str:
    buckets: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for info in slug_map.values():
        node_type = info["node"].get("type") or "unknown"
        buckets[node_type].append(info)

    lines = ["# Cognee Knowledge Graph", ""]
    lines.append(f"Total nodes: {len(slug_map)}")
    lines.append("")
    for node_type in sorted(buckets):
        entries = sorted(buckets[node_type], key=lambda e: e["label"])
        lines.append(f"## {node_type} ({len(entries)})")
        for info in entries:
            lines.append(f"- [[{info['slug']}|{info['label']}]]")
        lines.append("")
    return "\n".join(lines)


async def run(args: argparse.Namespace) -> None:
    vault: Path = args.vault
    nodes_dir = vault / "nodes"

    if args.clean and nodes_dir.exists():
        log.info("cleaning %s", nodes_dir)
        shutil.rmtree(nodes_dir)

    vault.mkdir(parents=True, exist_ok=True)
    nodes_dir.mkdir(parents=True, exist_ok=True)

    log.info("loading graph from Cognee")
    nodes, edges = await load_graph()
    log.info("loaded %d nodes and %d edges", len(nodes), len(edges))

    slug_map = build_slug_map(nodes)

    outgoing_by_source: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for edge in edges:
        outgoing_by_source[edge["source"]].append(edge)

    for node_id, info in slug_map.items():
        content = render_node(info, outgoing_by_source.get(node_id, []), slug_map)
        (nodes_dir / f"{info['slug']}.md").write_text(content + "\n", encoding="utf-8")

    (vault / "index.md").write_text(render_index(slug_map) + "\n", encoding="utf-8")
    log.info("wrote %d node files to %s", len(slug_map), nodes_dir)


def main() -> None:
    asyncio.run(run(parse_args()))


if __name__ == "__main__":
    main()
