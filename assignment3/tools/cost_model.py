#!/usr/bin/env python3
"""Monthly cost model for the exam platform.

    python3 tools/cost_model.py            -> prints the tables, writes evidence/calculator/*.csv + summary.json

Unit prices come from evidence/pricing/prices-<region>.json (AWS Price List API, the data behind
the AWS Pricing Calculator). Every quantity below is an explicit assumption so the numbers can be
typed into the calculator line by line (see evidence/calculator/README.md).

Designs:   "a2"  = Assignment 2 architecture moved to the Region unchanged
           "opt" = Assignment 3 revised, cost-optimized architecture
Profiles:  "normal" (10 months/yr, 300-500 concurrent users) and "exam" (2 months/yr, 3,000-student peaks)
"""
import csv, json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "evidence" / "calculator"
HOURS = 730  # hours per month used by the AWS Pricing Calculator

# ----------------------------------------------------------------------------------------------
# Workload assumptions (one place, referenced by the report)
# ----------------------------------------------------------------------------------------------
STUDENTS, STAFF = 8000, 400
A = {
    # normal month: 400 concurrent users (mid of 300-500) x 1 API call / 20 s x 10 h/day x 22 days
    "normal_api_req": 400 * (1 / 20) * 3600 * 10 * 22,              # 15.84 M
    # exam month: the same baseline + 8,000 students x 5 exams = 40,000 sittings of 2 h
    "sittings": 40_000,
    "req_per_sitting": 250,                                           # 240 autosaves (every 30 s) + open/start/submit/views
    "autosave_per_sitting": 240,
    "exam_sessions": 20,                                              # exam starts per exam month (morning + afternoon, 10 days)
    # request mix outside exams
    "share_autosave": 0.30, "share_db": 0.40,                        # 30% DynamoDB writes, 40% hit Aurora
    "sql_per_db_req": 1.5,                                            # Data API calls per Aurora request
    "sql_per_sitting": {"a2": 6, "opt": 4.1},                         # open 2(0.1 cached) + start 1 + submit 1 + marking 2
    "lambda_ms": 60, "lambda_gb": 0.5,                                # api: 512 MB arm64, 60 ms average
    "wru_per_save": 1.5, "rru_per_save": 0.5,                         # 1-2 answers per save; #meta check is an eventually consistent read
    # Aurora
    "aurora_storage_gb": 20, "aurora_io_normal": 20e6, "aurora_io_exam": 30e6, "aurora_backup_extra_gb": 10,
    "acu_normal": {"writer": 1.0, "reader": 0.5},                     # average ACUs outside exams
    "acu_exam_window_h": 30, "acu_exam_window": 4,                    # 20 exams x 1.5 h at min 4 ACU
    # provisioned concurrency (api, 512 MB)
    "pc": {"a2": (300, 200), "opt": (50, 20)},                        # (instances, hours per exam month)
    # DynamoDB
    "ddb_table_gb": 10,                                               # year-1 average size of attempts + submissions
    # files: 8,000 students x 2 uploads x 8 MB in a normal month, 1 upload in an exam month
    "uploads": {"normal": 16_000, "exam": 8_000}, "upload_mb": 8,
    "downloads_per_upload": 1.2,                                      # tutors download each file ~1.2 times
    # S3 storage at the end of year 1 (month 12) under the lifecycle: 1 month Standard, 5 IA, 6 Glacier IR
    "s3_months": {"std": 1, "sia": 5, "gir": 6, "gda": 0},
    # SPA and API through CloudFront
    "sessions_per_user": 20, "spa_mb": 1.5, "static_req_per_session": 10, "api_resp_kb": 3,
    # logs
    "lambda_log_bytes": 350, "api_access_log_bytes": 250, "emf_bytes": 450,
    "log_retention_months": {"a2": 3, "opt": 1},
    "xray_rate": {"a2": 0.05, "opt": 0.01},
    "emf_metrics": 24,                                                # 3 metrics x 8 routes
    "emails": {"normal": 24_000, "exam": 48_000},
    "kms_req": {"normal": 300_000, "exam": 600_000},
    "nat_gb": 30,
    "sqs_req": {"normal": 2.1e6, "exam": 2.6e6},                      # messages x3 + Lambda long-poll receives
    "alarms": {"a2": 8, "opt": 9},
}

