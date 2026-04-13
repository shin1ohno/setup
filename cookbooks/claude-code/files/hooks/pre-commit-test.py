#!/usr/bin/env python3
"""Claude Code PreToolUse hook: run project tests before git commit."""

import json
import os
import subprocess
import sys


def main():
    data = json.load(sys.stdin)
    command = data.get("tool_input", {}).get("command", "")

    # Only intercept git commit commands
    if not command.strip().startswith("git commit"):
        sys.exit(0)

    # Project type detection: (marker file, test command)
    runners = [
        ("package.json", "npm test"),
        ("Gemfile", "bundle exec rake test"),
        ("Makefile", "make test"),
        ("Cargo.toml", "cargo test"),
        ("pyproject.toml", "python -m pytest"),
        ("go.mod", "go test ./..."),
    ]

    for marker, test_cmd in runners:
        if os.path.exists(marker):
            result = subprocess.run(
                test_cmd, shell=True, capture_output=True, text=True
            )
            if result.returncode != 0:
                out = result.stdout[-500:] if len(result.stdout) > 500 else result.stdout
                err = result.stderr[-500:] if len(result.stderr) > 500 else result.stderr
                if out:
                    print(out, file=sys.stderr)
                if err:
                    print(err, file=sys.stderr)
                sys.exit(2)
            break

    sys.exit(0)


if __name__ == "__main__":
    main()
