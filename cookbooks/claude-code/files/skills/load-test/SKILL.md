---
name: load-test
description: Progressive load testing and performance tuning for Docker services. Identifies hard constraints, finds breaking points, and proposes tuning within safe limits.
user-invocable: true
argument-hint: "<service-name or URL>"
---

# Load Test & Performance Tuning Skill

## Purpose

Systematically identify performance limits of a Docker-based service, find the bottleneck, and tune configuration within hard constraints. Follows the principle: **discover hard limits first, then tune within them**.

## Argument Parsing

`$ARGUMENTS` identifies the target service. Accepted formats:

| Format | Example | Interpretation |
|--------|---------|----------------|
| Service name | `cognee` | Auto-detect Docker container and API endpoint |
| URL | `http://localhost:8001/api/v1/datasets` | Direct endpoint |
| Docker container | `docker:my-container-1` | Container name for log/stats analysis |

If `$ARGUMENTS` is empty, use AskUserQuestion to ask which service to test.

## Workflow

### Step 1: Target Resolution

Resolve the target into three components:

1. **API endpoint URL** — the HTTP endpoint to benchmark
2. **Docker container name(s)** — for log analysis and resource monitoring
3. **Authentication method** — Bearer token, Basic auth, or none

Auto-detection:
- Run `docker ps` to find matching containers
- Check for health endpoints (`/health`, `/api/v1/health`)
- If authentication is needed, check for login endpoints or env vars

Use AskUserQuestion if the target is ambiguous or authentication cannot be auto-detected.

### Step 2: Hard Constraint Discovery (CRITICAL)

**Before any load testing**, identify immutable upper bounds. This step prevents tuning parameters beyond what the infrastructure can support.

Launch up to 3 sub-agents in parallel:

**Agent 1 — Infrastructure limits:**
```
- DB: SELECT max_connections (PostgreSQL/MySQL via docker exec or direct query)
- DB: SELECT count(*) FROM pg_stat_activity GROUP BY usename (current usage)
- OS: ulimit -n (file descriptors)
- OS: free -h, nproc (memory, CPU cores)
- Docker: resource limits from docker inspect (cpus, memory)
```

**Agent 2 — Application constraints:**
```
- Docker compose env vars (connection pool settings, worker counts)
- Entrypoint/startup scripts (hardcoded limits like -w 1)
- File-based locks (kuzu, SQLite — single-writer constraint)
- Config files inside container (docker exec cat)
```

**Agent 3 — Shared resource mapping:**
```
- Other services sharing the same DB (check pg_stat_activity by user)
- Other services sharing the same Docker network
- Reverse proxy connection limits (nginx, caddy)
```

Present findings as a constraint table:

```
| Constraint | Value | Source | Shared? |
|-----------|-------|--------|---------|
| DB max_connections | 79 | RDS t4g.micro | Yes (mem0: 1, hydra: 2) |
| Available DB slots | ~63 | 79 - 11 reserved - 5 buffer | — |
| Gunicorn workers | 1 (hardcoded) | entrypoint.sh | No |
| File lock | kuzu (single-writer) | graph DB | No |
```

### Step 2b: DB-less Service Shortcut

If Step 2 reveals the service has **no database dependency** (no PostgreSQL, MySQL, SQLite, or connection pool):

1. Skip pool-related constraint analysis
2. Run Steps 3-4 with higher initial concurrency (start at 100, escalate to 500, 1000)
3. The primary bottleneck is likely OS-level (file descriptors, TCP backlog) or application-level (event loop saturation, worker threads)
4. If the service handles 1000+ concurrent with 100% success, conclude "no tuning needed" and skip Steps 5-6

### Step 3: Baseline Measurement

Run progressive benchmarks using curl:

1. **Single request** — verify connectivity, measure latency
2. **10 concurrent × 10 rounds** — light load baseline
3. **50 concurrent × 20 rounds** — moderate load

For each level, report:

```
| Concurrency | Total | Success | Fail | Throughput | Duration |
|-------------|-------|---------|------|------------|----------|
| 1           | 1     | 1       | 0    | —          | 245ms    |
| 10          | 100   | 100     | 0    | 8.2 req/s  | 12s      |
| 50          | 1000  | 1000    | 0    | 14.9 req/s | 67s      |
```

Benchmark script pattern:
```bash
# Auth → loop(concurrent curl with timeout → write HTTP code to file) → categorize → summary
```

