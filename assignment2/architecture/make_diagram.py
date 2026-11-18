#!/usr/bin/env python3
"""Draws architecture/diagram.svg (production architecture, both walkthroughs numbered)."""
from pathlib import Path

W, H = 1700, 1240
out = []
add = out.append

COL = {
    "edge": "#8C4FFF", "compute": "#ED7100", "db": "#C925D1", "storage": "#7AA116", "int": "#E7157B",
    "sec": "#DD344C", "net": "#8C4FFF", "mgmt": "#E7157B", "dev": "#3F8624", "user": "#232F3E",
}
W1, W2 = "#1565C0", "#D84315"


def rect(x, y, w, h, stroke, fill="none", dash=None, r=10, sw=2):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')


def text(x, y, s, size=13, weight="normal", color="#1b1f24", anchor="start"):
    s = s.replace("&", "&amp;").replace("<", "&lt;")
    add(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}">{s}</text>')


def group(x, y, w, h, label, stroke, fill, dash=None):
    rect(x, y, w, h, stroke, fill, dash)
    text(x + 12, y + 22, label, 14, "bold", stroke)


def node(x, y, label, sub, kind, w=170, h=54):
    c = COL[kind]
    rect(x, y, w, h, c, "#ffffff", r=8, sw=2)
    add(f'<rect x="{x}" y="{y}" width="8" height="{h}" rx="3" fill="{c}"/>')
    text(x + 16, y + 22, label, 13, "bold")
    if sub:
        text(x + 16, y + 40, sub, 11, color="#57606a")
    return (x, y, w, h)


def mid(n, side):
    x, y, w, h = n
    return {"l": (x, y + h / 2), "r": (x + w, y + h / 2), "t": (x + w / 2, y), "b": (x + w / 2, y + h)}[side]


def arrow(a, b, color, label=None, dash=None, via=None, lpos=0.5):
    pts = [a] + (via or []) + [b]
    d = " ".join(("M" if i == 0 else "L") + f"{p[0]:.0f},{p[1]:.0f}" for i, p in enumerate(pts))
    ds = f' stroke-dasharray="{dash}"' if dash else ""
    mk = "w1" if color == W1 else "w2" if color == W2 else "g"
    add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="2.2"{ds} marker-end="url(#{mk})"/>')
    if label:
        i = max(0, min(len(pts) - 2, int((len(pts) - 1) * lpos)))
        (x1, y1), (x2, y2) = pts[i], pts[i + 1]
        cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
        add(f'<circle cx="{cx:.0f}" cy="{cy:.0f}" r="11" fill="{color}"/>')
        text(cx, cy + 4.5, label, 12, "bold", "#fff", "middle")


add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Inter, Segoe UI, Helvetica, Arial, sans-serif">')
add('<defs>' + "".join(
    f'<marker id="{i}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>'
    for i, c in (("w1", W1), ("w2", W2), ("g", "#6e7781"))) + '</defs>')
