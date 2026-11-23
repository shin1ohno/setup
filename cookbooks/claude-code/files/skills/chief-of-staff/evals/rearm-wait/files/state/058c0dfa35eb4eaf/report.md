# Task 058c0dfa35eb4eaf attempt 1

docs/sync.md section Retries now states: the first retry waits 0.5 s, each later retry doubles the wait, capped at 8 s, with up to 10% jitter.
