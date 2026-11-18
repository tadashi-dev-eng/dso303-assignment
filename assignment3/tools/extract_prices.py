#!/usr/bin/env python3
"""Pull the unit prices the cost model needs out of the AWS Price List API CSV files.

    python3 tools/extract_prices.py <dir-with-csvs>  ->  evidence/pricing/prices-<region>.json

The CSVs come from https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/<Offer>/current/<region>/index.csv
(the same price data the AWS Pricing Calculator uses). Every price is stored with its usageType
and description so it can be checked against the calculator.
"""
import csv, json, sys
from pathlib import Path

SRC = Path(sys.argv[1])
OUT = Path(__file__).resolve().parent.parent / "evidence" / "pricing"
REGIONS = {"ap-southeast-1": "APS1", "ap-south-1": "APS3"}

# key: (offer file, usageType suffix after "<P>-", optional text that must appear, StartingRange or None)
WANT = {
    "lambda_request": ("AWSLambda", "Request-ARM", None, None),
    "lambda_gb_s_arm": ("AWSLambda", "Lambda-GB-Second-ARM", None, "0"),
    "lambda_pc_arm": ("AWSLambda", "Lambda-Provisioned-Concurrency-ARM", None, None),
    "lambda_pc_gb_s_arm": ("AWSLambda", "Lambda-Provisioned-GB-Second-ARM", None, None),
    "apigw_http_per_req": ("AmazonApiGateway", "ApiGatewayHttpRequest", None, "0"),
    "ddb_wru": ("AmazonDynamoDB", "WriteRequestUnits", None, None),
    "ddb_rru": ("AmazonDynamoDB", "ReadRequestUnits", None, None),
    "ddb_storage_gb": ("AmazonDynamoDB", "TimedStorage-ByteHrs", None, "25"),
    "ddb_pitr_gb": ("AmazonDynamoDB", "TimedPITRStorage-ByteHrs", None, None),
    "aurora_r6g_large_hr": ("AmazonRDS", "InstanceUsage:db.r6g.large", "Aurora PostgreSQL", None),
    "aurora_acu_hr": ("AmazonRDS", "Aurora:ServerlessV2Usage", "PostgreSQL", None),
    "aurora_storage_gb": ("AmazonRDS", "Aurora:StorageUsage", "PostgreSQL", None),
    "aurora_io_per_req": ("AmazonRDS", "Aurora:StorageIOUsage", "PostgreSQL", None),
    "aurora_backup_gb": ("AmazonRDS", "Aurora:BackupUsage", "PostgreSQL", None),
    "rds_data_api_per_req": ("AmazonRDS", "RDS:Data-API-Usage", "per Data API request up to", None),
    "s3_std_gb": ("AmazonS3", "TimedStorage-ByteHrs", None, "0"),
    "s3_sia_gb": ("AmazonS3", "TimedStorage-SIA-ByteHrs", None, None),
    "s3_gir_gb": ("AmazonS3", "TimedStorage-GIR-ByteHrs", None, None),
    "s3_int_monitor_per_obj": ("AmazonS3", "Monitoring-Automation-INT", None, None),
    "s3_put_per_req": ("AmazonS3", "Requests-Tier1", None, None),
    "s3_get_per_req": ("AmazonS3", "Requests-Tier2", None, None),
    "s3_sia_put_per_req": ("AmazonS3", "Requests-SIA-Tier1", None, None),
    "s3_gir_put_per_req": ("AmazonS3", "Requests-GIR-Tier1", None, None),
    "s3_gda_gb": ("AmazonS3GlacierDeepArchive", "TimedStorage-GDA-ByteHrs", None, None),
    "s3_gda_transition_per_req": ("AmazonS3GlacierDeepArchive", "Requests-Tier3", "Lifecycle", None),
    "dto_internet_gb": ("AWSDataTransfer", "DataTransfer-Out-Bytes", None, "0"),
    "waf_acl_month": ("awswaf", "WebACLV2", None, None),
    "waf_rule_month": ("awswaf", "RuleV2", None, None),
    "waf_per_req": ("awswaf", "RequestV2-Tier1", None, None),
    "cw_logs_ingest_gb": ("AmazonCloudWatch", "DataProcessing-Bytes", None, None),
    "cw_vended_logs_gb": ("AmazonCloudWatch", "VendedLog-Bytes", None, "0"),
    "cw_logs_storage_gb": ("AmazonCloudWatch", "TimedStorage-ByteHrs", None, None),
    "cw_alarm_month": ("AmazonCloudWatch", "CW:AlarmMonitorUsage", None, None),
    "cw_metric_month": ("AmazonCloudWatch", "CW:MetricMonitorUsage", None, "0"),
    "sqs_per_req": ("AWSQueueService", "Requests-Tier1", None, "0"),
    "ses_per_email": ("AmazonSES", "Recipients", None, None),
    "secret_month": ("AWSSecretsManager", "AWSSecretsManager-Secret", None, None),
    "secrets_api_per_req": ("AWSSecretsManager", "AWSSecretsManagerAPIRequest", None, None),
    "kms_per_req": ("awskms", "={region}-KMS-Requests", None, None),  # KMS uses the Region code as prefix
    "vpce_hour": ("AmazonVPC", "VpcEndpoint-Hours", None, None),
    "vpce_gb": ("AmazonVPC", "VpcEndpoint-Bytes", None, "0"),
    "nat_hour": ("AmazonEC2-nat", "NatGateway-Hours", None, None),
    "nat_gb": ("AmazonEC2-nat", "NatGateway-Bytes", None, None),
    "backup_ddb_warm_gb": ("AWSBackup", "WarmStorage-ByteHrs-DynamoDB", None, None),
    "backup_ddb_cold_gb": ("AWSBackup", "ColdStorage-ByteHrs-DynamoDB", None, None),
    "xray_trace": ("AWSXRay", "XRay-TracesStored", None, None),
}
GLOBAL = {  # global offers (not per Region)
    "cf_india_gb": ("AmazonCloudFront", "IN-DataTransfer-Out-Bytes", "0"),
    "cf_india_https_per_req": ("AmazonCloudFront", "IN-Requests-Tier2-HTTPS", None),
    "route53_zone_month": ("AmazonRoute53", "HostedZone", "0"),
}


