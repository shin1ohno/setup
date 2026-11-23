# Question from task d559605b7b844c25 attempt 1

The 2026-11 export job (jobs/export_users.py) still reads users.legacy_email.
Option 1: drop the column in this migration and change the export job to read users.email.
Option 2: keep the column for one more release and only stop writing to it.
Draft PR 42 holds the scaffolding; the migration body waits for this decision.
