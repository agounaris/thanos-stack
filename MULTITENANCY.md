# Multi-tenancy

Thanos is multi-tenant on **both** paths, and this chart wires both when
`multiTenancy.enabled=true`:

```
 producer ──(mTLS cert CN=acme)──▶ ingest-gateway ─▶ receive-router ─▶ ingester
                                   nginx: CN→tenant     splits by header  stamps tenant_id=acme
                                   sets THANOS-TENANT    (overwrites client value)

 caller ──(Basic auth: acme)──▶ tenant-gateway ─▶ query-frontend ─▶ query
                                nginx: user→tenant   cache keyed     --query.enforce-tenancy
                                sets THANOS-TENANT    per tenant      injects tenant_id="acme"
```

Both gateways are the **only** components that decide a request's tenant — the
client's own `THANOS-TENANT` is always overwritten. NetworkPolicies stop anything
else reaching `receive-router` / `query` / `query-frontend`.

The tenant is a **label** (`tenant_id`, configurable). Isolation on read is real:
Thanos Query with `--query.enforce-tenancy` rewrites every request
(`query`, `query_range`, `series`, `labels`, `rules`, `alerts`) to force
`tenant_id="<header>"` — a caller asking for `up{tenant_id="other"}` gets **its
own** data back, never the other tenant's.

## What the chart configures

