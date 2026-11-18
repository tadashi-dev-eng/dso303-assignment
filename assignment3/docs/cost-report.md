# Cost and service report – Assignment 3

Online Exams & Submissions Platform in **Asia Pacific (Singapore), ap-southeast-1**.

* **Prices:** AWS Price List API (the data the AWS Pricing Calculator uses), offer files published **2026-11-11T22:30:04Z**, checked **2026-11-15**. Every unit price, its `usageType` and its description are in [`../evidence/pricing/prices-ap-southeast-1.json`](../evidence/pricing/prices-ap-southeast-1.json) and [`prices-ap-south-1.json`](../evidence/pricing/prices-ap-south-1.json).
* **Model:** [`../tools/cost_model.py`](../tools/cost_model.py) applies those prices to the workload below. It writes one calculator-style estimate per Region, design and load profile to [`../evidence/calculator/`](../evidence/calculator/). The run is shown in `evidence/terminal/11-cost-model.png`.
* **Designs:** "A2" is the Assignment 2 architecture moved to Singapore unchanged. "A3" is the revised architecture in [`../architecture/`](../architecture/).

## 1. Load profiles and assumptions

| | Normal month (10 per year) | Exam month (2 per year) |
|---|---|---|
| Users | 300–500 concurrent (400 used), 10 h/day, 22 days | Normal traffic **plus** 8,000 students × 5 exams = **40,000 sittings** of 2 h |
| API requests | 400 users × 1 call / 20 s → **15.84 M** | 15.84 M + 40,000 × 250 (240 autosaves + open/start/submit) = **25.84 M** |
| Peak | ~20 req/s | **3,000 students start one exam within 5 min**: 10 opens/s, then 3,000 ÷ 30 s = **100 autosaves/s** |
| Uploads | 16,000 files × 8 MB = 125 GB | 8,000 files = 62.5 GB |
| Emails | 24,000 | 48,000 |

Other assumptions (all in `cost_model.py`):
* `api` Lambda: 512 MB arm64, 60 ms average.
* 30% of normal calls are DynamoDB autosaves, 1.5 WRU each. 40% read Aurora, at 1.5 Data API calls per request.
* Aurora: 20 GB of storage, 20 M I/O (normal) and 30 M I/O (exam).
* DynamoDB tables: 10 GB average in year 1.
* Tutors download each file 1.2 times. The SPA is 1.5 MB per session, 20 sessions per user per month.
* Logs: 600 bytes per request (Lambda platform lines and API access log), plus 450 bytes for the EMF line in A3.
* S3 is shown at **month 12** of year 1 (1 month of uploads in Standard, 5 in Standard-IA, 6 in Glacier Instant Retrieval).
* Always-free tiers are applied the way the calculator applies them: Lambda (1 M requests and 400k GB-s), SQS (1 M), CloudFront (1 TB and 10 M requests), DynamoDB (25 GB), X-Ray (100k traces), Cognito (10,000 MAU) and 10 alarms. The RDS Data API free tier is **not** applied.

## 2. Monthly cost per service (Singapore)

