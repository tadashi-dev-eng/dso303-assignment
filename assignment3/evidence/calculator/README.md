# Costed estimate – calculator evidence

## What is in this folder

| File | Content |
|---|---|
| `estimate-ap-southeast-1-opt-normal.csv` | **Revised design, normal month, Singapore**: one row per service, monthly and 12-month cost, configuration |
| `estimate-ap-southeast-1-opt-exam.csv` | **Revised design, exam month, Singapore** |
| `estimate-ap-southeast-1-a2-*.csv` | Assignment 2 design in Singapore (baseline for the optimizations) |
| `estimate-ap-south-1-*.csv` | The same four estimates for Mumbai (Region comparison) |
| `summary.json` | All assumptions and every line item, as produced by `tools/cost_model.py` |
| `../pricing/prices-*.json` | The unit prices used, with AWS `usageType` and description, Price List published 2026-11-11T22:30:04Z |

The CSVs use the layout of the AWS Pricing Calculator export (Service, Description, Region, Monthly, 12 months, Configuration summary). They were generated from the AWS Price List API, which is the calculator's price source.

## AWS Pricing Calculator links

| Estimate | Link | Expected monthly total |
|---|---|---:|
| Revised design – normal month (ap-southeast-1) | _add share link_ | $363.57 |
| Revised design – exam month (ap-southeast-1) | _add share link_ | $440.83 |

To create them: open <https://calculator.aws/#/estimate>, choose **Asia Pacific (Singapore)** for every service, enter the values below, then **Share → Agree and continue → Copy public link** and **Export → CSV**. Save the exported CSVs here as `calculator-normal.csv` and `calculator-exam.csv`. Small differences from the model (cents) come from calculator rounding and free-tier handling.

| Calculator service | Normal month | Exam month |
|---|---|---|
| Amazon Aurora PostgreSQL-Compatible → Aurora Serverless v2 | 1.5 ACU average × 730 h (1,095 ACU-h); storage 20 GB; I/O 20 M; backup 10 GB | 1,185 ACU-h (1.5 ACU + 30 h at 4 ACU); I/O 30 M |
| (add as "Amazon RDS Data API" note / custom) | 9.50 M requests × $0.42/M | 9.74 M |
| AWS Lambda (arm64, 512 MB, 60 ms, include free tier) | 15.84 M requests | 25.84 M requests + provisioned concurrency 50 × 20 h |
| Amazon API Gateway → HTTP API | 15.84 M requests | 25.84 M |
| AWS WAF | 1 web ACL, 4 rules, 17.52 M requests | 27.52 M requests |
| Amazon CloudFront (India) | 17.52 M HTTPS requests, 291 GB out | 27.52 M requests, 320 GB out |
| Amazon DynamoDB on-demand | 7.13 M WRU, 4.75 M RRU, 10 GB, PITR 10 GB | 21.53 M WRU, 9.55 M RRU |
| AWS Backup (DynamoDB) | monthly backups: 30 GB warm, 90 GB cold | same |
| Amazon S3 Standard / Standard-IA / Glacier IR | 125 GB / 625 GB / 750 GB; 16,000 PUT; 19,200 GET; lifecycle transitions 16,000 each | 8,000 PUT, 9,600 GET |
| Data transfer out (S3 → Internet) | 150 GB | 75 GB |
| Amazon CloudWatch | 15.5 GB logs ingested, 30 days; 9 alarms; 1 dashboard; 24 custom metrics | 25.3 GB logs |
| AWS X-Ray | 0.95 M traces recorded | 1.05 M |
| Amazon SQS standard | 2.1 M requests | 2.6 M |
| Amazon SES | 24,000 emails | 48,000 |
| AWS KMS | 1 key, 0.3 M requests | 0.6 M |
| AWS Secrets Manager · Route 53 · Cognito | 1 secret · 1 hosted zone · 8,400 MAU | same |
