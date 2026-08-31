# Full deploy on Docker Desktop (single-node Kubernetes)

End-to-end: an ingress controller, object storage, the whole Thanos stack with a
bundled collector, Grafana, and — optionally — multi-tenancy and the Prometheus
Operator. Every command here was run on Docker Desktop Kubernetes `v1.34`.

**The values file this repo's examples use:** `examples/local-docker-desktop.yaml`
(the base), optionally layered with `examples/multi-tenancy/values.yaml` for the
tenant gateways / OTLP / per-tenant Grafana.

---

## 0. Prerequisites

| | |
|---|---|
| Docker Desktop | Settings → Kubernetes → **Enable Kubernetes** |
| Resources | Settings → Resources → **CPUs ≥ 6, Memory ≥ 12 GB**. The base stack + Grafana + Alloy sits around 5 GB / 3 CPU of *requests*; add the Prometheus Operator and you're near 10 GB. |
| `kubectl` | context `docker-desktop` (`kubectl config use-context docker-desktop`) |
| `helm` | ≥ 3.14 |
| `htpasswd` | only for multi-tenancy — `brew install httpd` / `apt install apache2-utils` |
| `jq` | optional, for the verify snippets |

```sh
kubectl config use-context docker-desktop
git clone <this repo> && cd thanos-helm-chart
```

## What you'll end up with

```
ingress-nginx/   ingress-nginx-controller           (LoadBalancer -> localhost:80)
default/         minio + bucket "thanos"            (S3 backend)
                 thanos-stack-receive-router  x2    (stateless ingest tier)
                 thanos-stack-receive         x2    (ingesters, RF2, PVCs)
                 thanos-stack-storegateway-{recent,historical}
                 thanos-stack-compactor       x1
                 thanos-stack-query           x2
                 thanos-stack-query-frontend  x2
                 thanos-stack-ruler-{platform,apps}  (2 shards, +reloader +k8s-sidecar)
                 thanos-stack-alloy                 (scrape + OTLP receiver)
                 grafana
```

`~24 pods`, `~5 GB` memory requests, `~3 CPU`. PVCs total ~15 GB on the
`hostpath` storageclass.

---

## 1. Ingress controller

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.watchIngressWithoutClass=true \
  --set controller.admissionWebhooks.enabled=false

kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
```

Docker Desktop maps the LoadBalancer to `localhost:80/443`.

## 2. Object storage (MinIO)

```sh
kubectl apply -f examples/minio.yaml
kubectl -n default rollout status deploy/minio
kubectl -n default wait --for=condition=complete job/minio-make-bucket --timeout=120s
```

Creates a `minio` Deployment + a `thanos` bucket. For a real bucket instead,
skip this and set `objstore.existingSecret` / `objstore.config` in your values.

## 3. Deploy the stack

### Option A — base (no multi-tenancy)

```sh
helm install thanos-stack . -n default -f examples/local-docker-desktop.yaml

kubectl -n default rollout status sts/thanos-stack-receive
kubectl -n default rollout status deploy/thanos-stack-query
```

`examples/local-docker-desktop.yaml` = `size: small` with resources shrunk to fit
a laptop, 2 store-gateway time shards, a 2-shard ruler, bundled Alloy (scrape +
OTLP), ServiceMonitors + PrometheusRule on (harmless if the operator isn't
installed — the objects just sit there), and ingress hosts
`thanos.local` / `thanos-query.local` / `thanos-ruler.local`.

### Option B — with multi-tenancy

```sh
# htpasswd: username == tenant; `shared` -> the __no_tenant__ bucket
htpasswd -bcB htpasswd infra   infra-secret
htpasswd -bB  htpasswd acme    acme-secret
htpasswd -bB  htpasswd globex  globex-secret
htpasswd -bB  htpasswd shared  shared-secret
htpasswd -bB  htpasswd nobody  nobody-secret
kubectl -n default create secret generic thanos-tenant-htpasswd --from-file=htpasswd

helm install thanos-stack . -n default \
  -f examples/local-docker-desktop.yaml \
  -f examples/multi-tenancy/values.yaml

kubectl -n default rollout status deploy/thanos-stack-tenant-gateway
kubectl -n default rollout status deploy/thanos-stack-ingest-gateway
```

This adds the `tenant-gateway` (read) and `ingest-gateway` (write) nginx
Deployments, turns on `--query.enforce-tenancy`, per-tenant Receive limits, a
per-tenant query-frontend cache, and NetworkPolicies. Full walkthrough +
test suites: **[examples/multi-tenancy/README.md](examples/multi-tenancy/README.md)**.

> With multi-tenancy on, drop the `ingress.query` host — it reaches Query
> directly, bypassing the gateway. Keep only `ingress.queryFrontend` (which the
> chart re-points at the tenant-gateway).

## 4. Hostnames + access

```sh
sudo sh -c 'echo "127.0.0.1 thanos.local thanos-query.local thanos-ruler.local grafana.local" >> /etc/hosts'
```

| URL | Backend | Auth (Option B) |
|---|---|---|
| `http://thanos.local` | query-frontend UI + API | Basic, per tenant (via tenant-gateway) |
| `http://thanos-ruler.local` | Ruler UI (rules / alerts) | none |
| `http://grafana.local` | Grafana | anonymous Admin / `admin` |
| remote-write target | `thanos-stack-receive.default.svc:19291` (A) or `thanos-stack-ingest-gateway…:19291` (B) | — / Basic |
| OTLP | `thanos-stack-alloy.default.svc:4317` (gRPC) / `:4318` (HTTP) | — |