| Service | What is billed | A2 normal | A2 exam | **A3 normal** | **A3 exam** |
|---|---|---:|---:|---:|---:|
| Aurora PostgreSQL – compute | A2: 2 × db.r6g.large On-Demand @ $0.313/h · A3: Serverless v2, 1,095 / 1,185 ACU-h @ $0.20 | 456.98 | 456.98 | **219.00** | **237.00** |
| Aurora – storage, I/O, backup | 20 GB @ $0.11, I/O @ $0.22/M, 10 GB backup @ $0.023 | 6.83 | 9.03 | 6.83 | 9.03 |
| RDS Data API *(hidden)* | 9.5 M / 9.7 M calls @ $0.42/M | 3.99 | 4.09 | 3.99 | 4.06 |
| Lambda – requests + duration | 15.8 M / 25.8 M requests, arm64 @ $0.0000133/GB-s | 3.97 | 9.97 | 3.97 | 9.97 |
| Lambda – provisioned concurrency | A2: 300 × 0.5 GB × 200 h · A3: 50 × 0.5 GB × 20 h @ $0.0000041593/GB-s | – | 449.20 | – | **7.49** |
| API Gateway HTTP API | @ $1.25/M | 19.80 | 32.30 | 19.80 | 32.30 |
| AWS WAF | $5 ACL + $1/rule (3 in A2, 4 in A3) + $0.60/M | 18.51 | 24.51 | 19.51 | 25.51 |
| CloudFront (India edges) | HTTPS @ $0.012/10k beyond 10 M free; 290 GB out (inside the 1 TB free tier) | 9.02 | 21.02 | 9.02 | 21.02 |
| Route 53 · Cognito | 1 zone · 8,400 MAU (free up to 10,000) | 0.50 | 0.50 | 0.50 | 0.50 |
| DynamoDB | 7.1 M / 21.5 M WRU @ $0.71/M, RRU @ $0.1425/M, PITR 10 GB @ $0.228 | 8.02 | 18.93 | 8.02 | 18.93 |
| **Backups** *(hidden)* | DynamoDB via AWS Backup: A2 daily × 35 + monthly · A3 monthly only | 46.40 | 46.40 | **6.50** | **6.50** |
| S3 | Submissions storage at month 12 + PUT/GET + lifecycle transitions + frontend/logs | 17.53 | 17.48 | 17.53 | 17.48 |
| **Data transfer out** *(hidden)* | tutor downloads straight from S3: 150 / 75 GB @ $0.12 | 18.00 | 9.00 | 18.00 | 9.00 |
| **NAT gateway processing + hours** *(hidden)* | 2 × 730 h @ $0.059 + 30 GB @ $0.059 | 87.91 | 87.91 | – | – |
| **CloudWatch Logs** *(hidden)* | ingestion @ $0.70/GB; A2 90 days, A3 30 days (+ EMF lines) | 6.99 | 11.41 | 11.31 | 18.45 |
| CloudWatch alarms/dashboard/metrics | 8–9 alarms (10 free), $3 dashboard, A3 24 EMF metrics @ $0.30 | 3.00 | 3.00 | 10.20 | 10.20 |
| X-Ray | 1/s reservoir + 5% (A2) or 1% (A3) @ $5/M traces | 7.42 | 9.92 | 4.25 | 4.75 |
| SQS · SES | 2.1–2.6 M requests @ $0.40/M · emails @ $0.10/1,000 | 2.84 | 5.44 | 2.84 | 5.44 |
| **KMS requests** *(hidden)* · Secrets Manager | $1 key + 0.3/0.6 M requests @ $0.03/10k · 1 secret $0.40 | 2.30 | 3.20 | 2.30 | 3.20 |
| **Total per month** | | **720.01** | **1,220.29** | **363.57** | **440.83** |

**Year and per-student figures (Singapore):**

| | A2 design | **A3 design** |
|---|---:|---:|
| Annual total (10 normal + 2 exam months) | $9,640.68 | **$4,517.36** |
| Average per month | $803.39 | **$376.45** |
| Cost per student per year (8,000 students) | $1.21 | **$0.56** |
| Cost per exam sitting (annual cost ÷ 80,000 sittings) | $0.121 | **$0.056** |

**Hidden costs.** These are the charges that are easy to miss because no resource carries their name:
* **Data transfer out:** $18 per month for tutor downloads directly from S3.
* **NAT gateways:** $87.91 per month for the hours plus GB processed (A2 only).
* **CloudWatch Logs:** $11–18 per month.
* **KMS requests:** about $1–2 per month on top of the $1 key.
* **Backups:** $46.40 per month in A2, because every daily DynamoDB backup is a full copy.
* **RDS Data API calls:** about $4 per month.
* **Not modelled:** cross-AZ data transfer (nothing zonal talks across AZs any more) and CloudTrail (the first management trail is free).

## 3. The three most expensive components and why

1. **Aurora PostgreSQL – $219 (normal) / $237 (exam), 60% and 54% of the bill.** A relational database must exist, and must exist in two AZs, even when nobody is online, because it holds the system of record and the failover target that the "survive the loss of one AZ" target requires. Serverless v2 cuts the idle cost from two always-on db.r6g.large instances ($457) to roughly 1.5 ACU outside exams. The floor is 0.5 ACU per instance.
2. **API Gateway – $19.80 / $32.30.** It is billed per request, and every autosave is a request. 25.8 M calls in an exam month × $1.25/M. The HTTP API is already the cheapest front door; a REST API would cost $4.20/M.
3. **AWS WAF – $19.51 / $25.51.** $9 fixed (ACL + 4 rules) plus $0.60 for every million requests that CloudFront passes through it, which is all 26–30 M of them.

Close behind are data transfer out ($18), S3 ($17.53) and CloudFront request fees ($21 in exam months). In A2 the top three were different: Aurora instances ($457), provisioned concurrency ($449 in exam months) and NAT gateways ($88). All three were removed or cut by the changes in section 6.

## 4. Service choices compared with an alternative