def rows(path):
    with open(path, encoding="utf-8") as f:
        r = list(csv.reader(f))
    pub = next((x[1] for x in r[:5] if x and x[0] == "Publication Date"), "")
    hdr = r[5]
    return pub, [dict(zip(hdr, x)) for x in r[6:] if len(x) == len(hdr) and x[hdr.index("TermType")] == "OnDemand"]


cache = {}
def load(name):
    if name not in cache:
        cache[name] = rows(SRC / name)
    return cache[name]


def find(file, usage, must, start):
    pub, rs = load(file)
    for x in rs:
        # Regions sometimes spell a usage type with a trailing "s" (Secret / Secrets).
        if x["usageType"] in (usage, usage + "s") and (must is None or must in x["PriceDescription"]) and (start is None or x["StartingRange"] == start):
            return {"price": float(x["PricePerUnit"]), "unit": x["Unit"], "usageType": usage,
                    "description": x["PriceDescription"].strip(), "published": pub}
    raise SystemExit(f"not found: {file} {usage} {must}")


for region, p in REGIONS.items():
    out = {"region": region, "source": "AWS Price List API (same data as the AWS Pricing Calculator)", "prices": {}}
    for k, (offer, suffix, must, start) in WANT.items():
        usage = suffix[1:].format(region=region) if suffix.startswith("=") else f"{p}-{suffix}"
        out["prices"][k] = find(f"{offer}.{region}.csv", usage, must, start)
    for k, (offer, usage, start) in GLOBAL.items():
        out["prices"][k] = find(f"{offer}.csv", usage, None, start)
    out["published"] = out["prices"]["lambda_request"]["published"]
    (OUT / f"prices-{region}.json").write_text(json.dumps(out, indent=2))
    print(f"{region}: {len(out['prices'])} prices, price list published {out['published']}")
