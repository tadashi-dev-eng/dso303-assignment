#!/usr/bin/env python3
"""Generates the Cloud Architecture Lab (AWS Architecture Lab) reference file for the
online exams platform: lab/exam-platform.reference.json.

Import it in the lab with  Reference Diagrams -> Import  (or drop it into the simulator's
src/data/references/ folder). Coordinates follow the lab's centre-point containment rule:
every service sits inside the subnet/AZ box it is deployed to.
"""
import json
from pathlib import Path

OUT = Path(__file__).with_name("exam-platform.reference.json")

nodes, edges = [], []


def box(id_, kind, label, x, y, w, h, z, **extra):
    data = {"label": label, "boundaryType": kind, "width": w, "height": h, **extra}
    nodes.append({"id": id_, "type": "boundaryNode", "position": {"x": x, "y": y}, "data": data,
                  "style": {"width": w, "height": h}, "draggable": True, "selectable": True, "zIndex": z})


def svc(id_, service, label, category, x, y, az, subnet, replicas=1, multi=False, notes=None, **extra):
    data = {"serviceId": service, "label": label, "category": category, "health": "healthy",
            "az": az, "subnet": subnet, "replicas": replicas, "multiAz": multi, **extra}
    if notes:
        data["notes"] = notes
    nodes.append({"id": id_, "type": "serviceNode", "position": {"x": x, "y": y}, "data": data})


def edge(src, dst, protocol, step=None, label=None, kind="synchronous", critical=True, timeout=2000, **extra):
    data = {"protocol": protocol, "interactionType": kind, "isCriticalDependency": critical, "timeoutMs": timeout, **extra}
    if step is not None:
        data["stepNumber"] = step
    if label:
        data["label"] = label
    edges.append({"id": f"e-{src}-{dst}", "source": src, "target": dst, "type": "custom", "data": data})


EDGE = "Edge / Global"
ACCT = "000000000000"
ARN = {
    "attempts": f"arn:aws:dynamodb:us-east-1:{ACCT}:table/exams-prod-attempts",
    "submissions": f"arn:aws:dynamodb:us-east-1:{ACCT}:table/exams-prod-submissions",
    "subs_bucket": "arn:aws:s3:::exams-prod-submissions/submissions/*",
    "marking": f"arn:aws:sqs:us-east-1:{ACCT}:exams-prod-marking",
    "uploads": f"arn:aws:sqs:us-east-1:{ACCT}:exams-prod-uploads",
    "notify": f"arn:aws:sqs:us-east-1:{ACCT}:exams-prod-notify",
    "secret": f"arn:aws:secretsmanager:us-east-1:{ACCT}:secret:exams-prod/db/master",
    "kms": f"arn:aws:kms:us-east-1:{ACCT}:key/exams-prod-data",
}


def role(name, *statements):
    """Execution role mirroring infra/compute.tf. The lab identifies the Lambda service as 'lambda'."""
    return {"id": f"exams-prod-{name}-role",
            "trustPolicy": {"id": "trust", "kind": "trust", "statements": [
                {"effect": "Allow", "principals": ["lambda.amazonaws.com", "lambda"], "actions": ["sts:AssumeRole"], "resources": ["*"]}]},
            "identityPolicies": [{"id": f"exams-prod-{name}-policy", "kind": "identity", "statements": [
                {"effect": "Allow", "actions": a, "resources": r} for a, r in statements]}]}


COMMON = [(["secretsmanager:GetSecretValue"], [ARN["secret"]]), (["kms:Decrypt", "kms:GenerateDataKey"], [ARN["kms"]])]
API_ROLE = role("api", *COMMON,
                (["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query", "dynamodb:GetItem"], [ARN["attempts"]]),
                (["s3:PutObject"], [ARN["subs_bucket"]]),
                (["sqs:SendMessage"], [ARN["marking"], ARN["notify"]]))