```sh
# Option A
curl -s 'http://thanos.local/api/v1/query?query=count%20by%20(job)%20(up)'

# Option B (tenant-gateway needs Basic auth)
curl -s -u acme:acme-secret --get http://thanos.local/api/v1/query \
  --data-urlencode 'query=count by (tenant_id) (up)'
```

## 5. Grafana

```sh
# Option A — one Thanos datasource
kubectl apply -f examples/grafana.yaml

# Option B — a datasource per tenant (Basic auth through the gateway)
kubectl apply -f examples/multi-tenancy/grafana.yaml
```

`http://grafana.local` (or `kubectl -n default port-forward svc/grafana 3000:3000`).

## 6. Data

The bundled **Alloy** already scrapes kubelet / cAdvisor / kube-apiserver and the
Thanos components — you have data within a minute. To add more:

```sh
# tenant load (Option B) — agent-acme / agent-globex push through the ingest gateway
kubectl apply -f examples/multi-tenancy/tenant-load-agents.yaml

# OTLP, tenant from a resource attribute
kubectl apply -f examples/multi-tenancy/otlp-test.yaml
kubectl -n default port-forward svc/thanos-stack-alloy 4318:4318 &
examples/multi-tenancy/send-otlp-sample.sh acme my_metric 42
```

## 7. Verify

```sh
kubectl -n default get pods -l app.kubernetes.io/instance=thanos-stack

# stores discovered by Query (receive + store-gw shards + ruler shards, no errors)
kubectl -n default exec deploy/thanos-stack-query -c query -- \
  wget -qO- localhost:10902/api/v1/stores | jq '.data | keys, (.[] | length)'

# per-tenant TSDBs in Receive
kubectl -n default exec thanos-stack-receive-0 -c receive -- \
  sh -c 'wget -qO- localhost:10902/metrics' | grep 'head_series{tenant'

# recording rule output through the read path
curl -s 'http://thanos.local/api/v1/query?query=job:up:count'          # (Option A)
```

## 8. Optional: Prometheus Operator

```sh
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
  -f examples/prometheus-operator/kube-prometheus-stack-values.yaml
helm install blackbox prometheus-community/prometheus-blackbox-exporter -n monitoring
kubectl apply -f examples/prometheus-operator/crds-probe-podmonitor-scrapeconfig.yaml
```

Its Prometheus discovers the chart's ServiceMonitors / PrometheusRule and
`remoteWrite`s everything into `thanos-stack-receive`. Details:
**[examples/prometheus-operator/README.md](examples/prometheus-operator/README.md)**.

---

## Troubleshooting (things that actually bite on Docker Desktop)

| Symptom | Cause / fix |
|---|---|
| `node-exporter` `CrashLoopBackOff`, `path / is mounted on / but it is not a shared or slave mount` | Known Docker Desktop issue. The `kube-prometheus-stack` values here set `nodeExporter.enabled: false`; Alloy's kubelet/cAdvisor scrape covers node metrics anyway. |
| `thanos-stack-query` `OOMKilled` (exit 137) | Its memory limit is tight once you add the operator + lots of series. Raise `overrides.query.resources.limits.memory` in your values, or reduce load. |
| StatefulSet stuck after a bad config change (`OrderedReady` won't replace a not-Ready pod) | `kubectl -n default delete pod <sts>-0` to force recreation onto the new spec. |
| `nginx: [emerg] duplicate default map parameter` on a gateway pod | An htpasswd **username `default`** collides with nginx's `map` keyword. Use any other name (`shared`, `viewer`, …) + `gateway.auth.userToTenant`. |
| NetworkPolicies have no effect | Docker Desktop's default CNI **does not enforce NetworkPolicy**. The `tenant-isolation` / `ingest-isolation` objects render but don't block — the gateways + `--query.enforce-tenancy` still isolate correctly; the NPs matter on a real CNI (Calico, Cilium). |
| `ImagePullBackOff` on `quay.io/thanos/thanos:<x>` | Thanos tags are `v`-prefixed. `Chart.yaml` `appVersion` is `v0.42.4`; if you override `image.tag`, keep the `v`. |
| Ingress host returns 503 | The backing pods aren't Ready yet, or (Option B) you hit `thanos.local` without Basic auth → 401 is expected. |
| Memory pressure / pods `Pending` | Bump Docker Desktop memory; or deploy Option A without the operator. |

## Teardown

```sh
kubectl -n default delete -f examples/multi-tenancy/tenant-load-agents.yaml \
  -f examples/multi-tenancy/otlp-test.yaml -f examples/grafana.yaml \
  -f examples/multi-tenancy/grafana.yaml --ignore-not-found
helm uninstall thanos-stack -n default
kubectl -n default delete -f examples/minio.yaml
kubectl -n default delete pvc -l app.kubernetes.io/instance=thanos-stack
kubectl -n default delete secret thanos-tenant-htpasswd --ignore-not-found

# optional infra
helm uninstall kps blackbox -n monitoring
helm uninstall ingress-nginx -n ingress-nginx
```
