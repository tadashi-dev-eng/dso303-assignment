# My notes – DSO303 Assignment 3

Personal study notes. This file is outside `assignment3/` on purpose, so it is not part of the submission.

## 1. What the assignment is about

Assignment 2 designed and deployed an online exams platform:
* Cognito sign-in;
* timed exams with autosave every 30 s into DynamoDB;
* MCQ auto-marking through SQS → Lambda → Aurora;
* 50 MB uploads straight to S3;
* SES emails.

Assignment 3 asks a business question about that design: **what will it cost to run in Singapore (ap-southeast-1), can the university afford it, and where will it break or slow down?**

The inputs are fixed:
* **Load:** 10 normal months with 300–500 concurrent users, and 2 exam months where 3,000 students start one exam within 5 minutes.
* **Budget:** USD 1,000 per month, averaged over the year.
* **Targets** (same as A2): RPO 5 min (lose at most 5 min of work), RTO 1 h (back within an hour), survive losing one Availability Zone, keep files 5 years.
* **Prices:** from the AWS Pricing Calculator in USD, with the date checked.

## 2. What I am supposed to do (tasks and deliverables)

| Task | What is required | Where I put it |
|---|---|---|
| **Task 1 – Revised architecture** | Final cost-optimized diagram; mark every single point of failure and whether it is removed or accepted; change log against A2 | `architecture/diagram.png` (+ `.svg`, `make_diagram.py`), `architecture/change-log.md` |
| **Task 2 – Cost and service report** | (1) monthly cost per service for a normal and an exam month, annual total, cost per student, hidden costs (data transfer out, NAT processing, CloudWatch Logs, KMS requests, backups); (2) top-3 most expensive and why; (3) ≥ 4 service choices vs an alternative (cost, performance, resilience, effort); (4) Singapore vs one other Region incl. latency from Bhutan; (5) feasibility verdict on budget, peak, RPO, RTO | `docs/cost-report.md` |
| **Task 3 – Costed estimate** | Both load profiles in the AWS Pricing Calculator, then ≥ 3 optimizations with the saving of each | `tools/cost_model.py`, `evidence/calculator/`, `evidence/pricing/`, cost report §6 |
| **Task 3 – Failure tests** | ≥ 3 scenarios (rubric: 4) with expected impact, measured against RPO/RTO, with fixes | `infra/failure-tests/` (scripts + README) |
| **Task 3 – Load test** (rubric) | Prove a bottleneck with CloudWatch, fix it, re-test; reason about two more | `scripts/load-test.sh/.mjs`, README "Load test and bottlenecks" |
| Deliverables | README (summary, verdict, calculator links, ≤ 5-min demo video link in my own voice showing one failure test + the load test) | `README.md`, plus `REPORT.md/.html/.pdf` |

Rubric (10 marks): architecture 2, service documentation 2, costed estimate 2, failure tests 2, load test 2. The tutor may ask me to explain or re-run things in a viva.

## 3. How it was done

### Step 1 – Start from Assignment 2

I copied the A2 code (Terraform, Lambda code, scripts) into `assignment3/` without its report and evidence. Then I moved everything to **ap-southeast-1**:
* `region`, `azs`, the CI workflow, the state backend and the scripts all point at Singapore now.
* CloudFront's WAF and ACM certificate **must** stay in us-east-1. I added a second Terraform provider, `aws.us_east_1`, for them.

### Step 2 – Get real prices

* I had no real AWS account, so I used the **AWS Price List API**. It is the public price data the Pricing Calculator itself uses.
* `tools/extract_prices.py` pulls the 49 unit prices I need for Singapore and Mumbai into `evidence/pricing/*.json`. Each price is saved with its AWS `usageType`.
* Price list published 2026-11-11, checked 2026-11-15.

### Step 3 – Cost model

`tools/cost_model.py` has all workload assumptions in one place:
* normal month = 400 users × 1 call / 20 s × 10 h × 22 days = 15.84 M API calls;
* exam month = that + 40,000 exam sittings × 250 calls.

It prices every service for the **A2 design** and the **revised design**, for both months and both Regions.

Results (Singapore):

| | Normal | Exam | Annual | Avg / month |
|---|---:|---:|---:|---:|
| A2 | $720 | $1,220 | $9,641 | $803 |
| **A3** | **$364** | **$441** | **$4,517** | **$376** |

A3 works out to $0.56 per student per year.

### Step 4 – What I changed and why (the 9 changes, C1–C9)

