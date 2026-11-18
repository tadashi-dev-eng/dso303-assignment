#!/usr/bin/env bash
# F3 - A submitted assignment file is deleted by mistake (tutor/admin error or a buggy script).
# Expected impact: the tutor gets 404 for that file. Versioning keeps the object under a
# delete marker, so removing the marker restores the identical bytes (RPO 0, RTO minutes).
# Lifecycle keeps noncurrent versions 30 days, so this must be noticed within 30 days.
source "$(dirname "$0")/lib.sh"
BKT="$(out submissions_bucket)"; KEY="submissions/DSO303/A3-test/lt-2700/report.pdf"
F=/tmp/f3-report.pdf

step "1. Student submission stored (5 MB PDF)"
head -c 5242880 /dev/urandom > "$F"; SUM="$(sha256sum "$F" | cut -c1-16)"
aws s3api put-object --bucket "$BKT" --key "$KEY" --body "$F" --content-type application/pdf --query VersionId --output text | sed 's/^/version: /'
echo "sha256 (first 16): $SUM"

step "2. FAILURE at $(ts): the object is deleted"
T_FAIL=$(now)
aws s3api delete-object --bucket "$BKT" --key "$KEY" --query '[DeleteMarker,VersionId]' --output text | awk '{print "delete marker created: "$1"  marker version: "$2}'
aws s3api head-object --bucket "$BKT" --key "$KEY" >/dev/null 2>&1 || echo "tutor download: 404 Not Found"

step "3. RECOVERY: list versions and remove the delete marker"
aws s3api list-object-versions --bucket "$BKT" --prefix "$KEY" \
  --query '[Versions[].[`version`,VersionId,Size], DeleteMarkers[].[`delete-marker`,VersionId,`-`]][]' --output text
MARKER="$(aws s3api list-object-versions --bucket "$BKT" --prefix "$KEY" --query 'DeleteMarkers[?IsLatest].VersionId' --output text)"
aws s3api delete-object --bucket "$BKT" --key "$KEY" --version-id "$MARKER" >/dev/null && echo "delete marker $MARKER removed"
aws s3api get-object --bucket "$BKT" --key "$KEY" /tmp/f3-restored.pdf --query ContentLength --output text | sed 's/^/restored: /; s/$/ bytes/'
R="$(sha256sum /tmp/f3-restored.pdf | cut -c1-16)"
echo "sha256 (first 16): $R  $([[ "$R" == "$SUM" ]] && echo 'IDENTICAL')"
echo "RPO: 0 bytes lost. RTO: $(( $(now) - T_FAIL ))s from deletion to restored file (target 3600s)"
