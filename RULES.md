# Recording & alerting rules with thanos-stack

The ruler evaluates Prometheus-format rule files against the global **Query**
view, then:

- **recording rules** → samples written to a local TSDB (`mode: statefulset`)
  and uploaded to the bucket as blocks, *or* `remote_write`n to Receive
  (`mode: stateless`).
- **alerting rules** → alerts sent to every endpoint in `ruler.alertmanagers`.

Rule files reach the ruler as **ConfigMaps** mounted at `/etc/thanos/rules/`.
A `prometheus-config-reloader` sidecar watches the mount and calls
`POST /-/reload` — no operator, no pod restart.

---

## 1. Inline rules (simplest)

Each key under `ruler.ruleFiles` becomes one ConfigMap and one file. Use file
names ending `.yaml` / `.yml`.

```yaml
# values.yaml
size: medium
objstore:
  existingSecret: thanos-objstore

ruler:
  alertmanagers:
    - dnssrv+http://_web._tcp.alertmanager-operated.monitoring.svc

  ruleFiles:
    # ---- recording rules ----
    recording-http.yaml: |
      groups:
        - name: http.rules
          interval: 30s
          rules:
            - record: job:http_requests:rate5m
              expr: sum by (job) (rate(http_requests_total[5m]))
            - record: job:http_request_errors:ratio5m
              expr: |
                sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))
                /
                sum by (job) (rate(http_requests_total[5m]))

    # ---- alerting rules ----
    alerts-availability.yaml: |
      groups:
        - name: availability.alerts
          rules:
            - alert: TargetDown
              expr: up == 0
              for: 10m
              labels:
                severity: critical
              annotations:
                summary: "{{ $labels.job }} target {{ $labels.instance }} is down"

            - alert: HighErrorRatio
              expr: job:http_request_errors:ratio5m > 0.05
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "{{ $labels.job }} error ratio {{ $value | humanizePercentage }}"
```

`helm upgrade` re-renders the ConfigMaps; the reloader picks up the change
within ~1 minute (kubelet ConfigMap sync period) and reloads the ruler.

### Templating gotcha
`{{ $labels.x }}` in annotations is **Prometheus** templating. Because Helm also
uses `{{ }}`, keep rule bodies as literal block scalars (`|`) exactly as above —
Helm does not touch the content of a `|` block. If you ever need Helm to *not*
parse something outside a block, wrap it in `{{ "{{" }}`.

---

## 2. Externally-managed rules (large / generated rule sets)

Point the ruler at ConfigMaps you create yourself (CI, jsonnet, another chart):

```yaml
ruler:
  existingRuleConfigMaps:
    - platform-alerts
    - app-team-recording-rules
```

```yaml
# platform-alerts ConfigMap — every key is mounted as a file
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-alerts
  namespace: monitoring
data:
  node.yaml: |
    groups:
      - name: node.alerts
        rules:
          - alert: NodeDiskFull
            expr: node_filesystem_avail_bytes / node_filesystem_size_bytes < 0.10
            for: 15m
            labels: { severity: critical }
  kubernetes.yaml: |
    groups:
      - name: kube.alerts
        rules:
          - alert: KubePodCrashLooping
            expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
            for: 15m
            labels: { severity: warning }
```

Inline `ruleFiles` and `existingRuleConfigMaps` can be used together.

---

## 3. ConfigMap size limits

| Limit | Value | Why |
|---|---|---|
| **Hard cap per ConfigMap** | **1 MiB (1,048,576 bytes)** | Kubernetes enforces this on ConfigMap + Secret objects (etcd value size). `helm upgrade` fails with `ConfigMap "x" is invalid: []: Too long`. |
| Practical cap per key | ~**900 KiB** | leave headroom for metadata, labels, annotations, and the `last-applied` annotation Helm/kubectl add. |
| ConfigMaps per ruler pod | dozens is fine | they are combined into one `projected` volume; each is a separate mount source. |
| Total rules across the stack | no Thanos limit | bounded by ruler CPU/RAM and eval interval. |

### If a single rule file would exceed ~900 KiB

Split its groups across multiple files/ConfigMaps:

```yaml
ruler:
  ruleFiles:
    recording-part-a.yaml: |
      groups:
        - name: aggregations.a
          rules: [ ... ]        # ~half the groups
    recording-part-b.yaml: |
      groups:
        - name: aggregations.b
          rules: [ ... ]        # the other half
```

Rules for splitting:

- **Group names must be globally unique** across every file loaded by one ruler
  instance (or shard). Duplicate group names are rejected at load time.
- Keep a full group in one file — a group is the unit of evaluation ordering
  (`record`s in a group see earlier `record`s in the same group, same tick).
- Order *between* groups is not guaranteed, so don't split a dependency chain
  across groups unless you accept a one-interval lag.

### Signs you've outgrown ConfigMaps entirely

Thousands of rules / multi-MiB total, or rules owned by many teams with
independent release cadence → move to **sharding** (below), externally-built
ConfigMaps per team, or the operator's `ThanosRuler` CRD (§6).

---

## 4. Sharding the ruler

Thanos Ruler has **no automatic rule distribution** (unlike Prometheus scrape
sharding). You partition rule *files* across shards yourself. Each shard is its
own StatefulSet/Deployment + headless Service, and **Query discovers them all**,
so results and alerts are transparent to consumers.

