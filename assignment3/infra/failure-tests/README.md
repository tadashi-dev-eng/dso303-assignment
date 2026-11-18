# Failure test scenarios

Each script injects one failure into the Floci deployment (`ENV=floci`, Region ap-southeast-1), measures the impact against **RPO 5 min / RTO 1 h**, then applies the fix. Run them from the repository root, for example `./infra/failure-tests/f1-az-loss.sh`. Output and screenshots are in `evidence/terminal/07`–`10`.

`exam-traffic.mjs` drives the RPO measurement. It acts as 5 students autosaving every 3 s through the failure. A failed save is kept and re-sent, as the SPA does with its browser copy. At the end every client's newest answer is compared with what DynamoDB stored. `lib.sh` holds the shared helpers.

## Results

| # | Scenario | Expected impact on the infrastructure | Measured (Floci) | RPO | RTO | Fix / likely solution |
|---|---|---|---|---|---|---|
| **F1** | **Loss of AZ ap-southeast-1a** during an exam (`f1-az-loss.sh`) | The Aurora writer in AZ-a is gone. Aurora promotes the AZ-b reader (~30 s in AWS). Exam opens, starts and submits fail during that window. Autosaves (DynamoDB, regional) and the SPA (CloudFront) carry on. Lambdas are not in a VPC, so there is no NAT or ENI to lose | Service verified **30 s** after the failure. 35 autosaves, 1 failed and was re-sent. AZ-a instance rebuilt by `terraform apply` in **110 s**; whole incident **184 s** | **0 answers lost** | 30 s to serve, 184 s to full redundancy | Automatic Multi-AZ failover; `terraform apply` restores the lost instance. Keep the reader (C1). The exam cache (C8) keeps exam opens working from memory during the failover |
| **F2** | **Marking worker outage** right after an exam (bad marker release, or the function throttled to 0) (`f2-marking-outage.sh`) | Students still get `202 submitted`, because the API only enqueues. Attempts wait in SQS (4-day retention, DLQ after 5 failed receives). Results are late; nothing is lost | 10 submissions accepted while the marker was at 0. After the fix the backlog drained in **180 s**; incident **296 s** | **0 submissions lost** | 296 s | Restore the worker from code (`terraform apply` puts reserved concurrency back to 50). The `marking-backlog-age` (>15 min) and `marking-dlq` alarms page on-call. Redrive the DLQ after a code fix |
| **F3** | **A submitted file is deleted by mistake** (`f3-deleted-submission.sh`) | The tutor gets 404. Versioning keeps the bytes under a delete marker; noncurrent versions are kept 30 days | 5 MB PDF deleted, then restored by removing the delete marker; SHA-256 identical; **28 s** | **0 bytes** | 28 s | S3 versioning (already on). For deliberate deletion protection add S3 Object Lock (governance mode) on `submissions/` |
| **F4** | **Broken API release mid-exam** (`f4-bad-deploy.sh`) | Every API call returns 5xx, so autosaves fail. The browser keeps the unsent answers. The `api-5xx` alarm fires after 2 minutes | 502s from 16:04:03Z. Rolled back in **20 s**; outage **54 s**; all clients re-synced at **135 s** | **0 answers lost** | 54 s to serve, 135 s including re-sync | In AWS repoint the `live` alias to the previous version (seconds); on Floci, redeploy the last good build. Prevention: CI smoke test before apply, and no deploys inside exam windows (S4) |

## Scenarios documented but not runnable on Floci

Floci has no `RestoreTableToPointInTime`, `CreateBackup` or `CreateDBClusterSnapshot`, so these are AWS runbooks with expected numbers.

| # | Scenario | Expected impact | Expected RPO / RTO | Solution |
|---|---|---|---|---|
| F5 | Answers corrupted or deleted in DynamoDB by a bad script | Affected attempts show wrong or empty answers | RPO: seconds (PITR); RTO: ~20–40 min to restore a 10 GB table to a new table and swap the name in `ATTEMPTS_TABLE` | `aws dynamodb restore-table-to-point-in-time --use-latest-restorable-time`; deletion protection is on in prod |
| F6 | Aurora data corrupted (bad migration) | Exams, attempts or results rows are wrong | RPO ≤ 5 min (latest restorable time is normally within 5 min); RTO ~30–45 min (restore cluster + instance, repoint `DB_CLUSTER_ARN`) | `aws rds restore-db-cluster-to-point-in-time`; monthly AWS Backup copies for 5-year history |
| F7 | Loss of the whole ap-southeast-1 Region | Platform down | RPO up to 24 h (no cross-Region copy); RTO many hours | Accepted (S8). If required later: AWS Backup cross-Region copy to ap-south-1 (~$5–10/month) and a second Terraform workspace |
