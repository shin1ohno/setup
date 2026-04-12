"""Watch the Cognee knowledge graph and export to Obsidian vault on changes.

Polls the graph DB periodically and re-exports when node or edge counts change.
Designed to run as a long-lived sidecar inside the cognee Docker image.

Env vars:
  EXPORT_POLL_SECONDS   Seconds between polls (default 60)
  VAULT_DIR             Output vault directory (default /vault)
  STARTUP_DELAY_SECONDS Seconds to wait before first poll (default 30)
"""

import asyncio
import logging
import os
import sys
from argparse import Namespace
from pathlib import Path

import export_vault

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("cognee-vault-watcher")

POLL_SECONDS = float(os.environ.get("EXPORT_POLL_SECONDS", "60"))
VAULT_DIR = Path(os.environ.get("VAULT_DIR", "/vault"))
STARTUP_DELAY = float(os.environ.get("STARTUP_DELAY_SECONDS", "30"))


async def get_counts() -> tuple[int, int]:
    """Load the graph and return (node_count, edge_count)."""
    nodes, edges = await export_vault.load_graph()
    return len(nodes), len(edges)


async def do_export() -> None:
    """Run the full export in --clean mode."""
    args = Namespace(vault=VAULT_DIR, clean=True)
    await export_vault.run(args)


async def main() -> None:
    log.info(
        "starting vault watcher: poll=%ss, vault=%s, startup_delay=%ss",
        POLL_SECONDS,
        VAULT_DIR,
        STARTUP_DELAY,
    )

    log.info("waiting %ss for cognee to initialize", STARTUP_DELAY)
    await asyncio.sleep(STARTUP_DELAY)

    prev_node_count: int | None = None
    prev_edge_count: int | None = None

    while True:
        try:
            node_count, edge_count = await get_counts()
            log.info(
                "poll: nodes=%d edges=%d (prev: nodes=%s edges=%s)",
                node_count,
                edge_count,
                prev_node_count,
                prev_edge_count,
            )

            changed = (node_count != prev_node_count) or (edge_count != prev_edge_count)

            if changed:
                if prev_node_count is None:
                    log.info("initial export")
                else:
                    log.info("change detected, re-exporting")
                try:
                    await do_export()
                    log.info("export completed successfully")
                except Exception:
                    log.exception("export failed")
                else:
                    prev_node_count = node_count
                    prev_edge_count = edge_count

        except Exception:
            log.exception("poll failed (will retry next cycle)")

        await asyncio.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("shutting down")
