# Multi-tenancy — manual testing

Everything needed to stand up the multi-tenant stack on a laptop and verify
tenant isolation on the **read** path, the **write** path, and the **OTLP**
path. All commands below were run against Docker Desktop Kubernetes.

- [`values.yaml`](values.yaml) — the multi-tenant overlay
- [`isolation-tests.sh`](isolation-tests.sh) — read-path suite (12 checks)
- [`ingest-tests.sh`](ingest-tests.sh) — write-path suite (6 checks)
- [`tenant-load-agents.yaml`](tenant-load-agents.yaml) — `agent-acme` / `agent-globex`, continuous data via the ingest gateway
- [`otlp-test.yaml`](otlp-test.yaml) — telemetrygen Jobs pushing OTLP tagged per tenant
- [`send-otlp-sample.sh`](send-otlp-sample.sh) — one OTLP metric, tenant of your choice
- [`grafana.yaml`](grafana.yaml) — Grafana with a datasource per tenant

Background: [`../../MULTITENANCY.md`](../../MULTITENANCY.md).

---

## 1. Setup

```sh
cd examples/multi-tenancy

# htpasswd — username == tenant name; `shared` maps to the __no_tenant__ bucket
htpasswd -bcB htpasswd infra   infra-secret
htpasswd -bB  htpasswd acme    acme-secret
htpasswd -bB  htpasswd globex  globex-secret
htpasswd -bB  htpasswd shared  shared-secret
htpasswd -bB  htpasswd nobody  nobody-secret      # valid login, mapped to NO tenant
kubectl -n default create secret generic thanos-tenant-htpasswd --from-file=htpasswd

# object storage + the stack + the multi-tenant overlay
kubectl apply -f ../minio.yaml
helm upgrade --install thanos-stack ../.. -n default \
  -f ../local-docker-desktop.yaml -f values.yaml

kubectl -n default rollout status deploy/thanos-stack-tenant-gateway
kubectl -n default rollout status deploy/thanos-stack-ingest-gateway
```

### Credentials

