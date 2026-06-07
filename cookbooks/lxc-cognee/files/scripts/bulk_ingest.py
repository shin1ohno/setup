"""One-shot bulk ingestion into Cognee.

Usage (inside the cognee container):
    python /app/scripts/bulk_ingest.py --urls /app/ingest/urls.txt --dir /app/ingest
    python /app/scripts/bulk_ingest.py --reset --dir /app/ingest

Reads URLs from a text file (one per line, blank lines and '#' comments ignored),
recursively collects supported files from a directory, and feeds them all to
`cognee.add()` in a single call before running `cognee.cognify()`.
"""

import argparse
import asyncio
import logging
import sys
import time
from pathlib import Path

import cognee
from cognee.modules.search.types import SearchType  # noqa: F401  (imported for user convenience)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("cognee-bulk-ingest")

SUPPORTED_EXTS = {".md", ".txt", ".pdf", ".docx", ".csv", ".html", ".htm"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bulk ingest into Cognee")
    parser.add_argument("--urls", type=Path, help="File containing one URL per line")
    parser.add_argument("--dir", type=Path, help="Directory to recursively scan for files")
    parser.add_argument("--dataset", default="main_dataset", help="Dataset name")
    parser.add_argument("--reset", action="store_true", help="Prune existing data before ingesting")
    return parser.parse_args()


def load_urls(path: Path) -> list[str]:
    urls: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        urls.append(stripped)
    return urls


def collect_files(root: Path) -> list[str]:
    paths: list[str] = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.suffix.lower() in SUPPORTED_EXTS and not path.name.startswith("."):
            paths.append(str(path))
    return paths


async def run(args: argparse.Namespace) -> None:
    if args.reset:
        log.info("pruning existing data and system state")
        await cognee.prune.prune_data()
        await cognee.prune.prune_system(metadata=True)

    payload: list[str] = []
    if args.urls and args.urls.exists():
        urls = load_urls(args.urls)
        log.info("loaded %d URLs from %s", len(urls), args.urls)
        payload.extend(urls)

    if args.dir and args.dir.exists():
        files = collect_files(args.dir)
        log.info("collected %d files under %s", len(files), args.dir)
        payload.extend(files)

    if not payload:
        log.warning("nothing to ingest — provide --urls and/or --dir")
        return

    log.info("adding %d items to dataset %s", len(payload), args.dataset)
    started = time.monotonic()
    await cognee.add(payload, dataset_name=args.dataset)
    log.info("add finished in %.1fs", time.monotonic() - started)

    log.info("running cognify")
    started = time.monotonic()
    await cognee.cognify()
    log.info("cognify finished in %.1fs", time.monotonic() - started)


def main() -> None:
    asyncio.run(run(parse_args()))


if __name__ == "__main__":
    main()