MARKER_ROLE = role("marker", *COMMON, (["dynamodb:Query", "dynamodb:GetItem"], [ARN["attempts"]]),
                   (["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], [ARN["marking"]]))
NOTIFIER_ROLE = role("notifier", *COMMON, (["dynamodb:PutItem"], [ARN["submissions"]]),
                     (["s3:GetObject", "s3:GetObjectAttributes"], [ARN["subs_bucket"]]),
                     (["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], [ARN["uploads"], ARN["notify"]]),
                     (["ses:SendEmail"], ["*"]))
REGIONAL = "Multi-AZ"

# ---------------------------------------------------------------- boundaries
box("box-region", "region", "AWS Region us-east-1", 380, 220, 1330, 1000, -4)
box("box-vpc", "vpc", "VPC 10.20.0.0/16", 420, 300, 820, 880, -3, cidr="10.20.0.0/16")
box("box-az-a", "az", "Availability Zone us-east-1a", 440, 340, 380, 820, -2)
box("box-az-b", "az", "Availability Zone us-east-1b", 840, 340, 380, 820, -2)
for az, x in (("a", 460), ("b", 860)):
    i = 0 if az == "a" else 1
    box(f"box-pub-{az}", "public_subnet", f"Public subnet {az.upper()} 10.20.{i}.0/24", x, 380, 340, 170, 0,
        cidr=f"10.20.{i}.0/24")
    box(f"box-app-{az}", "private_subnet", f"Private app subnet {az.upper()} 10.20.{16 * (i + 1)}.0/20", x, 580, 340, 330, 0,
        cidr=f"10.20.{16 * (i + 1)}.0/20")
    box(f"box-data-{az}", "private_subnet", f"Private data subnet {az.upper()} 10.20.{200 + i}.0/24", x, 940, 340, 200, 0,
        cidr=f"10.20.{200 + i}.0/24")

# ---------------------------------------------------------------- clients
svc("node-student-exam", "user", "Student (exam session)", "Client", 40, 360, EDGE, "global")
svc("node-student-upload", "user", "Student (assignment upload)", "Client", 40, 760, EDGE, "global")
svc("node-tutor", "user", "Tutor / Admin", "Client", 40, 1060, EDGE, "global")

# ---------------------------------------------------------------- edge layer (global)
svc("node-r53", "route53", "Route 53 (exams.example-university.edu)", "Networking & Content Delivery", 240, 40, EDGE, "global")
svc("node-cf", "cloudfront", "CloudFront (SPA + /api/*)", "Networking & Content Delivery", 450, 40, EDGE, "global")
svc("node-waf", "waf", "AWS WAF (CRS, bad inputs, rate limit)", "Security", 660, 40, EDGE, "global")
svc("node-apigw", "api_gateway", "API Gateway HTTP API (JWT auth)", "Networking & Content Delivery", 870, 40, REGIONAL, "global",
    replicas=2, multi=True)
svc("node-cognito", "cognito", "Cognito user pool (students/tutors/admins)", "Security", 1080, 40, REGIONAL, "global", multi=True)
svc("node-s3-web", "s3", "S3 frontend bucket (OAC)", "Storage", 450, 150, REGIONAL, "global", multi=True)
svc("node-acm", "acm", "ACM certificate (TLS 1.2+)", "Security", 240, 150, EDGE, "global")

# ---------------------------------------------------------------- VPC: per-AZ resources
svc("node-igw", "internet_gateway", "Internet Gateway", "Networking & Content Delivery", 780, 300, REGIONAL, "global", multi=True)
for az, x in (("a", 480), ("b", 880)):
    AZ = f"AZ-{az.upper()}"
    svc(f"node-nat-{az}", "nat_gateway", f"NAT gateway {az.upper()}", "Networking & Content Delivery", x + 110, 430, AZ, "public")
    svc(f"node-api-{az}", "lambda", f"api Lambda ({AZ})", "Compute", x, 610, AZ, "private",
        notes="Exam/autosave/upload API. Reserved concurrency 600, provisioned 300 in exam windows.", iamRole=API_ROLE)
    svc(f"node-marker-{az}", "lambda", f"marker Lambda ({AZ})", "Compute", x + 190, 610, AZ, "private",
        notes="Auto-marks MCQs from the marking queue.", iamRole=MARKER_ROLE)
svc("node-aurora", "aurora", "Aurora PostgreSQL writer (AZ-A)", "Databases", 560, 1000, "AZ-A", "private",
    replicas=2, multi=True, notes="Writer in us-east-1a, reader/failover target in us-east-1b; Data API; 35-day PITR.")
svc("node-aurora-reader", "aurora", "Aurora reader / failover target (AZ-B)", "Databases", 960, 1000, "AZ-B", "private",
    replicas=1, multi=True)
svc("node-vpce", "s3_gateway_endpoint", "Gateway endpoints (S3 + DynamoDB)", "Networking & Content Delivery", 700, 880, REGIONAL,
    "private", multi=True)

# ---------------------------------------------------------------- regional managed services
x0 = 1290
svc("node-ddb", "dynamodb", "DynamoDB attempts (autosave, PITR)", "Databases", x0, 560, REGIONAL, "global", multi=True, customConfig={"resourceArn": ARN["attempts"]})
svc("node-ddb-subs", "dynamodb", "DynamoDB submissions register", "Databases", x0 + 210, 560, REGIONAL, "global", multi=True, customConfig={"resourceArn": ARN["submissions"]})
svc("node-s3-subs", "s3", "S3 submissions (SSE-KMS, versioned, lifecycle 5y)", "Storage", x0, 760, REGIONAL, "global", multi=True, customConfig={"resourceArn": ARN["subs_bucket"]})
svc("node-sqs-uploads", "sqs", "SQS uploads queue (+DLQ)", "Application Integration", x0 + 210, 760, REGIONAL, "global", multi=True, customConfig={"resourceArn": ARN["uploads"]})
svc("node-sqs-marking", "sqs", "SQS marking queue (+DLQ)", "Application Integration", x0, 380, REGIONAL, "global", multi=True, customConfig={"resourceArn": ARN["marking"]})
svc("node-sqs-notify", "sqs", "SQS notify queue (+DLQ)", "Application Integration", x0 + 210, 380, REGIONAL, "global", multi=True, customConfig={"resourceArn": ARN["notify"]})
svc("node-notifier", "lambda", "notifier Lambda (regional, outside VPC)", "Compute", x0 + 420, 560, REGIONAL, "global",
    replicas=2, multi=True, notes="Only calls public AWS APIs (S3, DynamoDB, SES, RDS Data API) - no VPC, no NAT dependency.", iamRole=NOTIFIER_ROLE)
svc("node-ses", "ses", "Amazon SES (result + submission emails)", "Business Applications", x0 + 210, 960, REGIONAL, "global", multi=True)
svc("node-secrets", "secrets_manager", "Secrets Manager (DB credentials)", "Security", x0, 960, REGIONAL, "global", multi=True, customConfig={"resourceArn": ARN["secret"]})
svc("node-kms", "kms", "KMS customer key (rotation on)", "Security", x0, 1100, REGIONAL, "global", multi=True, customConfig={"resourceArn": ARN["kms"]})
svc("node-cw", "cloudwatch", "CloudWatch logs, alarms, dashboard", "Management & Governance", x0 + 210, 1100, REGIONAL, "global", multi=True)
svc("node-sns", "sns", "SNS ops alarm topic", "Application Integration", x0 + 420, 1100, REGIONAL, "global", multi=True)
svc("node-backup", "backup", "AWS Backup (35 d daily, 5 y monthly)", "Storage", x0 + 420, 960, REGIONAL, "global", multi=True)
svc("node-trail", "cloudtrail", "CloudTrail (audit)", "Management & Governance", x0 + 420, 760, REGIONAL, "global", multi=True)
svc("node-cicd", "codepipeline", "CI/CD: GitHub Actions + Terraform (OIDC)", "Developer Tools", 1080, 150, REGIONAL, "global")

# ---------------------------------------------------------------- Walkthrough 1: open exam + autosave
edge("node-student-exam", "node-r53", "DNS", 1, "1. Resolve exams domain", timeout=1000)
edge("node-r53", "node-cf", "HTTPS", 2, "2. Alias to CloudFront", kind="cached")
edge("node-cf", "node-waf", "HTTPS", 3, "3. WAF inspects request")
edge("node-waf", "node-apigw", "HTTPS", 4, "4. /api/* to HTTP API")
edge("node-apigw", "node-api-a", "HTTPS", 5, "5. Invoke (any healthy AZ)")
edge("node-apigw", "node-api-b", "HTTPS", 5, "5. Invoke (any healthy AZ)")
edge("node-api-a", "node-ddb", "HTTPS", 6, "6. PUT answers (conditional write)")
edge("node-api-b", "node-ddb", "HTTPS", 6, "6. PUT answers (conditional write)")
edge("node-apigw", "node-cognito", "HTTPS", 9, "Validate JWT", critical=False, relationship="authorization")
edge("node-cf", "node-s3-web", "HTTPS", 9, "Static SPA (OAC)", kind="cached", critical=False, traversal="dependency")
for az in "ab":
    edge(f"node-api-{az}", "node-aurora", "SQL", 9, "Read exam + questions (Data API)", traversal="dependency")
    edge(f"node-api-{az}", "node-sqs-marking", "HTTPS", 9, "Submit -> marking", kind="asynchronous", critical=False, traversal="dependency")

# ---------------------------------------------------------------- Auto-marking (continues walkthrough 1)
edge("node-sqs-marking", "node-marker-a", "Message", 1, "Poll batch of 10", kind="asynchronous")
edge("node-sqs-marking", "node-marker-b", "Message", 1, "Poll batch of 10", kind="asynchronous")
edge("node-marker-a", "node-aurora", "SQL", 2, "Write MCQ result")
edge("node-marker-b", "node-aurora", "SQL", 2, "Write MCQ result")
edge("node-aurora", "node-aurora-reader", "SQL", 9, "Storage replication across AZs", kind="asynchronous", critical=False,
     traversal="dependency")

# ---------------------------------------------------------------- Walkthrough 2: 40 MB upload + tutor notified
edge("node-student-upload", "node-s3-subs", "HTTPS", 1, "1. PUT 40 MB to presigned URL", timeout=60000)
edge("node-s3-subs", "node-sqs-uploads", "HTTPS", 2, "2. ObjectCreated event", kind="event")
edge("node-sqs-uploads", "node-notifier", "Message", 3, "3. Poll event", kind="asynchronous")
edge("node-notifier", "node-ddb-subs", "HTTPS", 4, "4. Record submission (PutItem)", action="dynamodb:PutItem")
# The lab has no Lambda->SES connection contract ("behavior not modeled"), so the email is a drawn
# dependency here; the real SES send is demonstrated on Floci (scripts/walkthrough-2-upload-notify.sh).
edge("node-notifier", "node-ses", "HTTPS", 9, "5. Email tutor (SES SendEmail)", traversal="dependency")
for az in "ab":
    edge(f"node-api-{az}", "node-s3-subs", "HTTPS", 9, "Presign PUT (POST /uploads)", critical=False, traversal="dependency")

# ---------------------------------------------------------------- Results release + supporting edges
edge("node-tutor", "node-r53", "DNS", 1, "Tutor/admin console", timeout=1000)
edge("node-sqs-notify", "node-notifier", "Message", 1, "Result emails", kind="asynchronous", critical=False, traversal="dependency")
for az in "ab":
    edge(f"node-api-{az}", "node-secrets", "HTTPS", 9, "DB secret", critical=False, traversal="dependency")
    edge(f"node-api-{az}", "node-nat-{az}".format(az=az), "HTTPS", 9, "Egress (same-AZ NAT)", critical=False, traversal="dependency")
    edge(f"node-nat-{az}", "node-igw", "HTTPS", 9, "To Internet", critical=False, traversal="dependency")
edge("node-api-a", "node-vpce", "HTTPS", 9, "Private route to S3/DynamoDB", critical=False, traversal="dependency")
edge("node-api-b", "node-vpce", "HTTPS", 9, "Private route to S3/DynamoDB", critical=False, traversal="dependency")
edge("node-s3-subs", "node-kms", "HTTPS", 9, "SSE-KMS", critical=False, traversal="dependency")
edge("node-aurora", "node-kms", "HTTPS", 9, "Storage encryption", critical=False, traversal="dependency")
edge("node-cw", "node-sns", "HTTPS", 9, "Alarm -> ops email", kind="asynchronous", critical=False, traversal="dependency")
edge("node-backup", "node-aurora", "HTTPS", 9, "Backup plan", kind="asynchronous", critical=False, traversal="dependency")
edge("node-cicd", "node-apigw", "HTTPS", 9, "terraform apply on push to main", kind="asynchronous", critical=False,
     traversal="dependency")

reference = {
    "id": "dso303-a2-online-exams",
    "name": "DSO303 A2 - Online Exams & Submissions Platform",
    "category": "High Availability",
    "difficulty": "Advanced",
    "description": ("Two-AZ serverless exam platform: Route 53 -> CloudFront + WAF -> API Gateway (Cognito JWT) -> "
                    "Lambda in private subnets of both AZs -> DynamoDB autosave and Aurora PostgreSQL (writer AZ-A, reader AZ-B); "
                    "presigned S3 uploads with lifecycle, SQS-driven marking and notifications, SES email."),
    "learningOutcome": ("Exam peak absorbed by API Gateway, Lambda concurrency and on-demand DynamoDB; losing one AZ removes "
                        "only that AZ's Lambda ENIs, NAT gateway and Aurora writer, which fails over to AZ-B."),
    "nodes": nodes,
    "edges": edges,
    "scenario": {"id": "w1", "name": "Walkthrough 1 - open exam and autosave", "method": "PUT",
                 "path": "/api/attempts/{attemptId}/answers", "startNodeId": "node-student-exam", "trafficLevel": "high"},
}

OUT.write_text(json.dumps(reference, indent=2) + "\n")
print(f"wrote {OUT} ({len(nodes)} nodes, {len(edges)} edges)")

# The lab's Send Request starts at the loaded reference's scenario.startNodeId, so each
# walkthrough is also published as its own reference (same diagram, different request).
VARIANTS = [
    ("w1-autosave", "W1a open exam + autosave", "PUT", "/api/attempts/{id}/answers", "node-student-exam", "high"),
    ("w1-marking", "W1c auto-marking (marker -> Aurora)", "POST", "/internal/mark", "node-marker-a", "high"),
    ("w1-marking-azb", "W1c auto-marking from AZ-B (AZ-A outage)", "POST", "/internal/mark", "node-marker-b", "high"),
    ("w2-upload", "W2a 40 MB upload to S3", "PUT", "/submissions/DSO303/A2/report.pdf", "node-student-upload", "high"),
    ("w2-notify", "W2b notifier records submission for tutor", "POST", "/internal/notify", "node-notifier", "normal"),
]
for vid, vname, method, path, start, load in VARIANTS:
    v = dict(reference, id=f"dso303-a2-{vid}", name=f"DSO303 A2 - {vname}",
             scenario={"id": vid, "name": vname, "method": method, "path": path, "startNodeId": start, "trafficLevel": load})
    target = OUT.with_name(f"exam-platform.{vid}.reference.json")
    target.write_text(json.dumps(v, indent=2) + "\n")
    print(f"wrote {target.name}")
