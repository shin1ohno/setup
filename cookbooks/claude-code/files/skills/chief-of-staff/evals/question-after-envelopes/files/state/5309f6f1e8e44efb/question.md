# Question from task 5309f6f1e8e44efb attempt 1

The 2026-11 export job (jobs/export_users.py) still reads users.legacy_email.
Option 1: drop the column in this migration and change the export job to read users.email.
Option 2: keep the column for one more release and only stop writing to it.
The worker stopped before writing the migration.
