#!/usr/bin/env python3
"""Draws architecture/diagram.svg - the revised, cost-optimized Assignment 3 architecture.

Red hexagon badges S1..S9 mark every single point of failure (legend: removed / accepted).
Green tags C1..C9 mark the changes against Assignment 2 (see change-log.md).
PNG: google-chrome --headless --screenshot=diagram.png --window-size=1700,1290 diagram.svg
"""
from pathlib import Path

W, H = 1700, 1290
out = []
add = out.append
COL = {"edge": "#8C4FFF", "compute": "#ED7100", "db": "#C925D1", "storage": "#7AA116", "int": "#E7157B",
       "sec": "#DD344C", "net": "#8C4FFF", "mgmt": "#E7157B", "user": "#232F3E"}
FLOW, GREY, RED, GREEN, AMBER = "#1565C0", "#6e7781", "#C62828", "#2E7D32", "#B26A00"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def rect(x, y, w, h, stroke, fill="none", dash=None, r=10, sw=2):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')


def text(x, y, s, size=13, weight="normal", color="#1b1f24", anchor="start"):
    add(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}">{esc(s)}</text>')


def group(x, y, w, h, label, stroke, fill, dash=None):
    rect(x, y, w, h, stroke, fill, dash)
    text(x + 12, y + 22, label, 14, "bold", stroke)


def node(x, y, label, sub, kind, w=180, h=56, ghost=False):
    c = COL[kind]
    if ghost:
        rect(x, y, w, h, "#9aa0a6", "#f6f6f6", dash="5 4", r=8, sw=1.5)
        text(x + 12, y + 22, label, 13, "bold", "#9aa0a6")
        text(x + 12, y + 40, sub, 11, color="#9aa0a6")
        add(f'<line x1="{x}" y1="{y}" x2="{x + w}" y2="{y + h}" stroke="{RED}" stroke-width="1.5" opacity="0.6"/>')
        return (x, y, w, h)
    rect(x, y, w, h, c, "#ffffff", r=8, sw=2)
    add(f'<rect x="{x}" y="{y}" width="8" height="{h}" rx="3" fill="{c}"/>')
    text(x + 16, y + 22, label, 13, "bold")
    if sub:
        text(x + 16, y + 40, sub, 11, color="#57606a")
    return (x, y, w, h)


def spof(x, y, n, color=RED):
    pts = " ".join(f"{x + 13 * dx:.0f},{y + 13 * dy:.0f}" for dx, dy in ((1, 0), (0.5, 0.87), (-0.5, 0.87), (-1, 0), (-0.5, -0.87), (0.5, -0.87)))
    add(f'<polygon points="{pts}" fill="{color}"/>')
    text(x, y + 4, f"S{n}", 10, "bold", "#fff", "middle")


def tag(x, y, s):
    w = 9 + 7.5 * len(s)
    add(f'<rect x="{x}" y="{y - 12}" width="{w}" height="17" rx="8" fill="{GREEN}"/>')
    text(x + w / 2, y + 1, s, 10.5, "bold", "#fff", "middle")


def mid(n, side):
    x, y, w, h = n
    return {"l": (x, y + h / 2), "r": (x + w, y + h / 2), "t": (x + w / 2, y), "b": (x + w / 2, y + h)}[side]


def arrow(a, b, color=FLOW, dash=None, via=None, label=None):
    pts = [a] + (via or []) + [b]
    d = " ".join(("M" if i == 0 else "L") + f"{p[0]:.0f},{p[1]:.0f}" for i, p in enumerate(pts))
    ds = f' stroke-dasharray="{dash}"' if dash else ""
    mk = "f" if color == FLOW else "g"
    add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="2"{ds} marker-end="url(#{mk})"/>')
    if label:
        (x1, y1), (x2, y2) = pts[-2], pts[-1]
        text((x1 + x2) / 2 + 4, (y1 + y2) / 2 - 5, label, 10.5, color=color)


add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Inter, Segoe UI, Helvetica, Arial, sans-serif">')
add('<defs>' + "".join(
    f'<marker id="{i}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>'
    for i, c in (("f", FLOW), ("g", GREY))) + '</defs>')