* **C1 Aurora Serverless v2** instead of 2 always-on db.r6g.large instances. The database was 63% of the bill and idle outside exams. Saves $2,820/yr.
* **C2 Singapore Region**, with WAF and ACM kept in us-east-1.
* **C3 Lambdas taken out of the VPC.** They reach Aurora through the **RDS Data API** over HTTPS, so they never needed the VPC. This removes both **NAT gateways** ($88/month, and a zonal single point of failure).
* **C4 Exam window right-sized.** `exam-window.sh open` gives 50 warm Lambdas for 1 h per exam plus Aurora min 4 ACU. A2 had 300 warm Lambdas for whole exam days ($449 per exam month).
* **C5 Reserved concurrency 600 → 200.** The peak needs only ~15, from Little's law: 110 req/s × ~0.1 s.
* **C6 Observability.** Logs 90 → 30 days, X-Ray 5% → 1%, EMF metrics per route, a Budget alarm at 80% of $1,000.
* **C7 WAF fix.** The per-IP limit of 20,000 per 5 min would have blocked a whole exam hall that shares one campus IP (3,000 × 10 autosaves = 30,000). Now 600 per user + 100,000 per IP.
* **C8 Exam definition cached** for 60 s inside each Lambda, so exam opens don't hammer Aurora.
* **C9 No daily DynamoDB backups.** They were full copies duplicating PITR, a $46/month hidden cost. DynamoDB now gets monthly 5-year copies only.

### Step 5 – Deploy and test on Floci (the AWS emulator)

* **Deployment.** I deployed the revised Terraform to Floci in ap-southeast-1. With your OK, I destroyed only the A2 *emulator deployment* first, because Floci has only 5 database ports. The A2 files are untouched; re-run `assignment2/scripts/deploy.sh` to bring it back.
* **Load test** (`scripts/load-test.sh before|after`):
  * The laptop can't fake 3,000 students, so I ran the same shape at 1/15 of the rate.
  * The driver sends its numbers to CloudWatch.
  * The api Lambda logs one EMF line per request. That showed exam opens spending 15 of 15.06 seconds in SQL, plus 10 cold starts: **bottleneck B1, proven.**
  * Fix: cache (C8) + pre-warm (C4). Result: **37.7% → 100% success, p95 30 s → 257 ms, 0 cold starts.**
  * B2 (WAF) and B3 (Lambda quota / Aurora cold start) are reasoned with numbers.
* **Failure tests** (`infra/failure-tests/f1…f4`). Background "students" autosave during each failure, then I check that nothing was lost:

  | Test | Scenario | Lost | Recovery |
  |---|---|---|---|
  | F1 | AZ loss | 0 | serving in 30 s, rebuilt in 184 s |
  | F2 | Marking worker down | 0 | 296 s |
  | F3 | Deleted file restored from S3 versioning | 0 | 28 s |
  | F4 | Bad release rolled back | 0 | 54 s |

  PITR-restore scenarios (F5–F7) are written up as runbooks because Floci doesn't support them.
* **Latency** from my machine in Bhutan: Mumbai 63 ms, Hyderabad 76 ms, Singapore 87 ms, N. Virginia 331 ms.

### Step 6 – Evidence and report

* Every run was recorded and drawn as terminal screenshots in the same style as A2 (`evidence/terminal/*.png`, raw logs in `evidence/terminal/logs/`).
* The diagram is generated from `architecture/make_diagram.py`.
* `REPORT.pdf` combines everything (20 pages).

## 4. What I still have to do myself

1. **AWS Pricing Calculator links.**
   * Enter the values from `evidence/calculator/README.md` at calculator.aws, region Asia Pacific (Singapore), once for the normal month and once for the exam month.
   * Totals should be close to $363.57 and $440.83.
   * Share each estimate, paste the 2 links into `README.md`, and export CSVs into `evidence/calculator/`.
2. **Demo video (≤ 5 min, my own voice).** Suggested flow:
   * diagram + verdict (30 s);
   * `./scripts/load-test.sh before`, then `after`, explaining the EMF table (2 min);
   * `./infra/failure-tests/f1-az-loss.sh`, explaining RPO/RTO (2 min);
   * wrap-up (30 s).
   * Upload it and put the link in `README.md`.
3. Fill in my name and student ID at the top of `REPORT.md`, then rebuild or print the PDF.
4. Commit and push it myself. Nothing was committed, and no co-author lines were added.

## 5. Viva cheat-sheet

* **Why no NAT?** The Data API is HTTPS and IAM-authenticated, and every other service has a public regional endpoint. Nothing needs private routing, so a NAT would only add cost ($88/month) and a zonal failure point.
* **Why keep an Aurora reader at all?** Without it, losing AZ-a means Aurora must create a new instance (~10 min). The reader costs ~$73/month and makes failover ~30 s.
* **Why not RIs?** The load is seasonal. A 1-yr RI on 2 × r6g.large ($353/month) is still more than Serverless v2 ($219).
* **Why Singapore if Mumbai is cheaper and closer?** The university asked for Singapore. The gap is $335/yr and ~25 ms per call, which a 30 s autosave never notices. It's a one-line change if they decide otherwise.
* **Hidden costs:** data transfer out, NAT processing, CloudWatch Logs, KMS requests, backups (full DynamoDB copies!), Data API calls.