| Decision | Chosen | Alternative(s) | Cost (Singapore, per month) | Performance | Resilience | Effort |
|---|---|---|---|---|---|---|
| **Backend compute** | **Lambda (arm64)** + 50 provisioned for 1 h per exam | ECS Fargate behind an ALB · EC2 Auto Scaling | **Lambda $4 normal, $17 exam.** Fargate: 4 always-on ARM tasks (2 per AZ, 1 vCPU/2 GB @ $0.04045 + 2 × $0.00442/h) = $144 + ALB $18.40 + LCU ≈ $12 = **≈ $174**, plus NAT or endpoints (~$76–88), plus more tasks in exams | Lambda scales per request in seconds; cold starts are removed by the exam window. Fargate/EC2 take 1–3 min to add capacity, so they must run pre-scaled | All three span AZs; Lambda has no instance to lose | Lambda: no OS, no AMIs, no scaling policies. EC2: patching + AMIs + ASG tuning |
| **Answers / records database** | **DynamoDB on-demand** for autosaves + **Aurora Serverless v2** for records | Aurora provisioned 2 × r6g.large · RDS PostgreSQL Multi-AZ r6g.large · DynamoDB only | **Serverless v2 $219–237.** Aurora r6g.large × 2: $457 On-Demand, $353 1-yr RI. RDS Multi-AZ r6g.large: $0.54/h = $394 + gp3 storage. DynamoDB-only: ~$27 but no SQL | DynamoDB: single-digit-ms autosaves at any rate. Aurora scales 0.5 → 16 ACU in seconds | Aurora failover ~30 s, 6 copies in 3 AZs. RDS Multi-AZ failover 60–120 s and no Data API (needs RDS Proxy or VPC Lambdas) | DynamoDB-only would mean rewriting results/marking queries as key-value access patterns |
| **Private traffic** | **No VPC for Lambda**: Data API + public AWS endpoints over TLS + IAM | 2 NAT gateways (A2) · VPC interface endpoints | **$0.** NAT: 2 × 730 × $0.059 + $0.059/GB = **$87.91.** Interface endpoints for rds-data, sqs, secretsmanager and kms in 2 AZs: 8 × 730 × $0.013 = **$75.92** + $0.01/GB | No ENI set-up; the same latency to DynamoDB/S3 | The NAT gateway is zonal (an SPOF per AZ). No-VPC Lambda has no zonal component | Less Terraform: 4 subnets, 2 NATs, 2 EIPs, the IGW, route tables and a SG removed |
| **Purchase option** | **On-Demand / serverless** (no commitment) | Reserved Instances · Savings Plans | Aurora r6g.large 1-yr RI (no upfront $0.2417/h): 2 × $176 = $353, still above Serverless v2 ($219). Compute Savings Plans would discount Lambda (~$4–17), saving ≈ $2/month | Same | Same | An RI locks the instance size for a year; the load is seasonal (2 exam months), so commitments buy idle capacity |
| **5-year file retention** | **S3 lifecycle**: Standard → IA (30 d) → Glacier IR (180 d) → Deep Archive (365 d) → delete at 5 y | S3 Standard only · Intelligent-Tiering · Deep Archive from day 0 | Year-5 steady state (≈ 7 TB): Standard only **$176**; Intelligent-Tiering (FA/IA/Archive Instant, $0.0025/1,000 objects monitoring) **≈ $42**; lifecycle **≈ $27**; Deep Archive only ≈ $14 | Glacier IR keeps millisecond access for re-marking and appeals. Deep Archive restores take up to 12 h | All 11 nines, multi-AZ | Lifecycle rules are 20 lines of Terraform. Deep Archive from day 0 would block tutors marking within the semester |

## 5. Singapore compared with Mumbai (ap-south-1), including latency from Bhutan