FREE = {"lambda_req": 1e6, "lambda_gbs": 400_000, "sqs": 1e6, "cf_gb": 1024, "cf_req": 10e6,
        "ddb_gb": 25, "xray": 100_000, "alarms": 10}


def prices(region):
    p = json.loads((ROOT / "evidence" / "pricing" / f"prices-{region}.json").read_text())
    return {k: v["price"] for k, v in p["prices"].items()}, p["published"]


def month(design, profile, region):
    P, _ = prices(region)
    exam = profile == "exam"
    api = A["normal_api_req"] + (A["sittings"] * A["req_per_sitting"] if exam else 0)
    saves = A["normal_api_req"] * A["share_autosave"] + (A["sittings"] * A["autosave_per_sitting"] if exam else 0)
    sql = A["normal_api_req"] * A["share_db"] * A["sql_per_db_req"] + (A["sittings"] * A["sql_per_sitting"][design] if exam else 0)
    users = STUDENTS + STAFF
    static_req = users * A["sessions_per_user"] * A["static_req_per_session"]
    cf_req = api + static_req
    cf_gb = users * A["sessions_per_user"] * A["spa_mb"] / 1024 + api * A["api_resp_kb"] / 1024 / 1024
    uploads = A["uploads"][profile]
    dl_gb = uploads * A["downloads_per_upload"] * A["upload_mb"] / 1024
    items = []

    def add(service, desc, cost, config):
        items.append({"service": service, "description": desc, "monthly": round(cost, 2), "config": config})

    # --- Aurora
    if design == "a2":
        add("Amazon Aurora PostgreSQL", "2 x db.r6g.large On-Demand (writer AZ-a, reader AZ-b)", 2 * HOURS * P["aurora_r6g_large_hr"],
            f"2 instances x {HOURS} h x ${P['aurora_r6g_large_hr']}/h")
    else:
        acu_h = (A["acu_normal"]["writer"] * HOURS + A["acu_normal"]["reader"] * HOURS)
        if exam:
            acu_h += A["acu_exam_window_h"] * (A["acu_exam_window"] - A["acu_normal"]["writer"])
        add("Amazon Aurora PostgreSQL", "Serverless v2, writer + reader (0.5-16 ACU)", acu_h * P["aurora_acu_hr"],
            f"{acu_h:,.0f} ACU-h x ${P['aurora_acu_hr']}")
    io = A["aurora_io_exam"] if exam else A["aurora_io_normal"]
    add("Amazon Aurora PostgreSQL", "storage, I/O and backup beyond the free allowance",
        A["aurora_storage_gb"] * P["aurora_storage_gb"] + io * P["aurora_io_per_req"] + A["aurora_backup_extra_gb"] * P["aurora_backup_gb"],
        f"{A['aurora_storage_gb']} GB, {io/1e6:.0f} M I/O, {A['aurora_backup_extra_gb']} GB backup")
    add("RDS Data API", "Data API requests (hidden cost)", sql * P["rds_data_api_per_req"], f"{sql/1e6:.2f} M requests")

    # --- Lambda
    gbs = api * A["lambda_ms"] / 1000 * A["lambda_gb"]
    add("AWS Lambda", "api + marker + notifier requests and duration (arm64)",
        max(0, api - FREE["lambda_req"]) * P["lambda_request"] + max(0, gbs - FREE["lambda_gbs"]) * P["lambda_gb_s_arm"],
        f"{api/1e6:.2f} M requests, {gbs:,.0f} GB-s (free tier applied)")
    if exam:
        n, h = A["pc"][design]
        add("AWS Lambda", "provisioned concurrency during exam windows", n * A["lambda_gb"] * 3600 * h * P["lambda_pc_arm"],
            f"{n} x 0.5 GB x {h} h")

    # --- edge / API
    add("Amazon API Gateway", "HTTP API requests", api * P["apigw_http_per_req"], f"{api/1e6:.2f} M requests")
    rules = 3 if design == "a2" else 4
    add("AWS WAF", "web ACL, rules, requests", P["waf_acl_month"] + rules * P["waf_rule_month"] + cf_req * P["waf_per_req"],
        f"1 ACL, {rules} rules, {cf_req/1e6:.2f} M requests")
    add("Amazon CloudFront", "HTTPS requests (India edge) beyond free tier",
        max(0, cf_req - FREE["cf_req"]) * P["cf_india_https_per_req"] + max(0, cf_gb - FREE["cf_gb"]) * P["cf_india_gb"],
        f"{cf_req/1e6:.2f} M requests, {cf_gb:,.0f} GB out (1 TB free)")
    add("Amazon Route 53", "hosted zone (alias queries are free)", P["route53_zone_month"], "1 zone")
    add("Amazon Cognito", "8,400 MAU (Essentials free tier 10,000)", 0, f"{users} MAU")

    # --- DynamoDB
    wru = saves * A["wru_per_save"]; rru = saves * A["rru_per_save"] + A["normal_api_req"] * 0.3 * 0.5
    add("Amazon DynamoDB", "on-demand writes/reads, PITR", wru * P["ddb_wru"] + rru * P["ddb_rru"] +
        max(0, A["ddb_table_gb"] - FREE["ddb_gb"]) * P["ddb_storage_gb"] + A["ddb_table_gb"] * P["ddb_pitr_gb"],
        f"{wru/1e6:.1f} M WRU, {rru/1e6:.1f} M RRU, {A['ddb_table_gb']} GB + PITR")

    # --- backups (AWS Backup): daily 35 d + monthly 5 y; Assignment 3 drops DynamoDB from the daily rule
    monthly_backups = A["ddb_table_gb"] * (3 * P["backup_ddb_warm_gb"] + 9 * P["backup_ddb_cold_gb"])  # year-1 month 12
    daily = 35 * A["ddb_table_gb"] * P["backup_ddb_warm_gb"] if design == "a2" else 0
    add("AWS Backup", "DynamoDB backups (hidden cost)" + (" - daily x35 + monthly" if design == "a2" else " - monthly only, PITR covers 35 days"),
        daily + monthly_backups, f"{A['ddb_table_gb']} GB table")

    # --- S3
    up_gb = uploads * A["upload_mb"] / 1024
    m = A["s3_months"]; base = A["uploads"]["normal"] * A["upload_mb"] / 1024
    store = base * (m["std"] * P["s3_std_gb"] + m["sia"] * P["s3_sia_gb"] + m["gir"] * P["s3_gir_gb"] + m["gda"] * P["s3_gda_gb"])
    reqs = uploads * P["s3_put_per_req"] + uploads * A["downloads_per_upload"] * P["s3_get_per_req"]
    transitions = A["uploads"]["normal"] * (P["s3_sia_put_per_req"] + P["s3_gir_put_per_req"] + P["s3_gda_transition_per_req"])
    add("Amazon S3", "submissions (lifecycle Std->IA->Glacier IR->Deep Archive), frontend, logs",
        store + reqs + transitions + 0.5, f"{up_gb:,.0f} GB new; {base*12:,.0f} GB stored at month 12")
    add("Data transfer out", "tutor downloads straight from S3 (hidden cost)", dl_gb * P["dto_internet_gb"], f"{dl_gb:,.0f} GB")

    # --- networking
    if design == "a2":
        add("NAT gateway", "2 NAT gateways (one per AZ) + processing (hidden cost)",
            2 * HOURS * P["nat_hour"] + A["nat_gb"] * P["nat_gb"], f"2 x {HOURS} h + {A['nat_gb']} GB")

    # --- observability
    per_req = A["lambda_log_bytes"] + A["api_access_log_bytes"] + (A["emf_bytes"] if design == "opt" else 0)
    log_gb = api * per_req / 1024 ** 3
    add("Amazon CloudWatch", "Logs ingestion + storage (hidden cost)",
        log_gb * P["cw_logs_ingest_gb"] + log_gb * A["log_retention_months"][design] * P["cw_logs_storage_gb"],
        f"{log_gb:.1f} GB/month, {A['log_retention_months'][design]*30} days")
    add("Amazon CloudWatch", "alarms, dashboard, EMF metrics",
        max(0, A["alarms"][design] - FREE["alarms"]) * P["cw_alarm_month"] + 3 +
        (A["emf_metrics"] * P["cw_metric_month"] if design == "opt" else 0),
        f"{A['alarms'][design]} alarms, 1 dashboard" + (f", {A['emf_metrics']} EMF metrics" if design == "opt" else ""))
    traces = HOURS * 0 + 220 * 3600 * 1 + api * A["xray_rate"][design]
    add("AWS X-Ray", "traces (1/s reservoir + sampling rate)", max(0, traces - FREE["xray"]) * P["xray_trace"],
        f"{traces/1e6:.2f} M traces at {A['xray_rate'][design]:.0%}")

    # --- messaging / security
    add("Amazon SQS", "marking, notify, uploads queues", max(0, A["sqs_req"][profile] - FREE["sqs"]) * P["sqs_per_req"],
        f"{A['sqs_req'][profile]/1e6:.1f} M requests")
    add("Amazon SES", "result and submission emails", A["emails"][profile] * P["ses_per_email"], f"{A['emails'][profile]:,} emails")
    add("AWS KMS", "1 customer key + requests (hidden cost)", 1 + A["kms_req"][profile] * P["kms_per_req"],
        f"1 key, {A['kms_req'][profile]:,} requests")
    add("AWS Secrets Manager", "database secret", P["secret_month"], "1 secret")
    return items