add(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
text(30, 40, "Online Exams & Submissions Platform - revised cost-optimized architecture (ap-southeast-1 Singapore, two AZs)", 22, "bold")
text(30, 64, "Blue = request path.  Grey dashed = async / supporting.  Red hexagon Sn = single point of failure (see legend).  Green Cn = change against Assignment 2.  Struck-through grey = removed.", 12.5, color="#57606a")

# --- users and edge
users = node(30, 120, "Students / tutors", "Bhutan, ~70-90 ms to SG/BOM", "user", 190)
spof(210, 120, 9, AMBER)
group(250, 90, 1420, 120, "Edge (global) - served from CloudFront edges in India", COL["edge"], "#f6f0ff", "6 4")
r53 = node(270, 130, "Route 53", "alias to CloudFront (100% SLA)", "net", 200)
cf = node(490, 130, "CloudFront", "PriceClass_200 · SPA + /api/*", "net", 210)
waf = node(720, 130, "AWS WAF (us-east-1)", "per-user 600 + per-IP 100k /5 min", "sec", 240)
tag(900, 125, "C7")
tag(840, 125, "C2")
acm = node(980, 130, "ACM (us-east-1)", "TLS certificate", "sec", 160)
s3web = node(1160, 130, "S3 frontend", "OAC, private", "storage", 150)
cog = node(1330, 130, "Cognito user pool", "8,400 MAU (free tier)", "sec", 190)
spof(1520, 130, 6, AMBER)

# --- region
rect(250, 230, 1420, 770, "#232F3E", "#fbfbfc")
text(620, 252, "AWS Region ap-southeast-1 (Singapore) - regional services below are multi-AZ by design, no subnets", 14, "bold", "#232F3E")
spof(1650, 232, 8, AMBER)
apigw = node(270, 290, "API Gateway HTTP API", "JWT authorizer · throttle 5k/2k", "net", 220)
api = node(520, 290, "Lambda api (no VPC)", "reserved 200 · exam cache 60 s", "compute", 240)
tag(700, 285, "C3")
tag(744, 285, "C8")
pc = node(520, 362, "Exam window (C4)", "PC 50 x 1 h + Aurora min 4 ACU", "compute", 240, 50)
ddb = node(800, 290, "DynamoDB attempts", "on-demand · PITR 35 d · KMS", "db", 230)
ddbs = node(800, 362, "DynamoDB submissions", "on-demand · GSI byCourse · PITR", "db", 230, 50)
s3sub = node(1070, 290, "S3 submissions", "versioned · SSE-KMS · lifecycle 5 y", "storage", 240)
sqs = node(270, 470, "SQS marking / notify / uploads", "+ 3 DLQs (5 receives)", "int", 260)
marker = node(560, 470, "Lambda marker (no VPC)", "batch 10 · reserved 50", "compute", 230)
notif = node(820, 470, "Lambda notifier (no VPC)", "uploads + result emails", "compute", 230)
ses = node(1080, 470, "Amazon SES", "result / submission email", "int", 200)
spof(1280, 470, 7, AMBER)
kms = node(1330, 290, "KMS CMK + Secrets Mgr", "rotation · 30-day deletion window", "sec", 300)
spof(1630, 290, 5, AMBER)
cw = node(1330, 362, "CloudWatch + X-Ray 1%", "EMF metrics · 9 alarms · logs 30 d", "mgmt", 300, 50)
tag(1560, 357, "C6")
bk = node(1330, 470, "AWS Backup + Budgets", "Aurora daily 35 d · all monthly 5 y", "mgmt", 300)
tag(1560, 465, "C9")

# --- VPC with data tier only
group(270, 580, 1380, 400, "VPC 10.20.0.0/16 - data tier only (no IGW, no NAT, no route out)", "#248814", "#f3faf1")
tag(820, 580, "C3")
group(290, 615, 650, 270, "AZ ap-southeast-1a · private data subnet 10.20.200.0/24", "#147EBA", "#f2f8fd", "5 4")
group(980, 615, 650, 270, "AZ ap-southeast-1b · private data subnet 10.20.201.0/24", "#147EBA", "#f2f8fd", "5 4")
w_ = node(330, 660, "Aurora writer", "Serverless v2 0.5-16 ACU · tier 0", "db", 260, 60)
r_ = node(1020, 660, "Aurora reader / failover", "Serverless v2 · promotion tier 2", "db", 260, 60)
tag(470, 655, "C1")
tag(1160, 655, "C1")
spof(590, 660, 1)
rect(330, 760, 1260, 40, "#C925D1", "#fbf0fc", r=6, sw=1.5)
text(960, 785, "Aurora cluster storage - 6 copies across 3 AZs · PITR 35 days · Data API endpoint (HTTPS, no DB connections)", 12, "bold", "#8a1a91", "middle")
spof(1595, 760, 2)
nat_a = node(620, 820, "NAT gateway A", "removed (C3) - USD 44/month", "net", 220, 50, ghost=True)
nat_b = node(1310, 820, "NAT gateway B", "removed (C3) - USD 44/month", "net", 220, 50, ghost=True)
pub = node(330, 820, "public + app subnets", "removed with the NAT gateways", "net", 260, 50, ghost=True)
text(960, 915, "Lambda functions call Aurora through the Data API and every other service through its regional endpoint,", 12, color="#57606a", anchor="middle")
text(960, 933, "so nothing zonal sits in the request path: losing an AZ costs at most one Aurora failover (S1).", 12, color="#57606a", anchor="middle")
spof(940, 820, 3)

# --- CI/CD + state
node(30, 1030, "GitHub Actions + Terraform", "OIDC role · plan/apply · smoke test", "mgmt", 300)
spof(330, 1030, 4, AMBER)
node(30, 1110, "Terraform state", "S3 versioned + DynamoDB lock (SG)", "storage", 260)

# flows
arrow(mid(users, "r"), mid(r53, "l"))
arrow(mid(r53, "r"), mid(cf, "l"))
arrow(mid(cf, "r"), mid(waf, "l"))
arrow(mid(cf, "b"), (380, 290), via=[(595, 220), (380, 220)], label="/api/*")
arrow(mid(apigw, "r"), mid(api, "l"))
arrow(mid(api, "r"), mid(ddb, "l"))
text(764, 312, "autosave", 10, color=FLOW)
arrow((760, 335), mid(w_, "t"), via=[(780, 335), (780, 640), (460, 640)])
text(786, 455, "Data API (HTTPS)", 10.5, color=FLOW)
arrow(mid(api, "l"), mid(sqs, "t"), color=GREY, dash="5 4", via=[(505, 318), (505, 450), (400, 450)])
arrow(mid(sqs, "r"), mid(marker, "l"), color=GREY, dash="5 4")
arrow(mid(s3sub, "b"), mid(sqs, "b"), color=GREY, dash="5 4", via=[(1190, 560), (400, 560)])
arrow(mid(notif, "r"), mid(ses, "l"), color=GREY, dash="5 4")
arrow(mid(w_, "r"), mid(r_, "l"), color=GREY, dash="5 4", label="failover ~30 s")
arrow(mid(users, "b"), mid(s3sub, "t"), color=FLOW, dash="2 3", via=[(125, 225), (1190, 225)])
text(1196, 280, "presigned PUT (50 MB)", 10.5, color=FLOW)

# legend: single points of failure
lx, ly = 900, 1030
rect(lx, ly, 750, 245, "#d0d7de", "#ffffff")
text(lx + 12, ly + 22, "Single points of failure", 14, "bold")
rows = [
    (1, RED, "Aurora writer instance (AZ-a)", "REMOVED: reader in AZ-b promoted automatically (F1)"),
    (2, RED, "Aurora storage volume", "REMOVED: 6 copies / 3 AZs + PITR 35 d + monthly 5 y"),
    (3, RED, "NAT gateway per AZ (Assignment 2)", "REMOVED: Lambdas out of the VPC, no NAT at all"),
    (4, AMBER, "Deploy pipeline / bad release", "ACCEPTED: rollback in 20 s (F4), no deploys in exam windows"),
    (5, AMBER, "Single KMS key and DB secret", "ACCEPTED: regional multi-AZ service, 30-day deletion window"),
    (6, AMBER, "Cognito user pool (one Region)", "ACCEPTED: regional multi-AZ; 4-h tokens outlast an exam"),
    (7, AMBER, "SES in one Region", "ACCEPTED: SQS keeps emails 4 days, DLQ + alarm"),
    (8, AMBER, "Whole Region ap-southeast-1", "ACCEPTED: not in requirements; backups allow rebuild"),
    (9, AMBER, "Campus Internet link in Bhutan", "ACCEPTED: outside AWS; answers kept in browser storage"),
]
for k, (n, c, what, how) in enumerate(rows):
    y = ly + 48 + k * 21.5
    spof(lx + 24, y - 4, n, c)
    text(lx + 44, y, what, 11.5, "bold")
    text(lx + 290, y, how, 11.5, color=GREEN if c == RED else AMBER)

# legend: changes against Assignment 2
cx, cy = 360, 1030
rect(cx, cy, 520, 245, "#d0d7de", "#ffffff")
text(cx + 12, cy + 22, "Changes against Assignment 2 (change-log.md)", 14, "bold")
for k, (c, what) in enumerate([
    ("C1", "Aurora 2 x db.r6g.large -> Serverless v2, reader tier 2"),
    ("C2", "us-east-1 -> ap-southeast-1; WAF/ACM pinned to us-east-1"),
    ("C3", "Lambdas out of VPC; NAT gateways + 4 subnets removed"),
    ("C4", "Provisioned concurrency 300 x exam day -> 50 x 1 h"),
    ("C5", "Reserved concurrency 600 -> 200 (peak need ~15)"),
    ("C6", "Logs 90 -> 30 days, X-Ray 5% -> 1%, EMF metrics"),
    ("C7", "WAF per-IP 20k -> per-user 600 + per-IP 100k"),
    ("C8", "Exam definition cached 60 s per Lambda instance"),
    ("C9", "DynamoDB daily backups dropped (PITR covers 35 d)"),
]):
    y = cy + 48 + k * 21.5
    tag(cx + 12, y, c)
    text(cx + 52, y, what, 11.5)

add("</svg>")
Path(__file__).with_name("diagram.svg").write_text("\n".join(out))
print("wrote architecture/diagram.svg")