| | **ap-southeast-1 Singapore** | ap-south-1 Mumbai |
|---|---:|---:|
| A3 normal month | $363.57 | $336.36 |
| A3 exam month | $440.83 | $409.33 |
| A3 annual | $4,517.36 | $4,182.26 (−$335, −7.4%) |
| Price differences | ACU $0.20, NAT $0.059, API GW $1.25/M, DTO $0.12/GB | ACU $0.18, NAT $0.056, API GW $1.05/M, DTO $0.1093/GB |
| **Latency from Bhutan** (TCP connect to the regional DynamoDB endpoint, median of 20, from the author's machine on 2026-11-15, `scripts/region-latency.sh`) | **87 ms** (TLS handshake done 177 ms) | **63 ms** (TLS handshake done 125 ms) |
| Hyderabad ap-south-2 / N. Virginia us-east-1 (A2 Region) for reference | 76 ms / 331 ms | |

**What the latency means for this application.** The SPA and static files are served by CloudFront edges in India in both cases, so only the `/api/*` calls go to the Region. CloudFront also keeps connections to the origin open, so a student pays roughly one extra Bhutan → Region round trip per API call: about 25 ms more for Singapore than for Mumbai. An autosave every 30 s is not sensitive to 25 ms, and opening an exam takes 2 calls. The difference is invisible next to the 30 s autosave interval and next to campus Wi-Fi.

**Why Singapore anyway.**
* It is the Region the university asked to be costed.
* It is 4 times closer than the Assignment 2 Region (us-east-1).
* It has 3 AZs and every service used here, including Aurora Serverless v2, the Data API and SES.

**Mumbai would save about $335 per year and about 25 ms per call.** Moving later is a single change of `region`/`azs` in `prod.tfvars`. The Mumbai estimates are in `evidence/calculator/estimate-ap-south-1-*.csv`.

## 6. Optimizations and their savings (Singapore)

| # | Change (change-log ID) | A2 → A3 | Saving per month | Saving per year |
|---|---|---|---:|---:|
| O1 | Aurora 2 × db.r6g.large → **Serverless v2** 0.5–16 ACU, reader in promotion tier 2 (C1) | $456.98 → $219.00 (normal), $237.00 (exam) | $237.98 / $219.98 | **$2,819.76** |
| O2 | **Lambdas out of the VPC, NAT gateways removed** (C3) | $87.91 → $0 | $87.91 | **$1,054.92** |
| O3 | **Provisioned concurrency sized by the load test**: 300 × whole exam days → 50 × 1 h per exam (C4) | $449.20 → $7.49 per exam month | $441.71 (exam months) | **$883.42** |
| O4 | **DynamoDB out of the daily backup rule**; PITR already covers 35 days (C9) | $46.40 → $6.50 | $39.90 | **$478.80** |
| O5 | X-Ray sampling 5% → 1% (C6) | $7.42 → $4.25 (normal) | $3.17 / $5.17 | $42.04 |
| | Spent on purpose: one more WAF rule (C7), EMF metrics and log lines for load evidence (C6/C8) | | −$12.67 / −$14.28 | −$155.68 |
| | **Net** | **$9,640.68 → $4,517.36 per year** | | **$5,123.32 (−53%)** |

**Not applied yet (recommended next):**
* Serve tutor downloads through CloudFront with signed URLs. S3 → CloudFront transfer is free and CloudFront stays inside its 1 TB free tier: −$18 per month (normal) and −$9 (exam), $198 per year.
* Send API access logs to the Infrequent Access log class, which costs half as much per GB.

## 7. Feasibility verdict

| Question | Target | Evidence | Verdict |
|---|---|---|---|
| **Budget** | ≤ USD 1,000 per month averaged over the year | **$376.45 average** ($363.57 normal, $440.83 exam); even the worst month is 44% of the budget. The A2 design would average $803 but **break $1,000 in exam months ($1,220)** | **Meets, with 62% headroom** |
| **Peak load** | 3,000 students start one exam within 5 min | ~110 req/s, needing ~15 concurrent Lambdas (Little's law at 60–130 ms). Reserved concurrency 200, 50 pre-warmed, API Gateway 2,000 rps / 5,000 burst, DynamoDB on-demand. Load test (scaled 1/15 on Floci): **100% success, p95 257 ms, 0 cold starts** after the fixes, against 37.7% success before (`evidence/terminal/05`, `06`). WAF per-user limit fixed so one exam hall cannot be blocked | **Meets**, after fixes B1/B2 (see README) |
| **RPO 5 min** | lose at most 5 min of work | Autosave every 30 s + browser copy; DynamoDB PITR to the second; Aurora storage replicated synchronously, PITR. **Measured: 0 answers lost in F1 and F4, 0 submissions lost in F2, 0 bytes lost in F3** | **Meets** |
| **RTO 1 h** | service back within 60 min | Aurora failover ~30 s (AWS); measured on Floci: AZ loss served again within 30 s and fully rebuilt in 184 s; marking backlog drained 296 s after the failure; deleted file restored in 28 s; bad release rolled back in 20 s | **Meets** |
| **Loss of one AZ** | survive | Nothing zonal in the request path except the Aurora writer, which has a reader in the other AZ (diagram S1–S3) | **Meets** |
| **5-year retention** | keep files 5 years | S3 lifecycle to Deep Archive, delete at 5 y + 30 d; AWS Backup monthly copies of Aurora and DynamoDB kept 5 years | **Meets**; storage cost grows to ~$27/month by year 5 |

**Overall: feasible.** The revised design costs about **$4,500 a year (USD 0.56 per student)**, survives the loss of an AZ, and meets RPO 5 min and RTO 1 h with large margins. The main risks are operational, not financial:
* the exam window must be opened before each exam;
* nobody deploys during an exam;
* the WAF and Lambda concurrency limits must stay sized for one shared campus IP.
