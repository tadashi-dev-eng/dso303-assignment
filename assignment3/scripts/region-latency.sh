#!/usr/bin/env bash
# Measures TCP connect (one network round trip) and TLS handshake time from this machine to
# each Region's DynamoDB endpoint, 20 samples per Region, and prints median / p90.
N=20
printf '%-16s %-38s %10s %10s %10s\n' Region Endpoint "TCP p50" "TCP p90" "TLS p50"
for R in ap-south-1 ap-south-2 ap-southeast-1 us-east-1; do
  H="dynamodb.$R.amazonaws.com"
  for i in $(seq 1 $N); do
    curl -s -o /dev/null -w '%{time_connect} %{time_appconnect}\n' --max-time 10 "https://$H/" ; sleep 0.2
  done | python3 -c '
import sys, statistics
r = [tuple(map(float, l.split())) for l in sys.stdin if l.strip()]
tcp = sorted(x[0] * 1000 for x in r); tls = sorted(x[1] * 1000 for x in r)
p = lambda a, q: a[min(len(a) - 1, int(q * len(a)))]
print(f"{sys.argv[1]:<16} {sys.argv[2]:<38} {statistics.median(tcp):8.0f}ms {p(tcp, .9):8.0f}ms {statistics.median(tls):8.0f}ms")' "$R" "$H"
done
