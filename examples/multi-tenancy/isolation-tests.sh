#!/usr/bin/env bash
# Multi-tenancy isolation tests against the live thanos-stack.
set -u
GW=http://localhost:18080          # tenant-gateway (port-forwarded)
QF=http://localhost:18081          # query-frontend direct (bypass gateway)
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL  $1  --  $2"; FAIL=$((FAIL+1)); }

# query <base> <promql> [curl auth args...] -> writes /tmp/mtr, echoes http code
query(){ local base=$1 q=$2; shift 2
  curl -s -o /tmp/mtr -w '%{http_code}' "$@" --get "$base/api/v1/query" --data-urlencode "query=$q"; }
rescount(){ python3 -c 'import json;d=json.load(open("/tmp/mtr"));print(len(d["data"]["result"]) if d.get("status")=="success" else -1)' 2>/dev/null || echo -1; }
val(){ python3 -c 'import json;d=json.load(open("/tmp/mtr"));r=d["data"]["result"];print(r[0]["value"][1] if r else "")' 2>/dev/null; }
tenants(){ python3 -c 'import json;d=json.load(open("/tmp/mtr"));print(sorted(set(x["metric"].get("tenant_id","?") for x in d["data"]["result"])))' 2>/dev/null; }

echo "== auth =="
c=$(query "$GW" 'up'); [ "$c" = 401 ] && ok "no credentials -> 401" || no "no credentials -> 401" "got $c"
c=$(query "$GW" 'up' -u acme:wrong); [ "$c" = 401 ] && ok "wrong password -> 401" || no "wrong password -> 401" "got $c"
c=$(query "$GW" 'up' -u nobody:nobody-secret); [ "$c" = 400 ] && ok "valid user, no tenant mapping -> 400" || no "valid user w/o tenant -> 400" "got $c"

echo "== visibility =="
query "$GW" 'count(up{env="acme-prod"})'   -u acme:acme-secret     >/dev/null; aa=$(val)
query "$GW" 'count(up{env="globex-prod"})' -u acme:acme-secret     >/dev/null; ag=$(rescount)
query "$GW" 'count(up{env="globex-prod"})' -u globex:globex-secret >/dev/null; gg=$(val)
query "$GW" 'count(up{env="acme-prod"})'   -u globex:globex-secret >/dev/null; ga=$(rescount)
[ -n "$aa" ] && ok "acme sees acme data (count=$aa)"      || no "acme sees acme data" "empty"
[ "$ag" = 0 ] && ok "acme does NOT see globex data"       || no "acme leaked into globex" "results=$ag"
[ -n "$gg" ] && ok "globex sees globex data (count=$gg)"  || no "globex sees globex data" "empty"
[ "$ga" = 0 ] && ok "globex does NOT see acme data"       || no "globex leaked into acme" "results=$ga"

echo "== enforce-tenancy neutralises a crafted matcher =="
# acme asks for globex's data explicitly; Thanos silently rewrites tenant_id -> acme
query "$GW" 'up{tenant_id="globex",env="globex-prod"}' -u acme:acme-secret >/dev/null
t=$(tenants); n=$(rescount)
{ [ "$t" = "['acme']" ] || [ "$n" = 0 ]; } && ok "acme asking for {tenant_id=\"globex\"} gets only acme data ($t, $n series)" \
  || no "acme spoofed into globex" "tenants=$t results=$n"

echo "== unscoped query is auto-scoped to the caller =="
query "$GW" 'up' -u acme:acme-secret   >/dev/null; t=$(tenants); [ "$t" = "['acme']" ]   && ok "acme unscoped 'up' -> $t"   || no "acme unscoped" "$t"
query "$GW" 'up' -u globex:globex-secret >/dev/null; t=$(tenants); [ "$t" = "['globex']" ] && ok "globex unscoped 'up' -> $t" || no "globex unscoped" "$t"

echo "== query-frontend result cache is per-tenant =="
query "$GW" 'count(up)' -u acme:acme-secret   >/dev/null; ca=$(val)
query "$GW" 'count(up)' -u globex:globex-secret >/dev/null; cg=$(val)
{ [ -n "$ca" ] && [ -n "$cg" ] && [ "$ca" != "$cg" ]; } && ok "count(up): acme=$ca vs globex=$cg (no cache bleed)" || no "cache isolation" "acme=$ca globex=$cg"

echo "== bypassing the gateway (no header) =="
c=$(query "$QF" 'up'); n=$(rescount); t=$(tenants)
{ [ "$c" = 200 ] && [ "$n" = 0 ]; } && ok "direct to query-frontend, no header -> 0 series ($t)" || no "gateway bypass leak" "code=$c results=$n tenants=$t"

echo
echo "== $PASS passed, $FAIL failed =="
exit $FAIL
