# Task 841b114c257a4b11 attempt 1

tests/sync/test_client.py::test_retry_after_timeout used a real 50 ms sleep that raced the client timer.
It now advances a fake clock, so the test no longer depends on wall time.
