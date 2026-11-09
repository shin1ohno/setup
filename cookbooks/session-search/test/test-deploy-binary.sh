#!/bin/bash
# Deliberately uses /bin/bash (3.2 on macOS); all state is in a temp HOME.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/test_binary.py"
