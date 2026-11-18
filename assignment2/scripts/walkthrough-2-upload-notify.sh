#!/usr/bin/env bash
# Walkthrough 2: a student uploads a 40 MB assignment straight to S3 and the tutor is notified.
source "$(dirname "$0")/common.sh"
API="$(out api_url)"; BUCKET="$(out submissions_bucket)"; SUBS="$(out submissions_table)"
NOTIFIER="$(tf output -json lambda_functions | python3 -c 'import json,sys;print(json.load(sys.stdin)["notifier"])')"
STU="${STU:-0001}"
H=(-H "x-demo-user: stu-$STU" -H "x-demo-groups: students" -H "content-type: application/json")
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FILE="$WORK/A2-report-stu-$STU.pdf"

step "1. Student's 40 MB PDF"
{ printf '%%PDF-1.7\n'; head -c $((40*1024*1024 - 9)) /dev/urandom; } > "$FILE"
ls -l "$FILE" | awk '{print $5" bytes  "$9}'
SIZE=$(stat -c %s "$FILE")

step "2. Upload rules enforced before any bytes move"
printf '60 MB zip  -> '; curl -sS -X POST "${H[@]}" "$API/uploads" -d '{"courseId":"DSO303","assignmentId":"A2","fileName":"big.zip","size":62914560}'; echo
printf '.exe file  -> '; curl -sS -X POST "${H[@]}" "$API/uploads" -d '{"courseId":"DSO303","assignmentId":"A2","fileName":"setup.exe","size":1024}'; echo

step "3. POST /uploads -> presigned S3 PUT URL (size + content-type are signed)"
PRESIGN="$(curl -sS -X POST "${H[@]}" "$API/uploads" -d "{\"courseId\":\"DSO303\",\"assignmentId\":\"A2\",\"fileName\":\"$(basename "$FILE")\",\"size\":$SIZE}")"
URL="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["uploadUrl"])' "$PRESIGN")"
KEY="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["key"])' "$PRESIGN")"
echo "key:     $KEY"
echo "url:     ${URL%%\?*}?X-Amz-Algorithm=...&X-Amz-Expires=900&X-Amz-Signature=..."

step "4. Browser PUTs the file directly to S3 (API Lambda never sees the 40 MB)"
# Inside Floci the URL host is the emulator's container name; map it to localhost for this shell.
CONNECT=(); [[ "$ENV" == "floci" ]] && CONNECT=(--connect-to floci:4566:localhost:4566)
curl -sS "${CONNECT[@]}" -X PUT -T "$FILE" -H "content-type: application/pdf" "$URL" \
  -o /dev/null -w "HTTP %{http_code}  uploaded %{size_upload} bytes in %{time_total}s\n"
aws s3api head-object --bucket "$BUCKET" --key "$KEY" \
  --query '{Size:ContentLength,Type:ContentType,VersionId:VersionId}' --output table

step "5. S3 ObjectCreated -> SQS uploads queue -> notifier Lambda -> DynamoDB + SES email to tutor"
for i in $(seq 1 20); do
  N="$(aws dynamodb scan --table-name "$SUBS" --filter-expression '#k = :k' --expression-attribute-names '{"#k":"key"}' \
      --expression-attribute-values "{\":k\":{\"S\":\"$KEY\"}}" --query Count --output text)"
  [[ "$N" == "1" ]] && break; sleep 3
done
aws logs filter-log-events --log-group-name "/aws/lambda/$NOTIFIER" --filter-pattern "submission-recorded" \
  --query 'events[].message' --output text | grep -o '{.*}' | grep "$(basename "$KEY" | cut -c1-36)" | tail -1 | python3 -m json.tool

if [[ "$ENV" == "floci" ]]; then
  echo "Tutor's inbox (Floci SES mailbox):"
  curl -sS "$AWS_ENDPOINT_URL/_aws/ses" | python3 -c '
import json, sys
m = [x for x in json.load(sys.stdin)["messages"] if "New submission" in x["Subject"]][-1]
print("  To:     ", ", ".join(m["Destination"]["ToAddresses"]))
print("  From:   ", m["Source"])
print("  Subject:", m["Subject"])
print("  Body:   ", m["Body"]["text_part"])'
fi

step "6. Tutor view: GET /courses/DSO303/submissions"
curl -sS -H "x-demo-user: tut-0001" -H "x-demo-groups: tutors" "$API/courses/DSO303/submissions" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("submissions:", d["count"])
for s in d["submissions"]:
    print("  %-9s %-28s %5.1f MB  %s" % (s["studentId"], s["fileName"], s["sizeBytes"] / 1048576, s["receivedAt"]))'
echo "Student calling the tutor-only route:"
curl -sS "${H[@]}" "$API/courses/DSO303/submissions"; echo

step "7. Bucket controls: default encryption + lifecycle"
aws s3api get-bucket-encryption --bucket "$BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text | sed 's/^/default encryption: /'
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --query 'sort_by(Rules[0].Transitions, &Days)[].[Days,StorageClass]' --output text \
  | awk '{printf "  after %4s days -> %s\n", $1, $2}'
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --query 'Rules[0].Expiration.Days' --output text | sed 's/^/  expire after /; s/$/ days (5 years + 30-day grace)/'
