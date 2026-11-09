#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 -B "$HERE/test_distribution_guards.py"
python3 -B "$HERE/test_workflow_auth.py"
python3 -B "$HERE/test_crosscheck.py"
python3 -B "$HERE/test_python_tree.py"
exec python3 -B -u "$HERE/test_rollback.py"