```yaml
ruler:
  mode: stateless          # recommended for sharded setups (see §5)
  alertmanagers:
    - dnssrv+http://_web._tcp.alertmanager-operated.monitoring.svc

  ruleFiles:
    platform-recording.yaml: | ...
    platform-alerts.yaml: | ...
    payments-recording.yaml: | ...
    payments-alerts.yaml: | ...
    search-alerts.yaml: | ...

  shards:
    - name: platform
      replicas: 2
      ruleFileKeys: [platform-recording.yaml, platform-alerts.yaml]
    - name: payments
      replicas: 2
      ruleFileKeys: [payments-recording.yaml, payments-alerts.yaml]
    - name: search
      replicas: 1
      existingRuleConfigMaps: [search-team-rules]   # per-shard external CMs also work
```

- Omit `shards` entirely → one shard named `default` with all rules.
- Each shard stamps `rule_shard="<name>"` as an external label on its output.
- `ruleFileKeys` selects a subset of `ruler.ruleFiles`; `existingRuleConfigMaps`
  at shard level overrides the top-level list for that shard.

**When to shard**

| Reason | Shard by |
|---|---|
| Total eval time per interval approaching the interval | even split by rule count |
| Team ownership / independent deploys | team |
| A few very expensive rules starving cheap ones | isolate the expensive ones |
| Blast radius (one bad rule shouldn't stop all eval) | domain |

---

## 5. High availability & `stateless` vs `statefulset`

| | `statefulset` (default) | `stateless` |
|---|---|---|
| Recording-rule results | local TSDB → uploaded as blocks | `remote_write` → Receive |
| Needs a PVC | yes | no (emptyDir) |
| Pod is disposable | no (block upload in progress) | yes |
| Scale / reshard | slow (PVC per pod, block handoff) | trivial |
| Extra moving parts | none | depends on Receive being up |

**HA within a shard:** set `replicas: 2+`. Every replica evaluates the same
rules. Query strips `ruler_replica` during dedup, so recording rules aren't
double-counted. Alertmanager dedups identical alerts from the replicas.

For sharded deployments prefer `mode: stateless` — you get HA and rebalancing
for free and never wait on block handoff. The cost is that rule results depend
on Receive being available (same as your scraped metrics already do).

---

## 5b. GitOps: label-selected rule ConfigMaps (`ruler.dynamicRules`)

Instead of listing `existingRuleConfigMaps`, discover them by label at runtime:

```yaml
ruler:
  dynamicRules:
    enabled: true
    labelSelector: "thanos-stack.io/rule=true"
    namespaces: "ALL"
```

A `k8s-sidecar` container on each ruler pod watches every ConfigMap with that
label (cluster-wide), writes their keys into `/etc/thanos/rules-dynamic/`, and
the reloader triggers `POST /-/reload`. Add/remove a ConfigMap in git → rules
change in ~1 minute, **no Helm upgrade, no pod restart**. Inline `ruleFiles` and
`existingRuleConfigMaps` still work alongside it.

Full multi-team repo layout, `build.sh`, and ArgoCD `ApplicationSet` in
[`examples/gitops-config/`](examples/gitops-config/).

## 6. Alternative: the Prometheus Operator `ThanosRuler` CRD

Use this **instead of** this chart's ruler (`ruler.enabled=false`) when you want
rules authored as `PrometheusRule` resources across namespaces and auto-aggregated
by label selector.

```yaml
# needs prometheus-operator installed (the operator only — no Prometheus)
apiVersion: monitoring.coreos.com/v1
kind: ThanosRuler
metadata:
  name: global
  namespace: monitoring
spec:
  image: quay.io/thanos/thanos:v0.42.4
  ruleSelector:
    matchLabels: { thanos-ruler: global }      # selects PrometheusRule objects
  queryEndpoints:
    - dnssrv+http://_http._tcp.thanos-thanos-stack-query-headless.monitoring.svc
  alertmanagersUrl:
    - dnssrv+http://_web._tcp.alertmanager-operated.monitoring.svc
  objectStorageConfig:
    key: objstore.yml
    name: thanos-objstore
```

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: payments
  namespace: payments
  labels: { thanos-ruler: global }
spec:
  groups:
    - name: payments.alerts
      rules:
        - alert: PaymentsHighLatency
          expr: histogram_quantile(0.99, sum by (le) (rate(payment_latency_seconds_bucket[5m]))) > 1
          for: 10m
```

Trade-off: the operator generates the config, runs the reloader, and lifts the
1 MiB limit (it shards rules across generated ConfigMaps automatically) — at the
cost of a cluster-wide operator with broad RBAC. If you already run
kube-prometheus-stack, this is low marginal cost. If not, stick with §1–§5.

---

## 7. Verifying rules

```sh
# rules loaded?
kubectl -n monitoring port-forward svc/thanos-thanos-stack-ruler-default-headless 10902:10902
curl -s localhost:10902/api/v1/rules | jq '.data.groups[].name'

# force a reload
curl -XPOST localhost:10902/-/reload

# recording-rule output visible globally?
curl -s 'http://<query-frontend>/api/v1/query?query=job:http_requests:rate5m'

# alerts firing?
curl -s localhost:10902/api/v1/alerts | jq '.data.alerts[] | {name:.labels.alertname, state}'
```

Lint before shipping:

```sh
promtool check rules myrules.yaml      # thanos rule uses Prometheus rule syntax
```
