#!/usr/bin/env bash
# Ingest-gateway tests. Assumes multiTenancy.ingestGateway.auth.method=basic
# with the thanos-tenant-htpasswd Secret (users: infra/acme/globex/nobody).
#
#   kubectl -n default port-forward svc/thanos-stack-ingest-gateway 19291:19291 &
#   kubectl -n default port-forward svc/thanos-stack-query          18090:10902 &
#   ./ingest-tests.sh
set -u
GW=http://localhost:19291
Q=http://localhost:18090
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1  --  $2"; FAIL=$((FAIL+1)); }

# minimal valid remote-write request: one sample, snappy-compressed protobuf.
# We only need the HTTP status, so a tiny hand-built body is enough for auth
# checks; for "where did it land" we rely on the running agents.
rw(){ # rw <auth-args...> -> http code
  curl -s -o /dev/null -w '%{http_code}' -XPOST "$GW/api/v1/receive" \
    -H 'Content-Type: application/x-protobuf' -H 'Content-Encoding: snappy' \
    -H 'X-Prometheus-Remote-Write-Version: 0.1.0' --data-binary '' "$@"; }

echo "== auth =="
c=$(rw);                               [ "$c" = 401 ] && ok "no credentials -> 401"            || no "no creds -> 401" "got $c"
c=$(rw -u acme:wrong);                 [ "$c" = 401 ] && ok "wrong password -> 401"            || no "wrong pw -> 401" "got $c"
c=$(rw -u nobody:nobody-secret);       [ "$c" = 401 ] && ok "valid login, no tenant -> 401"   || no "nobody -> 401" "got $c"
# acme with an empty body: gateway auth passes (200/4xx from Receive parsing, not 401)
c=$(rw -u acme:acme-secret);           [ "$c" != 401 ] && ok "acme creds accepted by gateway (Receive said $c)" || no "acme -> not 401" "got $c"

echo
echo "== tenant attribution (needs agent-viagw running, authed as acme, spoofing THANOS-TENANT: globex) =="
land(){ curl -s -H "THANOS-TENANT: $1" --get "$Q/api/v1/query" \
  --data-urlencode 'query=count(up{via="ingest-gateway"})' \
  | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(int(float(r[0]["value"][1])) if r else 0)'; }
a=$(land acme); g=$(land globex)
[ "${a:-0}" -ge 1 ] && ok "acme-authed push landed in tenant_id=acme ($a series)" || no "acme push not in acme" "acme=$a"
[ "${g:-0}" = 0 ]   && ok "spoofed 'THANOS-TENANT: globex' header was ignored (globex=$g)" || no "spoof leaked to globex" "globex=$g"

echo
echo "== $PASS passed, $FAIL failed =="
exit $FAIL