def total(items):
    return round(sum(i["monthly"] for i in items), 2)


def write_csv(path, items, region, design, profile, published):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Estimate", f"exam platform - {design} - {profile} month", "Region", region, "Prices", f"AWS Price List API, published {published}"])
        w.writerow(["Service", "Description", "Region", "Monthly (USD)", "12 months (USD)", "Configuration summary"])
        for i in items:
            w.writerow([i["service"], i["description"], region, f"{i['monthly']:.2f}", f"{i['monthly']*12:.2f}", i["config"]])
        w.writerow(["TOTAL", "", region, f"{total(items):.2f}", f"{total(items)*12:.2f}", ""])


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    summary = {}
    for region in ("ap-southeast-1", "ap-south-1"):
        _, published = prices(region)
        for design in ("a2", "opt"):
            for profile in ("normal", "exam"):
                items = month(design, profile, region)
                summary[f"{region}/{design}/{profile}"] = {"total": total(items), "items": items}
                write_csv(OUT / f"estimate-{region}-{design}-{profile}.csv", items, region, design, profile, published)
    for region in ("ap-southeast-1", "ap-south-1"):
        for design in ("a2", "opt"):
            n = summary[f"{region}/{design}/normal"]["total"]; e = summary[f"{region}/{design}/exam"]["total"]
            year = 10 * n + 2 * e
            summary[f"{region}/{design}/year"] = {"normal": n, "exam": e, "annual": round(year, 2), "avg_month": round(year / 12, 2),
                                                  "per_student_year": round(year / STUDENTS, 2),
                                                  "per_sitting": round(year / (2 * A["sittings"]), 3)}
    (OUT / "summary.json").write_text(json.dumps({"assumptions": A, "results": summary}, indent=1, default=str))

    # console report
    sg = "ap-southeast-1"
    print(f"Prices: AWS Price List API, published {prices(sg)[1]}  (checked {__import__('datetime').date.today()})\n")
    print(f"{'Service':28} {'Description':62} {'A2 normal':>10} {'A2 exam':>10} {'A3 normal':>10} {'A3 exam':>10}")
    keys = []
    for d in ("a2", "opt"):
        for i in summary[f"{sg}/{d}/exam"]["items"]:
            k = (i["service"], i["description"])
            if k not in keys:
                keys.append(k)
    def val(d, p, k):
        return next((i["monthly"] for i in summary[f"{sg}/{d}/{p}"]["items"] if (i["service"], i["description"]) == k), None)
    for k in keys:
        cells = [val(d, p, k) for d in ("a2", "opt") for p in ("normal", "exam")]
        print(f"{k[0][:28]:28} {k[1][:62]:62} " + " ".join(f"{c:10.2f}" if c is not None else f"{'-':>10}" for c in cells))
    print(f"{'TOTAL per month':91} " + " ".join(f"{summary[f'{sg}/{d}/{p}']['total']:10.2f}" for d in ("a2", "opt") for p in ("normal", "exam")))
    print()
    for region in ("ap-southeast-1", "ap-south-1"):
        for d, name in (("a2", "Assignment 2 design"), ("opt", "Assignment 3 design")):
            y = summary[f"{region}/{d}/year"]
            print(f"{region:15} {name}: normal ${y['normal']:,.2f}  exam ${y['exam']:,.2f}  annual ${y['annual']:,.2f}  "
                  f"avg/month ${y['avg_month']:,.2f}  per student/yr ${y['per_student_year']:.2f}  per exam sitting ${y['per_sitting']:.3f}")


if __name__ == "__main__":
    main()
