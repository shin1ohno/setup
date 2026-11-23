# Task 498d474fc64f43a3 attempt 1

Changed src/sync/client.py: the retry backoff now doubles from 0.5 s to at most 8 s with jitter (it was a fixed 0.5 s).
Added tests/sync/test_backoff.py (4 tests).

make test: 42 passed (unit-tests.txt).
make test-integration: did not run; the Docker daemon is not reachable from this pane (integration-attempt.txt).
