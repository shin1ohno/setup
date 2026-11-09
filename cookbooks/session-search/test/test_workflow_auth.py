"""Every real pin/manifest caller gets only a read-only GitHub job token."""
import json
from pathlib import Path
import subprocess

repo = Path(__file__).resolve().parents[3]
workflow = repo / ".github/workflows/test-setup.yml"
parsed = json.loads(subprocess.check_output(["ruby", "-ryaml", "-rjson", "-e",
    'puts JSON.generate(YAML.load_file(ARGV[0], aliases: true))', str(workflow)], text=True))
count = 0
for name in ("syntax-check", "test-macos"):
    job = parsed["jobs"][name]
    assert job["permissions"] == {"contents": "read"}, name + " must use only contents:read"
    for step in job["steps"]:
        script = step.get("run", "")
        if any(call in script for call in ("bin/check-memory-v2-manifest", "bin/check-ai-memory-pin",
                                          "test/check-pin.sh", "test/test-attestation-auth.sh")):
            env = dict(job.get("env", {}), **step.get("env", {}))
            token = env.get("GH_TOKEN", env.get("GITHUB_TOKEN"))
            assert token == "${{ github.token }}", name + ": missing job token for " + step["name"]
            count += 1
assert count >= 6, "real provenance caller inventory unexpectedly shrank"
print("PASS read-only job token wiring for", count, "real verifier steps")