Categorize results by HTTP code:
- **200**: success
- **000**: connection refused / timeout (curl couldn't connect — indicates backlog overflow or service down)
- **5xx**: server error (application processed the request but failed — indicates pool exhaustion, OOM, etc.)
- **4xx**: client error (auth failure, bad request — likely a benchmark script bug)

Report failures broken down by category, not just "fail" count.

### Step 4: Breaking Point Discovery

Double concurrency until failures appear:
- 50 → 100 → 200 (stop at first failure or 200)

Monitor simultaneously:
- `docker stats --no-stream` for CPU/memory during load
- Error count per round

### Step 4b: Recovery Check

After finding the breaking point, verify the service can recover:

1. Wait 10 seconds after the breaking-point test
2. Run a single request to check if the service responds
3. If it doesn't respond, check `docker ps` for unhealthy status
4. Record recovery behavior:
   - **Self-healing**: service recovers without intervention
   - **Needs restart**: service stays unhealthy, requires `docker compose restart`
   - **Cascading failure**: service crash affects dependent services

This information is critical for operational planning — a service that doesn't self-heal after pool exhaustion needs monitoring alerts or a restart policy.

### Step 5: Bottleneck Analysis

When failures are found, launch 3 sub-agents in parallel:

| Agent | Task |
|-------|------|
| Error log analyzer | `docker logs --since 5m` filtered for error/timeout/pool/connection/limit |
| Resource monitor | `docker stats` + `uptime` + `free -h` during load |
| Config researcher | Web search for `<service-name> performance tuning`, official docs, GitHub issues |

Synthesize into a root cause statement:
```
Bottleneck: [component] — [specific error message]
Hard constraint: [which limit was hit]
Tunable parameters: [what can be changed within the constraint]
```

### Step 6: Tuning Proposal

Enter plan mode (EnterPlanMode) with a tuning plan that:

1. **Respects all hard constraints** from Step 2
2. Lists specific parameter changes with before/after values
3. Explains why each change helps
4. Identifies files to modify (docker-compose.yml, .env, custom configs)
5. Includes rollback instructions

### Step 7: Verification

After changes are applied:

1. Re-run the same benchmark from Step 3 (same concurrency levels)
2. Re-run the breaking-point test from Step 4
3. Compare before/after in a summary table:

```
| Test | Before | After |
|------|--------|-------|
| 50 concurrent | 100% (14.9 req/s) | 100% (14.1 req/s) |
| 100 concurrent | 1.1% (6.6 req/s) | 100% (20.4 req/s) |
```

4. Verify no errors in `docker logs`
5. Check that shared services (other DB users) are unaffected

### Step 8: Long-Duration Stability Test (Optional)

When the user requests extended stability validation, run intermittent load bursts over several hours:

1. **Configuration**: use the safe concurrency level from Step 4 (below breaking point)
2. **Cycle structure**: burst → 60s cooldown → health check → 19min rest → next cycle
3. **Minimum duration**: 6 cycles (~2 hours) to detect slow leaks
4. **Monitor per cycle**:
   - Success rate and throughput (compare against baseline from Step 3)
   - Memory usage trend (detect leaks: >20% growth over test duration is a flag)
   - Container restart count
   - Error log analysis
5. **The agent must own the loop** — do not launch a bash script in the background and terminate. The agent iterates over cycles directly, sleeping between them
6. **Report**: cycle-by-cycle table with throughput, memory, and success rate. Final verdict: stable / degrading / unstable

```
| Cycle | Success | Throughput | Memory | Restarts |
|-------|---------|------------|--------|----------|
| 1     | 100%    | 12.4 req/s | 162MB  | 0        |
| 2     | 100%    | 12.2 req/s | 163MB  | 0        |
| ...   | ...     | ...        | ...    | ...      |
| 6     | 100%    | 12.5 req/s | 166MB  | 0        |
```

Memory trend: 162→166MB (+2.5%) — no leak detected.

## Principles

- **Constraint-first**: never increase a parameter without first confirming the hard limit it feeds into
- **Measure before and after**: every change must have before/after benchmark data
- **Fail fast over fail slow**: prefer short timeouts (30s) over long ones (280s) to prevent cascading failures
- **One variable at a time**: when multiple changes are needed, apply and verify incrementally when possible
- **Shared resources need budget**: if a DB is shared, calculate available slots per service, not total capacity