add(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
text(30, 40, "Online Exams & Submissions Platform - production architecture (us-east-1, two Availability Zones)", 22, "bold")
text(30, 64, "Blue = Walkthrough 1 (open exam, autosave every 30 s, submit, auto-mark).  Orange = Walkthrough 2 (40 MB upload, tutor notified).  Grey dashed = supporting.", 13, color="#57606a")

# --- users and edge
student = node(30, 140, "Students / Tutors", "browser (8,000 + 400)", "user", 160)
group(220, 90, 1450, 120, "Edge (global)", COL["edge"], "#f6f0ff", "6 4")
r53 = node(240, 130, "Route 53", "alias exams.example-univ…", "net")
cf = node(450, 130, "CloudFront", "SPA + /api/* · TLS 1.2", "net")
waf = node(660, 130, "AWS WAF", "CRS · bad inputs · rate", "sec")
acm = node(870, 130, "ACM", "TLS certificate", "sec", 120)
s3web = node(1010, 130, "S3 frontend", "OAC, private", "storage", 140)

# --- region
group(220, 230, 1450, 860, "AWS Region us-east-1", "#232F3E", "#fbfbfc")
apigw = node(240, 270, "API Gateway HTTP API", "JWT authorizer · throttle 5k", "net", 200)
cog = node(460, 270, "Cognito user pool", "students / tutors / admins", "sec", 190)

# VPC
group(240, 345, 860, 720, "VPC 10.20.0.0/16", "#3F8624", "#f3faf0")
for i, (ax, azn) in enumerate(((260, "us-east-1a"), (680, "us-east-1b"))):
    group(ax, 380, 400, 670, f"Availability Zone {azn}", "#147EBA", "#ffffff", "7 5")
    group(ax + 15, 415, 370, 90, f"Public subnet 10.20.{i}.0/24", "#3F8624", "#eef8ea")
    group(ax + 15, 520, 370, 250, f"Private app subnet 10.20.{16 * (i + 1)}.0/20", "#147EBA", "#eef5fb")
    group(ax + 15, 785, 370, 140, f"Private data subnet 10.20.{200 + i}.0/24", "#147EBA", "#eef5fb")
nat_a = node(450, 445, "NAT gateway A", "EIP, own route table", "net")
nat_b = node(870, 445, "NAT gateway B", "EIP, own route table", "net")
api_a = node(290, 560, "api Lambda", "ENI in AZ-a", "compute", 150)
api_b = node(710, 560, "api Lambda", "ENI in AZ-b", "compute", 150)
mk_a = node(470, 560, "marker Lambda", "ENI in AZ-a", "compute", 150)
mk_b = node(890, 560, "marker Lambda", "ENI in AZ-b", "compute", 150)
text(290, 650, "lambda-sg: egress 443 + 5432 only", 11, color="#57606a")
text(710, 650, "lambda-sg: egress 443 + 5432 only", 11, color="#57606a")
vpce = node(560, 690, "Gateway endpoints", "S3 + DynamoDB (both AZs)", "net", 200)
aur_a = node(290, 830, "Aurora PG writer", "db-sg · KMS · PITR 35 d", "db", 200)
aur_b = node(710, 830, "Aurora PG reader", "failover target", "db", 200)
arrow(mid(aur_a, "r"), mid(aur_b, "l"), "#6e7781", dash="5 4")
text(510, 822, "sync storage, 6 copies / 3 AZs", 11, color="#57606a")
text(260, 1080, "Data subnets have no route to the Internet. Each AZ's app route table uses its own NAT gateway.", 12, color="#57606a")

# regional managed services (right)
x1, x2 = 1130, 1400
ddb = node(x1, 280, "DynamoDB attempts", "on-demand · PITR · KMS", "db", 230)
sqs_m = node(x2, 280, "SQS marking + DLQ", "batch 10 → marker", "int", 240)
s3sub = node(x1, 400, "S3 submissions", "SSE-KMS · versioned · lifecycle", "storage", 230)
sqs_u = node(x2, 400, "SQS uploads + DLQ", "ObjectCreated events", "int", 240)
ddbs = node(x1, 520, "DynamoDB submissions", "GSI byCourse", "db", 230)
notif = node(x2, 520, "notifier Lambda", "outside VPC (no NAT dep.)", "compute", 240)
sqs_n = node(x2, 640, "SQS notify + DLQ", "results released", "int", 240)
ses = node(x2, 760, "Amazon SES", "email tutors / students", "int", 240)
sec = node(x1, 640, "Secrets Manager", "DB credentials", "sec", 230)
kms = node(x1, 760, "KMS CMK", "rotation on", "sec", 230)
cw = node(x1, 880, "CloudWatch", "logs · alarms · dashboard", "mgmt", 230)
sns = node(x2, 880, "SNS ops alarms", "email on-call", "int", 240)
trail = node(x1, 1000, "CloudTrail", "audit, validated", "mgmt", 230)
bak = node(x2, 1000, "AWS Backup", "35 d daily · 5 y monthly", "storage", 240)
text(x1, 395, "lifecycle: IA 30 d → Glacier IR 180 d → Deep Archive 365 d → delete 5 y", 10.5, color="#57606a")

# CI/CD
group(30, 1110, 1640, 110, "CI/CD (push to main redeploys)", COL["dev"], "#f2f8ee", "6 4")
gh = node(50, 1145, "GitHub repo", "infra/ app/ scripts/", "dev", 160)
ci = node(260, 1145, "GitHub Actions", "fmt · validate · Floci test", "dev", 200)
oidc = node(510, 1145, "IAM OIDC role", "main branch only", "sec", 180)
tf = node(740, 1145, "terraform plan → apply", "env: production", "dev", 220)
state = node(1010, 1145, "S3 state + DynamoDB lock", "versioned", "storage", 240)
arrow(mid(gh, "r"), mid(ci, "l"), "#6e7781")
arrow(mid(ci, "r"), mid(oidc, "l"), "#6e7781")
arrow(mid(oidc, "r"), mid(tf, "l"), "#6e7781")
arrow(mid(tf, "r"), mid(state, "l"), "#6e7781")
text(1270, 1170, "post-apply: DB migration Lambda", 12, color="#57606a")
text(1270, 1188, "invoke + /health smoke test", 12, color="#57606a")

# Walkthrough 1 (blue)
arrow(mid(student, "t"), mid(r53, "l"), W1, "1", via=[(110, 120), (225, 120), (225, 157)], lpos=0.3)
arrow(mid(r53, "r"), mid(cf, "l"), W1, "2")
arrow(mid(cf, "r"), mid(waf, "l"), W1, "3")
arrow(mid(waf, "b"), mid(apigw, "t"), W1, "4", via=[(745, 225), (340, 225)], lpos=0.5)
arrow(mid(apigw, "r"), mid(cog, "l"), "#6e7781", dash="5 4")
arrow((300, 324), mid(api_a, "t"), W1, "5", via=[(300, 400), (365, 400)], lpos=0.6)
arrow((400, 324), mid(api_b, "t"), W1, "5", via=[(400, 370), (785, 370)], lpos=0.6)
arrow(mid(api_a, "b"), mid(aur_a, "t"), W1, "6", via=[(365, 760), (390, 760)], lpos=0.3)
arrow(mid(api_b, "r"), mid(vpce, "r"), W1, "7", via=[(875, 610), (875, 717)], lpos=0.5)
arrow(mid(vpce, "t"), mid(ddb, "l"), W1, "7", via=[(660, 670), (1110, 670), (1110, 307)], lpos=0.6)
arrow((440, 600), mid(sqs_m, "t"), W1, "8", via=[(450, 600), (450, 520), (1115, 520), (1115, 258), (1520, 258)], lpos=0.55)
arrow(mid(sqs_m, "b"), mid(mk_b, "r"), W1, "9", via=[(1520, 360), (1095, 360), (1095, 587)], lpos=0.4)
arrow(mid(mk_b, "b"), mid(aur_b, "t"), W1, "10", via=[(965, 760), (810, 760)], lpos=0.5)
text(980, 822, "writes go to writer", 10.5, color=W1)

# Walkthrough 2 (orange)
arrow(mid(student, "b"), mid(apigw, "l"), W2, "1", via=[(80, 300)], lpos=0.5)
arrow(mid(student, "r"), mid(s3sub, "b"), W2, "2", via=[(205, 167), (205, 1100), (1245, 1100), (1245, 470)], lpos=0.45)
arrow(mid(s3sub, "r"), mid(sqs_u, "l"), W2, "3")
arrow(mid(sqs_u, "b"), mid(notif, "t"), W2, "4")
arrow(mid(notif, "l"), mid(ddbs, "r"), W2, "5")
arrow((1640, 547), mid(ses, "r"), W2, "6", via=[(1660, 547), (1660, 787)], lpos=0.5)
arrow(mid(sqs_n, "t"), mid(notif, "b"), "#6e7781", dash="5 4")
arrow(mid(cw, "r"), mid(sns, "l"), "#6e7781", dash="5 4")

# legend for walkthrough steps
lx, ly = 30, 360
rect(lx, ly, 180, 520, "#d0d7de", "#ffffff")
text(lx + 10, ly + 22, "Walkthrough 1", 13, "bold", W1)
for k, s in enumerate(["1 DNS lookup", "2 HTTPS to edge", "3 WAF inspects", "4 /api/* → HTTP API", "   (JWT checked)", "5 Lambda, any AZ",
                       "6 read exam (Data API)", "7 autosave → DynamoDB", "   via gateway endpoint", "8 submit → SQS", "9 marker polls", "10 MCQ marks → Aurora"]):
    text(lx + 10, ly + 44 + k * 18, s, 11.5)
text(lx + 10, ly + 280, "Walkthrough 2", 13, "bold", W2)
for k, s in enumerate(["1 POST /uploads →", "   presigned PUT URL", "2 browser PUTs 40 MB", "   straight to S3", "3 ObjectCreated → SQS",
                       "4 notifier polls", "5 record submission", "6 SES email to tutor"]):
    text(lx + 10, ly + 302 + k * 18, s, 11.5)

add("</svg>")
Path(__file__).with_name("diagram.svg").write_text("\n".join(out))
print("wrote architecture/diagram.svg")
