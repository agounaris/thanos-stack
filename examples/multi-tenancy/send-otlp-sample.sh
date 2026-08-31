#!/usr/bin/env bash
# Send ONE OTLP metric sample to the bundled Alloy, tagged with a tenant.
# No tooling beyond curl. Receive splits it into that tenant's TSDB.
#
#   kubectl -n default port-forward svc/thanos-stack-alloy 4318:4318 &
#   ./send-otlp-sample.sh acme my_metric 42
#   ./send-otlp-sample.sh globex queue_depth 7
#
# Verify:
#   kubectl -n default port-forward svc/thanos-stack-query 18090:10902 &
#   curl -s -H 'THANOS-TENANT: acme' --get localhost:18090/api/v1/query \
#     --data-urlencode 'query=my_metric'
set -eu
TENANT=${1:?tenant}; METRIC=${2:-manual_sample}; VALUE=${3:-1}
ENDPOINT=${OTLP_HTTP:-http://localhost:4318}
NOW_NS=$(( $(date +%s) * 1000000000 ))

curl -sS -o /dev/null -w 'OTLP %{http_code}\n' -X POST "$ENDPOINT/v1/metrics" \
  -H 'Content-Type: application/json' -d @- <<JSON
{"resourceMetrics":[{
  "resource":{"attributes":[
    {"key":"tenant","value":{"stringValue":"$TENANT"}},
    {"key":"service.name","value":{"stringValue":"manual-test"}}
  ]},
  "scopeMetrics":[{"metrics":[{
    "name":"$METRIC",
    "gauge":{"dataPoints":[{
      "asDouble":$VALUE,
      "timeUnixNano":"$NOW_NS",
      "attributes":[{"key":"source","value":{"stringValue":"send-otlp-sample.sh"}}]
    }]}
  }]}]
}]}
JSON
