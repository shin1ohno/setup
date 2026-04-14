---
globs: ["*.yaml", "*.yml", "*.tf", "Dockerfile", "docker-compose*.yml"]
---

# Infrastructure File Guidelines

- Always verify changes with dry-run / plan before applying
- Never hardcode secrets, tokens, or passwords — use environment variables or secret management
- Validate YAML/HCL syntax before committing
- Document non-obvious configuration choices with comments

## Blast Radius Awareness

When modifying infrastructure, always evaluate whether the change triggers resource recreation or just in-place update.

- **Before adding logic to a provisioning script** (user_data, cloud-init, etc.): check whether that script's content hash feeds into a replace trigger. If it does, the change will destroy and recreate the resource
- **Separate base infrastructure from application deployment**: OS setup, networking, and runtime installation belong in provisioning (runs at resource creation). Application code, configs, and container orchestration belong in a deploy step that can run independently without recreating the resource
- **Never mix change frequencies**: a file that changes weekly (app config) must not share a content hash with a file that should change rarely (OS bootstrap). If they are hashed together, the fast-changing file forces recreation of the slow-changing resource
- **When fixing a bug on a running instance**: determine whether the fix belongs in the base provisioning layer or the application deploy layer. Defaulting to the provisioning script because "it's already there" creates coupling that causes unnecessary recreation later

## Commit Timing for Cookbook Changes

After implementing a cookbook change:
1. Run mitamae dry-run (via mitamae-validator agent)
2. If dry-run passes: commit immediately — do not wait for deploy or user prompt
3. If dry-run fails: fix and retry, then commit

Dry-run passing is the commit gate for cookbook changes. Never leave cookbook changes uncommitted after a passing dry-run.

## Incident First Response

When a user reports any service or application misbehavior (slow, unavailable, failing):
1. Run `systemctl --failed` and check OOM kills in journal before diagnosing application logic
2. Check `journalctl -u <service> -n 50 --no-pager` for the affected service
3. Report findings before proposing fixes — the cause may be OS-level, not app-level
