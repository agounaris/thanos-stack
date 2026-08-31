# thanos-stack

A full [Thanos](https://thanos.io) stack from a single t-shirt size. Push /
remote-write architecture: your Prometheis `remote_write` into **Thanos Receive**,
everything else reads the object-storage bucket.

Components deployed: **receive** (ingester), **store gateway** (time-sharded),
**compactor** (singleton), **query**, **query-frontend**, **ruler** (shardable).

```
 Prometheus / Alloy ─remote_write─▶  Receive ─┐
                                              ├─▶  Object Storage (S3/GCS/…)
 Ruler ──(stateless)─remote_write──▶ ─────────┘        ▲
                                                       │
 Query ◀── StoreAPI ── Receive, Store GW (per time shard), Ruler
   ▲
 Query Frontend  ◀── Grafana / users (split + cache + retry)
```

`alloy.enabled=true` bundles a Grafana Alloy collector preconfigured to scrape
the common Kubernetes endpoints and push into Receive — a self-contained way to
prove the stack works. See [Bundled Alloy collector](#bundled-alloy-collector).

## Quick start

```sh
helm install thanos ./thanos-helm-chart \
  --set size=medium \
  --set-file objstore.config=my-objstore.yaml   # or --set objstore.existingSecret=thanos-objstore
```

`my-objstore.yaml` is a standard [Thanos objstore config](https://thanos.io/tip/thanos/storage.md):

```yaml
type: S3
config:
  bucket: thanos
  endpoint: s3.eu-west-1.amazonaws.com
  region: eu-west-1
  # prefer IRSA / Workload Identity over static keys
```

Point Prometheus at Receive:

```yaml
remote_write:
  - url: http://thanos-thanos-stack-receive.monitoring.svc.cluster.local:19291/api/v1/receive
```

### Try it on a laptop

Full step-by-step (ingress controller, MinIO, the stack, Grafana, optional
multi-tenancy + Prometheus Operator, troubleshooting): **[DOCKER-DESKTOP.md](DOCKER-DESKTOP.md)**.

[`examples/local-docker-desktop.yaml`](examples/local-docker-desktop.yaml) brings
up the **whole stack** (router + 2× receive RF2, 2 store-gw time shards,
compactor, 2× query, 2× query-frontend, a 2-shard ruler, **bundled Alloy** for
data) shrunk to ~5 GB / 3 CPU. The short version:

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
  --set controller.admissionWebhooks.enabled=false

kubectl apply -f examples/minio.yaml          # or any S3/GCS bucket you have
helm install thanos-stack ./thanos-helm-chart -n default -f examples/local-docker-desktop.yaml
kubectl apply -f examples/grafana.yaml

sudo sh -c 'echo "127.0.0.1 thanos.local grafana.local" >> /etc/hosts'
curl -s 'http://thanos.local/api/v1/query?query=count%20by%20(job)%20(up)'
```

Add multi-tenancy with `-f examples/multi-tenancy/values.yaml` — see
[examples/multi-tenancy/README.md](examples/multi-tenancy/README.md).

## The only knobs you need

| Value | Meaning |
|---|---|
| `size` | `small` \| `medium` \| `large` \| `xl` \| `xxl` \| `custom` |
| `objstore.existingSecret` / `objstore.config` | the bucket (required) |
| `externalLabels` | block labels; keep unique per stack writing to the bucket |
| `retention.{raw,fiveMinutes,oneHour}` | compactor retention per resolution |
| `overrides` | deep-merged on top of the size profile for targeted tuning |

### Sizes

Profiles live in [`templates/_profiles.tpl`](templates/_profiles.tpl). They are
**starting points** — real capacity depends on series churn, replication factor
and query shape. Watch `prometheus_tsdb_head_series` on the receivers and the
receive/store memory, then bump with `overrides` or move up a size.

| size | target ingest | ~active series | receive | store-gw time shards | query | compactor |
|---|---|---|---|---|---|---|
| small  | ~17k samples/s  | ~0.5M | router 2 + 2 × 2Gi, RF2 | 1 | 2 × 1Gi | 4Gi / 50Gi |
| medium | ~35k samples/s  | ~1M   | router 2 + 3 × 4Gi, RF3 | 2 | 3 × 2Gi | 8Gi / 100Gi |
| large  | ~70k samples/s  | ~2.5M | router 3 + 4 × 8Gi, RF3 | 3 | 4 × 3Gi | 16Gi / 200Gi |
| xl     | ~120k samples/s | ~4M   | router 3 + 6 × 12Gi, RF3 | 4 | 6 × 4Gi | 24Gi / 300Gi |
| xxl    | ~170k samples/s | ~5M+  | router 4 + 8 × 16Gi, RF3 | 8 | 8 × 6Gi | 32Gi / 500Gi |

`custom`: the profile is empty — you provide everything under `overrides`.

### Targeted overrides

```yaml
size: large
overrides:
  receive:
    replicas: 6
  storeGateway:
    timeShards:
      - { name: recent, minTime: "-30d", maxTime: "" }
      - { name: deep,   minTime: "",     maxTime: "-29d" }
```

Merge semantics: **maps deep-merge, lists replace**. So overriding `timeShards`
replaces the whole list.

## Component notes

### Receive — router/distributor tier + ingesters
Ingestion is **always** two-tier: producers hit a stateless **router**
(`receive.router.replicas`) which hashring-routes each series to
`replicationFactor` **ingesters** (the StatefulSet with the TSDB). Nothing ever
writes to an ingester directly — the `…-receive` Service points at the routers;
`…-receive-headless` (ingesters) is for StoreAPI + hashring DNS only.

- `replicationFactor` — series copies across ingesters. RF2 tolerates 1 loss,
  RF3 tolerates 2; ~RF× ingester storage/memory. Change only on a fresh install
  or a planned hashring migration.
- `localRetention` — how long data stays queryable **without** the store
  gateway. Bigger = bigger ingester PVC.
- Guard rails: `receive.limitsConfig` (request size / concurrency / per-request
  series & samples) and `receive.relabelConfig` (drop bad labels/series). See
  **[PROTECTION.md](PROTECTION.md)**.

### Store gateway (time-sharded)
One StatefulSet per `storeGateway.timeShards` entry, each with `--min-time` /
`--max-time`. Empty string = open-ended. Overlap boundaries by ~1 day so a block
straddling a boundary is always served (the profiles do this). Query discovers
every shard via DNS SRV.

Very large historical sets: hash-shard *within* a time shard by adding a
`--selector.relabel-config` via `overrides` and running the shard as multiple
StatefulSets (advanced — not generated for you).

### Compactor
**Singleton per bucket + `externalLabels` set.** The chart hard-fails on
`replicas > 1` unless you set `compactor.iKnowCompactorMustBeSingleton=true`
(only correct when you also add a `--selector.relabel-config` to partition
blocks). Owns downsampling (5m, 1h) and retention.

### Query / Query Frontend
Query is stateless (optional HPA). Query Frontend splits range queries by
`splitInterval`, caches results (in-memory per size, or point at external
memcached), and retries. Put your Ingress in front of **query-frontend**.

### Ruler
See **[RULES.md](RULES.md)** for recording/alerting rule examples, ConfigMap
size limits, and sharding. For a multi-team GitOps layout (per-service rule /
scrape / alert-routing files, ArgoCD, hot reload) see
**[examples/gitops-config/](examples/gitops-config/)** and
`ruler.dynamicRules` (label-selected rule ConfigMaps synced in at runtime — no
Helm upgrade to add rules).

## Production defaults

Applied to every component, tunable in `values.yaml`:

| Concern | Default |
|---|---|
| Pod security | non-root (65534), `seccompProfile: RuntimeDefault`, `fsGroup` |
| Container security | `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, all caps dropped, writable `/tmp` emptyDir |
| SA token | `automountServiceAccountToken: false` (no component needs the API) |
| Anti-affinity | soft, per-component, `kubernetes.io/hostname` (`podAntiAffinity.type: hard` to force spread) |
| Disruption | PDB `maxUnavailable: 1` for every component with >1 replica (always for receive) |
| Probes | `startup` + `readiness` + `liveness` on `/-/ready` and `/-/healthy` (slow starters get long startup budgets) |
| Rollout | `RollingUpdate`, `Parallel` pod management for receive / store / ruler |
| Grace period | 120s for stateful components |

Also available: `nodeSelector`, `tolerations`, `affinity` (full override),
`topologySpreadConstraints`, `priorityClassName`, `extraEnv`, per-component
`extraArgs`.

### Ingress

```yaml
ingress:
  enabled: true
  className: nginx
  annotations: {}
  tls:
    - { secretName: thanos-tls, hosts: [thanos.example.com] }
  queryFrontend: { host: thanos.example.com }     # main read path
  query:         { host: "" }                      # raw Query UI (no frontend cache)
  ruler:         { host: rules.thanos.example.com }
  receive:       { host: "" }                      # remote-write — secure this one
```

Only endpoints with a non-empty `host` get an Ingress. The `receive` endpoint
accepts remote-write from anywhere it's reachable — terminate TLS and add auth
(mTLS, or an `nginx.ingress.kubernetes.io/auth-*` annotation) before exposing it.

### Bundled Alloy collector

`alloy.enabled=true` deploys a single **Grafana Alloy** pod (its own
ServiceAccount + minimal ClusterRole) that scrapes and `remote_write`s into this
release's Receive. Meant for demos, laptops, and "is ingestion working?" checks —
in production your existing Prometheus/Alloy fleet fills this role.

```yaml
alloy:
  enabled: true
  scrape:
    interval: 30s
    kubelet: true          # node /metrics            (via apiserver proxy)
    cadvisor: true         # container cpu/mem/net/fs  (via apiserver proxy)
    apiserver: true        # kube-apiserver request/latency/etcd
    kubeStateMetrics: true # only if KSM is already installed (service discovery)
    annotatedPods: true    # pods with prometheus.io/scrape=true
    thanosStack: true      # this release's own Thanos components
  extraConfig: ""          # raw Alloy syntax appended to the generated config
```

Everything it ships carries `collector="grafana-alloy"` plus your
`externalLabels`. Verified on Docker Desktop: kubelet + cadvisor + apiserver +
thanos-stack targets, ~900 distinct metric names queryable through Query within a
minute. Alloy's own UI: `kubectl -n <ns> port-forward svc/<release>-alloy 12345`.

`alloy.otlp.enabled=true` adds an **OTLP metrics receiver** (`:4317` gRPC /
`:4318` HTTP). With multi-tenancy on, the tenant is taken from an OTel resource
attribute (`alloy.otlp.tenantResourceAttribute`) and Receive splits the write
per tenant — see [MULTITENANCY.md](MULTITENANCY.md#otlp-ingest--tenant-from-a-resource-attribute).

### Observability

- `serviceMonitor.enabled=true` — one ServiceMonitor per component (needs the
  Prometheus Operator CRDs).
- `prometheusRule.enabled=true` — component-health alerts (compactor halted,
  receive rejecting writes, ruler not evaluating, store gRPC errors, …).
- `networkPolicy.enabled=true` — default-deny ingress with intra-stack traffic
  allowed; add `networkPolicy.extraIngress` selectors for your Prometheus /
  Grafana / Alertmanager.

## FAQ

### Do I need Alertmanager?
Only if you use **alerting** rules. Most clusters already run one — wire it in:

```yaml
ruler:
  alertmanagers:
    - dnssrv+http://_web._tcp.alertmanager-operated.monitoring.svc
```

The bundled `alertmanager` dependency is **off by default** on purpose; enabling
a second one just fights your existing setup.

### Do I need the Prometheus Operator for the ruler to load rules?
**No.** Thanos Ruler reads rule files from disk and reloads on `POST /-/reload`.
This chart mounts your rules from ConfigMaps and runs a `prometheus-config-reloader`
sidecar that watches them and triggers the reload. No CRDs, no operator.

You *only* need the operator if you want rules authored as `PrometheusRule`
custom resources across namespaces — then use its `ThanosRuler` CRD instead of
this chart's ruler (`ruler.enabled=false` here). Details in RULES.md.

### How do I isolate tenants?
`multiTenancy.enabled=true` turns on `--query.enforce-tenancy` (a caller only
ever sees its own `tenant_id`), per-tenant Receive limits, a per-tenant
query-frontend cache, and an nginx **tenant-gateway** (read) that authenticates callers and injects the
`THANOS-TENANT` header. `multiTenancy.ingestGateway.enabled=true` adds the
matching **ingest-gateway** in front of receive-router — Receive itself has no
tenant allowlist. The `tenants:` list is the allowlist. Full design + verified test results in
**[MULTITENANCY.md](MULTITENANCY.md)**.

### Should rules run in Thanos Ruler at all?
Evaluate where the data is. Rules that fit inside one Prometheus should run
*there* — local evaluation is more reliable (no network hop to Query). Use
Thanos Ruler for rules that genuinely need the global / cross-cluster view.

## Layout

```
Chart.yaml               # appVersion pins the Thanos image (quay.io/thanos/thanos)
values.yaml              # size + objstore + per-component defaults + hardening/ingress
values.schema.json       # enforces the size enum + required objstore
templates/
  _helpers.tpl           # names, labels, objstore wiring, StoreAPI discovery, hardening
  _profiles.tpl          # the t-shirt sizes + merge logic (thanos-stack.cfg)
  common.yaml            # ServiceAccount (no token) + objstore Secret
  ingress.yaml           # one Ingress per exposed endpoint
  servicemonitor.yaml    # per-component ServiceMonitor (opt-in)
  prometheusrule.yaml    # component-health alerts (opt-in)
  networkpolicy.yaml     # default-deny + intra-stack allow (opt-in)
  receive/               # hashring CM, ingestor STS, router Deploy (split), svc, PDB
  store-gateway/         # one STS + headless svc (+ PDB) per time shard
  compactor/             # singleton STS + headless svc (guarded against replicas>1)
  query/                 # Deploy, svc, headless svc, PDB, optional HPA
  query-frontend/        # Deploy, svc, PDB, cache CM
  receive/               # hashring CM, LIMITS CM, ingester STS, router Deploy, svcs, PDBs
  ruler/                 # rule CMs, RBAC (dynamicRules), STS/Deploy + svc (+ PDB) per shard, reloader [+ k8s-sidecar]
  alloy/                 # opt-in Grafana Alloy collector: RBAC, config CM, Deploy, svc
examples/
  local-docker-desktop.yaml  # full stack + bundled Alloy on a laptop (tested)
  minio.yaml                 # throwaway S3 backend for the above
  grafana.yaml               # Grafana + a Thanos datasource (non-multi-tenant)
  small-s3.yaml
  xl-gcs-sharded-ruler.yaml
  prometheus-operator/       # kube-prometheus-stack alongside the stack (tested)
  gitops-config/             # multi-team config repo layout + ArgoCD (draft)
  multi-tenancy/             # read + write + OTLP tenant isolation: gateways, Grafana
                             #   per tenant, test suites, manual-testing README (tested)
```

More docs: **[DOCKER-DESKTOP.md](DOCKER-DESKTOP.md)** · **[RULES.md](RULES.md)** · **[PROTECTION.md](PROTECTION.md)** ·
**[MULTITENANCY.md](MULTITENANCY.md)** · **[examples/gitops-config/README.md](examples/gitops-config/README.md)** ·
**[examples/multi-tenancy/README.md](examples/multi-tenancy/README.md)**

Runs Thanos `{{ appVersion }}` (currently `v0.42.4`); override with `image.tag`.