| htpasswd user | password | resolves to tenant |
|---|---|---|
| `infra` | `infra-secret` | `infra` (the bundled Alloy's scraped metrics) |
| `acme` | `acme-secret` | `acme` |
| `globex` | `globex-secret` | `globex` |
| `shared` | `shared-secret` | `__no_tenant__` (unattributed bucket) |
| `nobody` | `nobody-secret` | *(none)* → 400/401 |

### Port-forwards used below

```sh
kubectl -n default port-forward svc/thanos-stack-tenant-gateway  18080:10902 &   # read gateway
kubectl -n default port-forward svc/thanos-stack-query-frontend  18081:10902 &   # bypass check
kubectl -n default port-forward svc/thanos-stack-ingest-gateway  19291:19291 &   # write gateway
kubectl -n default port-forward svc/thanos-stack-query           18090:10902 &   # raw Query (any tenant via header)
kubectl -n default port-forward svc/thanos-stack-alloy           4318:4318   &   # OTLP/HTTP
```

---

## 2. Generate per-tenant data

Any one of these; the tests below need `acme` **and** `globex` to have data.

**a. Continuous, via the ingest gateway** (recommended)

```sh
kubectl apply -f tenant-load-agents.yaml
# agent-acme  -> Basic acme:acme-secret   -> tenant acme,   external_label env=acme-prod
# agent-globex-> Basic globex:globex-secret-> tenant globex, external_label env=globex-prod
```

**b. Short bursts of OTLP** (tenant from a resource attribute)

```sh
kubectl apply -f otlp-test.yaml     # 120s of metrics: tenant="acme" and tenant="globex"
```

**c. A single OTLP sample**

```sh
./send-otlp-sample.sh acme   my_metric   42
./send-otlp-sample.sh globex queue_depth 7
```

---

## 3. Read path — `tenant-gateway`

```sh
./isolation-tests.sh          # 12/12
```

<details><summary>expected output</summary>

```
== auth ==
  PASS  no credentials -> 401
  PASS  wrong password -> 401
  PASS  valid user, no tenant mapping -> 400
== visibility ==
  PASS  acme sees acme data
  PASS  acme does NOT see globex data
  PASS  globex sees globex data
  PASS  globex does NOT see acme data
== enforce-tenancy neutralises a crafted matcher ==
  PASS  acme asking for {tenant_id="globex"} gets only acme data
== unscoped query is auto-scoped to the caller ==
  PASS  acme unscoped 'up' -> ['acme']
  PASS  globex unscoped 'up' -> ['globex']
== query-frontend result cache is per-tenant ==
  PASS  count(up): acme=... vs globex=... (no cache bleed)
== bypassing the gateway (no header) ==
  PASS  direct to query-frontend, no header -> 0 series
```
</details>

### The same, by hand

```sh
GW=http://localhost:18080

# auth
curl -s -o/dev/null -w '%{http_code}\n' $GW/api/v1/query                                  # 401
curl -s -o/dev/null -w '%{http_code}\n' -u nobody:nobody-secret \
     --get $GW/api/v1/query --data-urlencode 'query=up'                                   # 400

# acme is scoped to acme — the tenant_id label proves it
curl -s -u acme:acme-secret --get $GW/api/v1/query \
     --data-urlencode 'query=count by (tenant_id) (up)'                                   # {"tenant_id":"acme"}

# acme cannot read globex, even asking explicitly
curl -s -u acme:acme-secret --get $GW/api/v1/query \
     --data-urlencode 'query=up{tenant_id="globex"}'                                      # returns tenant_id=acme series only

# the "default" bucket via the `shared` login
curl -s -u shared:shared-secret --get $GW/api/v1/query \
     --data-urlencode 'query=count by (tenant_id) (up)'                                   # {"tenant_id":"__no_tenant__"}

# bypass attempt — straight to query-frontend, no header
curl -s --get http://localhost:18081/api/v1/query --data-urlencode 'query=up'             # 0 series (__no_tenant__)
```

---

## 4. Write path — `ingest-gateway`

```sh
./ingest-tests.sh             # 6/6   (needs an agent authed as acme sending a spoof globex header)
```

### By hand

```sh
IGW=http://localhost:19291

curl -s -o/dev/null -w '%{http_code}\n' -XPOST $IGW/api/v1/receive                        # 401 (no creds)
curl -s -o/dev/null -w '%{http_code}\n' -u nobody:nobody-secret -XPOST $IGW/api/v1/receive # 401 (no tenant)
curl -s -o/dev/null -w '%{http_code}\n' -u acme:acme-secret     -XPOST $IGW/api/v1/receive # not 401 (gateway ok; Receive rejects the empty body)
```

**Attribution / anti-spoof** — point an agent at the ingest gateway with Basic
`acme` **and** a bogus `THANOS-TENANT: globex` header (see `ingest-tests.sh`), then:

```sh
Q=http://localhost:18090
curl -s -H 'THANOS-TENANT: acme'   --get $Q/api/v1/query --data-urlencode 'query=count(up{via="ingest-gateway"})'  # >0
curl -s -H 'THANOS-TENANT: globex' --get $Q/api/v1/query --data-urlencode 'query=count(up{via="ingest-gateway"})'  # 0
```

### `onUnauthenticated` modes

| `ingestGateway.onUnauthenticated` | `auth.method` | unauthenticated push |
|---|---|---|
| `reject` (default) | any | **401** |
| `default` | `mtls` / `none` | **200**, data forced into `defaultTenant` (`__no_tenant__`), spoof header ignored |
| `default` | `basic` | **render fails** — basic can't be optional |

Test `default`:

```sh
helm upgrade thanos-stack ../.. -n default -f ../local-docker-desktop.yaml -f values.yaml \
  --set multiTenancy.ingestGateway.auth.method=mtls \
  --set multiTenancy.ingestGateway.onUnauthenticated=default
# push with no client cert + a spoof 'THANOS-TENANT: acme' header:
#   -> 200, lands in __no_tenant__, NOT acme
```

---

## 5. OTLP path — tenant from a resource attribute

```sh
kubectl -n default port-forward svc/thanos-stack-alloy 4318:4318 &

./send-otlp-sample.sh acme  otlp_probe 1     # resource attr tenant="acme"
./send-otlp-sample.sh <none> otlp_probe 1    # edit the script / omit -> no tenant attr

Q=http://localhost:18090
curl -s -H 'THANOS-TENANT: acme'  --get $Q/api/v1/query --data-urlencode 'query=otlp_probe'   # present, tenant_id=acme
curl -s -H 'THANOS-TENANT: globex' --get $Q/api/v1/query --data-urlencode 'query=otlp_probe'  # empty
curl -s -H 'THANOS-TENANT: infra' --get $Q/api/v1/query --data-urlencode 'query=otlp_probe'   # metric with NO tenant attr lands here (alloy.tenant fallback)
```

Raw OTLP/HTTP without the script:

```sh
NOW_NS=$(( $(date +%s) * 1000000000 ))
curl -s -XPOST http://localhost:4318/v1/metrics -H 'Content-Type: application/json' -d '{
  "resourceMetrics": [{
    "resource": { "attributes": [
      { "key": "tenant",       "value": { "stringValue": "acme" } },
      { "key": "service.name", "value": { "stringValue": "manual-test" } } ]},
    "scopeMetrics": [{ "metrics": [{
      "name": "my_metric",
      "gauge": { "dataPoints": [{ "asDouble": 42, "timeUnixNano": "'$NOW_NS'" }] } }]}]
  }]
}'
```

An app instead of curl:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://thanos-stack-alloy.default.svc:4318
OTEL_RESOURCE_ATTRIBUTES=tenant=acme,service.name=checkout
```

---

## 6. Grafana — a datasource per tenant

```sh
kubectl apply -f grafana.yaml
kubectl -n default port-forward svc/grafana 3000:3000        # http://localhost:3000 (anonymous Admin)
```

| Datasource | Basic-auth user | Tenant |
|---|---|---|
| `Thanos — default` | `shared` | `__no_tenant__` |
| `Thanos — acme` *(default)* | `acme` | `acme` |

Both point at the **same** gateway URL — only the credential differs.

```sh
# through Grafana's datasource proxy
for uid in thanos-acme thanos-default; do
  curl -s -u admin:admin-secret -G \
    "http://localhost:3000/api/datasources/proxy/uid/$uid/api/v1/query" \
    --data-urlencode 'query=count by (tenant_id) (up)'
done
# thanos-acme    -> {"tenant_id":"acme"}
# thanos-default -> {"tenant_id":"__no_tenant__"}
```

---

## 7. Unconfigured / missing tenant

Receive has **no** write allowlist — the ingest gateway is what enforces one.
To see the raw behaviour, push straight to `receive` (bypassing the gateway):

```sh
kubectl -n default port-forward svc/thanos-stack-receive 19291:19291 &
# an agent with header 'THANOS-TENANT: rogue-corp' -> Receive creates a TSDB for it
kubectl -n default exec thanos-stack-receive-0 -c receive -- \
  sh -c 'wget -qO- localhost:10902/metrics' | grep 'head_series{tenant'
```

`rogue-corp` data is stored, billed, and unqueryable (no gateway identity). See
MULTITENANCY.md → *The write path has NO tenant allowlist* for the backstops.

---

## 8. Teardown

```sh
kubectl -n default delete -f tenant-load-agents.yaml -f otlp-test.yaml -f grafana.yaml --ignore-not-found
kubectl -n default delete job -l job-name --ignore-not-found
helm upgrade thanos-stack ../.. -n default -f ../local-docker-desktop.yaml    # drop the MT overlay
# or: helm uninstall thanos-stack -n default; kubectl delete -f ../minio.yaml
pkill -f 'port-forward.*thanos'
```