| Component | When `multiTenancy.enabled` |
|---|---|
| **Receive** (router + ingester) | `--receive.tenant-header`, `--receive.tenant-label-name`, `--receive.default-tenant-id`; per-tenant `request` limits merged into `receive.limitsConfig` |
| **Query** | `--query.enforce-tenancy` + tenant header/label/default |
| **Query-Frontend** | `--query-frontend.forward-header` (pass the header downstream) + `--query-frontend.tenant-header` (**partition the result cache per tenant** — without this tenant A could be served tenant B's cached response) |
| **tenant-gateway** (read) | nginx: authenticates the caller, maps identity → tenant, sets `THANOS-TENANT`, **overwrites any client value**. The query-frontend Ingress points here. |
| **ingest-gateway** (write, `multiTenancy.ingestGateway.enabled`) | nginx in front of `receive-router`: authenticates the push client, maps identity → tenant, sets `THANOS-TENANT`, **overwrites any client value**. Producers point here. See [below](#the-write-path-has-no-tenant-allowlist). |
| **NetworkPolicy** | only the read gateway (+ ruler/query) reach query / query-frontend; only the ingest gateway (+ ruler) reach receive-router — no bypass |
| **Alloy** (`alloy.tenant`) | sets `THANOS-TENANT` on its own remote_write |

## The allowlist

`multiTenancy.tenants` **is** the allowlist. An identity that authenticates but
maps to no entry gets **400** (`onMissingTenant: reject`) or falls through as
`defaultTenant` (`onMissingTenant: default`). Keep `defaultTenant` a value no
writer uses (`__no_tenant__`) so a request that slips past the gateway sees
nothing rather than a real tenant's data.

Each tenant may carry:

```yaml
tenants:
  - name: acme
    limits:                          # -> receive limits-config write.tenants.acme
      request: { series_limit: 500000, samples_limit: 5000000, size_bytes_limit: 8388608 }
      head_series_limit: 3000000     # active-series cap — needs meta-monitoring, see PROTECTION.md
```

## Auth methods (`multiTenancy.gateway.auth.method`)

| Method | How the tenant is derived | Notes |
|---|---|---|
| `basic` | htpasswd username (→ `userToTenant` map, else username == tenant) | Secret key `htpasswd`, bcrypt lines |
| `mtls` | verified client-cert CN, passed by a TLS-terminating ingress in `mtlsCNHeader` | gateway does no TLS itself |
| `none` | the inbound `THANOS-TENANT` header, checked against the allowlist | only if something in front already authenticated |

Put OIDC in front (oauth2-proxy) and use `method: none` + `trustedDirectClients`
if you'd rather not manage htpasswd.

## The write path has NO tenant allowlist

**Thanos Receive accepts any tenant.** Verified on the live stack: a producer
sending `THANOS-TENANT: rogue-corp` (never listed in `tenants:`) had a TSDB
created for it on the fly and 1 200+ series ingested; a producer sending **no**
header dumped ~54 000 series into `__no_tenant__`. In both cases the data is:

- **stored and billed** — ingester memory, PVC, object storage, compactor CPU;
- capped only by `receive.limitsConfig.write.default.*` (body size, concurrency)
  — the per-tenant `series_limit` in `tenants[].limits` only applies to *named*
  tenants;
- **orphaned on read** — no gateway identity maps to it, so it can never be
  queried through the gateway (`--query.enforce-tenancy` needs a matching
  `THANOS-TENANT`).

`multiTenancy.tenants` gates **reads** (gateway identity → tenant) and supplies
**per-tenant limits**. It does not gate writes — the ingest gateway below does.

### Enforcing an ingest allowlist

**`multiTenancy.ingestGateway.enabled=true`** deploys an nginx in front of
`receive-router` that does for writes what the tenant-gateway does for reads:
authenticate the push client, map identity → tenant, **set `THANOS-TENANT` and
overwrite any client value**, and handle an unknown identity per
`onUnauthenticated`. Producers point at `‹release›-ingest-gateway:19291`; a
NetworkPolicy (`ingestGateway.networkPolicy`) stops anything else reaching
`receive-router`.

```yaml
multiTenancy:
  ingestGateway:
    enabled: true
    onUnauthenticated: reject          # 401  (or `default` -> accept into defaultTenant)
    auth:
      method: mtls                     # verified client-cert CN is the tenant
      # method: basic  -> existingSecret: <htpasswd>, username == tenant
      # method: none   -> TRUST the inbound header (only behind an authenticating LB)
```

| `auth.method` | tenant from | no identity |
|---|---|---|
| `mtls` | verified client-cert CN (`mtlsCNHeader`, set by a TLS-terminating LB) | `onUnauthenticated` |
| `basic` | htpasswd username | always **401** (basic can't be optional — `onUnauthenticated: default` is rejected at render) |
| `none` | inbound `THANOS-TENANT`, checked vs allowlist | `onUnauthenticated` |

**Verified on the live stack:**

```
== auth ==
  PASS  no credentials -> 401
  PASS  wrong password -> 401
  PASS  valid login, no tenant mapping -> 401
== tenant attribution ==
  PASS  acme-authed push landed in tenant_id=acme
  PASS  spoofed 'THANOS-TENANT: globex' header was ignored
== onUnauthenticated: default (mtls, no client cert) ==
  PASS  push accepted (200)
  PASS  data landed in __no_tenant__, NOT the spoofed 'acme'
```

### Backstops (do these regardless)

1. **`write.default` limits** — a cap for any tenant without a specific entry:
   ```yaml
   receive:
     limitsConfig:
       write:
         default:
           request: { series_limit: 100000, samples_limit: 1000000, size_bytes_limit: 8388608 }
   ```
2. **Quarantine header-less writes** — the chart sets
   `--receive.default-tenant-id=__no_tenant__`. Give it short retention, alert on
   it, GC its blocks with `thanos tools bucket`.
3. **Alert on unexpected tenants**:
   ```
   count by (tenant_id) (prometheus_tsdb_head_series{tenant_id!~"acme|globex|infra|__no_tenant__"}) > 0
   ```

### `--receive.relabel-config` cannot filter by tenant

Tested and confirmed: a `keep` on `tenant_id` in `receive.relabelConfig` drops
**100 % of ingestion** — relabeling runs *before* Receive stamps the tenant
label, so no series matches. Do not try to enforce tenancy this way.

## OTLP ingest — tenant from a resource attribute

`alloy.otlp.enabled=true` runs an **OTLP metrics receiver** on the bundled Alloy
(`:4317` gRPC, `:4318` HTTP). Apps push OTLP; the tenant comes from an OTel
**resource attribute**, and Receive splits one connection into many tenants:

```yaml
alloy:
  tenant: infra                       # fallback for OTLP without the attribute
  otlp:
    enabled: true
    tenantResourceAttribute: tenant   # e.g. "tenant", "service.namespace", "deployment.environment"
multiTenancy:
  splitTenantLabel: __tenant__        # -> receive --receive.split-tenant-label-name
```

Pipeline: `otelcol.receiver.otlp` → `otelcol.processor.transform` copies
`resource.attributes["tenant"]` to the datapoint attribute `__tenant__` →
`otelcol.exporter.prometheus` → `prometheus.remote_write` → Receive routes each
series to the tenant named in `__tenant__` (which then takes precedence over the
`THANOS-TENANT` header), strips it, and stamps `tenant_id`.

**Verified** (`examples/multi-tenancy/otlp-test.yaml`, `telemetrygen`):

```
OTLP metric, resource attr tenant="acme"  -> queryable as acme only
   {__name__="gen", job="checkout", tenant_id="acme", collector="grafana-alloy-otlp"}
   (globex / infra / __no_tenant__ -> 0 series)
OTLP metric, no tenant attribute           -> lands in `infra` (the alloy.tenant fallback)
```

An app configured for this just sets the resource attribute, e.g.
`OTEL_RESOURCE_ATTRIBUTES=tenant=acme,service.name=checkout` and
`OTEL_EXPORTER_OTLP_ENDPOINT=http://‹release›-alloy.‹ns›:4318`.

## Per-tenant components (scale / blast-radius, optional)

Isolation does **not** need these — the label matcher handles it. Add them for
scale or to limit blast radius:

- **Ruler** — one per tenant (`ruler.shards` with a `tenant_id` external label +
  the tenant header on `--query`). Rules and alert routing are tenant-scoped.
- **Store Gateway** — shard by `tenant_id` via `--selector.relabel-config`
  (`storeGateway.extraArgs`) so a tenant's queries only touch its blocks.
- **Compactor** — a single compactor handles all tenants (external labels
  differ). Shard per-tenant only for per-tenant retention/downsampling.
- **Receive hashring** — `--receive.split-tenant-label-name` + per-tenant
  `tenants:` in the hashring config to pin a noisy tenant to dedicated ingesters.

## Try it (verified on Docker Desktop)

```sh
cd examples/multi-tenancy
htpasswd -bcB htpasswd infra infra-secret
for u in acme:acme-secret globex:globex-secret nobody:nobody-secret; do
  htpasswd -bB htpasswd "${u%%:*}" "${u##*:}"; done
kubectl -n default create secret generic thanos-tenant-htpasswd --from-file=htpasswd

helm upgrade thanos-stack ../.. -n default \
  -f ../local-docker-desktop.yaml -f values.yaml

kubectl apply -f tenant-load-agents.yaml     # agent-acme / agent-globex push with the header

# read-path isolation
kubectl -n default port-forward svc/thanos-stack-tenant-gateway  18080:10902 &
kubectl -n default port-forward svc/thanos-stack-query-frontend  18081:10902 &
./isolation-tests.sh                          # 12/12

# write-path isolation (ingest gateway)
kubectl -n default port-forward svc/thanos-stack-ingest-gateway  19291:19291 &
kubectl -n default port-forward svc/thanos-stack-query           18090:10902 &
./ingest-tests.sh                             # 6/6
```

### `isolation-tests.sh` — result (12/12)

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
  PASS  count(up): acme=15 vs globex=10 (no cache bleed)
== bypassing the gateway (no header) ==
  PASS  direct to query-frontend, no header -> 0 series
```

## Grafana

**One datasource per tenant.** All point at the **same URL** (the tenant-gateway);
they differ only by the Basic-auth credential, which is what selects the tenant.
Do not let a datasource set `THANOS-TENANT` itself — the gateway derives it from
the login and overwrites anything the client sends.

`examples/multi-tenancy/grafana.yaml` is a working two-datasource Grafana
(provisioned, anonymous Admin for the demo):

| Datasource | Basic-auth user | tenant |
|---|---|---|
| `Thanos — default` | `shared` | `__no_tenant__` (the unattributed bucket) |
| `Thanos — acme` (default) | `acme` | `acme` |

```sh
cd examples/multi-tenancy
# add `shared` + `default`-bucket wiring: values.yaml already has
#   tenants: [__no_tenant__, ...]  and  gateway.auth.userToTenant: { shared: __no_tenant__ }
htpasswd -bB htpasswd shared shared-secret
kubectl -n default create secret generic thanos-tenant-htpasswd --from-file=htpasswd \
  --dry-run=client -o yaml | kubectl apply -f -
helm upgrade thanos-stack ../.. -n default -f ../local-docker-desktop.yaml -f values.yaml

kubectl apply -f grafana.yaml
kubectl -n default port-forward svc/grafana 3000:3000      # or add grafana.local to /etc/hosts
```

**Verified through Grafana's datasource proxy:**

```
Thanos — acme    -> count by (tenant_id,env)(up)  =>  {tenant_id="acme", env="acme-prod"} 18
Thanos — default -> count by (tenant_id,env)(up)  =>  {tenant_id="__no_tenant__"} 38
acme datasource asking up{tenant_id="globex"}     =>  18 series, all tenant_id="acme"
```

Never expose the raw query-frontend to users when multi-tenancy is on — the
NetworkPolicy blocks the pod path, and don't create the `ingress.query` /
`ingress.queryFrontend`-direct hosts.
