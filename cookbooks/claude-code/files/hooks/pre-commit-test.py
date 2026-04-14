#!/usr/bin/env python3
"""Claude Code PreToolUse hook: run project tests before git commit."""

import json
import os
import subprocess
import sys


def _has_npm_test():
    """Check package.json has a real test script (not the default placeholder)."""
    try:
        with open("package.json") as f:
            pkg = json.load(f)
        script = pkg.get("scripts", {}).get("test", "")
        return bool(script) and "no test specified" not in script
    except (json.JSONDecodeError, OSError):
        return False


def _has_make_target(target):
    """Check Makefile has the given target."""
    result = subprocess.run(
        ["make", "-n", target], capture_output=True, text=True
    )
    return result.returncode == 0


def main():
    data = json.load(sys.stdin)
    command = data.get("tool_input", {}).get("command", "")

    # Only intercept git commit commands
    if not command.strip().startswith("git commit"):
        sys.exit(0)

    # Project type detection: (marker file, guard check, test command)
    # Guard ensures the test infrastructure actually exists before running.
    runners = [
        ("package.json", _has_npm_test, "npm test"),
        ("Gemfile", lambda: os.path.exists("Rakefile"), "bundle exec rake test"),
        ("Makefile", lambda: _has_make_target("test"), "make test"),
        ("Cargo.toml", lambda: True, "cargo test"),
        ("pyproject.toml", lambda: True, "python -m pytest"),
        ("go.mod", lambda: True, "go test ./..."),
    ]

    for marker, guard, test_cmd in runners:
        if os.path.exists(marker) and guard():
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
