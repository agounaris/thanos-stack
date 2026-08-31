# Protecting the stack from bad metrics

Cardinality explosions and oversized labels are how a metrics stack falls over:
one bad deploy adds a `user_id` or `request_id` label and Receive/Store OOM.
Thanos gives you **four enforcement points**. Use them in order — the earliest
one that can stop a problem is the cheapest.

```
 target ──①──▶ collector ──②──▶ [③ proxy] ──▶ receive-router ──④──▶ ingester
        scrape limits   remote_write        (optional)        relabel + request
                        relabel                                limits
```

| # | Where | Can enforce | Cannot |
|---|---|---|---|
| ① | scrape config (Prometheus / Alloy) | **label count**, **label name/value length**, samples per scrape, targets per job | anything about series it never scrapes |
| ② | collector `remote_write` relabel | drop/keep labels & series by regex | count labels |
| ③ | validating proxy in front of Receive | anything (parses the write request) | — (you have to build/run it) |
| ④ | Thanos Receive | request body size, series/samples **per request**, write concurrency, per-tenant head-series | **per-series label count / length** |

**Key limitation:** Thanos Receive does **not** reject a series for having >N
labels or an over-long label value (Grafana Mimir does — `max_label_names_per_series`,
`max_label_name_length`, `max_label_value_length`). In Thanos that rule lives at
**①** or **③**.

---

## ① Scrape-side limits — do this first

Every scrape job should carry:

```yaml
label_limit: 40                 # reject the scrape if any series has >40 labels
label_name_length_limit: 200    # bytes
label_value_length_limit: 2048  # bytes
sample_limit: 100000            # reject the scrape if it yields >100k samples
# per job, optionally:
target_limit: 500               # cap targets discovered for this job
```

A scrape that violates any limit is dropped **whole** and `up=0` for that target —
loud and obvious, nothing partial reaches the stack.

**With the bundled Alloy collector:**

```yaml
alloy:
  limits:
    labelLimit: 40
    labelNameLengthLimit: 200
    labelValueLengthLimit: 2048
    sampleLimit: 100000     # 0 = off
```

applied to every generated `prometheus.scrape`. For teams' own scrape configs,
require these keys in CI (see `examples/gitops-config/README.md` §6).

**With Prometheus / the Operator:** set them in `scrape_configs` or, cluster-wide
defaults, in `spec.*` of the `Prometheus` CR
(`labelLimit`, `labelNameLengthLimit`, `labelValueLengthLimit`, `sampleLimit`).

---

## ② Collector remote_write relabel

Drop known offenders before they leave the collector:

```yaml
# Alloy
prometheus.relabel "guard" {
  forward_to = [prometheus.remote_write.thanos.receiver]
  rule { action = "labeldrop", regex = "id|uuid|request_id|session_id|trace_id" }
  rule { action = "drop", source_labels = ["__name__"], regex = "apiserver_request_duration_seconds_bucket" }  // notoriously heavy
}
```

Same idea in Prometheus `write_relabel_configs`.

---

## ③ Validating proxy (hard per-series enforcement)

If you must **guarantee** "no series with >30 labels ever enters the stack"
regardless of collector, put a small service between collectors and the router
that decodes the Prometheus remote-write protobuf, checks each `TimeSeries`, and
returns `400` on violation. Options:

- a ~150-line Go service using `prometheus/prometheus/prompb` + `golang/snappy`
- an Envoy `ext_proc` filter
- Grafana Mimir's distributor in "ingest-only" mode (heavier, but it's built for this)

Point `receive.service` consumers at the proxy; the proxy forwards clean writes
to `‹release›-receive`. Not provided by this chart.

---

## ④ Thanos Receive — request limits + relabel

### Request limits  →  `receive.limitsConfig`

```yaml
receive:
  limitsConfig:
    write:
      global:
        max_concurrency: 30           # concurrent remote-write requests per pod
      default:
        request:
          size_bytes_limit: 8388608   # reject bodies > 8 MiB
          series_limit: 0             # max series in one request (0 = off)
          samples_limit: 0            # max samples in one request (0 = off)
      tenants: {}                     # same shape, per THANOS-TENANT
```

Rendered to `--receive.limits-config-file` on the router **and** ingesters.
These are **per-request** limits — a guard against pathological payloads, not a
cardinality budget.

**Active-series (head-series) limits** — `default.head_series_limit` /
per-tenant — additionally require `write.global.meta_monitoring_url` pointing at
a Prometheus/Query that can be asked for each tenant's current series count. Set
that up if you run multi-tenant and need hard per-tenant caps.

### Relabel  →  `receive.relabelConfig`

```yaml
receive:
  relabelConfig:
    - action: labeldrop
      regex: "pod_template_hash|controller_revision_hash|apps_kubernetes_io_pod_index"
    - action: drop
      source_labels: [__name__]
      regex: "go_gc_pauses_seconds_bucket|prometheus_tsdb_.*_created"
```

Rendered to `--receive.relabel-config`. Last-resort scrubbing when you can't fix
the source. Cannot count labels.

---

## Recommended defaults

| Setting | Starting value | Raise only with a reason |
|---|---|---|
| `label_limit` | 40 | some exporters legitimately hit ~30 |
| `label_name_length_limit` | 200 B | |
| `label_value_length_limit` | 2048 B | URLs/queries as label values are a smell |
| `sample_limit` per job | 100k | big cluster-agg jobs may need more |
| `receive.limitsConfig … size_bytes_limit` | 8 MiB | |
| `receive.limitsConfig … max_concurrency` | 30 per pod | |

## Watch these

| Alert | Expr sketch |
|---|---|
| Receive rejecting writes | `rate(http_requests_total{handler="receive",code=~"4..|5.."}[5m]) / rate(http_requests_total{handler="receive"}[5m]) > 0.02` |
| Ingester head series climbing | `prometheus_tsdb_head_series{...receive...}` vs a budget line |
| Scrape dropped by a limit | `up == 0 and on(instance) scrape_samples_scraped == 0`, or `scrape_sample_limit`/`scrape_body_size_bytes` exceeded series |
| Per-target cardinality | `topk(20, count by (job)( {__name__!=""} ))` |

The chart's `prometheusRule.enabled=true` ships the Receive-rejection and
compactor-halted alerts; add cardinality-budget alerts per your org.
